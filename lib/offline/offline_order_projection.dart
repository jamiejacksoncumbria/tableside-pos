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
    this.addedAtUtc,
    this.sentAtUtc,
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
  final DateTime? addedAtUtc;
  final DateTime? sentAtUtc;

  int get totalMinor => quantity * unitPriceMinor;

  OfflineProjectedLine copyWith({
    int? quantity,
    int? unitPriceMinor,
    bool? sent,
    DateTime? sentAtUtc,
  }) => OfflineProjectedLine(
    id: id,
    productId: productId,
    name: name,
    quantity: quantity ?? this.quantity,
    unitPriceMinor: unitPriceMinor ?? this.unitPriceMinor,
    productionArea: productionArea,
    details: details,
    taxRateBasisPoints: taxRateBasisPoints,
    taxRateName: taxRateName,
    sent: sent ?? this.sent,
    addedAtUtc: addedAtUtc,
    sentAtUtc: sentAtUtc ?? this.sentAtUtc,
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
    this.closedAtUtc,
    this.channel = 'dineIn',
    this.customerId,
    this.customerName,
    this.customerPhone,
    this.deliveryAddress,
    this.deliveryAddressLabel,
    this.deliveryLatitude,
    this.deliveryLongitude,
    this.serviceAreaId,
    this.serviceAreaName,
    this.deliveryFeeMinor = 0,
    this.scheduledForUtc,
    this.fulfilmentStatus = 'awaitingPreparation',
    this.assignedDriverId,
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
  final DateTime? closedAtUtc;
  final String channel;
  final String? customerId;
  final String? customerName;
  final String? customerPhone;
  final String? deliveryAddress;
  final String? deliveryAddressLabel;
  final double? deliveryLatitude;
  final double? deliveryLongitude;
  final String? serviceAreaId;
  final String? serviceAreaName;
  final int deliveryFeeMinor;
  final DateTime? scheduledForUtc;
  final String fulfilmentStatus;
  final String? assignedDriverId;

  int get totalMinor =>
      lines.values.fold(0, (sum, line) => sum + line.totalMinor) +
      (channel == 'delivery' ? deliveryFeeMinor : 0);
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
    'closedAtUtc': closedAtUtc?.toIso8601String(),
    'channel': channel,
    'customerId': customerId,
    'customerName': customerName,
    'customerPhone': customerPhone,
    'deliveryAddress': deliveryAddress,
    'deliveryAddressLabel': deliveryAddressLabel,
    'deliveryLatitude': deliveryLatitude,
    'deliveryLongitude': deliveryLongitude,
    'serviceAreaId': serviceAreaId,
    'serviceAreaName': serviceAreaName,
    'deliveryFeeMinor': deliveryFeeMinor,
    'scheduledForUtc': scheduledForUtc?.toIso8601String(),
    'fulfilmentStatus': fulfilmentStatus,
    'assignedDriverId': assignedDriverId,
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
            'addedAtUtc': line.addedAtUtc?.toIso8601String(),
            'sentAtUtc': line.sentAtUtc?.toIso8601String(),
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
  DateTime? closedAtUtc;
  var channel = 'dineIn';
  String? customerId;
  String? customerName;
  String? customerPhone;
  String? deliveryAddress;
  String? deliveryAddressLabel;
  double? deliveryLatitude;
  double? deliveryLongitude;
  String? serviceAreaId;
  String? serviceAreaName;
  var deliveryFeeMinor = 0;
  DateTime? scheduledForUtc;
  var fulfilmentStatus = 'awaitingPreparation';
  String? assignedDriverId;

  // A replacement hub starts a new immutable epoch, but open orders may have
  // been created by the preceding hub. The cloud signs these baselines into
  // the encrypted snapshot. Seed replay from that trusted state before
  // applying new-epoch events, even when the baseline was appended later to
  // repair an order that had already received a command.
  final baselines = events
      .where((event) => event.type == 'order.cloudBaseline')
      .toList(growable: false);
  if (baselines.length > 1) {
    throw const OfflineProjectionException(
      'An order has more than one cloud baseline.',
    );
  }
  final baseline = baselines.firstOrNull;
  DateTime openedAtUtc = first.createdAtUtc;
  String? tableId = first.payload['tableId'] as String?;
  String? tabName = first.payload['tabName'] as String?;
  if (baseline != null) {
    final payload = baseline.payload;
    final sourceEpoch = (payload['sourceOfflineHubEpoch'] as num?)?.toInt();
    if (sourceEpoch == null || sourceEpoch > baseline.hubEpoch) {
      throw const OfflineProjectionException(
        'The cloud baseline belongs to a future hub epoch.',
      );
    }
    opened = true;
    openedAtUtc =
        DateTime.tryParse(payload['openedAtUtc'] as String? ?? '')?.toUtc() ??
        baseline.createdAtUtc;
    tableId = payload['tableId'] as String?;
    tabName = payload['tabName'] as String?;
    channel = payload['channel'] as String? ?? 'dineIn';
    if (!const ['dineIn', 'collection', 'delivery'].contains(channel)) {
      throw const OfflineProjectionException(
        'The cloud baseline channel is invalid.',
      );
    }
    customerId = payload['customerId'] as String?;
    customerName = payload['customerName'] as String?;
    customerPhone = payload['customerPhone'] as String?;
    deliveryAddress = payload['deliveryAddress'] as String?;
    deliveryAddressLabel = payload['deliveryAddressLabel'] as String?;
    deliveryLatitude = (payload['deliveryLatitude'] as num?)?.toDouble();
    deliveryLongitude = (payload['deliveryLongitude'] as num?)?.toDouble();
    serviceAreaId = payload['serviceAreaId'] as String?;
    serviceAreaName = payload['serviceAreaName'] as String?;
    deliveryFeeMinor = (payload['deliveryFeeMinor'] as num?)?.toInt() ?? 0;
    scheduledForUtc = DateTime.tryParse(
      payload['scheduledForUtc'] as String? ?? '',
    )?.toUtc();
    fulfilmentStatus =
        payload['fulfilmentStatus'] as String? ??
        (channel == 'delivery' ? 'awaitingDriver' : 'awaitingPreparation');
    assignedDriverId = payload['assignedDriverId'] as String?;
    final rawLines = payload['lines'];
    if (rawLines is! List) {
      throw const OfflineProjectionException(
        'The cloud baseline lines are invalid.',
      );
    }
    for (final raw in rawLines) {
      if (raw is! Map) {
        throw const OfflineProjectionException(
          'A cloud baseline line is invalid.',
        );
      }
      final value = Map<String, Object?>.from(raw);
      final lineId = _requiredString(value, 'id');
      if (lines.containsKey(lineId)) {
        throw const OfflineProjectionException(
          'A cloud baseline line ID was used more than once.',
        );
      }
      lines[lineId] = OfflineProjectedLine(
        id: lineId,
        productId: _requiredString(value, 'productId'),
        name: _requiredString(value, 'name'),
        quantity: _positiveInt(value, 'quantity'),
        unitPriceMinor: _nonNegativeInt(value, 'unitPriceMinor'),
        productionArea: value['productionArea'] as String? ?? 'kitchen',
        details:
            (value['details'] as List?)?.whereType<String>().toList(
              growable: false,
            ) ??
            const <String>[],
        taxRateBasisPoints: (value['taxRateBasisPoints'] as num?)?.toInt() ?? 0,
        taxRateName: value['taxRateName'] as String? ?? 'Zero Rate',
        sent: value['sent'] == true,
        addedAtUtc: DateTime.tryParse(
          value['addedAtUtc'] as String? ?? '',
        )?.toUtc(),
        sentAtUtc: DateTime.tryParse(
          value['sentAtUtc'] as String? ?? '',
        )?.toUtc(),
      );
    }
    final rawPayments = payload['payments'];
    if (rawPayments is! List) {
      throw const OfflineProjectionException(
        'The cloud baseline payments are invalid.',
      );
    }
    for (final raw in rawPayments) {
      if (raw is! Map) {
        throw const OfflineProjectionException(
          'A cloud baseline payment is invalid.',
        );
      }
      final value = Map<String, Object?>.from(raw);
      final paymentId = _requiredString(value, 'id');
      if (!paymentIds.add(paymentId)) {
        throw const OfflineProjectionException(
          'A cloud baseline payment ID was used more than once.',
        );
      }
      payments.add(
        OfflineProjectedPayment(
          id: paymentId,
          baseAmountMinor: _positiveInt(value, 'baseAmountMinor'),
          tenderedAmountMinor:
              (value['tenderedAmountMinor'] as num?)?.toInt() ??
              _positiveInt(value, 'baseAmountMinor'),
          method: _requiredString(value, 'method'),
          currencyCode: _requiredString(value, 'currencyCode'),
          exchangeRateToBase: value['exchangeRateToBase'] as String? ?? '1',
          recordedAtUtc:
              DateTime.tryParse(
                value['recordedAtUtc'] as String? ?? '',
              )?.toUtc() ??
              baseline.createdAtUtc,
          terminalLabel: value['terminalLabel'] as String?,
          cashChangeBaseMinor:
              (value['cashChangeBaseMinor'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    final total =
        lines.values.fold<int>(0, (sum, line) => sum + line.totalMinor) +
        (channel == 'delivery' ? deliveryFeeMinor : 0);
    final paid = payments.fold<int>(
      0,
      (sum, payment) => sum + payment.baseAmountMinor,
    );
    if (paid > total) {
      throw const OfflineProjectionException('The cloud baseline is overpaid.');
    }
  }

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
    if (event.type == 'order.cloudBaseline') {
      // The signed baseline is applied before chronological replay. It can be
      // appended after a local close during recovery, so encountering its
      // sequence after closure is a no-op rather than a post-close mutation.
      continue;
    }
    if (closed) {
      throw const OfflineProjectionException(
        'A closed offline order cannot be changed.',
      );
    }

    switch (event.type) {
      case 'order.opened':
        if (opened) {
          if (baseline != null) break;
          throw const OfflineProjectionException(
            'The order was opened more than once.',
          );
        }
        opened = true;
        channel = event.payload['channel'] as String? ?? 'dineIn';
        if (!const ['dineIn', 'collection', 'delivery'].contains(channel)) {
          throw const OfflineProjectionException(
            'The order channel is invalid.',
          );
        }
        customerId = event.payload['customerId'] as String?;
        customerName = event.payload['customerName'] as String?;
        customerPhone = event.payload['customerPhone'] as String?;
        deliveryAddress = event.payload['deliveryAddress'] as String?;
        deliveryAddressLabel = event.payload['deliveryAddressLabel'] as String?;
        deliveryLatitude = (event.payload['deliveryLatitude'] as num?)
            ?.toDouble();
        deliveryLongitude = (event.payload['deliveryLongitude'] as num?)
            ?.toDouble();
        serviceAreaId = event.payload['serviceAreaId'] as String?;
        serviceAreaName = event.payload['serviceAreaName'] as String?;
        deliveryFeeMinor =
            (event.payload['deliveryFeeMinor'] as num?)?.toInt() ?? 0;
        final scheduled = event.payload['scheduledForUtc'] as String?;
        scheduledForUtc = scheduled == null
            ? null
            : DateTime.tryParse(scheduled)?.toUtc();
        if (channel != 'dineIn' &&
            (customerId?.trim().isEmpty != false ||
                customerName?.trim().isEmpty != false)) {
          throw const OfflineProjectionException(
            'A fulfilment order needs a customer.',
          );
        }
        if (channel == 'delivery' && deliveryAddress?.trim().isEmpty != false) {
          throw const OfflineProjectionException(
            'A delivery order needs an address.',
          );
        }
        fulfilmentStatus = channel == 'delivery'
            ? 'awaitingDriver'
            : 'awaitingPreparation';
        break;
      case 'order.itemAdded':
        _requireOpened(opened);
        final lineId = _requiredString(event.payload, 'lineId');
        if (lines.containsKey(lineId)) {
          final existing = lines[lineId]!;
          // A same-epoch recovery baseline already contains cloud-projected
          // lines. Replaying the original add is idempotent when its immutable
          // sale identity matches; later quantity events still replay below.
          final sameCloudLine =
              baseline != null &&
              existing.productId ==
                  _requiredString(event.payload, 'productId') &&
              existing.name == _requiredString(event.payload, 'productName') &&
              existing.unitPriceMinor ==
                  _nonNegativeInt(event.payload, 'unitPriceMinor');
          if (sameCloudLine) break;
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
          addedAtUtc: event.createdAtUtc,
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
      case 'order.lineAdjusted':
        _requireOpened(opened);
        final lineId = _requiredString(event.payload, 'lineId');
        final existing = lines[lineId];
        if (existing == null) {
          throw const OfflineProjectionException(
            'Only an existing sale line can be adjusted.',
          );
        }
        final operation = _requiredString(event.payload, 'operation');
        final reason = _requiredString(event.payload, 'reason').trim();
        if (reason.isEmpty) {
          throw const OfflineProjectionException(
            'A manager adjustment needs a reason.',
          );
        }
        if (operation == 'remove') {
          lines.remove(lineId);
        } else {
          final valueMinor = _nonNegativeInt(event.payload, 'valueMinor');
          final nextPrice = operation == 'setUnitPrice'
              ? valueMinor
              : operation == 'discountUnitAmount'
              ? existing.unitPriceMinor - valueMinor
              : -1;
          if (nextPrice < 0) {
            throw const OfflineProjectionException(
              'The manager price adjustment is invalid.',
            );
          }
          lines[lineId] = existing.copyWith(unitPriceMinor: nextPrice);
        }
        final adjustedTotal =
            lines.values.fold<int>(0, (sum, line) => sum + line.totalMinor) +
            (channel == 'delivery' ? deliveryFeeMinor : 0);
        final alreadyPaid = payments.fold<int>(
          0,
          (sum, payment) => sum + payment.baseAmountMinor,
        );
        if (adjustedTotal < alreadyPaid) {
          throw const OfflineProjectionException(
            'This adjustment would invalidate payments already recorded.',
          );
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
          lines[value] = lines[value]!.copyWith(
            sent: true,
            sentAtUtc: event.createdAtUtc,
          );
        }
        break;
      case 'order.fulfilmentChanged':
        _requireOpened(opened);
        final status = _requiredString(event.payload, 'status');
        if (!const {
          'awaitingPreparation',
          'readyForCollection',
          'awaitingDriver',
          'assigned',
          'driverDeclined',
          'outForDelivery',
          'collected',
          'delivered',
          'cancelled',
        }.contains(status)) {
          throw const OfflineProjectionException(
            'The fulfilment status is invalid.',
          );
        }
        final managerAuthorized = event.payload['managerAuthorized'] == true;
        if (!managerAuthorized &&
            (assignedDriverId == null ||
                event.staffId != assignedDriverId ||
                !const {
                  'driverDeclined',
                  'outForDelivery',
                  'delivered',
                }.contains(status))) {
          throw const OfflineProjectionException(
            'A driver may update only their own assigned delivery.',
          );
        }
        // Historic delivery events predate structured service areas. They
        // must remain replayable so an upgraded hub can start and complete
        // those orders. New order.opened commands are still fail-closed by
        // VenueOfflineCatalogue.validateDeliveryArea before being committed.
        fulfilmentStatus = status;
        assignedDriverId = status == 'driverDeclined'
            ? null
            : event.payload['driverId'] as String? ?? assignedDriverId;
        break;
      case 'payment.recorded':
        _requireOpened(opened);
        final paymentId = _requiredString(event.payload, 'paymentId');
        if (!paymentIds.add(paymentId)) {
          final existing = payments.where((item) => item.id == paymentId).first;
          if (baseline != null &&
              existing.baseAmountMinor ==
                  _positiveInt(event.payload, 'baseAmountMinor')) {
            break;
          }
          throw const OfflineProjectionException(
            'A payment ID was used more than once.',
          );
        }
        final amountMinor = _positiveInt(event.payload, 'baseAmountMinor');
        // Delivery charges are part of the bill. This replay validation must
        // use the same total as [OfflineOrderProjection.totalMinor] and the
        // pre-commit order-book check; otherwise a valid full delivery payment
        // is incorrectly treated as an overpayment by exactly the fee amount.
        final total =
            lines.values.fold<int>(0, (sum, line) => sum + line.totalMinor) +
            (channel == 'delivery' ? deliveryFeeMinor : 0);
        final alreadyPaid = payments.fold<int>(
          0,
          (sum, payment) => sum + payment.baseAmountMinor,
        );
        if (alreadyPaid + amountMinor > total) {
          throw OfflineProjectionException(
            'The payment exceeds the outstanding balance '
            '(attempted $amountMinor minor units; '
            'remaining ${total - alreadyPaid}).',
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
      case 'payment.batchRecorded':
        _requireOpened(opened);
        _requiredString(event.payload, 'batchId');
        final rawPayments = event.payload['payments'];
        if (rawPayments is! List || rawPayments.any((value) => value is! Map)) {
          throw const OfflineProjectionException(
            'The payment batch is invalid.',
          );
        }
        final total =
            lines.values.fold<int>(0, (sum, line) => sum + line.totalMinor) +
            (channel == 'delivery' ? deliveryFeeMinor : 0);
        var paid = payments.fold<int>(
          0,
          (sum, payment) => sum + payment.baseAmountMinor,
        );
        for (final rawPayment in rawPayments.whereType<Map>()) {
          final payment = Map<String, Object?>.from(rawPayment);
          final paymentId = _requiredString(payment, 'paymentId');
          final amountMinor = _positiveInt(payment, 'baseAmountMinor');
          if (!paymentIds.add(paymentId)) {
            final existing = payments
                .where((item) => item.id == paymentId)
                .first;
            if (existing.baseAmountMinor == amountMinor) continue;
            throw const OfflineProjectionException(
              'A payment ID was used more than once.',
            );
          }
          if (paid + amountMinor > total) {
            throw const OfflineProjectionException(
              'The payment batch exceeds the outstanding balance.',
            );
          }
          payments.add(
            OfflineProjectedPayment(
              id: paymentId,
              baseAmountMinor: amountMinor,
              tenderedAmountMinor:
                  (payment['tenderedAmountMinor'] as num?)?.toInt() ??
                  amountMinor,
              method: _requiredString(payment, 'method'),
              currencyCode: _requiredString(payment, 'currencyCode'),
              exchangeRateToBase:
                  payment['exchangeRateToBase'] as String? ?? '1',
              recordedAtUtc: event.createdAtUtc,
              terminalLabel: payment['terminalLabel'] as String?,
              cashChangeBaseMinor:
                  (payment['cashChangeBaseMinor'] as num?)?.toInt() ?? 0,
            ),
          );
          paid += amountMinor;
        }
        if (event.payload['closeIfSettled'] == true) {
          if (lines.isEmpty || paid != total) {
            throw const OfflineProjectionException(
              'An order may close only when its balance is exactly zero.',
            );
          }
          closed = true;
          receiptNumber = event.payload['receiptNumber'] as String?;
          closedAtUtc = event.createdAtUtc;
        }
        break;
      case 'order.closed':
        _requireOpened(opened);
        final total =
            lines.values.fold<int>(0, (sum, line) => sum + line.totalMinor) +
            (channel == 'delivery' ? deliveryFeeMinor : 0);
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
        closedAtUtc = event.createdAtUtc;
        break;
      case 'order.cancelled':
        _requireOpened(opened);
        final reason = event.payload['reason'];
        if (lines.isNotEmpty ||
            payments.isNotEmpty ||
            reason is! String ||
            reason.trim().length < 3) {
          throw const OfflineProjectionException(
            'Only an empty, unpaid order can be cancelled.',
          );
        }
        closed = true;
        receiptNumber = null;
        closedAtUtc = event.createdAtUtc;
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
    openedAtUtc: openedAtUtc,
    tableId: tableId,
    tabName: tabName,
    hubEpoch: first.hubEpoch,
    lastSequence: lastSequence,
    lines: UnmodifiableMapView(lines),
    payments: List.unmodifiable(payments),
    isClosed: closed,
    receiptNumber: receiptNumber,
    closedAtUtc: closedAtUtc,
    channel: channel,
    customerId: customerId,
    customerName: customerName,
    customerPhone: customerPhone,
    deliveryAddress: deliveryAddress,
    deliveryAddressLabel: deliveryAddressLabel,
    deliveryLatitude: deliveryLatitude,
    deliveryLongitude: deliveryLongitude,
    serviceAreaId: serviceAreaId,
    serviceAreaName: serviceAreaName,
    deliveryFeeMinor: deliveryFeeMinor,
    scheduledForUtc: scheduledForUtc,
    fulfilmentStatus: fulfilmentStatus,
    assignedDriverId: assignedDriverId,
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
