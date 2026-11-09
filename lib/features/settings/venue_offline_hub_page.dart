import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/safe_dialog.dart';
import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../data/production_command_repository.dart';
import '../../offline/venue_hub_bootstrap.dart';
import '../../offline/venue_hub_backup_monitor.dart';
import '../../offline/hub_port_diagnostic.dart';
import '../../offline/venue_hub_device_credential.dart';
import '../../offline/venue_hub_client_registry.dart';
import '../../offline/venue_hub_runtime.dart';
import '../../offline/venue_hub_platform.dart';
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
  late final VoidCallback _takeoverListener;
  bool _busy = false;
  bool _hasCertificate = false;
  bool _hasPrivateKey = false;
  String? _message;

  String get _storagePrefix =>
      'tableside.offlineHub.tls.${widget.scope.tenantId}.${widget.scope.venueId}';

  @override
  void dispose() {
    _runtimeSubscription.cancel();
    VenueHubManualTakeoverCoordinator.instance.pending.removeListener(
      _takeoverListener,
    );
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
    _takeoverListener = () {
      if (mounted) setState(() {});
    };
    VenueHubManualTakeoverCoordinator.instance.pending.addListener(
      _takeoverListener,
    );
    _refresh();
  }

  Future<void> _refresh() => _run('Refresh offline hub', () async {
    final certificate = await _secrets.read(key: '$_storagePrefix.certificate');
    final privateKey = await _secrets.read(key: '$_storagePrefix.privateKey');
    final deviceId = await _identity.deviceIdForScope(widget.scope);
    final credential = await _credentialStore.getOrCreate(
      tenantId: widget.scope.tenantId,
      venueId: widget.scope.venueId,
      deviceId: deviceId,
    );
    VenueHubBootstrap? bootstrap;
    if (Firebase.apps.isNotEmpty) {
      final raw = await _repository.fetchOfflineHubBootstrap(
        scope: widget.scope,
      );
      bootstrap = VenueHubBootstrap.fromJson(raw);
      await VenueHubPrinterClientRegistry.instance.configure(
        scope: widget.scope,
        bootstrap: bootstrap,
        deviceId: deviceId,
        credential: credential,
      );
    } else {
      // Windows can intentionally start from the encrypted venue snapshot
      // without creating Firebase. Reuse the verified bootstrap already held
      // by the running hub/client rather than producing a core/no-app error.
      bootstrap =
          VenueHubRuntime.instance.activeBootstrap ??
          VenueHubClientRegistry.instance.bootstrapFor(widget.scope);
    }
    if (!mounted) return;
    if (bootstrap == null) {
      setState(() {
        _deviceId = deviceId;
        _credential = credential;
        _hasCertificate = certificate?.isNotEmpty == true;
        _hasPrivateKey = privateKey?.isNotEmpty == true;
        _message =
            'Cloud setup is unavailable while offline. The saved local hub configuration is unchanged.';
      });
      return;
    }
    if (_host.text.trim().isEmpty && bootstrap.endpoint != null) {
      _host.text = bootstrap.endpoint!.host;
      _port.text = '${bootstrap.endpoint!.port}';
    }
    setState(() {
      _deviceId = deviceId;
      _credential = credential;
      _bootstrap = bootstrap;
      _hasCertificate = certificate?.isNotEmpty == true;
      _hasPrivateKey = privateKey?.isNotEmpty == true;
      if (Firebase.apps.isEmpty) {
        _message =
            'Showing the saved local hub configuration. Cloud enrolment changes require internet.';
      }
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
    await VenueHubPrinterClientRegistry.instance.configure(
      scope: widget.scope,
      bootstrap: bootstrap,
      deviceId: deviceId,
      credential: credential,
    );
    VenueHubClientRegistry.instance.rememberEnrolledDevice(
      scope: widget.scope,
      bootstrap: bootstrap,
      deviceId: deviceId,
      credentialId: credential.credentialId,
    );
    if (mounted) {
      setState(() {
        _bootstrap = bootstrap;
        _message = 'This till/printer is enrolled with the hub.';
      });
    }
  });

  Future<void> _enrolAndActivate() async {
    if (!canHostVenueHub) {
      setState(() {
        _message =
            'Only an Android or Windows device can host the venue hub. This device can still join as a POS client.';
      });
      return;
    }
    if (!await _ensureHubSecurityFiles(
      purpose: 'make this device the venue hub',
    )) {
      return;
    }
    String? takeoverReason;
    if (_bootstrap?.enabled == true &&
        (_bootstrap?.hubDeviceId != _deviceId ||
            _bootstrap?.hubCredentialId != _credential?.credentialId)) {
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

  Future<void> _configureBackup() async {
    if (!await _ensureHubSecurityFiles(
      purpose: 'make this device the backup hub',
    )) {
      return;
    }
    await _run('Configure backup hub', () async {
      final deviceId = _deviceId;
      final credential = _credential;
      if (deviceId == null || credential == null) {
        throw StateError('The device identity is not ready.');
      }
      if (_bootstrap?.enabled != true || _bootstrap?.hubDeviceId == deviceId) {
        throw StateError(
          'Configure the primary hub first, then use a different Android or Windows device as its backup.',
        );
      }
      await _repository.enrollOfflineHubDeviceCredential(
        scope: widget.scope,
        deviceId: deviceId,
        credentialId: credential.credentialId,
        publicKeyBase64: credential.publicKeyBase64,
      );
      await _repository.configureOfflineVenueBackupHub(
        scope: widget.scope,
        deviceId: deviceId,
        credentialId: credential.credentialId,
        endpointHost: _host.text.trim(),
        endpointPort: int.tryParse(_port.text.trim()) ?? 8443,
      );
      final raw = await _repository.fetchOfflineHubBootstrap(
        scope: widget.scope,
      );
      if (mounted) {
        setState(() {
          _bootstrap = VenueHubBootstrap.fromJson(raw);
          _message =
              'This device is armed as the passive backup hub. It cannot accept orders until secure failover completes.';
        });
      }
    });
  }

  /// A primary or backup hub terminates HTTPS locally and therefore requires
  /// both halves of the venue TLS identity. Ordinary POS clients intentionally
  /// receive only the public certificate and must never receive the private
  /// key. This guided check runs before any cloud mutation so setup cannot end
  /// half-configured or fail with a message hidden below the current viewport.
  Future<bool> _ensureHubSecurityFiles({required String purpose}) async {
    if (_hasCertificate && _hasPrivateKey) return true;
    final importNow = await showAppDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.security_rounded),
        title: const Text('Hub security files required'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'To $purpose, import this venue\'s certificate and matching '
              'private key on this device first.',
            ),
            const SizedBox(height: 12),
            _SecurityFileRequirement(
              label: 'Venue certificate (.pem)',
              installed: _hasCertificate,
            ),
            const SizedBox(height: 6),
            _SecurityFileRequirement(
              label: 'Hub private key (.pem)',
              installed: _hasPrivateKey,
            ),
            const SizedBox(height: 12),
            const Text(
              'Android will open its file picker for each missing file. Keep '
              'the private key only on approved primary or backup hub devices.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not now'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('Import missing files'),
          ),
        ],
      ),
    );
    if (importNow != true || !mounted) return false;
    if (!_hasCertificate && !await _chooseTlsFile('certificate')) return false;
    if (!_hasPrivateKey && !await _chooseTlsFile('privateKey')) return false;
    return _hasCertificate && _hasPrivateKey;
  }

  Future<void> _removeBackup() => _run('Remove backup hub', () async {
    await _repository.removeOfflineVenueBackupHub(scope: widget.scope);
    final raw = await _repository.fetchOfflineHubBootstrap(scope: widget.scope);
    if (mounted) {
      setState(() {
        _bootstrap = VenueHubBootstrap.fromJson(raw);
        _message = 'The backup hub assignment was removed.';
      });
    }
  });

  Future<void> _confirmBackupTakeover() async {
    final request = VenueHubManualTakeoverCoordinator.instance.pending.value;
    if (request == null || request.scope != widget.scope) {
      setState(() {
        _message =
            'The primary hub is responding or has not yet reached the secure takeover threshold.';
      });
      return;
    }
    final pinController = TextEditingController();
    final reasonController = TextEditingController();
    var acknowledged = false;
    final approval = await showAppDialog<({String pin, String reason})>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          icon: const Icon(Icons.warning_amber_rounded),
          title: const Text('Take over as the main hub?'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'The primary hub has stopped renewing its authority lease. '
                  'Taking over revokes that hub and requires tills to reconnect. '
                  'Only continue after checking that the original hub is stopped '
                  'or cannot be recovered.',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: pinController,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  onChanged: (_) => setDialogState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Fresh manager PIN',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: reasonController,
                  maxLength: 200,
                  onChanged: (_) => setDialogState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Required takeover reason',
                    border: OutlineInputBorder(),
                  ),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: acknowledged,
                  onChanged: (value) =>
                      setDialogState(() => acknowledged = value == true),
                  title: const Text(
                    'I confirm the original hub is unavailable and authorise this backup to replace it.',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed:
                  acknowledged &&
                      RegExp(r'^\d{6}$').hasMatch(pinController.text.trim()) &&
                      reasonController.text.trim().isNotEmpty
                  ? () => Navigator.pop(dialogContext, (
                      pin: pinController.text.trim(),
                      reason: reasonController.text.trim(),
                    ))
                  : null,
              icon: const Icon(Icons.swap_horiz_rounded),
              label: const Text('Confirm takeover'),
            ),
          ],
        ),
      ),
    );
    pinController.dispose();
    reasonController.dispose();
    if (approval == null) return;
    await _run('Confirm backup hub takeover', () async {
      await VenueHubManualTakeoverCoordinator.instance.confirm(
        managerPin: approval.pin,
        reason: approval.reason,
      );
      if (mounted) {
        setState(() {
          _message =
              'Takeover was approved. This device is starting as the authoritative venue hub.';
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
    final result = await showAppDialog<String>(
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

  Future<bool> _chooseTlsFile(String kind) async {
    var saved = false;
    await _run('Choose TLS $kind', () async {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pem'],
      );
      final file = result?.files.single;
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final value = utf8.decode(bytes);
      final expected = kind == 'certificate'
          ? 'BEGIN CERTIFICATE'
          : 'BEGIN PRIVATE KEY';
      if (!value.contains(expected)) {
        throw FormatException('The selected PEM file is not a valid $kind.');
      }
      await _secrets.write(key: '$_storagePrefix.$kind', value: value);
      saved = true;
      if (mounted) {
        setState(() {
          if (kind == 'certificate') {
            _hasCertificate = true;
          } else {
            _hasPrivateKey = true;
          }
          _message = 'TLS $kind saved securely.';
        });
      }
    });
    return saved;
  }

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

  Future<void> _diagnosePort() => _run('Diagnose venue hub port', () async {
    final port = int.tryParse(_port.text.trim()) ?? 8443;
    final host = _host.text.trim();
    final result = await diagnoseVenueHubPort(host, port);
    if (mounted) setState(() => _message = result);
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
        bootstrap?.enabled == true &&
        bootstrap?.hubDeviceId == deviceId &&
        bootstrap?.hubCredentialId == _credential?.credentialId;
    final isThisBackup =
        bootstrap?.enabled == true &&
        bootstrap?.backupDeviceId == deviceId &&
        bootstrap?.backupCredentialId == _credential?.credentialId;
    final takeoverRequest =
        VenueHubManualTakeoverCoordinator.instance.pending.value;
    final takeoverRequired =
        isThisBackup && takeoverRequest?.scope == widget.scope;
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
                  Text(
                    canHostVenueHub
                        ? 'This Android or Windows device can be made the venue hub.'
                        : kIsWeb
                        ? 'Web POS devices cannot join or host offline venue routing.'
                        : 'This device is POS-client only. Android or Windows must host the venue hub.',
                  ),
                  const SizedBox(height: 8),
                  SelectableText('This device ID: ${deviceId ?? 'loading'}'),
                  if (_credential != null)
                    SelectableText(
                      'This device key: ${_credential!.credentialId}',
                    ),
                  if (bootstrap?.enabled == true) ...[
                    const SizedBox(height: 4),
                    SelectableText(
                      'Active hub ID: ${bootstrap!.hubDeviceId ?? 'missing'}',
                    ),
                    SelectableText(
                      'Active hub key: ${bootstrap.hubCredentialId ?? 'missing'}',
                    ),
                    if (bootstrap.backupDeviceId != null) ...[
                      const SizedBox(height: 4),
                      SelectableText(
                        'Backup hub ID: ${bootstrap.backupDeviceId}',
                      ),
                      Text(
                        isThisBackup
                            ? 'This device is the passive backup hub.'
                            : 'A separate passive backup hub is configured.',
                      ),
                      if (isThisBackup) ...[
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: takeoverRequired
                                ? Theme.of(context).colorScheme.errorContainer
                                : Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                takeoverRequired
                                    ? 'Primary hub needs attention'
                                    : 'Manual takeover only',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                takeoverRequired
                                    ? 'The primary lease has stopped. Orders remain blocked until a manager confirms takeover or the primary returns.'
                                    : 'This backup will never promote itself. If the primary stops, a manager must confirm the transfer here.',
                              ),
                              if (takeoverRequired) ...[
                                const SizedBox(height: 10),
                                FilledButton.icon(
                                  onPressed: _busy
                                      ? null
                                      : _confirmBackupTakeover,
                                  icon: const Icon(Icons.swap_horiz_rounded),
                                  label: const Text('Take over as main hub'),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ],
                  ],
                  if (canHostVenueHub) ...[
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
                            decoration: const InputDecoration(
                              labelText: 'Port',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (canHostVenueHub)
                        FilledButton.icon(
                          onPressed: _busy ? null : _enrolAndActivate,
                          icon: const Icon(Icons.verified_user_outlined),
                          label: Text(
                            isThisHub
                                ? 'Restart this hub'
                                : 'Make this the hub',
                          ),
                        ),
                      if (canHostVenueHub &&
                          bootstrap?.enabled == true &&
                          !isThisHub)
                        FilledButton.tonalIcon(
                          onPressed: _busy ? null : _configureBackup,
                          icon: const Icon(Icons.backup_outlined),
                          label: Text(
                            isThisBackup
                                ? 'Refresh backup setup'
                                : 'Make this the backup hub',
                          ),
                        ),
                      if (bootstrap?.backupDeviceId != null)
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _removeBackup,
                          icon: const Icon(Icons.remove_circle_outline),
                          label: const Text('Remove backup hub'),
                        ),
                      if (canJoinVenueHubAsNativeClient)
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _enrolThisDevice,
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
                  Text(
                    canHostVenueHub
                        ? 'Every primary or backup hub must import the venue certificate and its private key. Ordinary native POS devices import only the certificate. Plain HTTP is never allowed.'
                        : 'Import only the public venue certificate on this POS device. The hub private key must never be copied to an ordinary till.',
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      Chip(
                        avatar: Icon(
                          _hasCertificate
                              ? Icons.check_circle_outline
                              : Icons.warning_amber_rounded,
                        ),
                        label: Text(
                          _hasCertificate
                              ? 'Certificate installed'
                              : 'Certificate required',
                        ),
                      ),
                      if (canHostVenueHub)
                        Chip(
                          avatar: Icon(
                            _hasPrivateKey
                                ? Icons.check_circle_outline
                                : Icons.warning_amber_rounded,
                          ),
                          label: Text(
                            _hasPrivateKey
                                ? 'Private key installed'
                                : 'Private key required',
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: _busy || !canJoinVenueHubAsNativeClient
                            ? null
                            : () => _chooseTlsFile('certificate'),
                        child: const Text('Import venue certificate PEM'),
                      ),
                      if (canHostVenueHub) ...[
                        OutlinedButton(
                          onPressed: _busy
                              ? null
                              : () => _chooseTlsFile('privateKey'),
                          child: const Text('Import hub private key PEM'),
                        ),
                        FilledButton(
                          onPressed:
                              _busy ||
                                  !isThisHub ||
                                  !_hasCertificate ||
                                  !_hasPrivateKey
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
                        if (defaultTargetPlatform == TargetPlatform.android)
                          OutlinedButton.icon(
                            onPressed: _busy
                                ? null
                                : AndroidVenueHubService.openBatterySettings,
                            icon: const Icon(Icons.battery_saver_outlined),
                            label: const Text('Battery settings'),
                          ),
                        if (defaultTargetPlatform == TargetPlatform.windows)
                          OutlinedButton.icon(
                            onPressed: _busy ? null : _diagnosePort,
                            icon: const Icon(Icons.security_rounded),
                            label: const Text('Check port / firewall'),
                          ),
                      ],
                    ],
                  ),
                  if (canHostVenueHub) ...[
                    const SizedBox(height: 12),
                    Text(
                      defaultTargetPlatform == TargetPlatform.android
                          ? 'For a reliable Android hub: give TableSideCY unrestricted battery use, keep the device on charge, disable automatic Wi-Fi switching, and reserve its IP address in the router. After a reboot, open TableSideCY once when prompted so the encrypted hub can be restored.'
                          : 'For a reliable Windows hub: reserve this computer\'s IP address in the router and prevent sleep while the venue is open.',
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text('State: ${runtime.state.name}'),
                  Text('Pending cloud events: ${runtime.pendingEvents}'),
                  if (runtime.message != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.report_problem_rounded,
                            color: Theme.of(context).colorScheme.error,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              runtime.message!,
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onErrorContainer,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
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

class _SecurityFileRequirement extends StatelessWidget {
  const _SecurityFileRequirement({
    required this.label,
    required this.installed,
  });

  final String label;
  final bool installed;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(
        installed ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
        color: installed
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.error,
      ),
      const SizedBox(width: 8),
      Expanded(child: Text('$label — ${installed ? 'installed' : 'required'}')),
    ],
  );
}
