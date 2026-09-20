import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/app_logger.dart';
import '../core/tenant_scope.dart';
import '../data/production_command_repository.dart';
import '../features/printing/local_printer_device_identity.dart';
import 'venue_hub_bootstrap.dart';
import 'venue_hub_client_cache.dart';
import 'venue_hub_client_registry.dart';
import 'venue_hub_device_credential.dart';
import 'offline_event_ledger.dart';
import 'venue_hub_runtime.dart';
import 'venue_hub_platform.dart';

/// Starts the configured hub when its venue workspace opens. This deliberately
/// needs no staff PIN, so local ticket delivery continues while the UI locks.
class VenueHubAutoStartHost extends StatefulWidget {
  const VenueHubAutoStartHost({super.key, required this.scope});

  final VenueScope scope;

  @override
  State<VenueHubAutoStartHost> createState() => _VenueHubAutoStartHostState();
}

class _VenueHubAutoStartHostState extends State<VenueHubAutoStartHost> {
  static const _secrets = FlutterSecureStorage();
  bool _started = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void didUpdateWidget(covariant VenueHubAutoStartHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope) {
      _started = false;
      unawaited(_start());
    }
  }

  Future<void> _start() async {
    if (_started) return;
    _started = true;
    try {
      final cache = VenueHubClientCache();
      final repository = ProductionCommandRepository();
      VenueHubBootstrap? bootstrap;
      try {
        final raw = await repository
            .fetchOfflineHubBootstrap(scope: widget.scope)
            .timeout(const Duration(seconds: 8));
        bootstrap = VenueHubBootstrap.fromJson(raw);
        await cache.saveBootstrap(widget.scope, bootstrap);
      } catch (_) {
        bootstrap = await cache.readBootstrap(widget.scope);
      }
      if (bootstrap == null || !bootstrap.enabled) return;
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
      if (bootstrap.hubDeviceId != deviceId) return;
      if (!canHostVenueHub) {
        AppLogger.info(
          'This platform can join the venue hub but cannot host it.',
        );
        return;
      }
      if (bootstrap.hubCredentialId != credential.credentialId) return;
      final prefix =
          'tableside.offlineHub.tls.${widget.scope.tenantId}.${widget.scope.venueId}';
      final certificate = await _secrets.read(key: '$prefix.certificate');
      final privateKey = await _secrets.read(key: '$prefix.privateKey');
      if (certificate == null || privateKey == null) return;
      Map<String, Object?>? freshSnapshot;
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
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
