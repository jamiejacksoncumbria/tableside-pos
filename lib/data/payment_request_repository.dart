import 'package:cloud_firestore/cloud_firestore.dart';

import '../features/pos/domain.dart';

/// Creates a payment request for a trusted server to validate and process.
/// This repository must never mark a bill paid from the client application.
class PaymentRequestRepository {
  PaymentRequestRepository(this._firestore);

  final FirebaseFirestore _firestore;

  Future<PaymentRequest> requestPayment({
    required String tenantId,
    required String venueId,
    required String billId,
    required int amountMinor,
    required PaymentMethod method,
    required String idempotencyKey,
    String? terminalId,
  }) async {
    final reference = _firestore
        .collection('tenants/$tenantId/paymentRequests')
        .doc();
    final status = method == PaymentMethod.cardTerminal
        ? PaymentRequestStatus.awaitingTerminal
        : PaymentRequestStatus.requested;
    final request = PaymentRequest(
      id: reference.id,
      tenantId: tenantId,
      venueId: venueId,
      billId: billId,
      amountMinor: amountMinor,
      method: method,
      status: status,
      idempotencyKey: idempotencyKey,
      terminalId: terminalId,
    );
    await reference.set({
      'venueId': venueId,
      'billId': billId,
      'amountMinor': amountMinor,
      'method': method.name,
      'status': status.name,
      'idempotencyKey': idempotencyKey,
      'terminalId': terminalId,
      'requestedAt': FieldValue.serverTimestamp(),
    });
    return request;
  }

  Stream<PaymentRequest?> watchRequest({
    required String tenantId,
    required String requestId,
  }) {
    return _firestore
        .doc('tenants/$tenantId/paymentRequests/$requestId')
        .snapshots()
        .map((snapshot) {
          final data = snapshot.data();
          if (data == null) return null;
          return PaymentRequest(
            id: snapshot.id,
            tenantId: tenantId,
            venueId: data['venueId'] as String,
            billId: data['billId'] as String,
            amountMinor: data['amountMinor'] as int,
            method: _method(data['method'] as String?),
            status: _status(data['status'] as String?),
            idempotencyKey: data['idempotencyKey'] as String,
            terminalId: data['terminalId'] as String?,
          );
        });
  }

  PaymentMethod _method(String? value) => switch (value) {
    'cash' => PaymentMethod.cash,
    'online' => PaymentMethod.online,
    _ => PaymentMethod.cardTerminal,
  };

  PaymentRequestStatus _status(String? value) => switch (value) {
    'requested' => PaymentRequestStatus.requested,
    'paid' => PaymentRequestStatus.paid,
    'failed' => PaymentRequestStatus.failed,
    'cancelled' => PaymentRequestStatus.cancelled,
    _ => PaymentRequestStatus.awaitingTerminal,
  };
}
