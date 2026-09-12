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
    required this.productionArea,
    required this.details,
    required this.taxRateBasisPoints,
    required this.taxRateName,
    required this.sent,
  });

  final String id;
  final String productId;
  final String name;
  final int quantity;
  final int unitPriceMinor;
  final String productionArea;
  final List<String> details;
  final int taxRateBasisPoints;
  final String taxRateName;
  final bool sent;

  int get totalMinor => quantity * unitPriceMinor;

  OfflineProjectedLine copyWith({int? quantity, bool? sent}) =>
      OfflineProjectedLine(
        id: id,
        productId: productId,
        name: name,
        quantity: quantity ?? this.quantity,
        unitPriceMinor: unitPriceMinor,
        productionArea: productionArea,
        details: details,
        taxRateBasisPoints: taxRateBasisPoints,
        taxRateName: taxRateName,
        sent: sent ?? this.sent,
      );
}

class OfflineProjectedPayment {
  const OfflineProjectedPayment({
    required this.id,
    required this.baseAmountMinor,
    required this.tenderedAmountMinor,
    required this.method,
    required this.currencyCode,
    required this.exchangeRateToBase,
    required this.recordedAtUtc,
    this.terminalLabel,
    this.cashChangeBaseMinor = 0,
  });

  final String id;
  final int baseAmountMinor;
  final int tenderedAmountMinor;
  final String method;
  final String currencyCode;
  final String exchangeRateToBase;
  final DateTime recordedAtUtc;
  final String? terminalLabel;
  final int cashChangeBaseMinor;
}

class OfflineOrderProjection {
  const OfflineOrderProjection._({
    required this.tenantId,
    required this.venueId,
    required this.orderId,
    required this.openedAtUtc,
    this.tableId,
    this.tabName,
    required this.hubEpoch,
    required this.lastSequence,
    required this.lines,
    required this.payments,
    required this.isClosed,
    this.receiptNumber,
  });

  final String tenantId;
  final String venueId;
  final String orderId;
  final DateTime openedAtUtc;
  final String? tableId;
  final String? tabName;
  final int hubEpoch;
  final int lastSequence;
  final Map<String, OfflineProjectedLine> lines;
  final List<OfflineProjectedPayment> payments;
  final bool isClosed;
  final String? receiptNumber;

  int get totalMinor =>
      lines.values.fold(0, (sum, line) => sum + line.totalMinor);
  int get paidMinor =>
      payments.fold(0, (sum, payment) => sum + payment.baseAmountMinor);
  int get balanceDueMinor => totalMinor - paidMinor;

  Map<String, Object?> toJson() => <String, Object?>{
    'tenantId': tenantId,
    'venueId': venueId,
    'orderId': orderId,
    'hubEpoch': hubEpoch,
    'lastSequence': lastSequence,
    'openedAtUtc': openedAtUtc.toIso8601String(),
    'tableId': tableId,
    'tabName': tabName,
    'isClosed': isClosed,
    'receiptNumber': receiptNumber,
    'lines': lines.values
        .map(
          (line) => <String, Object?>{
            'id': line.id,
            'productId': line.productId,
            'name': line.name,
            'quantity': line.quantity,
            'unitPriceMinor': line.unitPriceMinor,
            'productionArea': line.productionArea,
            'details': line.details,
            'taxRateBasisPoints': line.taxRateBasisPoints,
            'taxRateName': line.taxRateName,
            'sent': line.sent,
          },
        )
        .toList(growable: false),
    'payments': payments
        .map(
          (payment) => <String, Object?>{
            'id': payment.id,
            'baseAmountMinor': payment.baseAmountMinor,
            'tenderedAmountMinor': payment.tenderedAmountMinor,
            'method': payment.method,
            'currencyCode': payment.currencyCode,
            'exchangeRateToBase': payment.exchangeRateToBase,
            'recordedAtUtc': payment.recordedAtUtc.toIso8601String(),
            'terminalLabel': payment.terminalLabel,
            'cashChangeBaseMinor': payment.cashChangeBaseMinor,
          },
        )
        .toList(growable: false),
  };
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
  var lastSequence = 0;
  var opened = false;
  var closed = false;
  String? receiptNumber;

  for (final event in events) {
    if (event.tenantId != first.tenantId || event.venueId != first.venueId) {
      throw const OfflineProjectionException(
        'An event belongs to a different tenant or venue.',
      );
    }
    if (event.hubEpoch != first.hubEpoch) {
      throw const OfflineProjectionException('A stale hub epoch was detected.');
    }
    if (event.sequence <= lastSequence) {
      throw const OfflineProjectionException(
        'The event sequence is duplicated or out of order.',
      );
    }
    lastSequence = event.sequence;
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
        final unitPriceMinor = _nonNegativeInt(event.payload, 'unitPriceMinor');
        lines[lineId] = OfflineProjectedLine(
          id: lineId,
          productId: _requiredString(event.payload, 'productId'),
          name: _requiredString(event.payload, 'productName'),
          quantity: quantity,
          unitPriceMinor: unitPriceMinor,
          productionArea:
              event.payload['productionArea'] as String? ?? 'kitchen',
          details: _productionDetails(event.payload),
          taxRateBasisPoints:
              (event.payload['taxRateBasisPoints'] as num?)?.toInt() ?? 0,
          taxRateName: event.payload['taxRateName'] as String? ?? 'Zero Rate',
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
          (sum, payment) => sum + payment.baseAmountMinor,
        );
        if (alreadyPaid + amountMinor > total) {
          throw const OfflineProjectionException(
            'The payment exceeds the outstanding balance.',
          );
        }
        payments.add(
          OfflineProjectedPayment(
            id: paymentId,
            baseAmountMinor: amountMinor,
            tenderedAmountMinor:
                (event.payload['tenderedAmountMinor'] as num?)?.toInt() ??
                amountMinor,
            method: _requiredString(event.payload, 'method'),
            currencyCode: _requiredString(event.payload, 'currencyCode'),
            exchangeRateToBase:
                event.payload['exchangeRateToBase'] as String? ?? '1',
            recordedAtUtc: event.createdAtUtc,
            terminalLabel: event.payload['terminalLabel'] as String?,
            cashChangeBaseMinor:
                (event.payload['cashChangeBaseMinor'] as num?)?.toInt() ?? 0,
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
          (sum, payment) => sum + payment.baseAmountMinor,
        );
        if (lines.isEmpty || paid != total) {
          throw const OfflineProjectionException(
            'An order may close only when its balance is exactly zero.',
          );
        }
        closed = true;
        receiptNumber = event.payload['receiptNumber'] as String?;
        break;
      case 'receipt.requested':
        _requireOpened(opened);
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
    openedAtUtc: first.createdAtUtc,
    tableId: first.payload['tableId'] as String?,
    tabName: first.payload['tabName'] as String?,
    hubEpoch: first.hubEpoch,
    lastSequence: lastSequence,
    lines: UnmodifiableMapView(lines),
    payments: List.unmodifiable(payments),
    isClosed: closed,
    receiptNumber: receiptNumber,
  );
}

List<String> _productionDetails(Map<String, Object?> payload) {
  final details = <String>[];
  final variantName = payload['variantName'];
  if (variantName is String && variantName.trim().isNotEmpty) {
    details.add(variantName.trim());
  }
  final modifiers = payload['modifierSelections'];
  if (modifiers is List) {
    for (final raw in modifiers) {
      if (raw is Map && raw['optionName'] is String) {
        details.add((raw['optionName'] as String).trim());
      }
    }
  }
  final note = payload['itemNote'];
  if (note is String && note.trim().isNotEmpty) {
    details.add('NOTE: ${note.trim()}');
  }
  return List.unmodifiable(details);
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
