import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../data/production_command_repository.dart';
import '../features/printing/local_printer_device_identity.dart';
import 'app_environment.dart';
import 'diagnostic_log_store.dart';
import 'tenant_scope.dart';

/// Uploads only structured, non-message error metadata during staging tests.
/// Failures are intentionally silent to avoid a recursive logging/upload loop.
class CloudDiagnosticUploadHost extends StatefulWidget {
  const CloudDiagnosticUploadHost({super.key, required this.scope});

  final VenueScope scope;

  @override
  State<CloudDiagnosticUploadHost> createState() =>
      _CloudDiagnosticUploadHostState();
}

class _CloudDiagnosticUploadHostState extends State<CloudDiagnosticUploadHost> {
  final _repository = ProductionCommandRepository();
  Timer? _debounce;
  bool _uploading = false;
  String? _lastFingerprint;

  @override
  void initState() {
    super.initState();
    if (AppEnvironment.isStaging) {
      DiagnosticLogStore.instance.revision.addListener(_schedule);
      _debounce = Timer(const Duration(seconds: 10), _upload);
    }
  }

  @override
  void didUpdateWidget(covariant CloudDiagnosticUploadHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope) {
      _lastFingerprint = null;
      _schedule();
    }
  }

  void _schedule() {
    if (!AppEnvironment.isStaging) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 35), _upload);
  }

  Future<void> _upload() async {
    if (_uploading || !AppEnvironment.isStaging) return;
    final entries = DiagnosticLogStore.instance.cloudDiagnosticEntries;
    if (entries.isEmpty) return;
    final fingerprint = entries.map((entry) => entry.toString()).join('|');
    if (fingerprint == _lastFingerprint) return;
    _uploading = true;
    try {
      final deviceId = await LocalPrinterDeviceIdentity().deviceIdForScope(
        widget.scope,
      );
      await _repository.uploadDeviceDiagnostics(
        scope: widget.scope,
        deviceId: deviceId,
        platform: kIsWeb ? 'web' : defaultTargetPlatform.name,
        entries: entries,
      );
      _lastFingerprint = fingerprint;
    } on Object {
      // The local 1000-line log remains available and a later revision retries.
    } finally {
      _uploading = false;
    }
  }

  @override
  void dispose() {
    DiagnosticLogStore.instance.revision.removeListener(_schedule);
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
