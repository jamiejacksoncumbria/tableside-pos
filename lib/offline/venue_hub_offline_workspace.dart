import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/app_logger.dart';
import '../core/tenant_scope.dart';
import '../features/pos/domain.dart';
import '../features/printing/local_printer_device_identity.dart';
import 'offline_event_ledger.dart';
import 'venue_hub_client_cache.dart';
import 'venue_hub_client.dart';
import 'venue_hub_device_credential.dart';
import 'venue_hub_platform.dart';
import 'venue_hub_runtime.dart';

class VenueHubOfflineWorkspace {
  const VenueHubOfflineWorkspace({
    required this.scope,
    required this.profile,
    required this.venue,
    required this.hasVenueTheme,
  });

  final VenueScope scope;
  final TenantProfile profile;
  final Venue venue;
  final bool hasVenueTheme;
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

  Future<VenueHubOfflineWorkspace?> load({bool requireHubHost = true}) async {
    if (kIsWeb || !canHostVenueHub) return null;
    await _ledger.initialize();
    final candidates = await _cache.readCandidateScopes();
    if (candidates.isEmpty) {
      AppLogger.info('LAN workspace fallback: no cached venue scope.');
    }
    for (final scope in candidates) {
      try {
        final bootstrap = await _cache.readBootstrap(scope);
        if (bootstrap == null || !bootstrap.enabled) {
          AppLogger.info(
            'LAN workspace fallback skipped ${scope.venueId}: no enabled cached hub.',
          );
          continue;
        }
        final deviceId = await _identity.deviceIdForScope(scope);
        final credential = await _credentials.getOrCreate(
          tenantId: scope.tenantId,
          venueId: scope.venueId,
          deviceId: deviceId,
        );
        final enrolled = bootstrap.credentials[credential.credentialId];
        if (enrolled?.deviceId != deviceId) {
          AppLogger.info(
            'LAN workspace fallback skipped ${scope.venueId}: this device credential is not enrolled.',
          );
          continue;
        }
        if (requireHubHost &&
            (bootstrap.hubDeviceId != deviceId ||
                bootstrap.hubCredentialId != credential.credentialId)) {
          continue;
        }
        final prefix =
            'tableside.offlineHub.tls.${scope.tenantId}.${scope.venueId}';
        final certificate = await _secrets.read(key: '$prefix.certificate');
        if (certificate?.isNotEmpty != true) {
          AppLogger.info(
            'LAN workspace fallback skipped ${scope.venueId}: the pinned venue certificate is missing.',
          );
          continue;
        }
        if (!requireHubHost) {
          final cachedWorkspace = await _cache.readWorkspace(scope);
          final endpoint = bootstrap.endpoint;
          if (cachedWorkspace == null || endpoint == null) {
            AppLogger.info(
              'LAN workspace fallback skipped ${scope.venueId}: open this venue once online to cache its display settings.',
            );
            continue;
          }
          // A client may enter the cached PIN screen only while the exact
          // certificate-pinned hub generation is reachable over LAN. This
          // avoids turning local display data into an authentication bypass.
          final probe = VenueHubClient(
            configuration: VenueHubClientConfiguration(
              endpoint: endpoint,
              tenantId: scope.tenantId,
              venueId: scope.venueId,
              deviceId: deviceId,
              staffId: 'startup-probe',
              hubEpoch: bootstrap.hubEpoch,
              credential: credential,
              trustedCertificatePem: certificate,
            ),
            timeout: const Duration(seconds: 3),
          );
          try {
            if (!await probe.isHealthy()) {
              AppLogger.info(
                'LAN workspace fallback skipped ${scope.venueId}: ${probe.lastHealthFailure ?? 'hub health was not confirmed'}.',
              );
              continue;
            }
          } finally {
            probe.close();
          }
          return venueHubOfflineWorkspaceFromSnapshot(scope, cachedWorkspace);
        }
        final privateKey = await _secrets.read(key: '$prefix.privateKey');
        if (privateKey?.isNotEmpty != true) continue;
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
    hasVenueTheme: snapshot.containsKey('defaultThemeMode'),
    profile: TenantProfile(
      id: scope.tenantId,
      displayName: tenantName,
      legalName: tenantName,
      currencyCode: currency,
      logoUrl: snapshot['logoUrl'] as String?,
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
      notificationRetentionSeconds:
          (snapshot['notificationRetentionSeconds'] as num?)?.toInt() ?? 5,
      backgroundLockSeconds:
          (snapshot['backgroundLockSeconds'] as num?)?.toInt() ?? 120,
      orderFlowAmberMinutes:
          (snapshot['orderFlowAmberMinutes'] as num?)?.toInt() ?? 15,
      orderFlowRedMinutes:
          (snapshot['orderFlowRedMinutes'] as num?)?.toInt() ?? 25,
      defaultBookingDurationMinutes:
          (snapshot['defaultBookingDurationMinutes'] as num?)?.toInt() ?? 120,
      address: text('venueAddress', ''),
      phoneNumbers: venuePhones,
      receiptFooter: text('receiptFooter', ''),
      collectionEnabled: snapshot['collectionEnabled'] == true,
      deliveryEnabled: snapshot['deliveryEnabled'] == true,
      courseControlEnabled: snapshot['courseControlEnabled'] == true,
      defaultThemeMode: text('defaultThemeMode', 'light'),
      businessDayCutoffMinutes:
          (snapshot['businessDayCutoffMinutes'] as num?)?.toInt() ?? 240,
    ),
  );
}
