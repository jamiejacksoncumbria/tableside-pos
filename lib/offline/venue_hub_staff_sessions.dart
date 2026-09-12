import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import '../core/trusted_clock.dart';
import 'offline_event_ledger.dart';
import 'venue_hub_command_processor.dart';

class VenueHubIssuedStaffSession {
  const VenueHubIssuedStaffSession({
    required this.sessionId,
    required this.sessionToken,
    required this.grant,
  });

  final String sessionId;
  final String sessionToken;
  final VenueHubStaffGrant grant;
}

class _StoredStaffSession {
  const _StoredStaffSession({
    required this.sessionId,
    required this.tokenHash,
    required this.grant,
  });

  final String sessionId;
  final String tokenHash;
  final VenueHubStaffGrant grant;
}

/// Hub-local short-lived staff sessions. Only a SHA-256 token digest is kept
/// in the encrypted snapshot; plaintext session tokens live on the enrolled
/// client. PIN verification must occur before [issue] is called.
class VenueHubStaffSessionAuthority {
  VenueHubStaffSessionAuthority({
    required this.tenantId,
    required this.venueId,
    OfflineEventLedger? ledger,
  }) : _ledger = ledger ?? OfflineEventLedger.instance;

  static const _snapshotKind = 'staffSessions.v1';
  final String tenantId;
  final String venueId;
  final OfflineEventLedger _ledger;
  final Map<String, _StoredStaffSession> _sessions = {};
  int _version = 1;

  Future<void> initialize() async {
    final snapshot = await _ledger.readSnapshot(
      tenantId: tenantId,
      venueId: venueId,
      kind: _snapshotKind,
    );
    final value = snapshot?['value'];
    if (value is! Map) return;
    _version = (snapshot?['version'] as int?) ?? 1;
    final rawSessions = value['sessions'];
    if (rawSessions is! List) return;
    final now = TrustedClock.instance.nowUtc();
    for (final raw in rawSessions.whereType<Map>()) {
      final json = Map<String, Object?>.from(raw);
      final id = json['sessionId'];
      final hash = json['tokenHash'];
      final staffId = json['staffId'];
      final expires = DateTime.tryParse(json['expiresAtUtc'] as String? ?? '');
      final permissions = json['permissions'];
      if (id is! String ||
          hash is! String ||
          staffId is! String ||
          expires == null ||
          !expires.toUtc().isAfter(now) ||
          permissions is! List) {
        continue;
      }
      _sessions[id] = _StoredStaffSession(
        sessionId: id,
        tokenHash: hash,
        grant: VenueHubStaffGrant(
          staffId: staffId,
          permissions: permissions.whereType<String>().toSet(),
          expiresAtUtc: expires.toUtc(),
          pinVersion: (json['pinVersion'] as num?)?.toInt() ?? 0,
          membershipVersion: (json['membershipVersion'] as num?)?.toInt() ?? 0,
          active: json['active'] == true,
        ),
      );
    }
    await _removeExpiredAndSave();
  }

  Future<VenueHubIssuedStaffSession> issue(VenueHubStaffGrant grant) async {
    if (!grant.active ||
        grant.pinVersion < 1 ||
        grant.membershipVersion < 1 ||
        !grant.expiresAtUtc.toUtc().isAfter(TrustedClock.instance.nowUtc())) {
      throw StateError('An inactive or expired staff grant cannot be issued.');
    }
    final random = Random.secure();
    final id = 'lhs_${_randomBase64(random, 18)}';
    final token = _randomBase64(random, 32);
    _sessions[id] = _StoredStaffSession(
      sessionId: id,
      tokenHash: await _hash(token),
      grant: grant,
    );
    await _save();
    return VenueHubIssuedStaffSession(
      sessionId: id,
      sessionToken: token,
      grant: grant,
    );
  }

  Future<VenueHubStaffGrant?> authorize(
    String staffId,
    String sessionId,
    String sessionToken,
  ) async {
    final session = _sessions[sessionId];
    final now = TrustedClock.instance.nowUtc();
    if (session == null ||
        session.grant.staffId != staffId ||
        !session.grant.active ||
        !session.grant.expiresAtUtc.toUtc().isAfter(now)) {
      return null;
    }
    final supplied = await _hash(sessionToken);
    return _constantTimeEquals(session.tokenHash, supplied)
        ? session.grant
        : null;
  }

  Future<void> revokeStaff(String staffId) async {
    _sessions.removeWhere((_, session) => session.grant.staffId == staffId);
    await _save();
  }

  Future<void> revokeAll() async {
    _sessions.clear();
    await _save();
  }

  /// Immediately invalidates sessions when an online snapshot retires staff,
  /// changes a PIN, membership version, role, or effective permission set.
  Future<void> reconcileStaff(
    Map<
      String,
      ({int pinVersion, int membershipVersion, Set<String> permissions})
    >
    current,
  ) async {
    final before = _sessions.length;
    _sessions.removeWhere((_, session) {
      final value = current[session.grant.staffId];
      return value == null ||
          value.pinVersion != session.grant.pinVersion ||
          value.membershipVersion != session.grant.membershipVersion ||
          !_sameSet(value.permissions, session.grant.permissions);
    });
    if (_sessions.length != before) await _save();
  }

  Future<void> _removeExpiredAndSave() async {
    final now = TrustedClock.instance.nowUtc();
    final before = _sessions.length;
    _sessions.removeWhere(
      (_, session) => !session.grant.expiresAtUtc.toUtc().isAfter(now),
    );
    if (before != _sessions.length) await _save();
  }

  Future<void> _save() async {
    _version++;
    await _ledger.saveSnapshot(
      tenantId: tenantId,
      venueId: venueId,
      kind: _snapshotKind,
      version: _version,
      value: {
        'sessions': [
          for (final session in _sessions.values)
            {
              'sessionId': session.sessionId,
              'tokenHash': session.tokenHash,
              'staffId': session.grant.staffId,
              'permissions': session.grant.permissions.toList()..sort(),
              'expiresAtUtc': session.grant.expiresAtUtc
                  .toUtc()
                  .toIso8601String(),
              'pinVersion': session.grant.pinVersion,
              'membershipVersion': session.grant.membershipVersion,
              'active': session.grant.active,
            },
        ],
      },
    );
  }

  Future<String> _hash(String token) async =>
      base64UrlEncode((await Sha256().hash(utf8.encode(token))).bytes);

  String _randomBase64(Random random, int length) =>
      base64UrlEncode(List<int>.generate(length, (_) => random.nextInt(256)));

  bool _constantTimeEquals(String left, String right) {
    final a = utf8.encode(left);
    final b = utf8.encode(right);
    var difference = a.length ^ b.length;
    final length = a.length > b.length ? a.length : b.length;
    for (var index = 0; index < length; index++) {
      difference |=
          (index < a.length ? a[index] : 0) ^ (index < b.length ? b[index] : 0);
    }
    return difference == 0;
  }

  bool _sameSet(Set<String> left, Set<String> right) =>
      left.length == right.length && left.containsAll(right);
}
