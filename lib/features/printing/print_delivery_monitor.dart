import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../data/print_job_repository.dart';
import '../../data/printer_device_repository.dart';
import '../notifications/notification_centre.dart';
import '../pos/domain.dart';

/// Venue-wide, live printer delivery safeguards.
///
/// A production job is created by the trusted backend but printed by a native
/// device. A kitchen device being switched off must therefore be visible to
/// every signed-in till, not only to the device that happens to be assigned to
/// the route. Jobs begin as normal queue work; an alert appears only when they
/// have waited beyond the short hand-off window, become stuck while claimed,
/// or fail all retries. The monitor uses Firestore streams as the source of
/// truth and a small timer only to re-evaluate job age when no document changes.
class PrintDeliveryMonitorHost extends ConsumerStatefulWidget {
  const PrintDeliveryMonitorHost({super.key});

  @override
  ConsumerState<PrintDeliveryMonitorHost> createState() =>
      _PrintDeliveryMonitorHostState();
}

class _PrintDeliveryMonitorHostState
    extends ConsumerState<PrintDeliveryMonitorHost> {
  static const _queueAlertAfter = Duration(seconds: 15);
  static const _claimedAlertAfter = Duration(seconds: 45);
  static const _offlineAfter = Duration(seconds: 90);

  final PrintJobRepository _jobs = PrintJobRepository(
    FirebaseFirestore.instance,
  );
  final PrinterDeviceRepository _devices = PrinterDeviceRepository(
    FirebaseFirestore.instance,
  );
  StreamSubscription<List<PrintJob>>? _jobsSubscription;
  StreamSubscription<List<PrinterDevice>>? _devicesSubscription;
  Timer? _ageTimer;
  VenueScope? _scope;
  List<PrintJob> _currentJobs = const [];
  List<PrinterDevice> _currentDevices = const [];
  Set<String> _activeAlertKeys = const {};

  @override
  void dispose() {
    _jobsSubscription?.cancel();
    _devicesSubscription?.cancel();
    _ageTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = ref.watch(activeVenueScopeProvider);
    if (scope != _scope) {
      scheduleMicrotask(() => _configure(scope));
    }
    return const SizedBox.shrink();
  }

  void _configure(VenueScope? scope) {
    if (!mounted || scope == _scope) return;
    _jobsSubscription?.cancel();
    _devicesSubscription?.cancel();
    _ageTimer?.cancel();
    _resolveAllAlerts();
    _scope = scope;
    _currentJobs = const [];
    _currentDevices = const [];
    if (scope == null) return;

    _jobsSubscription = _jobs
        .watchVenueJobs(tenantId: scope.tenantId, venueId: scope.venueId)
        .listen(
          (jobs) {
            _currentJobs = jobs;
            AppLogger.info(
              'Print delivery monitor: ${jobs.length} job(s) loaded for this venue.',
            );
            _reconcile();
          },
          onError: (Object error, StackTrace stackTrace) {
            AppLogger.error(
              'Print delivery monitor job stream',
              error,
              stackTrace,
            );
            _showMonitorConnectionFailure();
          },
        );
    _devicesSubscription = _devices
        .watchVenueDevices(tenantId: scope.tenantId, venueId: scope.venueId)
        .listen(
          (devices) {
            _currentDevices = devices;
            _reconcile();
          },
          onError: (Object error, StackTrace stackTrace) {
            AppLogger.error(
              'Print delivery monitor device stream',
              error,
              stackTrace,
            );
            _showMonitorConnectionFailure();
          },
        );
    _ageTimer = Timer.periodic(const Duration(seconds: 5), (_) => _reconcile());
  }

  void _showMonitorConnectionFailure() {
    if (!mounted) return;
    showAppNotification(
      context,
      ref: ref,
      title: 'Printer delivery monitoring unavailable',
      message:
          'The app cannot currently watch pending production tickets. Check the internet connection.',
      level: AppNotificationLevel.error,
      deduplicationKey: 'print-delivery-monitor-connection',
      requiresAttention: true,
    );
  }

  void _reconcile() {
    if (!mounted || _scope == null) return;
    final now = DateTime.now();
    final jobsById = {for (final job in _currentJobs) job.id: job};
    final devicesById = {
      for (final device in _currentDevices) device.id: device,
    };
    final alerts = <_PrintDeliveryAlert>[];

    for (final job in _currentJobs) {
      final primary = job.fallbackFromJobId == null
          ? null
          : jobsById[job.fallbackFromJobId];
      // A failed primary reports the fallback as one coherent incident. Do
      // not create a second, competing warning for the fallback job itself.
      if (primary?.status == PrintJobStatus.failed) continue;
      final fallback = _currentJobs
          .where((candidate) => candidate.fallbackFromJobId == job.id)
          .firstOrNull;
      if (job.status == PrintJobStatus.printed) continue;

      // The primary job is no longer an undelivered ticket when its fallback
      // completed successfully. A failed fallback is handled in its own turn.
      if (job.status == PrintJobStatus.failed &&
          job.fallbackDeliveryStatus == 'printed') {
        continue;
      }

      final device = devicesById[job.targetDeviceId];
      if (job.status == PrintJobStatus.failed && fallback != null) {
        if (fallback.status != PrintJobStatus.failed) {
          alerts.add(
            _PrintDeliveryAlert(
              key: 'print-job-${job.id}-fallback',
              title: '${_areaLabel(job)} printer failed — fallback pending',
              message:
                  '${_ticketLabel(job)} could not print on ${_deviceLabel(device)}. It has been routed to ${_deviceLabel(devicesById[fallback.targetDeviceId])}. Check both printers until it is delivered.',
              level: AppNotificationLevel.error,
            ),
          );
        }
        continue;
      }

      if (job.status == PrintJobStatus.failed) {
        alerts.add(
          _PrintDeliveryAlert(
            key: 'print-job-${job.id}-failed',
            title: '${_areaLabel(job)} ticket failed to print',
            message:
                '${_ticketLabel(job)} failed after ${job.attempts} attempt(s) on ${_deviceLabel(device)}. Check power, paper and the printer connection; then reprint the ticket.',
            level: AppNotificationLevel.error,
          ),
        );
        continue;
      }

      if (job.status == PrintJobStatus.claimed &&
          now.difference(job.claimedAt ?? job.createdAt) >=
              _claimedAlertAfter) {
        alerts.add(
          _PrintDeliveryAlert(
            key: 'print-job-${job.id}-claimed',
            title: '${_areaLabel(job)} ticket is taking too long',
            message:
                '${_ticketLabel(job)} was claimed by ${_deviceLabel(device)} but has not confirmed printing. Check the printer before the order is missed.',
            level: AppNotificationLevel.error,
          ),
        );
        continue;
      }

      if (job.status == PrintJobStatus.queued &&
          now.difference(job.createdAt) >= _queueAlertAfter) {
        final offline =
            device == null ||
            !device.active ||
            device.lastHeartbeatAt == null ||
            now.difference(device.lastHeartbeatAt!) >= _offlineAfter;
        alerts.add(
          _PrintDeliveryAlert(
            key: 'print-job-${job.id}-queued',
            title: offline
                ? '${_areaLabel(job)} printer appears offline'
                : '${_areaLabel(job)} ticket is waiting to print',
            message: offline
                ? '${_ticketLabel(job)} is waiting for ${_deviceLabel(device)}, which has not checked in recently. Check the device, power and connection.'
                : '${_ticketLabel(job)} is still waiting for ${_deviceLabel(device)} to collect it. Check the printer now.',
            level: offline
                ? AppNotificationLevel.error
                : AppNotificationLevel.warning,
          ),
        );
      }
    }

    final controller = ref.read(appNotificationsProvider.notifier);
    final nextKeys = alerts.map((alert) => alert.key).toSet();
    for (final key in _activeAlertKeys.difference(nextKeys)) {
      controller.resolve(key);
    }
    _activeAlertKeys = nextKeys;
    for (final alert in alerts) {
      showAppNotification(
        context,
        ref: ref,
        title: alert.title,
        message: alert.message,
        level: alert.level,
        deduplicationKey: alert.key,
        requiresAttention: true,
      );
    }
    // A successful next snapshot proves that the stream monitor is healthy.
    controller.resolve('print-delivery-monitor-connection');
  }

  void _resolveAllAlerts() {
    final controller = ref.read(appNotificationsProvider.notifier);
    for (final key in _activeAlertKeys) {
      controller.resolve(key);
    }
    controller.resolve('print-delivery-monitor-connection');
    _activeAlertKeys = const {};
  }

  String _areaLabel(PrintJob job) => switch (job.productionArea) {
    'bar' => 'Bar',
    'dessert' => 'Dessert',
    _ => 'Kitchen',
  };

  String _deviceLabel(PrinterDevice? device) =>
      device == null ? 'the assigned printer' : 'printer ${device.name}';

  String _ticketLabel(PrintJob job) {
    final payload = job.payload;
    final tabName = payload['tabName'] as String?;
    final tableLabel = payload['tableLabel'] as String?;
    final reference = payload['reference'] as String?;
    final location = tabName?.trim().isNotEmpty == true
        ? 'tab $tabName'
        : tableLabel?.trim().isNotEmpty == true
        ? 'table $tableLabel'
        : 'this order';
    return reference?.trim().isNotEmpty == true
        ? 'Order $reference for $location'
        : 'The ticket for $location';
  }
}

class _PrintDeliveryAlert {
  const _PrintDeliveryAlert({
    required this.key,
    required this.title,
    required this.message,
    required this.level,
  });

  final String key;
  final String title;
  final String message;
  final AppNotificationLevel level;
}
