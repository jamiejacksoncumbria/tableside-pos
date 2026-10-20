import 'dart:async';
import 'dart:convert';

import '../core/app_logger.dart';
import 'offline_event.dart';
import 'offline_event_ledger.dart';
import 'offline_order_projection.dart';
import 'venue_offline_catalogue.dart';

/// Returns the business identity used when a client repeats an already
/// committed operation. Exposed for regression tests because weakening this
/// comparison can duplicate payments, while making it too broad strands
/// legitimate remote POS reconnects.
Map<String, Object?> offlineRetrySemanticPayload(
  String eventType,
  Map<String, Object?> value,
) {
  final result = Map<String, Object?>.from(value)..remove('remoteCommandId');
  if (eventType == 'order.opened') {
    return <String, Object?>{
      'orderId': result['orderId'],
      'tableId': result['tableId'],
      'tabName': result['tabName'],
      'channel': result['channel'] ?? 'dineIn',
    };
  }
  return result;
}

/// Serialises financial mutations and validates each proposed command before
/// it enters the append-only ledger. On restart, the complete encrypted event
/// chain is replayed so a separate mutable cache never becomes the authority.
class VenueOfflineOrderBook {
  VenueOfflineOrderBook({
    required this.tenantId,
    required this.venueId,
    required this.hubEpoch,
    this.catalogueProvider,
    OfflineEventLedger? ledger,
  }) : _ledger = ledger ?? OfflineEventLedger.instance;

  final String tenantId;
  final String venueId;
  final int hubEpoch;
  final OfflineEventLedger _ledger;
  final VenueOfflineCatalogue Function()? catalogueProvider;
  Future<void> _serial = Future.value();

  Future<OfflineEvent> commit(OfflineEventDraft draft, int epoch) {
    final completer = Completer<OfflineEvent>();
    _serial = _serial.then((_) async {
      try {
        if (epoch != hubEpoch ||
            draft.tenantId != tenantId ||
            draft.venueId != venueId) {
          throw const OfflineProjectionException(
            'The command belongs to a stale or different venue hub.',
          );
        }
        final existing = await _ledger.eventsForVenue(
          tenantId: tenantId,
          venueId: venueId,
          hubEpoch: hubEpoch,
        );
        final previous = _idempotentRetry(existing, draft);
        if (previous != null) {
          completer.complete(previous);
          return;
        }
        _validateProposed(existing, draft);
        // Replay a synthetic copy before appending it. Once an event reaches
        // the encrypted ledger it is a real financial fact, so no projection
        // error is allowed to surface only after the durable commit.
        _projectAffectedOrder([
          ...existing,
          OfflineEvent(
            id: 'preflight-${existing.length + 1}',
            tenantId: draft.tenantId,
            venueId: draft.venueId,
            deviceId: draft.deviceId,
            staffId: draft.staffId,
            managerApprovalStaffId: draft.managerApprovalStaffId,
            type: draft.type,
            payload: draft.payload,
            createdAtUtc: DateTime.now().toUtc(),
            deviceObservedAtUtc: DateTime.now().toUtc(),
            timeAuthority: OfflineTimeAuthority.venueHub,
            clockSkewMillis: 0,
            businessTimestampUtc:
                draft.businessTimestamp?.toUtc() ?? DateTime.now().toUtc(),
            sequence: existing.isEmpty ? 1 : existing.last.sequence + 1,
            hubEpoch: hubEpoch,
            previousHash: '',
            eventHash: '',
            syncState: OfflineEventSyncState.pending,
          ),
        ], draft.payload['orderId']);
        final event = await _ledger.commit(draft, hubEpoch: hubEpoch);
        completer.complete(event);
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  OfflineEvent? _idempotentRetry(
    List<OfflineEvent> existing,
    OfflineEventDraft draft,
  ) {
    final remoteCommandId = draft.payload['remoteCommandId'];
    if (remoteCommandId is String && remoteCommandId.isNotEmpty) {
      final remoteMatches = existing
          .where((event) => event.payload['remoteCommandId'] == remoteCommandId)
          .toList(growable: false);
      if (remoteMatches.isNotEmpty) {
        final previous = remoteMatches.last;
        if (previous.type != draft.type ||
            _canonicalJson(previous.payload) != _canonicalJson(draft.payload)) {
          throw const OfflineProjectionException(
            'A remote command key was reused with different data.',
          );
        }
        return previous;
      }
    }
    if (draft.type == 'order.opened') {
      final splitMatches = existing
          .where(
            (event) =>
                event.type == 'order.splitCreated' &&
                event.payload['splitOrderId'] == draft.payload['orderId'],
          )
          .toList(growable: false);
      if (splitMatches.isNotEmpty) {
        final split = splitMatches.last;
        final child = _projectOrderEvents(
          _eventsForOrder(existing, draft.payload['orderId']! as String),
        );
        final childIdentity = <String, Object?>{
          'orderId': child.orderId,
          'tableId': child.tableId,
          'tabName': child.tabName,
          'channel': child.channel,
        };
        if (!_sameOpenedOrderIdentity(childIdentity, draft.payload)) {
          throw const OfflineProjectionException(
            'The split bill identity does not match this table or tab.',
          );
        }
        // A split child is created by the single atomic split event rather
        // than a second order.opened write. Treat the normal pre-payment
        // ensureOrderOpened request as an idempotent assertion of that child.
        return split;
      }
      final baselineMatches = existing
          .where(
            (event) =>
                event.type == 'order.cloudBaseline' &&
                event.payload['orderId'] == draft.payload['orderId'],
          )
          .toList(growable: false);
      if (baselineMatches.isNotEmpty) {
        final baseline = baselineMatches.last;
        if (!_sameOpenedOrderIdentity(baseline.payload, draft.payload)) {
          throw const OfflineProjectionException(
            'The restored order identity does not match this table or tab.',
          );
        }
        // A replacement hub can know an open order only through its signed
        // cloud baseline. `ensureOrderOpened` is an idempotent assertion, not
        // a request to create a second order. Return that durable baseline as
        // the acknowledgement and do not append a duplicate opening event.
        return baseline;
      }
      final openedMatches = existing
          .where(
            (event) =>
                event.type == 'order.opened' &&
                event.payload['orderId'] == draft.payload['orderId'],
          )
          .toList(growable: false);
      if (openedMatches.isNotEmpty) {
        final opened = openedMatches.last;
        if (!_sameOpenedOrderIdentity(opened.payload, draft.payload)) {
          throw const OfflineProjectionException(
            'The open order identity changed between devices.',
          );
        }
        // ensureOrderOpened is an assertion that may be repeated before Send,
        // payment or fulfilment changes. Optional details can be absent from a
        // later client payload, so compare the protected location identity
        // rather than treating the assertion as a reused mutation key.
        return opened;
      }
    }
    bool hasSameIdentity(OfflineEvent event) {
      if (event.type != draft.type ||
          event.payload['orderId'] != draft.payload['orderId']) {
        return false;
      }
      return switch (draft.type) {
        'order.closed' || 'order.cancelled' => true,
        'order.itemAdded' ||
        'order.itemQuantityChanged' ||
        'order.lineAdjusted' =>
          event.payload['lineId'] == draft.payload['lineId'],
        'order.itemsAdded' =>
          _canonicalJson(event.payload['items']) ==
              _canonicalJson(draft.payload['items']),
        'payment.recorded' =>
          event.payload['paymentId'] == draft.payload['paymentId'],
        'payment.batchRecorded' =>
          event.payload['batchId'] == draft.payload['batchId'],
        'order.splitCreated' =>
          event.payload['splitOrderId'] == draft.payload['splitOrderId'],
        'order.sent' =>
          _canonicalJson(event.payload['lineIds']) ==
              _canonicalJson(draft.payload['lineIds']),
        'order.fulfilmentChanged' =>
          event.payload['status'] == draft.payload['status'] &&
              event.payload['driverId'] == draft.payload['driverId'],
        _ => false,
      };
    }

    final matches = existing.where(hasSameIdentity).toList(growable: false);
    if (matches.isEmpty) return null;
    final previous = matches.last;
    if (_canonicalJson(
          offlineRetrySemanticPayload(draft.type, previous.payload),
        ) !=
        _canonicalJson(
          offlineRetrySemanticPayload(draft.type, draft.payload),
        )) {
      throw const OfflineProjectionException(
        'An offline retry key was reused with different data.',
      );
    }
    return previous;
  }

  Future<Map<String, OfflineOrderProjection>> rebuild() async {
    final events = await _ledger.eventsForVenue(
      tenantId: tenantId,
      venueId: venueId,
      hubEpoch: hubEpoch,
    );
    final orderEvents = events.where(_isOrderEvent).toList(growable: false);
    final orderIds = <String>{};
    for (final event in orderEvents) {
      final orderId = event.payload['orderId'];
      if (orderId is! String || orderId.isEmpty) {
        throw const OfflineProjectionException(
          'An offline event does not identify an order.',
        );
      }
      orderIds.add(orderId);
      if (event.type == 'order.splitCreated') {
        final splitOrderId = event.payload['splitOrderId'];
        if (splitOrderId is! String || splitOrderId.isEmpty) {
          throw const OfflineProjectionException(
            'A split event does not identify its child bill.',
          );
        }
        orderIds.add(splitOrderId);
      }
    }
    final result = <String, OfflineOrderProjection>{};
    for (final orderId in orderIds) {
      result[orderId] = _projectOrderEvents(
        _eventsForOrder(orderEvents, orderId),
      );
    }
    // A settled child is no longer an obstacle to closing its main bill. The
    // immutable split event remains unchanged; this is derived state only.
    for (final entry in result.entries.toList(growable: false)) {
      final openChildren = entry.value.openSplitOrderIds
          .where((id) => result[id]?.isClosed == false)
          .toList(growable: false);
      if (openChildren.length != entry.value.openSplitOrderIds.length) {
        result[entry.key] = entry.value.withOpenSplitOrderIds(openChildren);
      }
    }
    return result;
  }

  /// Imports cloud-signed active orders that are absent from the local ledger
  /// exactly once. These immutable baseline events let a replacement or
  /// repaired hub continue a bill without inventing prices, lines or payments
  /// locally. A same-epoch baseline is valid because the signed snapshot can
  /// outlive damaged or replaced local storage without changing hub ownership.
  Future<void> installCloudBaselines(Map<String, Object?> snapshot) async {
    final rawOrders = snapshot['openOrders'];
    if (rawOrders is! List) return;
    final restored = await _ledger.restoreQuarantinedCloudBaselines(
      tenantId: tenantId,
      venueId: venueId,
      hubEpoch: hubEpoch,
    );
    if (restored > 0) {
      AppLogger.info(
        'Restored $restored cloud baseline event(s) to preserve the offline upload sequence.',
      );
    }
    final existing = await _ledger.eventsForVenue(
      tenantId: tenantId,
      venueId: venueId,
      hubEpoch: hubEpoch,
    );
    final localByOrder = <String, List<OfflineEvent>>{};
    for (final event in existing.where(_isOrderEvent)) {
      final orderId = event.payload['orderId'];
      if (orderId is! String || orderId.isEmpty) continue;
      localByOrder.putIfAbsent(orderId, () => []).add(event);
      if (event.type == 'order.splitCreated' &&
          event.payload['splitOrderId'] is String) {
        localByOrder.putIfAbsent(
          event.payload['splitOrderId']! as String,
          () => <OfflineEvent>[event],
        );
      }
    }

    // A cloud order can still be open while its valid local close is waiting
    // to sync. Never layer a recovery baseline over an order the append-only
    // local ledger can already reconstruct: doing so would duplicate its
    // balance authority. The event remains in the durable upload chain, but
    // local projection ignores it when the local event chain is complete.
    final reconstructable = <String>{};
    reconstructable.addAll(
      existing
          .where((event) => event.type == 'order.splitCreated')
          .map((event) => event.payload['splitOrderId'])
          .whereType<String>(),
    );
    for (final entry in localByOrder.entries) {
      final withoutBaselines = entry.value
          .where((event) => event.type != 'order.cloudBaseline')
          .toList(growable: false);
      if (withoutBaselines.isEmpty) continue;
      try {
        projectOfflineOrder(withoutBaselines);
        reconstructable.add(entry.key);
      } on OfflineProjectionException {
        // An incomplete replacement-hub chain may genuinely require its
        // signed cloud baseline, so it remains fail-closed and is not removed.
      }
    }

    final installed = existing
        .where((event) => event.type == 'order.cloudBaseline')
        .map((event) => event.payload['orderId'])
        .whereType<String>()
        .toSet();
    for (final raw in rawOrders) {
      if (raw is! Map) continue;
      final baseline = Map<String, Object?>.from(raw);
      final orderId = baseline['orderId'];
      final sourceEpoch = (baseline['sourceOfflineHubEpoch'] as num?)?.toInt();
      if (orderId is! String ||
          orderId.isEmpty ||
          sourceEpoch == null ||
          sourceEpoch > hubEpoch ||
          reconstructable.contains(orderId) ||
          installed.contains(orderId)) {
        continue;
      }
      await _ledger.commit(
        OfflineEventDraft(
          tenantId: tenantId,
          venueId: venueId,
          deviceId: 'hub-cloud-migration',
          staffId: 'cloud-verified-baseline',
          type: 'order.cloudBaseline',
          payload: baseline,
        ),
        hubEpoch: hubEpoch,
      );
      installed.add(orderId);
    }
  }

  Future<OfflineOrderProjection> order(String orderId) async {
    final orders = await rebuild();
    final result = orders[orderId];
    if (result == null) {
      throw const OfflineProjectionException('The order is not open.');
    }
    return result;
  }

  void _validateProposed(List<OfflineEvent> existing, OfflineEventDraft draft) {
    final orderId = draft.payload['orderId'];
    if (orderId is! String || orderId.isEmpty) {
      throw const OfflineProjectionException(
        'The offline command does not identify an order.',
      );
    }
    final orderEvents = _eventsForOrder(existing, orderId);
    if (draft.type == 'order.opened') {
      if (orderEvents.isNotEmpty) {
        throw const OfflineProjectionException('The order already exists.');
      }
      final tabName = draft.payload['tabName'];
      if (tabName is String && tabName.trim().isNotEmpty) {
        final key = tabName.trim().toLowerCase();
        final grouped = <String, List<OfflineEvent>>{};
        for (final event in existing) {
          final existingOrderId = event.payload['orderId'];
          if (existingOrderId is String) {
            grouped
                .putIfAbsent(existingOrderId, () => <OfflineEvent>[])
                .add(event);
          }
        }
        for (final events in grouped.values) {
          final opened = events.firstWhere(
            (event) => event.type == 'order.opened',
            orElse: () => events.first,
          );
          final existingName = opened.payload['tabName'];
          if (existingName is String &&
              existingName.trim().toLowerCase() == key &&
              !_projectOrderEvents(events).isClosed) {
            throw const OfflineProjectionException(
              'A tab is already open with this name.',
            );
          }
        }
      }
      catalogueProvider?.call().validateDeliveryArea(draft.payload);
      return;
    }
    if (orderEvents.isEmpty) {
      throw const OfflineProjectionException('The order is not open.');
    }
    final current = _projectOrderEvents(orderEvents);
    if (current.isClosed &&
        draft.type != 'order.fulfilmentChanged' &&
        draft.type != 'receipt.requested') {
      throw const OfflineProjectionException(
        'A closed offline order cannot be changed.',
      );
    }
    switch (draft.type) {
      case 'order.itemAdded':
        final lineId = draft.payload['lineId'];
        if (lineId is! String ||
            lineId.isEmpty ||
            current.lines.containsKey(lineId)) {
          throw const OfflineProjectionException(
            'The order line ID is invalid.',
          );
        }
        break;
      case 'order.itemsAdded':
        final rawItems = draft.payload['items'];
        if (rawItems is! List || rawItems.isEmpty) {
          throw const OfflineProjectionException(
            'The basket batch is empty or invalid.',
          );
        }
        final lineIds = <String>{};
        for (final raw in rawItems) {
          if (raw is! Map) {
            throw const OfflineProjectionException('A basket item is invalid.');
          }
          final lineId = raw['lineId'];
          if (lineId is! String ||
              lineId.isEmpty ||
              !lineIds.add(lineId) ||
              current.lines.containsKey(lineId)) {
            throw const OfflineProjectionException(
              'A basket line ID is invalid.',
            );
          }
        }
        break;
      case 'order.itemQuantityChanged':
        final lineId = draft.payload['lineId'];
        final line = current.lines[lineId];
        if (line == null || line.sent) {
          throw const OfflineProjectionException(
            'Only an unsent line can change quantity.',
          );
        }
        break;
      case 'order.lineAdjusted':
        final lineId = draft.payload['lineId'];
        final line = current.lines[lineId];
        final operation = draft.payload['operation'];
        final reason = draft.payload['reason'];
        final valueMinor = draft.payload['valueMinor'];
        if (lineId is! String ||
            line == null ||
            reason is! String ||
            reason.trim().isEmpty ||
            !const {
              'remove',
              'setUnitPrice',
              'discountUnitAmount',
            }.contains(operation) ||
            (operation != 'remove' && (valueMinor is! int || valueMinor < 0))) {
          throw const OfflineProjectionException(
            'The manager sale adjustment is invalid.',
          );
        }
        break;
      case 'order.sent':
        final lineIds = draft.payload['lineIds'];
        if (lineIds is! List ||
            lineIds.isEmpty ||
            lineIds.any(
              (id) => current.lines[id] == null || current.lines[id]!.sent,
            )) {
          throw const OfflineProjectionException(
            'The send command contains an unknown line.',
          );
        }
        catalogueProvider?.call().validateStockForSend(
          existing,
          current,
          lineIds.whereType<String>().toList(growable: false),
          managerOverride: draft.payload['stockOverride'] == true,
        );
        catalogueProvider?.call().validatePrintRoutes(
          current,
          lineIds.whereType<String>().toList(growable: false),
          printRequired: draft.payload['printRequired'] == true,
        );
        break;
      case 'order.splitCreated':
        final splitOrderId = draft.payload['splitOrderId'];
        final rawAllocations = draft.payload['splitLines'];
        if (current.splitFromOrderId != null ||
            current.payments.isNotEmpty ||
            splitOrderId is! String ||
            splitOrderId.isEmpty ||
            splitOrderId.length > 180 ||
            rawAllocations is! List ||
            rawAllocations.isEmpty ||
            rawAllocations.length > 100 ||
            existing.any(
              (event) =>
                  event.payload['orderId'] == splitOrderId ||
                  event.payload['splitOrderId'] == splitOrderId,
            )) {
          throw const OfflineProjectionException(
            'Only an unpaid main bill can be split.',
          );
        }
        var selectedQuantity = 0;
        final selectedLineIds = <String>{};
        for (final raw in rawAllocations) {
          if (raw is! Map) {
            throw const OfflineProjectionException(
              'A split bill item is invalid.',
            );
          }
          final lineId = raw['lineId'];
          final quantity = (raw['quantity'] as num?)?.toInt();
          final line = current.lines[lineId];
          if (lineId is! String ||
              quantity == null ||
              quantity <= 0 ||
              line == null ||
              !line.sent ||
              quantity > line.quantity ||
              !selectedLineIds.add(lineId)) {
            throw const OfflineProjectionException(
              'A selected split item is no longer available.',
            );
          }
          selectedQuantity += quantity;
        }
        final sourceQuantity = current.lines.values.fold<int>(
          0,
          (sum, line) => sum + line.quantity,
        );
        if (selectedQuantity >= sourceQuantity) {
          throw const OfflineProjectionException(
            'The split must leave at least one item on the main bill.',
          );
        }
        break;
      case 'order.fulfilmentChanged':
        final status = draft.payload['status'];
        if (status is! String ||
            !const {
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
        break;
      case 'payment.recorded':
        final amount = draft.payload['baseAmountMinor'];
        if (amount is! int || amount <= 0 || amount > current.balanceDueMinor) {
          throw const OfflineProjectionException(
            'The payment exceeds the outstanding balance.',
          );
        }
        break;
      case 'payment.batchRecorded':
        final rawPayments = draft.payload['payments'];
        if (draft.payload['batchId'] is! String ||
            (draft.payload['batchId'] as String).isEmpty ||
            rawPayments is! List ||
            rawPayments.any((value) => value is! Map)) {
          throw const OfflineProjectionException(
            'The payment batch is invalid.',
          );
        }
        final amount = rawPayments.whereType<Map>().fold<int>(
          0,
          (sum, value) =>
              sum + ((value['baseAmountMinor'] as num?)?.toInt() ?? -1),
        );
        if (amount < 0 || amount > current.balanceDueMinor) {
          throw const OfflineProjectionException(
            'The payment batch exceeds the outstanding balance.',
          );
        }
        if (draft.payload['closeIfSettled'] == true &&
            amount != current.balanceDueMinor) {
          throw const OfflineProjectionException(
            'The order cannot close with an outstanding balance.',
          );
        }
        if (draft.payload['printReceipt'] == true &&
            (rawPayments.isNotEmpty || current.balanceDueMinor == 0)) {
          catalogueProvider?.call().validateReceiptRoute(printRequired: true);
        }
        break;
      case 'order.closed':
        if (current.lines.isEmpty || current.balanceDueMinor != 0) {
          throw const OfflineProjectionException(
            'The order cannot close with an outstanding balance.',
          );
        }
        catalogueProvider?.call().validateReceiptRoute(
          printRequired: draft.payload['printReceipt'] == true,
        );
        break;
      case 'order.cancelled':
        final reason = draft.payload['reason'];
        if (current.lines.isNotEmpty ||
            current.payments.isNotEmpty ||
            reason is! String ||
            reason.trim().length < 3) {
          throw const OfflineProjectionException(
            'Only an empty, unpaid order can be cancelled.',
          );
        }
        break;
      case 'receipt.requested':
        if (current.lines.isEmpty) {
          throw const OfflineProjectionException(
            'An empty order has no receipt to print.',
          );
        }
        if (draft.payload['isDeliveryNote'] == true &&
            current.channel == 'dineIn') {
          throw const OfflineProjectionException(
            'A dine-in order does not have a delivery or collection note.',
          );
        }
        catalogueProvider?.call().validateReceiptRoute(printRequired: true);
        break;
      default:
        throw OfflineProjectionException(
          'Unsupported offline event type: ${draft.type}.',
        );
    }
  }

  void _projectAffectedOrder(List<OfflineEvent> events, Object? rawOrderId) {
    if (rawOrderId is! String) return;
    _projectOrderEvents(_eventsForOrder(events, rawOrderId));
    final latest = events.last;
    if (latest.type == 'order.splitCreated') {
      final splitOrderId = latest.payload['splitOrderId'];
      if (splitOrderId is String) {
        _projectOrderEvents(_eventsForOrder(events, splitOrderId));
      }
    }
  }
}

/// Builds the child bill deterministically from the single atomic split event.
/// No second ledger write is needed, so a crash cannot leave the parent reduced
/// without its payable child (or create the child without reducing the parent).
List<OfflineEvent> _eventsForOrder(
  Iterable<OfflineEvent> allEvents,
  String orderId,
) {
  final events = allEvents.where(_isOrderEvent).toList(growable: false);
  final direct = events
      .where((event) => event.payload['orderId'] == orderId)
      .toList(growable: true);
  final splitEvent = events.cast<OfflineEvent?>().firstWhere(
    (event) =>
        event?.type == 'order.splitCreated' &&
        event?.payload['splitOrderId'] == orderId,
    orElse: () => null,
  );
  if (splitEvent == null) return direct;
  final sourceOrderId = splitEvent.payload['orderId']! as String;
  final sourceEvents = events
      .where(
        (event) =>
            event.payload['orderId'] == sourceOrderId &&
            event.sequence < splitEvent.sequence,
      )
      .toList(growable: false);
  final source = _projectOrderEvents(sourceEvents);
  final allocations = <String, int>{
    for (final raw
        in (splitEvent.payload['splitLines'] as List).whereType<Map>())
      raw['lineId']! as String: (raw['quantity']! as num).toInt(),
  };
  var index = 0;
  final childLines = <Map<String, Object?>>[];
  for (final line in source.lines.values) {
    final quantity = allocations[line.id] ?? 0;
    if (quantity <= 0) continue;
    final suffix = orderId.length > 18
        ? orderId.substring(orderId.length - 18)
        : orderId;
    final sourceSuffix = line.id.length > 18
        ? line.id.substring(line.id.length - 18)
        : line.id;
    childLines.add(<String, Object?>{
      'id': 'split-$suffix-${index++}-$sourceSuffix',
      'productId': line.productId,
      'name': line.name,
      'quantity': quantity,
      'unitPriceMinor': line.unitPriceMinor,
      'productionArea': line.productionArea,
      'details': line.details,
      'taxRateBasisPoints': line.taxRateBasisPoints,
      'taxRateName': line.taxRateName,
      'sent': true,
      'addedAtUtc': line.addedAtUtc?.toIso8601String(),
      'sentAtUtc': line.sentAtUtc?.toIso8601String(),
    });
  }
  final baseline = OfflineEvent(
    id: 'derived-split-${splitEvent.id}',
    tenantId: splitEvent.tenantId,
    venueId: splitEvent.venueId,
    deviceId: splitEvent.deviceId,
    staffId: splitEvent.staffId,
    managerApprovalStaffId: splitEvent.managerApprovalStaffId,
    type: 'order.cloudBaseline',
    payload: <String, Object?>{
      'orderId': orderId,
      'sourceOfflineHubEpoch': splitEvent.hubEpoch,
      'openedAtUtc': splitEvent.createdAtUtc.toIso8601String(),
      'tableId': source.tableId,
      'tabName': source.tabName,
      'channel': source.channel,
      'customerId': source.customerId,
      'customerName': source.customerName,
      'customerPhone': source.customerPhone,
      'deliveryAddress': source.deliveryAddress,
      'deliveryAddressLabel': source.deliveryAddressLabel,
      'deliveryLatitude': source.deliveryLatitude,
      'deliveryLongitude': source.deliveryLongitude,
      'serviceAreaId': source.serviceAreaId,
      'serviceAreaName': source.serviceAreaName,
      // The venue delivery charge belongs to the main order only.
      'deliveryFeeMinor': 0,
      'scheduledForUtc': source.scheduledForUtc?.toIso8601String(),
      'fulfilmentStatus': source.fulfilmentStatus,
      'assignedDriverId': source.assignedDriverId,
      'splitFromOrderId': sourceOrderId,
      'splitSequence': source.splitSequence + 1,
      'openSplitOrderIds': const <String>[],
      'lines': childLines,
      'payments': const <Object?>[],
    },
    createdAtUtc: splitEvent.createdAtUtc,
    deviceObservedAtUtc: splitEvent.deviceObservedAtUtc,
    timeAuthority: splitEvent.timeAuthority,
    clockSkewMillis: splitEvent.clockSkewMillis,
    businessTimestampUtc: splitEvent.businessTimestampUtc,
    sequence: splitEvent.sequence,
    hubEpoch: splitEvent.hubEpoch,
    previousHash: splitEvent.previousHash,
    eventHash: splitEvent.eventHash,
    syncState: splitEvent.syncState,
    cloudAcknowledgedAtUtc: splitEvent.cloudAcknowledgedAtUtc,
    quarantineReason: splitEvent.quarantineReason,
  );
  return <OfflineEvent>[baseline, ...direct]
    ..sort((left, right) => left.sequence.compareTo(right.sequence));
}

bool _sameOpenedOrderIdentity(
  Map<String, Object?> authoritative,
  Map<String, Object?> proposed,
) {
  if (authoritative['orderId'] != proposed['orderId'] ||
      (authoritative['channel'] ?? 'dineIn') !=
          (proposed['channel'] ?? 'dineIn')) {
    return false;
  }
  final proposedTable = proposed['tableId'];
  if (proposedTable is String &&
      proposedTable.isNotEmpty &&
      authoritative['tableId'] != proposedTable) {
    return false;
  }
  final proposedTab = proposed['tabName'];
  if (proposedTab is String &&
      proposedTab.isNotEmpty &&
      authoritative['tabName'] != proposedTab) {
    return false;
  }
  return true;
}

/// Prefers the complete local event chain whenever it can stand on its own.
/// A recovery baseline remains in the append-only outbox (preserving sequence
/// continuity) but cannot overwrite a locally reconstructable close/payment.
/// Replacement hubs whose chain genuinely starts with a cloud baseline still
/// use the full projection.
OfflineOrderProjection _projectOrderEvents(List<OfflineEvent> events) {
  try {
    // Prefer the server-signed baseline because it carries the authoritative
    // legacy location/customer identity for recovery shells. Projection now
    // treats a baseline appended after closure as metadata, not a mutation.
    return projectOfflineOrder(events);
  } on OfflineProjectionException {
    // A stale cloud baseline can contain extra lines that never belonged to
    // the completed local bill. In that narrow case, the independently valid
    // immutable local chain remains the stronger close/payment authority.
  }
  final withoutBaselines = events
      .where((event) => event.type != 'order.cloudBaseline')
      .toList(growable: false);
  if (withoutBaselines.isEmpty) {
    return projectOfflineOrder(events);
  }
  return projectOfflineOrder(withoutBaselines);
}

bool _isOrderEvent(OfflineEvent event) =>
    event.type.startsWith('order.') ||
    event.type == 'payment.recorded' ||
    event.type == 'payment.batchRecorded' ||
    event.type == 'receipt.requested';

String _canonicalJson(Object? value) => jsonEncode(_canonicalValue(value));

Object? _canonicalValue(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalValue(value[key]),
    };
  }
  if (value is List) {
    return value.map(_canonicalValue).toList(growable: false);
  }
  return value;
}
