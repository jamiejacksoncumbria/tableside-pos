import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../features/pos/domain.dart';
import '../core/tenant_scope.dart';
import 'production_command_repository.dart';
import '../offline/venue_hub_runtime.dart';
import '../offline/venue_hub_client_registry.dart';

/// Native Android and Windows workers use this repository only after a
/// manager has explicitly registered the physical device to the venue.
/// Web clients never need Bluetooth or USB permission; they only create
/// approved order events.
class PrintJobRepository {
  PrintJobRepository(this._firestore, {ProductionCommandRepository? commands})
    : _commands = commands ?? ProductionCommandRepository();

  final FirebaseFirestore _firestore;
  final ProductionCommandRepository _commands;

  CollectionReference<Map<String, dynamic>> _jobs(String tenantId) =>
      _firestore.collection('tenants/$tenantId/printJobs');

  /// Emits whenever this venue's queued-print workload changes. Workers use
  /// this to wake immediately for a new ticket instead of waiting for a poll.
  /// Claiming remains a transaction below, so simultaneous printer devices
  /// still cannot print the same job twice.
  Stream<int> watchQueuedJobCount({
    required String tenantId,
    required String venueId,
  }) {
    return _jobs(tenantId)
        .where('venueId', isEqualTo: venueId)
        .where('status', isEqualTo: 'queued')
        .snapshots()
        .map((snapshot) => snapshot.size)
        .distinct();
  }

  /// A venue-wide live view used by every signed-in till to surface jobs that
  /// are waiting for an offline printer.  This is intentionally broader than
  /// the device worker's queued-count stream: service staff need to know that
  /// a ticket is at risk even though they cannot claim it themselves.
  Stream<List<PrintJob>> watchVenueJobs({
    required String tenantId,
    required String venueId,
  }) {
    final cloud = _jobs(tenantId)
        .where('venueId', isEqualTo: venueId)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map((document) => _fromDocument(tenantId, document))
              .toList(growable: false),
        );
    final scope = VenueScope(tenantId: tenantId, venueId: venueId);
    final local = VenueHubRuntime.instance.localPrintJobs(scope);
    if (local == null) return cloud;

    // Hub-local operational jobs and the older cloud queue are both valid
    // histories during migration. Merge them by id so recovery, reprinting and
    // alerts never hide a ticket merely because hub authority created it.
    return Stream<List<PrintJob>>.multi((controller) {
      var cloudJobs = const <PrintJob>[];
      var localJobs = const <PrintJob>[];
      void emit() {
        final byId = <String, PrintJob>{
          for (final job in cloudJobs) job.id: job,
          for (final job in localJobs) job.id: job,
        };
        final values = byId.values.toList(growable: false)
          ..sort((left, right) => right.createdAt.compareTo(left.createdAt));
        controller.add(values);
      }

      final cloudSubscription = cloud.listen((jobs) {
        cloudJobs = jobs;
        emit();
      }, onError: controller.addError);
      final localSubscription = local.listen((jobs) {
        localJobs = jobs
            .map((data) => _fromLocalSnapshot(tenantId, venueId, data))
            .toList(growable: false);
        emit();
      }, onError: controller.addError);
      controller.onCancel = () async {
        await cloudSubscription.cancel();
        await localSubscription.cancel();
      };
    });
  }

  /// Atomically claims one queued job. A worker must print an idempotent ticket
  /// from [idempotencyKey], then call [complete].
  Future<PrintJob?> claimNext({
    required String tenantId,
    required String venueId,
    required String deviceId,
    required String deviceCredential,
  }) async {
    final scope = VenueScope(tenantId: tenantId, venueId: venueId);
    final runtime = VenueHubRuntime.instance;
    final localScope = runtime.activeScope;
    if (localScope?.tenantId == tenantId && localScope?.venueId == venueId) {
      final local = await runtime.claimLocalPrintJob(deviceId);
      return local == null
          ? null
          : _fromLocal(tenantId, venueId, deviceId, local);
    }
    final hubPrinter = VenueHubPrinterClientRegistry.instance;
    if (hubPrinter.requiresHub(scope)) {
      // An online-only till must not claim the hub's local queue and must not
      // fall back to the cloud queue while hub authority is active. It can be
      // enrolled later by a manager without generating false printer alarms.
      if (!hubPrinter.isDeviceEnrolled(scope)) return null;
      final local = await hubPrinter.claim(scope);
      return local == null
          ? null
          : _fromLocal(tenantId, venueId, deviceId, local);
    }
    final data = await _commands.claimDevicePrintJob(
      scope: VenueScope(tenantId: tenantId, venueId: venueId),
      deviceId: deviceId,
      deviceCredential: deviceCredential,
    );
    if (data == null) return null;
    return PrintJob(
      id: data['id'] as String,
      tenantId: tenantId,
      venueId: data['venueId'] as String? ?? venueId,
      targetDeviceId: data['targetDeviceId'] as String? ?? deviceId,
      orderId: data['orderId'] as String? ?? '',
      status: PrintJobStatus.claimed,
      idempotencyKey: data['idempotencyKey'] as String? ?? data['id'] as String,
      createdAt:
          DateTime.tryParse(data['createdAt'] as String? ?? '') ??
          DateTime.now(),
      ticketId: data['ticketId'] as String?,
      productionArea: data['productionArea'] as String?,
      claimedByDeviceId: deviceId,
      fallbackDeviceId: data['fallbackDeviceId'] as String?,
      fallbackFromJobId: data['fallbackFromJobId'] as String?,
      fallbackDeliveryStatus: data['fallbackDeliveryStatus'] as String?,
      failureReason: data['failureReason'] as String?,
      claimedAt: (data['claimedAt'] as Timestamp?)?.toDate(),
      completedAt: (data['completedAt'] as Timestamp?)?.toDate(),
      attempts: data['attempts'] as int? ?? 1,
      payload: Map<String, Object?>.from(data['payload'] as Map? ?? const {}),
    );
  }

  Future<void> complete({
    required PrintJob job,
    required String deviceCredential,
    required bool printed,
    String? failureReason,
  }) {
    final scope = VenueScope(tenantId: job.tenantId, venueId: job.venueId);
    if (job.id.startsWith('offline-') &&
        VenueHubRuntime.instance.activeScope == scope) {
      return VenueHubRuntime.instance.completeLocalPrintJob(
        deviceId: job.targetDeviceId,
        jobId: job.id,
        printed: printed,
        failureReason: failureReason,
      );
    }
    final hubPrinter = VenueHubPrinterClientRegistry.instance;
    if (job.id.startsWith('offline-') && hubPrinter.requiresHub(scope)) {
      return hubPrinter.complete(
        scope: scope,
        jobId: job.id,
        printed: printed,
        failureReason: failureReason,
      );
    }
    return _commands.completeDevicePrintJob(
      scope: VenueScope(tenantId: job.tenantId, venueId: job.venueId),
      deviceId: job.targetDeviceId,
      deviceCredential: deviceCredential,
      jobId: job.id,
      printed: printed,
      failureReason: failureReason,
    );
  }

  PrintJob _fromLocal(
    String tenantId,
    String venueId,
    String deviceId,
    Map<String, Object?> data,
  ) => PrintJob(
    id: data['id'] as String,
    tenantId: tenantId,
    venueId: venueId,
    targetDeviceId: deviceId,
    orderId: data['orderId'] as String? ?? '',
    status: PrintJobStatus.claimed,
    idempotencyKey: data['id'] as String,
    createdAt:
        DateTime.tryParse(data['createdAtUtc'] as String? ?? '') ??
        DateTime.now(),
    productionArea: data['productionArea'] as String?,
    attempts: data['attempts'] as int? ?? 1,
    payload: Map<String, Object?>.from(data['payload'] as Map? ?? const {}),
  );

  PrintJob _fromLocalSnapshot(
    String tenantId,
    String venueId,
    Map<String, Object?> data,
  ) {
    final statusName = data['status'] as String? ?? 'queued';
    final status = PrintJobStatus.values
        .where((value) => value.name == statusName)
        .firstOrNull;
    return PrintJob(
      id: data['id'] as String,
      tenantId: tenantId,
      venueId: venueId,
      targetDeviceId: data['targetDeviceId'] as String? ?? '',
      orderId: data['orderId'] as String? ?? '',
      status: status ?? PrintJobStatus.queued,
      idempotencyKey: data['id'] as String,
      createdAt:
          DateTime.tryParse(data['createdAtUtc'] as String? ?? '') ??
          DateTime.now(),
      productionArea: data['productionArea'] as String?,
      claimedByDeviceId: statusName == 'claimed'
          ? data['targetDeviceId'] as String?
          : null,
      fallbackDeviceId: data['fallbackDeviceId'] as String?,
      failureReason: data['failureReason'] as String?,
      claimedAt: DateTime.tryParse(data['claimedAtUtc'] as String? ?? ''),
      completedAt: statusName == 'printed'
          ? DateTime.tryParse(data['createdAtUtc'] as String? ?? '')
          : null,
      attempts: data['attempts'] as int? ?? 0,
      payload: Map<String, Object?>.from(data['payload'] as Map? ?? const {}),
    );
  }

  PrintJob _fromDocument(
    String tenantId,
    QueryDocumentSnapshot<Map<String, dynamic>> document,
  ) {
    final data = document.data();
    final statusName = data['status'] as String? ?? 'queued';
    final status = PrintJobStatus.values
        .where((value) => value.name == statusName)
        .firstOrNull;
    return PrintJob(
      id: document.id,
      tenantId: tenantId,
      venueId: data['venueId'] as String? ?? '',
      targetDeviceId: data['targetDeviceId'] as String? ?? '',
      orderId: data['orderId'] as String? ?? '',
      status: status ?? PrintJobStatus.queued,
      idempotencyKey: data['idempotencyKey'] as String? ?? document.id,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      ticketId: data['ticketId'] as String?,
      productionArea: data['productionArea'] as String?,
      claimedByDeviceId: data['claimedByDeviceId'] as String?,
      fallbackDeviceId: data['fallbackDeviceId'] as String?,
      fallbackFromJobId: data['fallbackFromJobId'] as String?,
      fallbackDeliveryStatus: data['fallbackDeliveryStatus'] as String?,
      failureReason: data['failureReason'] as String?,
      claimedAt: (data['claimedAt'] as Timestamp?)?.toDate(),
      completedAt: (data['completedAt'] as Timestamp?)?.toDate(),
      attempts: data['attempts'] is int ? data['attempts'] as int : 0,
      payload: Map<String, Object?>.from(data['payload'] as Map? ?? const {}),
    );
  }
}
