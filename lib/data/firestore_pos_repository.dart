import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/tenant_scope.dart';
import '../features/pos/domain.dart';

final firestorePosRepositoryProvider = Provider<FirestorePosRepository>(
  (ref) => FirestorePosRepository(FirebaseFirestore.instance),
);

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
      return TenantProfile(
        id: document.id,
        displayName: data['displayName'] as String? ?? 'Unnamed restaurant',
        legalName: data['legalName'] as String? ?? '',
        currencyCode: data['currencyCode'] as String? ?? 'GBP',
        logoUrl: data['logoUrl'] as String?,
        address: data['address'] as String? ?? '',
        phone: data['phone'] as String? ?? '',
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
                );
              })
              .toList(growable: false),
        );
  }

  Stream<List<MenuSection>> watchMenuSections(VenueScope scope) {
    return _firestore
        .collection('tenants/${scope.tenantId}/menuSections')
        .orderBy('sortOrder')
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
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
                );
              })
              .toList(growable: false),
        );
  }

  Stream<List<MenuProduct>> watchProducts(VenueScope scope) {
    return _firestore
        .collection('tenants/${scope.tenantId}/products')
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
                );
              })
              .toList(growable: false),
        );
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

  Future<PosOrder?> fetchOpenOrder({
    required VenueScope scope,
    required String tableId,
  }) async {
    final table = await _firestore
        .doc('tenants/${scope.tenantId}/tables/$tableId')
        .get();
    final currentOrderId = table.data()?['currentOrderId'] as String?;
    if (currentOrderId == null || currentOrderId.isEmpty) return null;
    final order = await _firestore
        .doc('tenants/${scope.tenantId}/orders/$currentOrderId')
        .get();
    final data = order.data();
    if (data == null ||
        data['venueId'] != scope.venueId ||
        data['tableId'] != tableId ||
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
          );
        })
        .where((line) => line.id.isNotEmpty && line.productId.isNotEmpty)
        .toList(growable: false);
    final date = openedAt is Timestamp ? openedAt.toDate() : DateTime.now();
    return PosOrder(
      id: order.id,
      tenantId: scope.tenantId,
      venueId: scope.venueId,
      tableId: tableId,
      businessDate: DateTime(date.year, date.month, date.day),
      openedAt: date,
      status: OrderStatus.sent,
      lines: lines,
    );
  }

  Future<void> createMenuSection({
    required VenueScope scope,
    required String name,
    required String icon,
    required int sortOrder,
  }) async {
    final cleanedName = name.trim();
    if (cleanedName.isEmpty) throw ArgumentError.value(name, 'name');
    await _firestore.collection('tenants/${scope.tenantId}/menuSections').add({
      'venueId': scope.venueId,
      'name': cleanedName,
      'icon': icon.trim().isEmpty ? '🍽️' : icon.trim(),
      'sortOrder': sortOrder,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
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
  }) async {
    final cleanedName = name.trim();
    if (cleanedName.isEmpty || priceMinor < 0 || sectionIds.isEmpty) {
      throw ArgumentError('Product details are incomplete.');
    }
    if (stockPerSale <= 0 || !stockPerSale.isFinite) {
      throw ArgumentError.value(stockPerSale, 'stockPerSale');
    }
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
          'updatedAt': FieldValue.serverTimestamp(),
        });
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
    final venueId = data['venueId'] as String?;
    if (venueId == null) return null;
    final releasedAt = data['ticketReleasedAt'];
    final DateTime ticketReleasedAt = releasedAt is Timestamp
        ? releasedAt.toDate()
        : releasedAt is DateTime
        ? releasedAt
        : DateTime.now();
    final rawItems = data['productionItems'] ?? data['itemSummary'];
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
