import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_logger.dart';
import '../core/tenant_scope.dart';
import '../features/pos/domain.dart';
import 'production_command_repository.dart';

final firestorePosRepositoryProvider = Provider<FirestorePosRepository>(
  (ref) => FirestorePosRepository(FirebaseFirestore.instance),
);

final taxRatesProvider = StreamProvider<List<TaxRate>>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(const <TaxRate>[]);
  return ref.watch(firestorePosRepositoryProvider).watchTaxRates(scope);
});

class FirestorePosRepository {
  FirestorePosRepository(
    this._firestore, {
    ProductionCommandRepository? commands,
  }) : _commands = commands ?? ProductionCommandRepository();

  final FirebaseFirestore _firestore;
  final ProductionCommandRepository _commands;

  Stream<List<TenantMembership>> watchMemberships(String userId) {
    return _firestore
        .collectionGroup('members')
        .where('userId', isEqualTo: userId)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map((document) {
                final data = document.data();
                return TenantMembership(
                  tenantId: document.reference.parent.parent!.id,
                  userId: data['userId'] as String,
                  roles: List<String>.from(data['roles'] as List? ?? const []),
                  defaultVenueId: data['defaultVenueId'] as String?,
                );
              })
              .toList(growable: false),
        );
  }

  Stream<TenantProfile> watchTenant(String tenantId) {
    return _firestore.doc('tenants/$tenantId').snapshots().map((document) {
      final data = document.data() ?? const <String, dynamic>{};
      final phoneNumbers =
          List<String>.from(data['phoneNumbers'] as List? ?? const [])
              .where((number) => number.trim().isNotEmpty)
              .take(3)
              .toList(growable: false);
      final legacyPhone = data['phone'] as String? ?? '';
      return TenantProfile(
        id: document.id,
        displayName: data['displayName'] as String? ?? 'Unnamed restaurant',
        legalName: data['legalName'] as String? ?? '',
        currencyCode: data['currencyCode'] as String? ?? 'GBP',
        logoUrl: data['logoUrl'] as String?,
        address: data['address'] as String? ?? '',
        phone: phoneNumbers.isEmpty ? legacyPhone : phoneNumbers.first,
        phoneNumbers: phoneNumbers.isEmpty && legacyPhone.trim().isNotEmpty
            ? [legacyPhone]
            : phoneNumbers,
        receiptFooter: data['receiptFooter'] as String? ?? '',
      );
    });
  }

  Stream<List<Venue>> watchVenues(String tenantId) {
    return _firestore
        .collection('tenants/$tenantId/venues')
        .orderBy('name')
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map((document) {
                final data = document.data();
                return Venue(
                  id: document.id,
                  tenantId: tenantId,
                  name: data['name'] as String? ?? 'Unnamed venue',
                  timeZone: data['timeZone'] as String? ?? 'UTC',
                  notificationRetentionSeconds: _notificationRetentionSeconds(
                    data['notificationRetentionSeconds'],
                  ),
                  backgroundLockSeconds: _backgroundLockSeconds(
                    data['backgroundLockSeconds'],
                  ),
                  orderFlowAmberMinutes: _orderFlowMinutes(
                    data['orderFlowAmberMinutes'],
                    15,
                  ),
                  orderFlowRedMinutes: _orderFlowMinutes(
                    data['orderFlowRedMinutes'],
                    25,
                  ),
                  businessDayCutoffMinutes: _businessDayCutoffMinutes(
                    data['businessDayCutoffMinutes'],
                  ),
                  pendingBusinessDayCutoffMinutes:
                      data['pendingBusinessDayCutoffMinutes'] is num
                      ? (data['pendingBusinessDayCutoffMinutes'] as num).toInt()
                      : null,
                  pendingBusinessDayCutoffEffectiveDate:
                      data['pendingBusinessDayCutoffEffectiveDate'] as String?,
                );
              })
              .toList(growable: false),
        );
  }

  int _notificationRetentionSeconds(Object? value) {
    final seconds = value is int ? value : 5;
    return seconds.clamp(1, 60).toInt();
  }

  int _backgroundLockSeconds(Object? value) {
    final seconds = value is int ? value : 120;
    return seconds.clamp(15, 3600).toInt();
  }

  int _orderFlowMinutes(Object? value, int fallback) {
    final minutes = value is int ? value : fallback;
    return minutes.clamp(1, 480).toInt();
  }

  int _businessDayCutoffMinutes(Object? value) {
    final minutes = value is num ? value.toInt() : 240;
    return minutes.clamp(0, 1439).toInt();
  }

  int _taxRateBasisPoints(Object? value) {
    final rate = value is int ? value : 0;
    return rate.clamp(0, 100000).toInt();
  }

  List<String> _stringIds(Object? value) {
    if (value is! List) return const <String>[];
    final unique = <String>{};
    for (final item in value.whereType<String>()) {
      final id = item.trim();
      if (id.isNotEmpty) unique.add(id);
    }
    return unique.toList(growable: false);
  }

  List<MenuProductVariant> _productVariants(Object? value) {
    if (value is! List) return const <MenuProductVariant>[];
    final variants = <MenuProductVariant>[];
    final ids = <String>{};
    for (final raw in value.whereType<Map>()) {
      final data = Map<Object?, Object?>.from(raw);
      final id = data['id'] as String? ?? '';
      final name = data['name'] as String? ?? '';
      if (id.trim().isEmpty || name.trim().isEmpty || !ids.add(id.trim())) {
        continue;
      }
      variants.add(
        MenuProductVariant(
          id: id.trim(),
          name: name.trim(),
          priceDeltaMinor: (data['priceDeltaMinor'] as num?)?.toInt() ?? 0,
          isAvailable: data['isAvailable'] as bool? ?? true,
        ),
      );
    }
    return variants;
  }

  List<MenuModifierOption> _modifierOptions(Object? value) {
    if (value is! List) return const <MenuModifierOption>[];
    final options = <MenuModifierOption>[];
    final ids = <String>{};
    for (final raw in value.whereType<Map>()) {
      final data = Map<Object?, Object?>.from(raw);
      final id = data['id'] as String? ?? '';
      final name = data['name'] as String? ?? '';
      if (id.trim().isEmpty || name.trim().isEmpty || !ids.add(id.trim())) {
        continue;
      }
      options.add(
        MenuModifierOption(
          id: id.trim(),
          name: name.trim(),
          priceDeltaMinor: (data['priceDeltaMinor'] as num?)?.toInt() ?? 0,
          isAvailable: data['isAvailable'] as bool? ?? true,
        ),
      );
    }
    return options;
  }

  List<OrderModifierSelection> _orderModifierSelections(Object? value) {
    if (value is! List) return const <OrderModifierSelection>[];
    final selections = <OrderModifierSelection>[];
    final ids = <String>{};
    for (final raw in value.whereType<Map>()) {
      final data = Map<Object?, Object?>.from(raw);
      final groupId = data['groupId'] as String? ?? '';
      final optionId = data['optionId'] as String? ?? '';
      final groupName = data['groupName'] as String? ?? '';
      final optionName = data['optionName'] as String? ?? '';
      final key = '$groupId::$optionId';
      if (groupId.trim().isEmpty ||
          optionId.trim().isEmpty ||
          groupName.trim().isEmpty ||
          optionName.trim().isEmpty ||
          !ids.add(key)) {
        continue;
      }
      selections.add(
        OrderModifierSelection(
          groupId: groupId.trim(),
          groupName: groupName.trim(),
          optionId: optionId.trim(),
          optionName: optionName.trim(),
          priceDeltaMinor: (data['priceDeltaMinor'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    return selections;
  }

  Stream<List<MenuSection>> watchMenuSections(VenueScope scope) async* {
    AppLogger.info(
      'Load menu sections: tenant=${scope.tenantId}, venue=${scope.venueId}.',
    );
    try {
      await for (final snapshot
          in _firestore
              .collection('tenants/${scope.tenantId}/menuSections')
              .orderBy('sortOrder')
              .snapshots()) {
        final items = snapshot.docs
            .where(
              (document) =>
                  (document.data()['venueId'] as String?) == scope.venueId,
            )
            .map((document) {
              final data = document.data();
              return MenuSection(
                id: document.id,
                name: data['name'] as String? ?? 'Unnamed section',
                icon: data['icon'] as String? ?? '🍽️',
                parentSectionId: data['parentSectionId'] as String?,
              );
            })
            .toList(growable: false);
        AppLogger.info(
          'Menu sections loaded: ${snapshot.size} document(s) received, ${items.length} for the active venue.',
        );
        yield items;
      }
    } on Object catch (error, stackTrace) {
      AppLogger.error('Load menu sections', error, stackTrace);
      rethrow;
    }
  }

  Stream<List<MenuProduct>> watchProducts(VenueScope scope) async* {
    AppLogger.info(
      'Load menu products: tenant=${scope.tenantId}, venue=${scope.venueId}.',
    );
    try {
      await for (final snapshot
          in _firestore
              .collection('tenants/${scope.tenantId}/products')
              .orderBy('name')
              .snapshots()) {
        final items = snapshot.docs
            .where(
              (document) =>
                  (document.data()['venueId'] as String?) == scope.venueId,
            )
            .map((document) {
              final data = document.data();
              return MenuProduct(
                id: document.id,
                name: data['name'] as String? ?? 'Unnamed product',
                priceMinor: data['priceMinor'] as int? ?? 0,
                sectionIds: List<String>.from(
                  data['sectionIds'] as List? ?? const [],
                ),
                productionArea: _productionArea(
                  data['productionArea'] as String?,
                ),
                trackStock: data['trackStock'] as bool? ?? false,
                stockOnHand: (data['stockOnHand'] as num?)?.toDouble(),
                stockUnit: data['stockUnit'] as String? ?? 'each',
                stockPerSale: (data['stockPerSale'] as num?)?.toDouble() ?? 1,
                isAvailable: data['isAvailable'] as bool? ?? true,
                showOnOrderFlow: data['showOnOrderFlow'] as bool? ?? true,
                taxRateBasisPoints: _taxRateBasisPoints(
                  data['taxRateBasisPoints'],
                ),
                taxRateId: data['taxRateId'] as String?,
                taxRateName: data['taxRateName'] as String? ?? 'Zero rate',
                variants: _productVariants(data['variants']),
                modifierGroupIds: _stringIds(data['modifierGroupIds']),
              );
            })
            .toList(growable: false);
        AppLogger.info(
          'Menu products loaded: ${snapshot.size} document(s) received, ${items.length} for the active venue.',
        );
        yield items;
      }
    } on Object catch (error, stackTrace) {
      AppLogger.error('Load menu products', error, stackTrace);
      rethrow;
    }
  }

  Stream<List<DiningTable>> watchTables(VenueScope scope) {
    return _firestore
        .collection('tenants/${scope.tenantId}/tables')
        .orderBy('label')
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .where(
                (document) =>
                    (document.data()['venueId'] as String?) == scope.venueId,
              )
              .map((document) {
                final data = document.data();
                final currentOrderId = data['currentOrderId'] as String?;
                return DiningTable(
                  id: document.id,
                  label: data['label'] as String? ?? 'Table',
                  seats: data['seats'] as int? ?? 0,
                  hasOpenOrder: currentOrderId?.trim().isNotEmpty == true,
                  currentOrderId: currentOrderId?.trim().isNotEmpty == true
                      ? currentOrderId
                      : null,
                );
              })
              .toList(growable: false),
        );
  }

  /// Watches the server-owned name reservations for live, no-table tabs.
  /// There is one document per open name, so this stays small even when a
  /// venue has a long order history.
  Stream<List<OpenNamedTab>> watchOpenNamedTabs(VenueScope scope) {
    return _firestore
        .collection('tenants/${scope.tenantId}/openTabNames')
        .where('venueId', isEqualTo: scope.venueId)
        .snapshots()
        .map((snapshot) {
          final tabs = snapshot.docs
              .map((document) {
                final data = document.data();
                final orderId = data['orderId'] as String? ?? '';
                final name = data['tabName'] as String? ?? '';
                final createdAt = data['createdAt'];
                if (orderId.isEmpty || name.trim().isEmpty) return null;
                return OpenNamedTab(
                  id: document.id,
                  orderId: orderId,
                  name: name,
                  openedAt: createdAt is Timestamp ? createdAt.toDate() : null,
                );
              })
              .whereType<OpenNamedTab>()
              .toList(growable: false);
          tabs.sort(
            (first, second) => (second.openedAt ?? DateTime(0)).compareTo(
              first.openedAt ?? DateTime(0),
            ),
          );
          return tabs;
        });
  }

  /// Streams one active order. The POS listens to this after an order has
  /// been opened or sent, so additions, cancellations and status changes made
  /// by another device appear without reopening the table.
  Stream<PosOrder?> watchOrder({
    required VenueScope scope,
    required String orderId,
  }) async* {
    AppLogger.info(
      'Watch active order: tenant=${scope.tenantId}, venue=${scope.venueId}, order=$orderId.',
    );
    try {
      await for (final snapshot
          in _firestore
              .doc('tenants/${scope.tenantId}/orders/$orderId')
              .snapshots()) {
        final order = _orderFromSnapshot(scope: scope, order: snapshot);
        AppLogger.info(
          order == null
              ? 'Active order stream: $orderId is no longer open.'
              : 'Active order stream: $orderId now has ${order.lines.length} line(s).',
        );
        yield order;
      }
    } on Object catch (error, stackTrace) {
      AppLogger.error('Watch active order $orderId', error, stackTrace);
      rethrow;
    }
  }

  /// Streams the current order attached to [tableId], including a change from
  /// no order to a newly opened order. This is used for the initial table
  /// lookup and avoids leaving a table view on a stale point-in-time read.
  Stream<PosOrder?> watchOpenOrder({
    required VenueScope scope,
    required String tableId,
  }) {
    late final StreamController<PosOrder?> controller;
    StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
    tableSubscription;
    StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
    orderSubscription;
    String? observedOrderId;
    var hasObservedOrderId = false;

    Future<void> stopSubscriptions() async {
      await tableSubscription?.cancel();
      await orderSubscription?.cancel();
    }

    controller = StreamController<PosOrder?>(
      onListen: () {
        AppLogger.info(
          'Watch table order: tenant=${scope.tenantId}, venue=${scope.venueId}, table=$tableId.',
        );
        tableSubscription = _firestore
            .doc('tenants/${scope.tenantId}/tables/$tableId')
            .snapshots()
            .listen(
              (table) {
                final data = table.data();
                final orderId = data?['currentOrderId'] as String?;
                if (hasObservedOrderId && orderId == observedOrderId) return;
                hasObservedOrderId = true;
                observedOrderId = orderId;
                unawaited(orderSubscription?.cancel());
                orderSubscription = null;
                if (orderId == null || orderId.isEmpty) {
                  controller.add(null);
                  return;
                }
                orderSubscription = _firestore
                    .doc('tenants/${scope.tenantId}/orders/$orderId')
                    .snapshots()
                    .listen(
                      (order) {
                        final parsed = _orderFromSnapshot(
                          scope: scope,
                          order: order,
                        );
                        if (parsed?.tableId != tableId) {
                          controller.add(null);
                          return;
                        }
                        controller.add(parsed);
                      },
                      onError: (Object error, StackTrace stackTrace) {
                        AppLogger.error(
                          'Watch table order $tableId',
                          error,
                          stackTrace,
                        );
                        controller.addError(error, stackTrace);
                      },
                    );
              },
              onError: (Object error, StackTrace stackTrace) {
                AppLogger.error('Watch table $tableId', error, stackTrace);
                controller.addError(error, stackTrace);
              },
            );
      },
      onCancel: stopSubscriptions,
    );
    return controller.stream;
  }

  Future<PosOrder?> fetchOpenOrder({
    required VenueScope scope,
    required String tableId,
  }) => watchOpenOrder(scope: scope, tableId: tableId).first;

  Future<PosOrder?> fetchOrder({
    required VenueScope scope,
    required String orderId,
  }) => watchOrder(scope: scope, orderId: orderId).first;

  PosOrder? _orderFromSnapshot({
    required VenueScope scope,
    required DocumentSnapshot<Map<String, dynamic>> order,
  }) {
    final data = order.data();
    if (data == null ||
        data['venueId'] != scope.venueId ||
        data['status'] == 'closed') {
      return null;
    }
    final openedAt = data['openedAt'];
    final lines = List<Object?>.from(data['lines'] as List? ?? const [])
        .whereType<Map>()
        .map((raw) {
          final line = Map<String, Object?>.from(raw);
          return OrderLine(
            id: line['id'] as String? ?? '',
            productId: line['productId'] as String? ?? '',
            productName: line['productName'] as String? ?? 'Menu item',
            quantity: line['quantity'] as int? ?? 1,
            unitPriceMinor: line['unitPriceMinor'] as int? ?? 0,
            productionArea: _productionArea(line['productionArea'] as String?),
            trackStock: line['trackStock'] as bool? ?? false,
            stockPerSale: (line['stockPerSale'] as num?)?.toDouble() ?? 1,
            isSentToProduction: line['isSentToProduction'] as bool? ?? true,
            taxRateBasisPoints: _taxRateBasisPoints(line['taxRateBasisPoints']),
            taxRateId: line['taxRateId'] as String?,
            taxRateName: line['taxRateName'] as String? ?? 'Zero rate',
            variantId: line['variantId'] as String?,
            variantName: line['variantName'] as String?,
            variantPriceDeltaMinor:
                (line['variantPriceDeltaMinor'] as num?)?.toInt() ?? 0,
            modifiers: _orderModifierSelections(line['modifierSelections']),
            itemNote: line['itemNote'] as String? ?? '',
          );
        })
        .where((line) => line.id.isNotEmpty && line.productId.isNotEmpty)
        .toList(growable: false);
    final date = openedAt is Timestamp ? openedAt.toDate() : DateTime.now();
    final status = switch (data['status']) {
      'open' => OrderStatus.open,
      'pendingApproval' => OrderStatus.pendingApproval,
      'rolledOver' => OrderStatus.rolledOver,
      _ => OrderStatus.sent,
    };
    return PosOrder(
      id: order.id,
      tenantId: scope.tenantId,
      venueId: scope.venueId,
      tableId: data['tableId'] as String?,
      tabName: data['tabName'] as String?,
      businessDate: DateTime(date.year, date.month, date.day),
      openedAt: date,
      status: status,
      lines: lines,
      splitFromOrderId: data['splitFromOrderId'] as String?,
      splitSequence: (data['splitSequence'] as num?)?.toInt(),
      openSplitOrderIds: _stringIds(data['openSplitOrderIds']),
    );
  }

  /// Streams only active child bills for a parent table/name order. This lets
  /// a waiter safely return to an unpaid split rather than losing it after
  /// creating another guest's bill.
  Stream<List<PosOrder>> watchOpenSplitOrders({
    required VenueScope scope,
    required String sourceOrderId,
  }) {
    if (sourceOrderId.trim().isEmpty) {
      return Stream.value(const <PosOrder>[]);
    }
    return _firestore
        .collection('tenants/${scope.tenantId}/orders')
        .where('splitFromOrderId', isEqualTo: sourceOrderId)
        .snapshots()
        .map((snapshot) {
          final orders = snapshot.docs
              .map(
                (document) => _orderFromSnapshot(scope: scope, order: document),
              )
              .whereType<PosOrder>()
              .where((order) => order.venueId == scope.venueId)
              .toList(growable: false);
          orders.sort(
            (left, right) =>
                (left.splitSequence ?? 0).compareTo(right.splitSequence ?? 0),
          );
          return orders;
        });
  }

  Future<void> createMenuSection({
    required VenueScope scope,
    required String name,
    required String icon,
    required int sortOrder,
    String? parentSectionId,
  }) async {
    final cleanedName = name.trim();
    if (cleanedName.isEmpty) throw ArgumentError.value(name, 'name');
    await _commands.manageMenuConfiguration(
      scope: scope,
      resource: 'section',
      operation: 'save',
      values: {
        'name': cleanedName,
        'icon': icon.trim().isEmpty ? '🍽️' : icon.trim(),
        'sortOrder': sortOrder,
        if (parentSectionId != null && parentSectionId.trim().isNotEmpty)
          'parentSectionId': parentSectionId,
      },
    );
  }

  Future<void> updateMenuSection({
    required VenueScope scope,
    required String sectionId,
    required String name,
    required String icon,
    String? parentSectionId,
  }) async {
    final cleanedName = name.trim();
    if (cleanedName.isEmpty) throw ArgumentError.value(name, 'name');
    if (parentSectionId == sectionId) {
      throw ArgumentError('A section cannot be its own parent.');
    }
    await _commands.manageMenuConfiguration(
      scope: scope,
      resource: 'section',
      operation: 'save',
      documentId: sectionId,
      values: {
        'name': cleanedName,
        'icon': icon.trim().isEmpty ? '🍽️' : icon.trim(),
        if (parentSectionId != null &&
            parentSectionId.trim().isNotEmpty &&
            parentSectionId != sectionId)
          'parentSectionId': parentSectionId,
        if (parentSectionId == null || parentSectionId == sectionId)
          'parentSectionId': null,
      },
    );
  }

  Future<void> deleteMenuSection({
    required VenueScope scope,
    required String sectionId,
  }) async {
    final sections = await _firestore
        .collection('tenants/${scope.tenantId}/menuSections')
        .get();
    final products = await _firestore
        .collection('tenants/${scope.tenantId}/products')
        .get();
    final hasChild = sections.docs.any(
      (document) =>
          document.data()['venueId'] == scope.venueId &&
          document.data()['parentSectionId'] == sectionId,
    );
    final isInUse = products.docs.any(
      (document) =>
          document.data()['venueId'] == scope.venueId &&
          List<Object?>.from(
            document.data()['sectionIds'] as List? ?? const [],
          ).contains(sectionId),
    );
    if (hasChild || isInUse) {
      throw StateError(
        hasChild
            ? 'Move or delete its subcategories before deleting this section.'
            : 'Remove this section from its products before deleting it.',
      );
    }
    await _commands.manageMenuConfiguration(
      scope: scope,
      resource: 'section',
      operation: 'delete',
      documentId: sectionId,
    );
  }

  Future<void> createProduct({
    required VenueScope scope,
    required String name,
    required int priceMinor,
    required List<String> sectionIds,
    required ProductionArea productionArea,
    required bool trackStock,
    required double? stockOnHand,
    required double stockPerSale,
    required bool showOnOrderFlow,
    required int taxRateBasisPoints,
    required String? taxRateId,
    required String taxRateName,
    required List<MenuProductVariant> variants,
    required List<String> modifierGroupIds,
  }) async {
    final cleanedName = name.trim();
    if (cleanedName.isEmpty) throw ArgumentError.value(name, 'name');
    if (priceMinor < 0) {
      throw ArgumentError.value(priceMinor, 'priceMinor');
    }
    if (sectionIds.isEmpty) {
      throw ArgumentError.value(sectionIds, 'sectionIds');
    }
    if (stockPerSale <= 0 || !stockPerSale.isFinite) {
      throw ArgumentError.value(stockPerSale, 'stockPerSale');
    }
    _validateTaxRateBasisPoints(taxRateBasisPoints);
    final cleanedTaxRateName = _cleanTaxRateName(taxRateName);
    await _commands.manageMenuConfiguration(
      scope: scope,
      resource: 'product',
      operation: 'save',
      values: {
      'name': cleanedName,
      'priceMinor': priceMinor,
      'sectionIds': sectionIds,
      'productionArea': productionArea.name,
      'trackStock': trackStock,
      'stockOnHand': trackStock ? (stockOnHand ?? 0) : null,
      'stockPerSale': stockPerSale,
      'showOnOrderFlow': showOnOrderFlow,
      'taxRateBasisPoints': taxRateBasisPoints,
      'taxRateId': taxRateId,
      'taxRateName': cleanedTaxRateName,
      'variants': _variantsToMap(variants),
      'modifierGroupIds': _cleanModifierGroupIds(modifierGroupIds),
      },
    );
  }

  Future<void> setProductAvailability({
    required VenueScope scope,
    required String productId,
    required bool isAvailable,
  }) async {
    await _commands.manageMenuConfiguration(
      scope: scope,
      resource: 'product',
      operation: 'availability',
      documentId: productId,
      values: {'isAvailable': isAvailable},
    );
  }

  Future<void> updateProduct({
    required VenueScope scope,
    required String productId,
    required String name,
    required int priceMinor,
    required List<String> sectionIds,
    required ProductionArea productionArea,
    required bool trackStock,
    required double? stockOnHand,
    required double stockPerSale,
    required bool showOnOrderFlow,
    required int taxRateBasisPoints,
    required String? taxRateId,
    required String taxRateName,
    required List<MenuProductVariant> variants,
    required List<String> modifierGroupIds,
  }) async {
    final cleanedName = name.trim();
    if (cleanedName.isEmpty || priceMinor < 0 || sectionIds.isEmpty) {
      throw ArgumentError('Product details are incomplete.');
    }
    if (stockPerSale <= 0 || !stockPerSale.isFinite) {
      throw ArgumentError.value(stockPerSale, 'stockPerSale');
    }
    _validateTaxRateBasisPoints(taxRateBasisPoints);
    final cleanedTaxRateName = _cleanTaxRateName(taxRateName);
    await _commands.manageMenuConfiguration(
      scope: scope,
      resource: 'product',
      operation: 'save',
      documentId: productId,
      values: {
          'name': cleanedName,
          'priceMinor': priceMinor,
          'sectionIds': sectionIds,
          'productionArea': productionArea.name,
          'trackStock': trackStock,
          'stockOnHand': trackStock ? (stockOnHand ?? 0) : null,
          'stockPerSale': stockPerSale,
          'showOnOrderFlow': showOnOrderFlow,
          'taxRateBasisPoints': taxRateBasisPoints,
          'taxRateId': taxRateId,
          'taxRateName': cleanedTaxRateName,
          'variants': _variantsToMap(variants),
          'modifierGroupIds': _cleanModifierGroupIds(modifierGroupIds),
      },
    );
  }

  List<Map<String, Object?>> _variantsToMap(List<MenuProductVariant> variants) {
    final cleaned = <Map<String, Object?>>[];
    final ids = <String>{};
    final names = <String>{};
    for (final variant in variants) {
      final id = variant.id.trim();
      final name = variant.name.trim();
      final nameKey = name.toLowerCase();
      if (id.isEmpty ||
          name.isEmpty ||
          !ids.add(id) ||
          !names.add(nameKey) ||
          variant.priceDeltaMinor < -100000000 ||
          variant.priceDeltaMinor > 100000000) {
        throw ArgumentError(
          'Each variant needs a unique name and valid price adjustment.',
        );
      }
      cleaned.add({
        'id': id,
        'name': name,
        'priceDeltaMinor': variant.priceDeltaMinor,
        'isAvailable': variant.isAvailable,
      });
    }
    if (cleaned.length > 30) {
      throw ArgumentError('A product can have at most 30 variants.');
    }
    return cleaned;
  }

  List<String> _cleanModifierGroupIds(List<String> ids) {
    final cleaned = <String>{};
    for (final raw in ids) {
      final id = raw.trim();
      if (id.isEmpty || id.length > 180) {
        throw ArgumentError('A modifier group identifier is invalid.');
      }
      cleaned.add(id);
    }
    if (cleaned.length > 20) {
      throw ArgumentError('A product can have at most 20 modifier groups.');
    }
    return cleaned.toList(growable: false);
  }

  Stream<List<MenuModifierGroup>> watchModifierGroups(VenueScope scope) {
    return _firestore
        .collection('tenants/${scope.tenantId}/modifierGroups')
        .orderBy('name')
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .where(
                (document) =>
                    (document.data()['venueId'] as String?) == scope.venueId,
              )
              .map((document) {
                final data = document.data();
                final options = _modifierOptions(data['options']);
                final minimum =
                    (data['minimumSelections'] as num?)?.toInt() ?? 0;
                final maximum =
                    (data['maximumSelections'] as num?)?.toInt() ??
                    options.length;
                final safeMinimum = minimum.clamp(0, options.length).toInt();
                return MenuModifierGroup(
                  id: document.id,
                  name: data['name'] as String? ?? 'Unnamed options',
                  minimumSelections: safeMinimum,
                  maximumSelections: maximum
                      .clamp(safeMinimum, options.length)
                      .toInt(),
                  options: options,
                  isAvailable: data['isAvailable'] as bool? ?? true,
                );
              })
              .toList(growable: false),
        );
  }

  Future<void> createModifierGroup({
    required VenueScope scope,
    required String name,
    required int minimumSelections,
    required int maximumSelections,
    required List<MenuModifierOption> options,
  }) async {
    final data = _validatedModifierGroupData(
      name: name,
      minimumSelections: minimumSelections,
      maximumSelections: maximumSelections,
      options: options,
    );
    await _commands.manageMenuConfiguration(
      scope: scope,
      resource: 'modifierGroup',
      operation: 'save',
      values: {
          ...data,
      },
    );
  }

  Future<void> updateModifierGroup({
    required VenueScope scope,
    required String groupId,
    required String name,
    required int minimumSelections,
    required int maximumSelections,
    required List<MenuModifierOption> options,
  }) async {
    final data = _validatedModifierGroupData(
      name: name,
      minimumSelections: minimumSelections,
      maximumSelections: maximumSelections,
      options: options,
    );
    await _commands.manageMenuConfiguration(
      scope: scope,
      resource: 'modifierGroup',
      operation: 'save',
      documentId: groupId,
      values: data,
    );
  }

  Future<void> deleteModifierGroup({
    required VenueScope scope,
    required MenuModifierGroup group,
  }) async {
    final products = await _firestore
        .collection('tenants/${scope.tenantId}/products')
        .get();
    final inUse = products.docs.any((product) {
      final data = product.data();
      return data['venueId'] == scope.venueId &&
          _stringIds(data['modifierGroupIds']).contains(group.id);
    });
    if (inUse) {
      throw StateError(
        'Remove ${group.name} from its products before deleting it.',
      );
    }
    await _commands.manageMenuConfiguration(
      scope: scope,
      resource: 'modifierGroup',
      operation: 'delete',
      documentId: group.id,
    );
  }

  Map<String, Object?> _validatedModifierGroupData({
    required String name,
    required int minimumSelections,
    required int maximumSelections,
    required List<MenuModifierOption> options,
  }) {
    final cleanedName = name.trim();
    if (cleanedName.isEmpty || cleanedName.length > 80) {
      throw ArgumentError.value(name, 'name');
    }
    if (options.isEmpty || options.length > 50) {
      throw ArgumentError('Add between one and 50 options.');
    }
    if (minimumSelections < 0 ||
        maximumSelections < minimumSelections ||
        maximumSelections > options.length) {
      throw ArgumentError('Selection limits do not match the option list.');
    }
    final ids = <String>{};
    final names = <String>{};
    final optionData = <Map<String, Object?>>[];
    for (final option in options) {
      final id = option.id.trim();
      final optionName = option.name.trim();
      if (id.isEmpty ||
          optionName.isEmpty ||
          !ids.add(id) ||
          !names.add(optionName.toLowerCase()) ||
          option.priceDeltaMinor < -100000000 ||
          option.priceDeltaMinor > 100000000) {
        throw ArgumentError(
          'Each option needs a unique name and valid price adjustment.',
        );
      }
      optionData.add({
        'id': id,
        'name': optionName,
        'priceDeltaMinor': option.priceDeltaMinor,
        'isAvailable': option.isAvailable,
      });
    }
    return {
      'name': cleanedName,
      'minimumSelections': minimumSelections,
      'maximumSelections': maximumSelections,
      'options': optionData,
    };
  }

  void _validateTaxRateBasisPoints(int value) {
    if (value < 0 || value > 100000) {
      throw ArgumentError.value(
        value,
        'taxRateBasisPoints',
        'Tax must be between 0% and 1,000%.',
      );
    }
  }

  String _cleanTaxRateName(String value) {
    final name = value.trim();
    if (name.isEmpty || name.length > 80) {
      throw ArgumentError.value(value, 'taxRateName');
    }
    return name;
  }

  CollectionReference<Map<String, dynamic>> _taxRates(String tenantId) =>
      _firestore.collection('tenants/$tenantId/taxRates');

  Stream<List<TaxRate>> watchTaxRates(VenueScope scope) async* {
    AppLogger.info(
      'Load tax rates: tenant=${scope.tenantId}, venue=${scope.venueId}.',
    );
    try {
      await for (final snapshot in _taxRates(scope.tenantId).snapshots()) {
        final rates =
            snapshot.docs
                .where(
                  (document) =>
                      (document.data()['venueId'] as String?) == scope.venueId,
                )
                .map((document) {
                  final data = document.data();
                  return TaxRate(
                    id: document.id,
                    name: data['name'] as String? ?? 'Unnamed tax rate',
                    basisPoints: _taxRateBasisPoints(data['basisPoints']),
                    active: data['active'] as bool? ?? true,
                  );
                })
                .where((rate) => rate.active)
                .toList(growable: false)
              ..sort((left, right) => left.name.compareTo(right.name));
        AppLogger.info(
          'Tax rates loaded: ${snapshot.size} document(s) received, ${rates.length} for the active venue.',
        );
        yield rates;
      }
    } on Object catch (error, stackTrace) {
      AppLogger.error('Load tax rates', error, stackTrace);
      rethrow;
    }
  }

  Future<void> createTaxRate({
    required VenueScope scope,
    required String name,
    required int basisPoints,
  }) async {
    final cleanedName = _cleanTaxRateName(name);
    _validateTaxRateBasisPoints(basisPoints);
    await _ensureUniqueTaxRateName(scope, cleanedName);
    await _commands.manageMenuConfiguration(
      scope: scope,
      resource: 'taxRate',
      operation: 'save',
      values: {'name': cleanedName, 'basisPoints': basisPoints},
    );
  }

  Future<void> updateTaxRate({
    required VenueScope scope,
    required TaxRate existing,
    required String name,
    required int basisPoints,
  }) async {
    final cleanedName = _cleanTaxRateName(name);
    _validateTaxRateBasisPoints(basisPoints);
    await _ensureUniqueTaxRateName(scope, cleanedName, exceptId: existing.id);
    await _commands.manageMenuConfiguration(
      scope: scope,
      resource: 'taxRate',
      operation: 'save',
      documentId: existing.id,
      values: {'name': cleanedName, 'basisPoints': basisPoints},
    );
  }

  Future<void> deleteTaxRate({
    required VenueScope scope,
    required TaxRate rate,
  }) async {
    final products = await _firestore
        .collection('tenants/${scope.tenantId}/products')
        .where('taxRateId', isEqualTo: rate.id)
        .get();
    final inUse = products.docs.any(
      (product) => product.data()['venueId'] == scope.venueId,
    );
    if (inUse) {
      throw StateError(
        'Assign another tax rate to its products before deleting this rate.',
      );
    }
    await _commands.manageMenuConfiguration(
      scope: scope,
      resource: 'taxRate',
      operation: 'delete',
      documentId: rate.id,
    );
  }

  Future<void> _ensureUniqueTaxRateName(
    VenueScope scope,
    String name, {
    String? exceptId,
  }) async {
    final normalised = name.toLowerCase();
    final existing = await _taxRates(scope.tenantId).get();
    if (existing.docs.any(
      (document) =>
          document.id != exceptId &&
          document.data()['venueId'] == scope.venueId &&
          (document.data()['name'] as String? ?? '').trim().toLowerCase() ==
              normalised,
    )) {
      throw StateError(
        'A tax rate with this name already exists at this venue.',
      );
    }
  }

  /// Streams production-safe order summaries for the kitchen/bar/manager
  /// Order Flow Board. Filtering happens after the ordered stream so a new
  /// venue does not require a composite Firestore index before its first
  /// service.
  Stream<List<OrderFlowOrder>> watchOrderFlow(VenueScope scope) {
    return _firestore
        .collection('tenants/${scope.tenantId}/productionTickets')
        .orderBy('ticketReleasedAt', descending: true)
        .limit(200)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map((document) => _orderFlowFromDocument(document, scope))
              .whereType<OrderFlowOrder>()
              .where((order) => order.venueId == scope.venueId)
              .where((order) => !order.status.isTerminal)
              .toList(growable: false),
        );
  }

  /// Streams immutable closed-bill snapshots for manager reporting. Venue and
  /// period filtering remain client-side so this first report needs no new
  /// composite index and updates immediately when another till closes a bill.
  Stream<List<SalesReportBill>> watchSalesReportBills(VenueScope scope) {
    return _firestore
        .collection('tenants/${scope.tenantId}/bills')
        .where('venueId', isEqualTo: scope.venueId)
        .limit(5000)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map(_salesReportBillFromDocument)
              .whereType<SalesReportBill>()
              .toList(growable: false)
            ..sort((a, b) => b.businessDate.compareTo(a.businessDate)),
        );
  }

  Stream<List<PosOrder>> watchVenueOpenOrders(VenueScope scope) {
    return _firestore
        .collection('tenants/${scope.tenantId}/orders')
        .limit(1000)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map(
                (document) => _orderFromSnapshot(scope: scope, order: document),
              )
              .whereType<PosOrder>()
              .where((order) => order.venueId == scope.venueId)
              .toList(growable: false),
        );
  }

  SalesReportBill? _salesReportBillFromDocument(
    QueryDocumentSnapshot<Map<String, dynamic>> document,
  ) {
    final data = document.data();
    final venueId = data['venueId'] as String?;
    final rawBusinessDate = data['businessDate'] as String?;
    final businessDate = rawBusinessDate == null
        ? null
        : DateTime.tryParse(rawBusinessDate);
    if (venueId == null || businessDate == null) return null;
    final payments = List<Object?>.from(data['payments'] as List? ?? const [])
        .whereType<Map>()
        .map((raw) {
          final payment = Map<String, Object?>.from(raw);
          return SalesReportPayment(
            method: payment['method'] as String? ?? 'other',
            currencyCode:
                payment['tenderedCurrencyCode'] as String? ??
                data['currencyCode'] as String? ??
                'GBP',
            tenderedAmountMinor:
                (payment['tenderedAmountMinor'] as num?)?.toInt() ??
                (payment['baseAmountMinor'] as num?)?.toInt() ??
                0,
            baseAmountMinor: (payment['baseAmountMinor'] as num?)?.toInt() ?? 0,
            terminalLabel: payment['terminalLabel'] as String?,
          );
        })
        .toList(growable: false);
    final taxBreakdown =
        List<Object?>.from(data['taxBreakdown'] as List? ?? const [])
            .whereType<Map>()
            .map((raw) {
              final tax = Map<String, Object?>.from(raw);
              return SalesReportTaxEntry(
                name: tax['taxRateName'] as String? ?? 'Tax',
                basisPoints: (tax['taxRateBasisPoints'] as num?)?.toInt() ?? 0,
                grossMinor: (tax['grossMinor'] as num?)?.toInt() ?? 0,
                netMinor: (tax['netMinor'] as num?)?.toInt() ?? 0,
                taxMinor: (tax['taxMinor'] as num?)?.toInt() ?? 0,
              );
            })
            .toList(growable: false);
    final lines = List<Object?>.from(data['lines'] as List? ?? const [])
        .whereType<Map>()
        .map((raw) {
          final line = Map<String, Object?>.from(raw);
          final quantity = (line['quantity'] as num?)?.toInt() ?? 0;
          final lineTotal = (line['lineTotalMinor'] as num?)?.toInt();
          final unitPrice = (line['unitPriceMinor'] as num?)?.toInt() ?? 0;
          return SalesReportLine(
            productId: line['productId'] as String? ?? '',
            productName: line['productName'] as String? ?? 'Menu item',
            quantity: quantity,
            grossMinor: lineTotal ?? quantity * unitPrice,
          );
        })
        .toList(growable: false);
    final actor = data['closedByActor'];
    return SalesReportBill(
      id: document.id,
      receiptNumber: data['receiptNumber'] as String? ?? document.id,
      venueId: venueId,
      businessDate: businessDate,
      currencyCode: data['currencyCode'] as String? ?? 'GBP',
      grossMinor:
          (data['grossTotalMinor'] as num?)?.toInt() ??
          (data['totalMinor'] as num?)?.toInt() ??
          0,
      netMinor: (data['netTotalMinor'] as num?)?.toInt() ?? 0,
      taxMinor: (data['taxTotalMinor'] as num?)?.toInt() ?? 0,
      payments: payments,
      lines: lines,
      taxBreakdown: taxBreakdown,
      closedByName: actor is Map
          ? actor['displayName'] as String? ?? actor['email'] as String? ?? ''
          : '',
    );
  }

  OrderFlowOrder? _orderFlowFromDocument(
    QueryDocumentSnapshot<Map<String, dynamic>> document,
    VenueScope scope,
  ) {
    final data = document.data();
    if (data['showOnOrderFlow'] == false) return null;
    final venueId = data['venueId'] as String?;
    if (venueId == null) return null;
    final releasedAt = data['ticketReleasedAt'];
    final DateTime ticketReleasedAt = releasedAt is Timestamp
        ? releasedAt.toDate()
        : releasedAt is DateTime
        ? releasedAt
        : DateTime.now();
    final rawItems =
        data['orderFlowItems'] ??
        data['productionItems'] ??
        data['itemSummary'];
    final itemSummary = rawItems is List
        ? rawItems
              .map((item) {
                if (item is String) return item;
                if (item is Map) {
                  final quantity = item['quantity'];
                  final name = item['name'] ?? item['productName'];
                  final details = item['details'] is List
                      ? (item['details'] as List)
                            .whereType<String>()
                            .map((detail) => detail.trim())
                            .where((detail) => detail.isNotEmpty)
                            .toList(growable: false)
                      : const <String>[];
                  final suffix = details.isEmpty
                      ? ''
                      : '\n  ${details.join('\n  ')}';
                  return '${quantity ?? 1} × ${name ?? 'Item'}$suffix';
                }
                return 'Item';
              })
              .toList(growable: false)
        : const <String>['Order items'];
    final actor = data['createdByActor'];
    return OrderFlowOrder(
      id: document.id,
      tenantId: scope.tenantId,
      venueId: venueId,
      reference: data['reference'] as String? ?? document.id,
      tableLabel: data['tableLabel'] as String?,
      tabName: data['tabName'] as String?,
      productionArea: _productionArea(data['productionArea'] as String?),
      status: _orderFlowStatus(data['flowStatus'] as String?),
      ticketReleasedAt: ticketReleasedAt,
      itemSummary: itemSummary,
      createdByName: actor is Map ? actor['displayName'] as String? ?? '' : '',
      hasAllergyAlert: data['hasAllergyAlert'] as bool? ?? false,
      isDelayed: data['isDelayed'] as bool? ?? false,
      note: data['productionNote'] as String? ?? '',
    );
  }

  ProductionArea _productionArea(String? value) => switch (value) {
    'bar' => ProductionArea.bar,
    'dessert' => ProductionArea.dessert,
    _ => ProductionArea.kitchen,
  };

  OrderFlowStatus _orderFlowStatus(String? value) => switch (value) {
    'preparing' => OrderFlowStatus.preparing,
    'ready' => OrderFlowStatus.ready,
    'collected' => OrderFlowStatus.collected,
    'served' => OrderFlowStatus.served,
    'cancelled' => OrderFlowStatus.cancelled,
    'voided' => OrderFlowStatus.voided,
    _ => OrderFlowStatus.newOrder,
  };
}
