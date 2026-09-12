import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../data/production_command_repository.dart';
import '../../offline/venue_hub_bootstrap.dart';
import '../../offline/venue_hub_device_credential.dart';
import '../../offline/venue_hub_client_registry.dart';
import '../../offline/venue_hub_runtime.dart';
import '../printing/local_printer_device_identity.dart';

class VenueOfflineHubPage extends StatefulWidget {
  const VenueOfflineHubPage({super.key, required this.scope});

  final VenueScope scope;

  @override
  State<VenueOfflineHubPage> createState() => _VenueOfflineHubPageState();
}

class _VenueOfflineHubPageState extends State<VenueOfflineHubPage> {
  static const _secrets = FlutterSecureStorage();
  final _repository = ProductionCommandRepository();
  final _credentialStore = VenueHubDeviceCredentialStore();
  final _identity = LocalPrinterDeviceIdentity();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '8443');
  String? _deviceId;
  VenueHubDeviceCredential? _credential;
  VenueHubBootstrap? _bootstrap;
  late final StreamSubscription<VenueHubRuntimeStatus> _runtimeSubscription;
  bool _busy = false;
  String? _message;

  String get _storagePrefix =>
      'tableside.offlineHub.tls.${widget.scope.tenantId}.${widget.scope.venueId}';

  @override
  void dispose() {
    _runtimeSubscription.cancel();
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _runtimeSubscription = VenueHubRuntime.instance.statuses.listen((_) {
      if (mounted) setState(() {});
    });
    _refresh();
  }

  Future<void> _refresh() => _run('Refresh offline hub', () async {
    final deviceId = await _identity.deviceIdForScope(widget.scope);
    final credential = await _credentialStore.getOrCreate(
      tenantId: widget.scope.tenantId,
      venueId: widget.scope.venueId,
      deviceId: deviceId,
    );
    final raw = await _repository.fetchOfflineHubBootstrap(scope: widget.scope);
    if (!mounted) return;
    final bootstrap = VenueHubBootstrap.fromJson(raw);
    VenueHubPrinterClientRegistry.instance.configure(
      scope: widget.scope,
      bootstrap: bootstrap,
      deviceId: deviceId,
      credential: credential,
    );
    if (_host.text.trim().isEmpty && bootstrap.endpoint != null) {
      _host.text = bootstrap.endpoint!.host;
      _port.text = '${bootstrap.endpoint!.port}';
    }
    setState(() {
      _deviceId = deviceId;
      _credential = credential;
      _bootstrap = bootstrap;
    });
  });

  Future<void> _enrolThisDevice() => _run('Enrol offline device', () async {
    final deviceId = _deviceId;
    final credential = _credential;
    if (deviceId == null || credential == null) {
      throw StateError('The device identity is not ready.');
    }
    await _repository.enrollOfflineHubDeviceCredential(
      scope: widget.scope,
      deviceId: deviceId,
      credentialId: credential.credentialId,
      publicKeyBase64: credential.publicKeyBase64,
    );
    final raw = await _repository.fetchOfflineHubBootstrap(scope: widget.scope);
    final bootstrap = VenueHubBootstrap.fromJson(raw);
    VenueHubPrinterClientRegistry.instance.configure(
      scope: widget.scope,
      bootstrap: bootstrap,
      deviceId: deviceId,
      credential: credential,
    );
    if (mounted) {
      setState(() {
        _bootstrap = bootstrap;
        _message = 'This till/printer is enrolled with the hub.';
      });
    }
  });

  Future<void> _enrolAndActivate() async {
    String? takeoverReason;
    if (_bootstrap?.enabled == true && _bootstrap?.hubDeviceId != _deviceId) {
      takeoverReason = await _requestReason(
        title: 'Replace the active hub?',
        message:
            'Only continue after confirming the old hub is stopped. A takeover while it is still serving tills can create a split network and will be audited.',
        actionLabel: 'Replace hub',
      );
      if (takeoverReason == null) return;
    }
    return _run('Activate offline hub', () async {
      final deviceId = _deviceId;
      final credential = _credential;
      if (deviceId == null || credential == null) {
        throw StateError('The device identity is not ready.');
      }
      await _repository.enrollOfflineHubDeviceCredential(
        scope: widget.scope,
        deviceId: deviceId,
        credentialId: credential.credentialId,
        publicKeyBase64: credential.publicKeyBase64,
      );
      await _repository.activateOfflineVenueHub(
        scope: widget.scope,
        deviceId: deviceId,
        credentialId: credential.credentialId,
        endpointHost: _host.text.trim(),
        endpointPort: int.tryParse(_port.text.trim()) ?? 8443,
        takeoverReason: takeoverReason,
      );
      final raw = await _repository.fetchOfflineHubBootstrap(
        scope: widget.scope,
      );
      final bootstrap = VenueHubBootstrap.fromJson(raw);
      if (mounted) setState(() => _bootstrap = bootstrap);
      final snapshot = await _repository.fetchOfflineHubSnapshot(
        scope: widget.scope,
        deviceId: deviceId,
        hubEpoch: bootstrap.hubEpoch,
        credential: credential,
      );
      await _startRuntime(snapshot: snapshot, bootstrap: bootstrap);
      if (mounted) {
        setState(() => _message = 'This device is the active venue hub.');
      }
    });
  }

  Future<void> _deactivate() async {
    if (_bootstrap?.hubDeviceId == _deviceId &&
        VenueHubRuntime.instance.status.pendingEvents > 0) {
      setState(() {
        _message =
            'Wait for all pending hub events to synchronise before disabling offline routing.';
      });
      return;
    }
    final reason = await _requestReason(
      title: 'Disable venue offline routing?',
      message:
          'Do this only while internet is available and every till has stopped taking orders. The reason is required for the audit trail.',
      actionLabel: 'Disable',
    );
    if (reason == null) return;
    await _run('Deactivate offline hub', () async {
      await _repository.deactivateOfflineVenueHub(
        scope: widget.scope,
        reason: reason,
      );
      await VenueHubRuntime.instance.stop();
      VenueHubClientRegistry.instance.clear();
      final raw = await _repository.fetchOfflineHubBootstrap(
        scope: widget.scope,
      );
      if (mounted) {
        setState(() {
          _bootstrap = VenueHubBootstrap.fromJson(raw);
          _message = 'Venue offline routing is disabled.';
        });
      }
    });
  }

  Future<String?> _requestReason({
    required String title,
    required String message,
    required String actionLabel,
  }) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(message),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLength: 200,
              decoration: const InputDecoration(
                labelText: 'Required reason',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) Navigator.pop(context, value);
            },
            child: Text(actionLabel),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _downloadSnapshot() => _run('Download hub snapshot', () async {
    final deviceId = _deviceId;
    final credential = _credential;
    final bootstrap = _bootstrap;
    if (deviceId == null ||
        credential == null ||
        bootstrap == null ||
        !bootstrap.enabled ||
        bootstrap.hubDeviceId != deviceId) {
      throw StateError('Activate this device as the venue hub first.');
    }
    final snapshot = await _repository.fetchOfflineHubSnapshot(
      scope: widget.scope,
      deviceId: deviceId,
      hubEpoch: bootstrap.hubEpoch,
      credential: credential,
    );
    // Runtime startup stores this with authenticated encryption. Starting now
    // validates the TLS files and complete recovered event chain as one unit.
    await _startRuntime(snapshot: snapshot);
  });

  Future<void> _chooseTlsFile(String kind) =>
      _run('Choose TLS $kind', () async {
        final result = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['pem'],
          withData: true,
        );
        final bytes = result?.files.single.bytes;
        if (bytes == null) return;
        final value = utf8.decode(bytes);
        final expected = kind == 'certificate'
            ? 'BEGIN CERTIFICATE'
            : 'BEGIN PRIVATE KEY';
        if (!value.contains(expected)) {
          throw FormatException('The selected PEM file is not a valid $kind.');
        }
        await _secrets.write(key: '$_storagePrefix.$kind', value: value);
        if (mounted) setState(() => _message = 'TLS $kind saved securely.');
      });

  Future<void> _startRuntime({
    Map<String, Object?>? snapshot,
    VenueHubBootstrap? bootstrap,
  }) async {
    final deviceId = _deviceId;
    final credential = _credential;
    final activeBootstrap = bootstrap ?? _bootstrap;
    if (deviceId == null || credential == null || activeBootstrap == null) {
      throw StateError('Refresh the venue hub setup first.');
    }
    final certificate = await _secrets.read(key: '$_storagePrefix.certificate');
    final privateKey = await _secrets.read(key: '$_storagePrefix.privateKey');
    if (certificate == null || privateKey == null) {
      throw StateError(
        'Choose the trusted TLS certificate and private key first.',
      );
    }
    await VenueHubRuntime.instance.stop();
    await VenueHubRuntime.instance.start(
      scope: widget.scope,
      deviceId: deviceId,
      credential: credential,
      bootstrap: activeBootstrap,
      certificateChainPem: certificate,
      privateKeyPem: privateKey,
      allowedOrigins: const {
        'https://table-pos.web.app',
        'https://table-pos.firebaseapp.com',
      },
      freshSnapshot: snapshot,
    );
    if (mounted) setState(() => _message = 'Venue hub is running.');
  }

  Future<void> _stop() => _run('Stop venue hub', () async {
    await VenueHubRuntime.instance.stop();
    if (mounted) setState(() => _message = 'Venue hub stopped.');
  });

  Future<void> _run(String action, Future<void> Function() operation) async {
    if (_busy) return;
    if (mounted) setState(() => _busy = true);
    try {
      await operation();
    } catch (error, stackTrace) {
      AppLogger.error(action, error, stackTrace);
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bootstrap = _bootstrap;
    final deviceId = _deviceId;
    final isThisHub =
        bootstrap?.enabled == true && bootstrap?.hubDeviceId == deviceId;
    final runtime = VenueHubRuntime.instance.status;
    return Scaffold(
      appBar: AppBar(title: const Text('Venue offline hub')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Authority',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    bootstrap == null
                        ? 'Loading…'
                        : !bootstrap.enabled
                        ? 'Offline hub is not enabled.'
                        : isThisHub
                        ? 'This device owns hub generation ${bootstrap.hubEpoch}.'
                        : 'Another device owns hub generation ${bootstrap.hubEpoch}.',
                  ),
                  const SizedBox(height: 8),
                  SelectableText('Device: ${deviceId ?? 'loading'}'),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _host,
                          enabled: !_busy,
                          decoration: const InputDecoration(
                            labelText: 'LAN host or fixed IP',
                            hintText: '192.168.1.20',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 110,
                        child: TextField(
                          controller: _port,
                          enabled: !_busy,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Port'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _busy || kIsWeb ? null : _enrolAndActivate,
                        icon: const Icon(Icons.verified_user_outlined),
                        label: Text(
                          isThisHub ? 'Restart this hub' : 'Make this the hub',
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy || kIsWeb ? null : _enrolThisDevice,
                        icon: const Icon(Icons.devices_other_outlined),
                        label: const Text('Enrol this till / printer'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _refresh,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Refresh'),
                      ),
                      if (bootstrap?.enabled == true)
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _deactivate,
                          icon: const Icon(Icons.power_settings_new_rounded),
                          label: const Text('Disable offline routing'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Secure local service',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Use a venue certificate trusted by every till. Plain HTTP is never allowed.',
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: _busy || kIsWeb
                            ? null
                            : () => _chooseTlsFile('certificate'),
                        child: const Text('Choose certificate PEM'),
                      ),
                      OutlinedButton(
                        onPressed: _busy || kIsWeb
                            ? null
                            : () => _chooseTlsFile('privateKey'),
                        child: const Text('Choose private key PEM'),
                      ),
                      FilledButton(
                        onPressed: _busy || !isThisHub
                            ? null
                            : _downloadSnapshot,
                        child: const Text('Refresh data & start'),
                      ),
                      OutlinedButton(
                        onPressed:
                            _busy ||
                                runtime.state == VenueHubRuntimeState.stopped
                            ? null
                            : _stop,
                        child: const Text('Stop'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text('State: ${runtime.state.name}'),
                  Text('Pending cloud events: ${runtime.pendingEvents}'),
                  if (runtime.endpoint != null)
                    SelectableText('Local endpoint: ${runtime.endpoint}'),
                ],
              ),
            ),
          ),
          if (_message != null) ...[
            const SizedBox(height: 12),
            Text(
              _message!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
