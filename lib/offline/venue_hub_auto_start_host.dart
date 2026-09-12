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
import 'venue_hub_runtime.dart';

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
      VenueHubBootstrap? bootstrap;
      try {
        final raw = await ProductionCommandRepository()
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
      VenueHubPrinterClientRegistry.instance.configure(
        scope: widget.scope,
        bootstrap: bootstrap,
        deviceId: deviceId,
        credential: credential,
      );
      if (bootstrap.hubDeviceId != deviceId) return;
      if (bootstrap.hubCredentialId != credential.credentialId) return;
      final prefix =
          'tableside.offlineHub.tls.${widget.scope.tenantId}.${widget.scope.venueId}';
      final certificate = await _secrets.read(key: '$prefix.certificate');
      final privateKey = await _secrets.read(key: '$prefix.privateKey');
      if (certificate == null || privateKey == null) return;
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
      );
      AppLogger.info('Venue offline hub auto-started for this venue.');
    } catch (error, stackTrace) {
      AppLogger.error('Auto-start venue offline hub', error, stackTrace);
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
