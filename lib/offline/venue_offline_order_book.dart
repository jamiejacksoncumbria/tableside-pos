import 'dart:async';
import 'dart:convert';

import 'offline_event.dart';
import 'offline_event_ledger.dart';
import 'offline_order_projection.dart';
import 'venue_offline_catalogue.dart';

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
        final event = await _ledger.commit(draft, hubEpoch: hubEpoch);
        _projectAffectedOrder([...existing, event], draft.payload['orderId']);
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
    bool hasSameIdentity(OfflineEvent event) {
      if (event.type != draft.type ||
          event.payload['orderId'] != draft.payload['orderId']) {
        return false;
      }
      return switch (draft.type) {
        'order.opened' || 'order.closed' => true,
        'order.itemAdded' || 'order.itemQuantityChanged' =>
          event.payload['lineId'] == draft.payload['lineId'],
        'payment.recorded' =>
          event.payload['paymentId'] == draft.payload['paymentId'],
        'order.sent' =>
          _canonicalJson(event.payload['lineIds']) ==
              _canonicalJson(draft.payload['lineIds']),
        _ => false,
      };
    }

    final matches = existing.where(hasSameIdentity).toList(growable: false);
    if (matches.isEmpty) return null;
    final previous = matches.last;
    if (_canonicalJson(previous.payload) != _canonicalJson(draft.payload)) {
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
    final orderEvents = events.where(_isOrderEvent);
    final grouped = <String, List<OfflineEvent>>{};
    for (final event in orderEvents) {
      final orderId = event.payload['orderId'];
      if (orderId is! String || orderId.isEmpty) {
        throw const OfflineProjectionException(
          'An offline event does not identify an order.',
        );
      }
      grouped.putIfAbsent(orderId, () => []).add(event);
    }
    return <String, OfflineOrderProjection>{
      for (final entry in grouped.entries)
        entry.key: projectOfflineOrder(entry.value),
    };
  }

  Future<OfflineOrderProjection> order(String orderId) async {
    final events = await _ledger.eventsForVenue(
      tenantId: tenantId,
      venueId: venueId,
      hubEpoch: hubEpoch,
    );
    return projectOfflineOrder(
      events.where((event) => event.payload['orderId'] == orderId).toList(),
    );
  }

  void _validateProposed(List<OfflineEvent> existing, OfflineEventDraft draft) {
    final orderId = draft.payload['orderId'];
    if (orderId is! String || orderId.isEmpty) {
      throw const OfflineProjectionException(
        'The offline command does not identify an order.',
      );
    }
    final orderEvents = existing
        .where((event) => event.payload['orderId'] == orderId)
        .toList(growable: false);
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
              !projectOfflineOrder(events).isClosed) {
            throw const OfflineProjectionException(
              'A tab is already open with this name.',
            );
          }
        }
      }
      return;
    }
    if (orderEvents.isEmpty) {
      throw const OfflineProjectionException('The order is not open.');
    }
    final current = projectOfflineOrder(orderEvents);
    if (current.isClosed) {
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
      case 'order.itemQuantityChanged':
        final lineId = draft.payload['lineId'];
        final line = current.lines[lineId];
        if (line == null || line.sent) {
          throw const OfflineProjectionException(
            'Only an unsent line can change quantity.',
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
      case 'payment.recorded':
        final amount = draft.payload['baseAmountMinor'];
        if (amount is! int || amount <= 0 || amount > current.balanceDueMinor) {
          throw const OfflineProjectionException(
            'The payment exceeds the outstanding balance.',
          );
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
      case 'receipt.requested':
        if (current.lines.isEmpty) {
          throw const OfflineProjectionException(
            'An empty order has no receipt to print.',
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
    projectOfflineOrder(
      events
          .where((event) => event.payload['orderId'] == rawOrderId)
          .toList(growable: false),
    );
  }
}

bool _isOrderEvent(OfflineEvent event) =>
    event.type.startsWith('order.') ||
    event.type == 'payment.recorded' ||
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
