import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'venue_hub_command_processor.dart';
import 'venue_hub_staff_sessions.dart';
import 'offline_event_ledger.dart';

class VenueHubOfflinePinException implements Exception {
  const VenueHubOfflinePinException(this.message);

  final String message;

  @override
  String toString() => 'VenueHubOfflinePinException: $message';
}

class _OfflineStaffVerifier {
  const _OfflineStaffVerifier({
    required this.staffId,
    required this.displayName,
    required this.permissions,
    required this.pinVersion,
    required this.membershipVersion,
    required this.iterations,
    required this.salt,
    required this.hash,
  });

  final String staffId;
  final String displayName;
  final Set<String> permissions;
  final int pinVersion;
  final int membershipVersion;
  final int iterations;
  final List<int> salt;
  final List<int> hash;
}

/// Verifies staff PINs only on the authoritative venue hub. Verifiers arrive
/// inside the hub-key-signed snapshot and are stored only in encrypted native
/// storage. Three failures lock that staff member locally for 15 minutes; all
/// attempts should additionally be uploaded as security audit events.
class VenueHubOfflinePinAuthority {
  VenueHubOfflinePinAuthority({
    required VenueHubStaffSessionAuthority sessions,
    required this.tenantId,
    required this.venueId,
    OfflineEventLedger? ledger,
    this.sessionLifetime = const Duration(minutes: 30),
    this.lockDuration = const Duration(minutes: 15),
  }) : _sessions = sessions,
       _ledger = ledger ?? OfflineEventLedger.instance;

  final VenueHubStaffSessionAuthority _sessions;
  final String tenantId;
  final String venueId;
  final OfflineEventLedger _ledger;
  static const _attemptSnapshotKind = 'staffPinAttempts.v1';
  final Duration sessionLifetime;
  final Duration lockDuration;
  final Map<String, _OfflineStaffVerifier> _verifiers = {};
  final Map<String, int> _failures = {};
  final Map<String, DateTime> _lockedUntil = {};
  int _catalogueVersion = 0;

  Future<void> initialize() async {
    final stored = await _ledger.readSnapshot(
      tenantId: tenantId,
      venueId: venueId,
      kind: _attemptSnapshotKind,
    );
    final value = stored?['value'];
    if (value is! Map) return;
    final failures = value['failures'];
    if (failures is Map) {
      for (final entry in failures.entries) {
        if (entry.key is String && entry.value is int) {
          _failures[entry.key as String] = entry.value as int;
        }
      }
    }
    final locks = value['lockedUntil'];
    if (locks is Map) {
      for (final entry in locks.entries) {
        final parsed = DateTime.tryParse(entry.value as String? ?? '');
        if (entry.key is String && parsed != null) {
          _lockedUntil[entry.key as String] = parsed.toUtc();
        }
      }
    }
  }

  List<({String staffId, String displayName})> get staff =>
      _verifiers.values
          .map((item) => (staffId: item.staffId, displayName: item.displayName))
          .toList(growable: false)
        ..sort((a, b) => a.displayName.compareTo(b.displayName));

  Future<void> installSnapshot(Map<String, Object?> snapshot) async {
    final version = snapshot['version'];
    final rawStaff = snapshot['staff'];
    if (version is! int || version < _catalogueVersion || rawStaff is! List) {
      throw const VenueHubOfflinePinException(
        'The offline staff snapshot is invalid or stale.',
      );
    }
    final next = <String, _OfflineStaffVerifier>{};
    for (final raw in rawStaff.whereType<Map>()) {
      final json = Map<String, Object?>.from(raw);
      final staffId = json['staffId'];
      final displayName = json['displayName'];
      final permissions = json['permissions'];
      final iterations = json['offlinePinIterations'];
      if (staffId is! String ||
          staffId.isEmpty ||
          displayName is! String ||
          permissions is! List ||
          json['offlinePinAlgorithm'] != 'PBKDF2-HMAC-SHA256' ||
          iterations is! int ||
          iterations < 200000 ||
          iterations > 2000000) {
        throw const VenueHubOfflinePinException(
          'An offline staff verifier is invalid.',
        );
      }
      try {
        final salt = base64Url.decode(json['offlinePinSalt'] as String);
        final hash = base64Url.decode(json['offlinePinHash'] as String);
        if (salt.length < 16 || hash.length != 32)
          throw const FormatException();
        next[staffId] = _OfflineStaffVerifier(
          staffId: staffId,
          displayName: displayName,
          permissions: permissions.whereType<String>().toSet(),
          pinVersion: (json['pinVersion'] as num?)?.toInt() ?? 0,
          membershipVersion: (json['membershipVersion'] as num?)?.toInt() ?? 0,
          iterations: iterations,
          salt: salt,
          hash: hash,
        );
      } on Object {
        throw const VenueHubOfflinePinException(
          'An offline staff verifier is invalid.',
        );
      }
    }
    _verifiers
      ..clear()
      ..addAll(next);
    _failures.removeWhere((staffId, _) => !next.containsKey(staffId));
    _lockedUntil.removeWhere((staffId, _) => !next.containsKey(staffId));
    _catalogueVersion = version;
    await _sessions.reconcileStaff({
      for (final verifier in next.values)
        verifier.staffId: (
          pinVersion: verifier.pinVersion,
          membershipVersion: verifier.membershipVersion,
          permissions: verifier.permissions,
        ),
    });
  }

  Future<VenueHubIssuedStaffSession> verify({
    required String staffId,
    required String pin,
    DateTime? nowUtc,
  }) async {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    final verifier = _verifiers[staffId];
    if (verifier == null || !RegExp(r'^\d{6}$').hasMatch(pin)) {
      throw const VenueHubOfflinePinException('The staff PIN is invalid.');
    }
    final lockedUntil = _lockedUntil[staffId];
    if (lockedUntil != null && lockedUntil.isAfter(now)) {
      throw VenueHubOfflinePinException(
        'This PIN is locked until ${lockedUntil.toIso8601String()}.',
      );
    }
    final key = await Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: verifier.iterations,
      bits: 256,
    ).deriveKeyFromPassword(password: pin, nonce: verifier.salt);
    final supplied = await key.extractBytes();
    if (!_constantTimeEquals(verifier.hash, supplied)) {
      final failures = (_failures[staffId] ?? 0) + 1;
      _failures[staffId] = failures;
      if (failures >= 3) {
        _lockedUntil[staffId] = now.add(lockDuration);
        _failures[staffId] = 0;
      }
      await _saveAttempts();
      throw const VenueHubOfflinePinException('The staff PIN is invalid.');
    }
    _failures.remove(staffId);
    _lockedUntil.remove(staffId);
    await _saveAttempts();
    return _sessions.issue(
      VenueHubStaffGrant(
        staffId: staffId,
        permissions: verifier.permissions,
        expiresAtUtc: now.add(sessionLifetime),
        pinVersion: verifier.pinVersion,
        membershipVersion: verifier.membershipVersion,
      ),
    );
  }

  Future<void> _saveAttempts() => _ledger.saveSnapshot(
    tenantId: tenantId,
    venueId: venueId,
    kind: _attemptSnapshotKind,
    version: DateTime.now().toUtc().microsecondsSinceEpoch,
    value: <String, Object?>{
      'failures': _failures,
      'lockedUntil': _lockedUntil.map(
        (staffId, value) => MapEntry(staffId, value.toUtc().toIso8601String()),
      ),
    },
  );

  bool _constantTimeEquals(List<int> left, List<int> right) {
    var difference = left.length ^ right.length;
    final length = left.length > right.length ? left.length : right.length;
    for (var index = 0; index < length; index++) {
      difference |=
          (index < left.length ? left[index] : 0) ^
          (index < right.length ? right[index] : 0);
    }
    return difference == 0;
  }
}
