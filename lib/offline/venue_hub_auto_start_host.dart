import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/app_logger.dart';
import '../core/tenant_scope.dart';
import '../data/production_command_repository.dart';
import '../features/printing/local_printer_device_identity.dart';
import 'venue_hub_bootstrap.dart';
import 'venue_hub_availability.dart';
import 'venue_hub_backup_monitor.dart';
import 'venue_hub_client_cache.dart';
import 'venue_hub_client_registry.dart';
import 'venue_hub_device_credential.dart';
import 'offline_event_ledger.dart';
import 'venue_hub_runtime.dart';
import 'venue_hub_platform.dart';
import 'venue_hub_realtime_client.dart';

/// Starts the configured hub when its venue workspace opens. This deliberately
/// needs no staff PIN, so local ticket delivery continues while the UI locks.
class VenueHubAutoStartHost extends StatefulWidget {
  const VenueHubAutoStartHost({
    super.key,
    required this.scope,
    this.cloudRefreshEnabled = true,
  });

  final VenueScope scope;
  final bool cloudRefreshEnabled;

  @override
  State<VenueHubAutoStartHost> createState() => _VenueHubAutoStartHostState();
}

class _VenueHubAutoStartHostState extends State<VenueHubAutoStartHost> {
  static const _secrets = FlutterSecureStorage();
  bool _started = false;
  Timer? _retryTimer;
  StreamSubscription<VenueHubAuthorityChange>? _authoritySubscription;
  bool _refreshingAuthority = false;
  final VenueHubBackupMonitor _backupMonitor = VenueHubBackupMonitor();

  @override
  void initState() {
    super.initState();
    _authoritySubscription = VenueHubRealtimeClient.instance.authorityChanges
        .listen(_handleAuthorityChange);
    unawaited(_start());
  }

  @override
  void didUpdateWidget(covariant VenueHubAutoStartHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope) {
      _retryTimer?.cancel();
      unawaited(_backupMonitor.stop());
      _started = false;
      unawaited(_start());
    }
  }

  Future<void> _start({VenueHubBootstrap? preferredBootstrap}) async {
    if (_started) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    _started = true;
    try {
      final cache = VenueHubClientCache();
      final repository = ProductionCommandRepository();
      VenueHubBootstrap? bootstrap =
          preferredBootstrap ?? await cache.readBootstrap(widget.scope);
      if (preferredBootstrap == null && widget.cloudRefreshEnabled) {
        try {
          final raw = await repository
              .fetchOfflineHubBootstrap(scope: widget.scope)
              .timeout(const Duration(seconds: 8));
          bootstrap = VenueHubBootstrap.fromJson(raw);
          await cache.saveBootstrap(widget.scope, bootstrap);
        } catch (_) {
          // The cached cloud-signed authority is deliberately retained while
          // the internet is unavailable. Device/credential/epoch checks below
          // still prevent a copied or stale configuration becoming a hub.
        }
      }
      if (bootstrap == null || !bootstrap.enabled) {
        if (bootstrap != null) {
          VenueHubAvailability.markCloudOnly();
        }
        AppLogger.info(
          'Venue offline hub auto-start skipped: hub is not enabled.',
        );
        return;
      }
      final deviceId = await LocalPrinterDeviceIdentity().deviceIdForScope(
        widget.scope,
      );
      final credential = await VenueHubDeviceCredentialStore().getOrCreate(
        tenantId: widget.scope.tenantId,
        venueId: widget.scope.venueId,
        deviceId: deviceId,
      );
      await VenueHubPrinterClientRegistry.instance.configure(
        scope: widget.scope,
        bootstrap: bootstrap,
        deviceId: deviceId,
        credential: credential,
      );
      if (bootstrap.hubDeviceId != deviceId) {
        if (canHostVenueHub &&
            bootstrap.backupDeviceId == deviceId &&
            bootstrap.backupCredentialId == credential.credentialId) {
          await _backupMonitor.start(
            scope: widget.scope,
            deviceId: deviceId,
            credential: credential,
            bootstrap: bootstrap,
            onPromoted: _activatePromotedBackup,
          );
          // Keep a current encrypted snapshot on the standby so promotion can
          // start promptly. Snapshot verification accepts this configured
          // credential but all mutation endpoints remain active-hub-only.
          if (widget.cloudRefreshEnabled) {
            try {
              final snapshot = await repository.fetchOfflineHubSnapshot(
                scope: widget.scope,
                deviceId: deviceId,
                hubEpoch: bootstrap.hubEpoch,
                credential: credential,
              );
              if (snapshot['unchanged'] != true &&
                  snapshot['hubEpoch'] == bootstrap.hubEpoch &&
                  snapshot['version'] is int) {
                final ledger = OfflineEventLedger.instance;
                await ledger.initialize();
                await ledger.saveSnapshot(
                  tenantId: widget.scope.tenantId,
                  venueId: widget.scope.venueId,
                  kind: VenueHubRuntime.bootstrapSnapshotKind,
                  version: snapshot['version'] as int,
                  value: snapshot,
                );
              }
            } on Object catch (error, stackTrace) {
              AppLogger.error(
                'Preload backup venue hub snapshot',
                error,
                stackTrace,
              );
            }
          }
          return;
        }
        AppLogger.info(
          'Venue offline hub auto-start skipped: another device owns this venue. '
          'A manager can replace it in Settings > Venue offline hub.',
        );
        return;
      }
      await _backupMonitor.stop();
      if (!canHostVenueHub) {
        AppLogger.info(
          'This platform can join the venue hub but cannot host it.',
        );
        return;
      }
      if (bootstrap.hubCredentialId != credential.credentialId) {
        AppLogger.info(
          'Venue offline hub auto-start skipped: this installation has a new '
          'device credential. A manager must restart/replace the hub in settings.',
        );
        return;
      }
      final prefix =
          'tableside.offlineHub.tls.${widget.scope.tenantId}.${widget.scope.venueId}';
      final certificate = await _secrets.read(key: '$prefix.certificate');
      final privateKey = await _secrets.read(key: '$prefix.privateKey');
      if (certificate == null || privateKey == null) {
        AppLogger.info(
          'Venue offline hub auto-start skipped: the TLS certificate or private key is missing.',
        );
        return;
      }
      Map<String, Object?>? freshSnapshot;
      if (widget.cloudRefreshEnabled) {
        try {
          final ledger = OfflineEventLedger.instance;
          await ledger.initialize();
          final stored = await ledger.readSnapshot(
            tenantId: widget.scope.tenantId,
            venueId: widget.scope.venueId,
            kind: VenueHubRuntime.bootstrapSnapshotKind,
          );
          final storedValue = stored?['value'];
          final knownDigest = storedValue is Map
              ? storedValue['snapshotDigest'] as String?
              : null;
          final knownGeneration = storedValue is Map
              ? storedValue['snapshotGeneration'] as int?
              : null;
          freshSnapshot = await repository
              .fetchOfflineHubSnapshot(
                scope: widget.scope,
                deviceId: deviceId,
                hubEpoch: bootstrap.hubEpoch,
                credential: credential,
                knownSnapshotDigest: knownDigest,
                knownSnapshotGeneration: knownGeneration,
              )
              .timeout(const Duration(seconds: 15));
          if (freshSnapshot['unchanged'] == true) {
            final returnedGeneration =
                freshSnapshot['snapshotGeneration'] as int?;
            if (storedValue is Map) {
              freshSnapshot = Map<String, Object?>.from(storedValue);
              if (returnedGeneration != null) {
                freshSnapshot['snapshotGeneration'] = returnedGeneration;
              }
            } else {
              freshSnapshot = null;
            }
            AppLogger.info(
              'Encrypted venue snapshot is current; reused the durable local copy.',
            );
          } else {
            AppLogger.info(
              'Downloaded a changed venue snapshot before hub auto-start.',
            );
          }
        } catch (error, stackTrace) {
          // An internet outage is expected here. Runtime startup will use the
          // last authenticated encrypted snapshot when one is available.
          AppLogger.error(
            'Refresh venue snapshot before offline hub auto-start',
            error,
            stackTrace,
          );
        }
      }
      await VenueHubRuntime.instance.stop();
      await VenueHubRuntime.instance.start(
        scope: widget.scope,
        deviceId: deviceId,
        credential: credential,
        bootstrap: bootstrap,
        certificateChainPem: certificate,
        privateKeyPem: privateKey,
        allowedOrigins: const {
          'https://table-pos.web.app',
          'https://table-pos.firebaseapp.com',
        },
        freshSnapshot: freshSnapshot,
      );
      // The hub host should talk to its own listener through loopback. Using
      // its advertised LAN address can be blocked by Windows firewall or
      // router hairpin rules even though remote venue devices can reach it.
      await VenueHubPrinterClientRegistry.instance.configure(
        scope: widget.scope,
        bootstrap: bootstrap,
        deviceId: deviceId,
        credential: credential,
        endpointOverride: VenueHubRuntime.instance.status.endpoint,
      );
      AppLogger.info('Venue offline hub auto-started for this venue.');
    } catch (error, stackTrace) {
      AppLogger.error('Auto-start venue offline hub', error, stackTrace);
      // Startup can race Wi-Fi acquisition, Firebase token refresh, or a
      // previous listener releasing port 8443. A one-shot failure previously
      // left the designated hub stopped for the rest of the app session while
      // every client correctly failed closed. Retry without requiring staff to
      // restart the app; configuration errors remain visible in the log.
      _started = false;
      if (mounted) {
        _retryTimer = Timer(
          const Duration(seconds: 15),
          () => unawaited(_start()),
        );
      }
    }
  }

  Future<void> _activatePromotedBackup(int promotedEpoch) async {
    // Promotion can arrive both as the HTTPS response to the manager action
    // and as an RTDB authority event. Route both through one serialised path;
    // two concurrent restart paths can otherwise start the new generation and
    // then let the losing path stop it again as if it were the former hub.
    final deviceId = await LocalPrinterDeviceIdentity().deviceIdForScope(
      widget.scope,
    );
    await _handleAuthorityChange(
      VenueHubAuthorityChange(
        scope: widget.scope,
        deviceId: deviceId,
        hubEpoch: promotedEpoch,
      ),
    );
  }

  Future<void> _handleAuthorityChange(VenueHubAuthorityChange change) async {
    if (!mounted || change.scope != widget.scope || _refreshingAuthority) {
      return;
    }
    _refreshingAuthority = true;
    try {
      final current = VenueHubClientRegistry.instance.bootstrapFor(
        widget.scope,
      );
      if (current?.hubDeviceId == change.deviceId &&
          current?.hubEpoch == change.hubEpoch) {
        return;
      }
      final bootstrap = await _fetchChangedBootstrap(
        expectedDeviceId: change.deviceId,
        expectedEpoch: change.hubEpoch,
      );
      VenueHubClientRegistry.instance.rememberBootstrap(
        widget.scope,
        bootstrap,
      );
      VenueHubClientRegistry.instance.staffSessionInvalidations.value++;
      await VenueHubRealtimeClient.instance.clear();
      await _backupMonitor.stop();
      _started = false;
      await _start(preferredBootstrap: bootstrap);
      AppLogger.info(
        'Applied promoted venue hub authority; a fresh staff PIN session is required.',
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Apply promoted venue hub authority', error, stackTrace);
      _started = false;
      _retryTimer?.cancel();
      _retryTimer = Timer(
        const Duration(seconds: 5),
        () => unawaited(_start()),
      );
    } finally {
      _refreshingAuthority = false;
    }
  }

  Future<VenueHubBootstrap> _fetchChangedBootstrap({
    required String expectedDeviceId,
    required int expectedEpoch,
  }) async {
    final repository = ProductionCommandRepository();
    Object? lastError;
    for (var attempt = 1; attempt <= 6; attempt++) {
      try {
        final raw = await repository
            .fetchOfflineHubBootstrap(scope: widget.scope)
            .timeout(const Duration(seconds: 8));
        final bootstrap = VenueHubBootstrap.fromJson(raw);
        if (bootstrap.enabled &&
            bootstrap.hubDeviceId == expectedDeviceId &&
            bootstrap.hubEpoch == expectedEpoch) {
          await VenueHubClientCache().saveBootstrap(widget.scope, bootstrap);
          return bootstrap;
        }
        lastError = StateError(
          'The signed bootstrap has not reached promoted epoch $expectedEpoch yet.',
        );
      } on Object catch (error) {
        lastError = error;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    throw StateError(
      'The promoted venue hub bootstrap could not be refreshed securely: $lastError',
    );
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    unawaited(_authoritySubscription?.cancel());
    unawaited(_backupMonitor.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
