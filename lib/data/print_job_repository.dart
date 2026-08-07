import 'package:cloud_firestore/cloud_firestore.dart';

import '../features/pos/domain.dart';

/// Native Android and Windows workers use this repository after they are
/// provisioned with a device-specific custom claim. Web clients never need
/// Bluetooth or USB permission; they only create approved order events.
class PrintJobRepository {
  PrintJobRepository(this._firestore);

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> _jobs(String tenantId) =>
      _firestore.collection('tenants/$tenantId/printJobs');

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
        .limit(1)
        .get();
    if (candidates.docs.isEmpty) return null;

    final reference = candidates.docs.first.reference;
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
    return _jobs(job.tenantId).doc(job.id).update({
      'status': printed ? 'printed' : 'failed',
      'completedAt': FieldValue.serverTimestamp(),
      'failureReason': failureReason,
    });
  }
}
