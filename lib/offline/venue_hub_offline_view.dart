import 'dart:async';

import '../features/pos/domain.dart';

/// Last hub-approved catalogue used only when a Firestore stream fails.
/// Server mutations still independently canonicalise every line.
class VenueHubOfflineView {
  VenueHubOfflineView._();

  static final VenueHubOfflineView instance = VenueHubOfflineView._();
  Map<String, Object?>? _snapshot;
  final StreamController<List<PosOrder>> _orders =
      StreamController<List<PosOrder>>.broadcast();
  List<PosOrder> _currentOrders = const [];

  void install(Map<String, Object?> snapshot) =>
      _snapshot = Map<String, Object?>.unmodifiable(snapshot);
  void clear() => _snapshot = null;

  Stream<List<PosOrder>> get orderStream async* {
    yield _currentOrders;
    yield* _orders.stream;
  }

  List<PosOrder> get currentOrders => _currentOrders;

  void installOrders(List<Map<String, Object?>> values) {
    _currentOrders = values
        .map(_order)
        .whereType<PosOrder>()
        .toList(growable: false);
    _orders.add(_currentOrders);
  }

  PosOrder? _order(Map<String, Object?> value) {
    final orderId = value['orderId'];
    final openedAt = DateTime.tryParse(value['openedAtUtc'] as String? ?? '');
    final rawLines = value['lines'];
    if (orderId is! String || openedAt == null || rawLines is! List)
      return null;
    final lines = rawLines
        .whereType<Map>()
        .map((line) {
          final area = switch (line['productionArea']) {
            'bar' => ProductionArea.bar,
            'dessert' => ProductionArea.dessert,
            _ => ProductionArea.kitchen,
          };
          return OrderLine(
            id: line['id'] as String,
            productId: line['productId'] as String,
            productName: line['name'] as String,
            quantity: (line['quantity'] as num).toInt(),
            unitPriceMinor: (line['unitPriceMinor'] as num).toInt(),
            productionArea: area,
            trackStock: false,
            isSentToProduction: line['sent'] == true,
          );
        })
        .toList(growable: false);
    final rawPayments = value['payments'];
    final payments = rawPayments is List
        ? rawPayments
              .whereType<Map>()
              .map(
                (payment) => OrderPayment(
                  id: payment['id'] as String,
                  method: payment['method'] as String,
                  tenderedAmountMinor:
                      (payment['tenderedAmountMinor'] as num?)?.toInt() ??
                      (payment['baseAmountMinor'] as num).toInt(),
                  tenderedCurrencyCode: payment['currencyCode'] as String,
                  baseAmountMinor: (payment['baseAmountMinor'] as num).toInt(),
                  exchangeRateToBase:
                      payment['exchangeRateToBase'] as String? ?? '1',
                  recordedAt:
                      DateTime.tryParse(
                        payment['recordedAtUtc'] as String? ?? '',
                      )?.toLocal() ??
                      openedAt.toLocal(),
                  terminalLabel: payment['terminalLabel'] as String?,
                  cashChangeBaseMinor:
                      (payment['cashChangeBaseMinor'] as num?)?.toInt() ?? 0,
                ),
              )
              .toList(growable: false)
        : const <OrderPayment>[];
    return PosOrder(
      id: orderId,
      tenantId: value['tenantId'] as String,
      venueId: value['venueId'] as String,
      tableId: value['tableId'] as String?,
      tabName: value['tabName'] as String?,
      businessDate: _businessDate(openedAt),
      openedAt: openedAt.toLocal(),
      status: value['isClosed'] == true
          ? OrderStatus.closed
          : lines.any((line) => line.isSentToProduction)
          ? OrderStatus.sent
          : OrderStatus.open,
      lines: lines,
      payments: payments,
    );
  }

  DateTime _businessDate(DateTime utc) {
    final offset = (_snapshot?['venueUtcOffsetMinutes'] as num?)?.toInt() ?? 0;
    final cutoff =
        (_snapshot?['businessDayCutoffMinutes'] as num?)?.toInt() ?? 240;
    var venueTime = utc.toUtc().add(Duration(minutes: offset));
    if ((venueTime.hour * 60) + venueTime.minute < cutoff) {
      venueTime = venueTime.subtract(const Duration(days: 1));
    }
    return DateTime(venueTime.year, venueTime.month, venueTime.day);
  }

  List<MenuSection> get sections {
    final raw = _snapshot?['sections'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) {
          final value = Map<String, Object?>.from(item);
          return MenuSection(
            id: value['id'] as String,
            name: value['name'] as String,
            icon: value['icon'] as String? ?? '🍽️',
            parentSectionId: value['parentSectionId'] as String?,
            sortOrder: (value['sortOrder'] as num?)?.toInt() ?? 0,
          );
        })
        .toList(growable: false);
  }

  List<DiningTable> get tables {
    final raw = _snapshot?['tables'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .where((item) => item['active'] != false)
        .map((item) {
          return DiningTable(
            id: item['id'] as String,
            label: item['label'] as String,
            seats: (item['seats'] as num?)?.toInt() ?? 0,
          );
        })
        .toList(growable: false);
  }

  List<MenuModifierGroup> get modifierGroups {
    final raw = _snapshot?['modifierGroups'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) {
          return MenuModifierGroup(
            id: item['id'] as String,
            name: item['name'] as String,
            minimumSelections:
                (item['minimumSelections'] as num?)?.toInt() ?? 0,
            maximumSelections:
                (item['maximumSelections'] as num?)?.toInt() ?? 1,
            isAvailable: item['isAvailable'] != false,
            options: (item['options'] as List? ?? const [])
                .whereType<Map>()
                .map((option) {
                  return MenuModifierOption(
                    id: option['id'] as String,
                    name: option['name'] as String,
                    priceDeltaMinor:
                        (option['priceDeltaMinor'] as num?)?.toInt() ?? 0,
                    isAvailable: option['isAvailable'] != false,
                    stockComponents: _stockComponents(
                      option['stockComponents'],
                    ),
                  );
                })
                .toList(growable: false),
          );
        })
        .toList(growable: false);
  }

  List<MenuProduct> get products {
    final raw = _snapshot?['products'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) {
          final area = switch (item['productionArea']) {
            'bar' => ProductionArea.bar,
            'dessert' => ProductionArea.dessert,
            _ => ProductionArea.kitchen,
          };
          return MenuProduct(
            id: item['id'] as String,
            name: item['name'] as String,
            priceMinor: (item['priceMinor'] as num?)?.toInt() ?? 0,
            sectionIds: (item['sectionIds'] as List? ?? const [])
                .whereType<String>()
                .toList(),
            productionArea: area,
            trackStock: item['trackStock'] == true,
            stockOnHand: (item['stockOnHand'] as num?)?.toDouble(),
            stockPerSale: (item['stockPerSale'] as num?)?.toDouble() ?? 1,
            isAvailable: item['isAvailable'] == true,
            isArchived: item['isArchived'] == true,
            showOnOrderFlow: item['showOnOrderFlow'] != false,
            taxRateBasisPoints:
                (item['taxRateBasisPoints'] as num?)?.toInt() ?? 0,
            taxRateId: item['taxRateId'] as String?,
            taxRateName: item['taxRateName'] as String? ?? 'Zero Rate',
            modifierGroupIds: (item['modifierGroupIds'] as List? ?? const [])
                .whereType<String>()
                .toList(),
            variants: (item['variants'] as List? ?? const [])
                .whereType<Map>()
                .map((variant) {
                  return MenuProductVariant(
                    id: variant['id'] as String,
                    name: variant['name'] as String,
                    priceDeltaMinor:
                        (variant['priceDeltaMinor'] as num?)?.toInt() ?? 0,
                    isAvailable: variant['isAvailable'] != false,
                    stockComponents: _stockComponents(
                      variant['stockComponents'],
                    ),
                  );
                })
                .toList(growable: false),
            stockComponents: _stockComponents(item['stockComponents']),
          );
        })
        .toList(growable: false);
  }

  List<ProductStockComponent> _stockComponents(Object? raw) {
    if (raw is! List) return const [];
    final rawProducts = _snapshot?['products'];
    final products = rawProducts is List
        ? rawProducts.whereType<Map>()
        : const Iterable<Map>.empty();
    return raw
        .whereType<Map>()
        .map((component) {
          final productId = component['productId'] as String;
          final stockProduct = products
              .where((product) => product['id'] == productId)
              .firstOrNull;
          return ProductStockComponent(
            productId: productId,
            productName:
                component['productName'] as String? ??
                stockProduct?['name'] as String? ??
                productId,
            quantityPerSale:
                (component['quantityPerSale'] as num?)?.toDouble() ?? 0,
            stockUnit:
                component['stockUnit'] as String? ??
                stockProduct?['stockUnit'] as String? ??
                'each',
            stockOnHand: (stockProduct?['stockOnHand'] as num?)?.toDouble(),
            latestUnitCostMinor: (stockProduct?['latestUnitCostMinor'] as num?)
                ?.toDouble(),
          );
        })
        .toList(growable: false);
  }
}
