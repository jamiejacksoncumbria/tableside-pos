import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/app_logger.dart';
import '../core/tenant_scope.dart';
import '../features/pos/domain.dart';
import '../features/printing/local_printer_device_identity.dart';
import 'offline_event_ledger.dart';
import 'venue_hub_client_cache.dart';
import 'venue_hub_device_credential.dart';
import 'venue_hub_platform.dart';
import 'venue_hub_runtime.dart';

class VenueHubOfflineWorkspace {
  const VenueHubOfflineWorkspace({
    required this.scope,
    required this.profile,
    required this.venue,
  });

  final VenueScope scope;
  final TenantProfile profile;
  final Venue venue;
}

/// Restores only the designated hub's last authenticated local workspace.
///
/// This is intentionally stricter than an ordinary cache fallback. A copied
/// preferences file is insufficient: the physical device ID, OS-protected
/// Ed25519 private credential, cached cloud authority, TLS identity and
/// encrypted venue snapshot must all agree before the POS PIN screen opens.
class VenueHubOfflineWorkspaceLoader {
  VenueHubOfflineWorkspaceLoader({
    VenueHubClientCache? cache,
    OfflineEventLedger? ledger,
    LocalPrinterDeviceIdentity? identity,
    VenueHubDeviceCredentialStore? credentials,
  }) : _cache = cache ?? VenueHubClientCache(),
       _ledger = ledger ?? OfflineEventLedger.instance,
       _identity = identity ?? LocalPrinterDeviceIdentity(),
       _credentials = credentials ?? VenueHubDeviceCredentialStore();

  static const _secrets = FlutterSecureStorage();
  final VenueHubClientCache _cache;
  final OfflineEventLedger _ledger;
  final LocalPrinterDeviceIdentity _identity;
  final VenueHubDeviceCredentialStore _credentials;

  Future<VenueHubOfflineWorkspace?> load() async {
    if (kIsWeb || !canHostVenueHub) return null;
    await _ledger.initialize();
    for (final scope in await _cache.readCandidateScopes()) {
      try {
        final bootstrap = await _cache.readBootstrap(scope);
        if (bootstrap == null || !bootstrap.enabled) continue;
        final deviceId = await _identity.deviceIdForScope(scope);
        if (bootstrap.hubDeviceId != deviceId) continue;
        final credential = await _credentials.getOrCreate(
          tenantId: scope.tenantId,
          venueId: scope.venueId,
          deviceId: deviceId,
        );
        if (bootstrap.hubCredentialId != credential.credentialId) continue;
        final prefix =
            'tableside.offlineHub.tls.${scope.tenantId}.${scope.venueId}';
        final certificate = await _secrets.read(key: '$prefix.certificate');
        final privateKey = await _secrets.read(key: '$prefix.privateKey');
        if (certificate?.isNotEmpty != true || privateKey?.isNotEmpty != true) {
          continue;
        }
        final stored = await _ledger.readSnapshot(
          tenantId: scope.tenantId,
          venueId: scope.venueId,
          kind: VenueHubRuntime.bootstrapSnapshotKind,
        );
        final raw = stored?['value'];
        if (raw is! Map) continue;
        final snapshot = Map<String, Object?>.from(raw);
        if (snapshot['hubEpoch'] != bootstrap.hubEpoch) continue;
        return venueHubOfflineWorkspaceFromSnapshot(scope, snapshot);
      } catch (error, stackTrace) {
        AppLogger.error(
          'Validate cached offline hub workspace ${scope.venueId}',
          error,
          stackTrace,
        );
      }
    }
    return null;
  }
}

@visibleForTesting
VenueHubOfflineWorkspace venueHubOfflineWorkspaceFromSnapshot(
  VenueScope scope,
  Map<String, Object?> snapshot,
) {
  String text(String key, String fallback) {
    final value = snapshot[key];
    return value is String && value.trim().isNotEmpty ? value.trim() : fallback;
  }

  List<String> strings(String key) =>
      (snapshot[key] as List? ?? const []).whereType<String>().toList();

  Map<String, List<String>> locations() {
    final raw = snapshot['deliveryLocations'];
    if (raw is! Map) return const {};
    return {
      for (final entry in raw.entries)
        if (entry.key is String && entry.value is List)
          entry.key as String: (entry.value as List)
              .whereType<String>()
              .toList(),
    };
  }

  final tenantName = text('tenantName', 'Restaurant');
  final venueName = text('venueName', tenantName);
  final currency = text('currencyCode', 'GBP').toUpperCase();
  final tenantPhones = strings('tenantPhoneNumbers');
  final venuePhones = strings('venuePhoneNumbers');
  return VenueHubOfflineWorkspace(
    scope: scope,
    profile: TenantProfile(
      id: scope.tenantId,
      displayName: tenantName,
      legalName: tenantName,
      currencyCode: currency,
      address: text('tenantAddress', ''),
      phone: tenantPhones.firstOrNull ?? '',
      phoneNumbers: tenantPhones,
      receiptFooter: text('receiptFooter', ''),
    ),
    venue: Venue(
      id: scope.venueId,
      tenantId: scope.tenantId,
      name: venueName,
      timeZone: text('venueTimeZone', 'UTC'),
      country: text('venueCountry', 'Kuzey Kıbrıs Türk Cumhuriyeti'),
      deliveryLocations: locations(),
      address: text('venueAddress', ''),
      phoneNumbers: venuePhones,
      receiptFooter: text('receiptFooter', ''),
      collectionEnabled: snapshot['collectionEnabled'] == true,
      deliveryEnabled: snapshot['deliveryEnabled'] == true,
      courseControlEnabled: snapshot['courseControlEnabled'] == true,
      businessDayCutoffMinutes:
          (snapshot['businessDayCutoffMinutes'] as num?)?.toInt() ?? 240,
    ),
  );
}
