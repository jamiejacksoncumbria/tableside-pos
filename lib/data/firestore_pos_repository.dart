import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_logger.dart';
import '../core/tenant_scope.dart';
import '../features/pos/domain.dart';

final firestorePosRepositoryProvider = Provider<FirestorePosRepository>(
  (ref) => FirestorePosRepository(FirebaseFirestore.instance),
);

final taxRatesProvider = StreamProvider<List<TaxRate>>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(const <TaxRate>[]);
  return ref.watch(firestorePosRepositoryProvider).watchTaxRates(scope);
});

class FirestorePosRepository {
  FirestorePosRepository(this._firestore);

  final FirebaseFirestore _firestore;

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
                );
              })
              .toList(growable: false),
        );
  }

  int _notificationRetentionSeconds(Object? value) {
    final seconds = value is int ? value : 5;
    return seconds.clamp(1, 60).toInt();
  }

  int _taxRateBasisPoints(Object? value) {
    final rate = value is int ? value : 0;
    return rate.clamp(0, 100000).toInt();
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
                return DiningTable(
                  id: document.id,
                  label: data['label'] as String? ?? 'Table',
                  seats: data['seats'] as int? ?? 0,
                  hasOpenOrder: data['currentOrderId'] != null,
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
    );
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
    await _firestore.collection('tenants/${scope.tenantId}/menuSections').add({
      'venueId': scope.venueId,
      'name': cleanedName,
      'icon': icon.trim().isEmpty ? '🍽️' : icon.trim(),
      'sortOrder': sortOrder,
      'parentSectionId': parentSectionId,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
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
    await _firestore
        .doc('tenants/${scope.tenantId}/menuSections/$sectionId')
        .update({
          'name': cleanedName,
          'icon': icon.trim().isEmpty ? '🍽️' : icon.trim(),
          'parentSectionId': parentSectionId,
          'updatedAt': FieldValue.serverTimestamp(),
        });
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
    await _firestore
        .doc('tenants/${scope.tenantId}/menuSections/$sectionId')
        .delete();
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
    await _firestore.collection('tenants/${scope.tenantId}/products').add({
      'venueId': scope.venueId,
      'name': cleanedName,
      'priceMinor': priceMinor,
      'sectionIds': sectionIds,
      'productionArea': productionArea.name,
      'trackStock': trackStock,
      'stockOnHand': trackStock ? (stockOnHand ?? 0) : null,
      'stockUnit': 'each',
      'stockPerSale': stockPerSale,
      'isAvailable': true,
      'showOnOrderFlow': showOnOrderFlow,
      'taxRateBasisPoints': taxRateBasisPoints,
      'taxRateId': taxRateId,
      'taxRateName': cleanedTaxRateName,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> setProductAvailability({
    required VenueScope scope,
    required String productId,
    required bool isAvailable,
  }) {
    return _firestore
        .doc('tenants/${scope.tenantId}/products/$productId')
        .update({
          'isAvailable': isAvailable,
          'updatedAt': FieldValue.serverTimestamp(),
        });
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
    await _firestore
        .doc('tenants/${scope.tenantId}/products/$productId')
        .update({
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
          'updatedAt': FieldValue.serverTimestamp(),
        });
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
    await _taxRates(scope.tenantId).add({
      'venueId': scope.venueId,
      'name': cleanedName,
      'basisPoints': basisPoints,
      'active': true,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
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
    final rateRef = _taxRates(scope.tenantId).doc(existing.id);
    final rate = await rateRef.get();
    if (!rate.exists || rate.data()?['venueId'] != scope.venueId) {
      throw StateError(
        'This tax rate no longer belongs to the selected venue.',
      );
    }
    final productSnapshots = await _firestore
        .collection('tenants/${scope.tenantId}/products')
        .where('taxRateId', isEqualTo: existing.id)
        .get();
    final references = productSnapshots.docs
        .where((product) => product.data()['venueId'] == scope.venueId)
        .map((product) => product.reference)
        .toList(growable: false);
    await _commitTaxRateAndProductUpdates(
      rateRef: rateRef,
      productReferences: references,
      name: cleanedName,
      basisPoints: basisPoints,
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
    final reference = _taxRates(scope.tenantId).doc(rate.id);
    final current = await reference.get();
    if (!current.exists || current.data()?['venueId'] != scope.venueId) {
      throw StateError(
        'This tax rate no longer belongs to the selected venue.',
      );
    }
    await reference.delete();
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

  Future<void> _commitTaxRateAndProductUpdates({
    required DocumentReference<Map<String, dynamic>> rateRef,
    required List<DocumentReference<Map<String, dynamic>>> productReferences,
    required String name,
    required int basisPoints,
  }) async {
    // Keep below Firestore's 500-write limit. Selected product rate snapshots
    // are updated too, so future orders reflect a manager's amended rate.
    const maximumProductsPerBatch = 450;
    var offset = 0;
    do {
      final end = (offset + maximumProductsPerBatch).clamp(
        0,
        productReferences.length,
      );
      final batch = _firestore.batch();
      if (offset == 0) {
        batch.update(rateRef, {
          'name': name,
          'basisPoints': basisPoints,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
      for (final product in productReferences.sublist(offset, end)) {
        batch.update(product, {
          'taxRateName': name,
          'taxRateBasisPoints': basisPoints,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
      await batch.commit();
      offset = end;
    } while (offset < productReferences.length);
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
                  return '${quantity ?? 1} × ${name ?? 'Item'}';
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
