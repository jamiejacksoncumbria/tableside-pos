import 'package:cloud_firestore/cloud_firestore.dart';

import '../features/pos/domain.dart';

/// Native Android and Windows workers use this repository only after a
/// manager has explicitly registered the physical device to the venue.
/// Web clients never need Bluetooth or USB permission; they only create
/// approved order events.
class PrintJobRepository {
  PrintJobRepository(this._firestore);

  final FirebaseFirestore _firestore;

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

  /// Atomically claims one queued job. A worker must print an idempotent ticket
  /// from [idempotencyKey], then call [complete].
  Future<PrintJob?> claimNext({
    required String tenantId,
    required String venueId,
    required String deviceId,
  }) async {
    final candidates = await _jobs(tenantId)
        .where('venueId', isEqualTo: venueId)
        .where('targetDeviceId', isEqualTo: deviceId)
        .where('status', isEqualTo: 'queued')
        .orderBy('createdAt')
        .limit(25)
        .get();
    final now = DateTime.now();
    final candidate = candidates.docs.where((document) {
      final nextAttemptAt = document.data()['nextAttemptAt'];
      return nextAttemptAt is! Timestamp ||
          !nextAttemptAt.toDate().isAfter(now);
    }).firstOrNull;
    if (candidate == null) return null;

    final reference = candidate.reference;
    return _firestore.runTransaction((transaction) async {
      final snapshot = await transaction.get(reference);
      final data = snapshot.data();
      if (data == null || data['status'] != 'queued') return null;

      transaction.update(reference, {
        'status': 'claimed',
        'claimedByDeviceId': deviceId,
        'claimedAt': FieldValue.serverTimestamp(),
        'attempts': FieldValue.increment(1),
      });
      return PrintJob(
        id: snapshot.id,
        tenantId: tenantId,
        venueId: data['venueId'] as String,
        targetDeviceId: data['targetDeviceId'] as String,
        orderId: data['orderId'] as String,
        status: PrintJobStatus.claimed,
        idempotencyKey: data['idempotencyKey'] as String,
        createdAt:
            (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
        claimedByDeviceId: deviceId,
        attempts: (data['attempts'] as int? ?? 0) + 1,
        payload: Map<String, Object?>.from(data['payload'] as Map? ?? const {}),
      );
    });
  }

  Future<void> complete({
    required PrintJob job,
    required bool printed,
    String? failureReason,
  }) {
    if (printed) {
      return _jobs(job.tenantId).doc(job.id).update({
        'status': 'printed',
        'completedAt': FieldValue.serverTimestamp(),
        'failureReason': FieldValue.delete(),
        'nextAttemptAt': FieldValue.delete(),
      });
    }
    if (job.attempts < 3) {
      return _jobs(job.tenantId).doc(job.id).update({
        'status': 'queued',
        'failureReason':
            failureReason ?? 'The printer did not accept the ticket.',
        'nextAttemptAt': Timestamp.fromDate(
          DateTime.now().add(const Duration(seconds: 10)),
        ),
        'claimedByDeviceId': FieldValue.delete(),
        'claimedAt': FieldValue.delete(),
      });
    }
    return _jobs(job.tenantId).doc(job.id).update({
      'status': 'failed',
      'completedAt': FieldValue.serverTimestamp(),
      'failureReason':
          failureReason ?? 'The printer failed after three attempts.',
      'nextAttemptAt': FieldValue.delete(),
    });
  }
}
