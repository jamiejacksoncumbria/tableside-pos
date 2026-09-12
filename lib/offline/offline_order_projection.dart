import 'dart:collection';

import 'offline_event.dart';

class OfflineProjectionException implements Exception {
  const OfflineProjectionException(this.message);

  final String message;

  @override
  String toString() => 'OfflineProjectionException: $message';
}

class OfflineProjectedLine {
  const OfflineProjectedLine({
    required this.id,
    required this.productId,
    required this.name,
    required this.quantity,
    required this.unitPriceMinor,
    required this.sent,
  });

  final String id;
  final String productId;
  final String name;
  final int quantity;
  final int unitPriceMinor;
  final bool sent;

  int get totalMinor => quantity * unitPriceMinor;

  OfflineProjectedLine copyWith({int? quantity, bool? sent}) =>
      OfflineProjectedLine(
        id: id,
        productId: productId,
        name: name,
        quantity: quantity ?? this.quantity,
        unitPriceMinor: unitPriceMinor,
        sent: sent ?? this.sent,
      );
}

class OfflineProjectedPayment {
  const OfflineProjectedPayment({
    required this.id,
    required this.amountMinor,
    required this.method,
    required this.currencyCode,
  });

  final String id;
  final int amountMinor;
  final String method;
  final String currencyCode;
}

class OfflineOrderProjection {
  const OfflineOrderProjection._({
    required this.tenantId,
    required this.venueId,
    required this.orderId,
    required this.hubEpoch,
    required this.lastSequence,
    required this.lines,
    required this.payments,
    required this.isClosed,
  });

  final String tenantId;
  final String venueId;
  final String orderId;
  final int hubEpoch;
  final int lastSequence;
  final Map<String, OfflineProjectedLine> lines;
  final List<OfflineProjectedPayment> payments;
  final bool isClosed;

  int get totalMinor =>
      lines.values.fold(0, (sum, line) => sum + line.totalMinor);
  int get paidMinor =>
      payments.fold(0, (sum, payment) => sum + payment.amountMinor);
  int get balanceDueMinor => totalMinor - paidMinor;
}

/// Rebuilds an order solely from its immutable venue-hub events. Validation is
/// deliberately fail-closed: malformed, cross-venue, duplicate, stale-epoch or
/// out-of-sequence events must be quarantined instead of guessed into a sale.
OfflineOrderProjection projectOfflineOrder(List<OfflineEvent> events) {
  if (events.isEmpty) {
    throw const OfflineProjectionException('The event stream is empty.');
  }
  final first = events.first;
  final orderId = _requiredString(first.payload, 'orderId');
  final lines = <String, OfflineProjectedLine>{};
  final payments = <OfflineProjectedPayment>[];
  final paymentIds = <String>{};
  var expectedSequence = first.sequence;
  var opened = false;
  var closed = false;

  for (final event in events) {
    if (event.tenantId != first.tenantId || event.venueId != first.venueId) {
      throw const OfflineProjectionException(
        'An event belongs to a different tenant or venue.',
      );
    }
    if (event.hubEpoch != first.hubEpoch) {
      throw const OfflineProjectionException('A stale hub epoch was detected.');
    }
    if (event.sequence != expectedSequence) {
      throw const OfflineProjectionException(
        'The event sequence is missing, duplicated, or out of order.',
      );
    }
    expectedSequence++;
    if (_requiredString(event.payload, 'orderId') != orderId) {
      throw const OfflineProjectionException(
        'An event belongs to a different order.',
      );
    }
    if (closed) {
      throw const OfflineProjectionException(
        'A closed offline order cannot be changed.',
      );
    }

    switch (event.type) {
      case 'order.opened':
        if (opened) {
          throw const OfflineProjectionException(
            'The order was opened more than once.',
          );
        }
        opened = true;
        break;
      case 'order.itemAdded':
        _requireOpened(opened);
        final lineId = _requiredString(event.payload, 'lineId');
        if (lines.containsKey(lineId)) {
          throw const OfflineProjectionException(
            'An order line ID was used more than once.',
          );
        }
        final quantity = _positiveInt(event.payload, 'quantity');
        final unitPriceMinor = _nonNegativeInt(
          event.payload,
          'unitPriceMinor',
        );
        lines[lineId] = OfflineProjectedLine(
          id: lineId,
          productId: _requiredString(event.payload, 'productId'),
          name: _requiredString(event.payload, 'productName'),
          quantity: quantity,
          unitPriceMinor: unitPriceMinor,
          sent: false,
        );
        break;
      case 'order.itemQuantityChanged':
        _requireOpened(opened);
        final lineId = _requiredString(event.payload, 'lineId');
        final existing = lines[lineId];
        if (existing == null || existing.sent) {
          throw const OfflineProjectionException(
            'Only an existing unsent line can change quantity.',
          );
        }
        final quantity = _nonNegativeInt(event.payload, 'quantity');
        if (quantity == 0) {
          lines.remove(lineId);
        } else {
          lines[lineId] = existing.copyWith(quantity: quantity);
        }
        break;
      case 'order.sent':
        _requireOpened(opened);
        final rawLineIds = event.payload['lineIds'];
        if (rawLineIds is! List || rawLineIds.isEmpty) {
          throw const OfflineProjectionException(
            'A send event must identify at least one line.',
          );
        }
        for (final value in rawLineIds) {
          if (value is! String || !lines.containsKey(value)) {
            throw const OfflineProjectionException(
              'A send event refers to an unknown line.',
            );
          }
          lines[value] = lines[value]!.copyWith(sent: true);
        }
        break;
      case 'payment.recorded':
        _requireOpened(opened);
        final paymentId = _requiredString(event.payload, 'paymentId');
        if (!paymentIds.add(paymentId)) {
          throw const OfflineProjectionException(
            'A payment ID was used more than once.',
          );
        }
        final amountMinor = _positiveInt(event.payload, 'baseAmountMinor');
        final total = lines.values.fold<int>(
          0,
          (sum, line) => sum + line.totalMinor,
        );
        final alreadyPaid = payments.fold<int>(
          0,
          (sum, payment) => sum + payment.amountMinor,
        );
        if (alreadyPaid + amountMinor > total) {
          throw const OfflineProjectionException(
            'The payment exceeds the outstanding balance.',
          );
        }
        payments.add(
          OfflineProjectedPayment(
            id: paymentId,
            amountMinor: amountMinor,
            method: _requiredString(event.payload, 'method'),
            currencyCode: _requiredString(event.payload, 'currencyCode'),
          ),
        );
        break;
      case 'order.closed':
        _requireOpened(opened);
        final total = lines.values.fold<int>(
          0,
          (sum, line) => sum + line.totalMinor,
        );
        final paid = payments.fold<int>(
          0,
          (sum, payment) => sum + payment.amountMinor,
        );
        if (lines.isEmpty || paid != total) {
          throw const OfflineProjectionException(
            'An order may close only when its balance is exactly zero.',
          );
        }
        closed = true;
        break;
      default:
        throw OfflineProjectionException(
          'Unsupported offline event type: ${event.type}.',
        );
    }
  }
  _requireOpened(opened);
  return OfflineOrderProjection._(
    tenantId: first.tenantId,
    venueId: first.venueId,
    orderId: orderId,
    hubEpoch: first.hubEpoch,
    lastSequence: expectedSequence - 1,
    lines: UnmodifiableMapView(lines),
    payments: List.unmodifiable(payments),
    isClosed: closed,
  );
}

void _requireOpened(bool opened) {
  if (!opened) {
    throw const OfflineProjectionException(
      'The order must be opened before it can be changed.',
    );
  }
}

String _requiredString(Map<String, Object?> payload, String key) {
  final value = payload[key];
  if (value is! String || value.trim().isEmpty || value.length > 160) {
    throw OfflineProjectionException('$key is missing or invalid.');
  }
  return value.trim();
}

int _positiveInt(Map<String, Object?> payload, String key) {
  final value = _nonNegativeInt(payload, key);
  if (value == 0) {
    throw OfflineProjectionException('$key must be greater than zero.');
  }
  return value;
}

int _nonNegativeInt(Map<String, Object?> payload, String key) {
  final value = payload[key];
  if (value is! int || value < 0) {
    throw OfflineProjectionException('$key must be a non-negative integer.');
  }
  return value;
}
