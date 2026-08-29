import 'package:cloud_firestore/cloud_firestore.dart';

import '../features/pos/domain.dart';
import '../core/tenant_scope.dart';
import 'production_command_repository.dart';

/// Native Android and Windows workers use this repository only after a
/// manager has explicitly registered the physical device to the venue.
/// Web clients never need Bluetooth or USB permission; they only create
/// approved order events.
class PrintJobRepository {
  PrintJobRepository(
    this._firestore, {
    ProductionCommandRepository? commands,
  }) : _commands = commands ?? ProductionCommandRepository();

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
    return _jobs(tenantId)
        .where('venueId', isEqualTo: venueId)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map((document) => _fromDocument(tenantId, document))
              .toList(growable: false),
        );
  }

  /// Atomically claims one queued job. A worker must print an idempotent ticket
  /// from [idempotencyKey], then call [complete].
  Future<PrintJob?> claimNext({
    required String tenantId,
    required String venueId,
    required String deviceId,
    required String deviceCredential,
  }) async {
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
        createdAt: DateTime.tryParse(data['createdAt'] as String? ?? '') ?? DateTime.now(),
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
    return _commands.completeDevicePrintJob(
      scope: VenueScope(tenantId: job.tenantId, venueId: job.venueId),
      deviceId: job.targetDeviceId,
      deviceCredential: deviceCredential,
      jobId: job.id,
      printed: printed,
      failureReason: failureReason,
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
