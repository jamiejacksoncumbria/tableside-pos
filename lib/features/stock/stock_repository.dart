import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../data/production_command_repository.dart';
import 'stock_domain.dart';

final stockRepositoryProvider = Provider<StockRepository>(
  (ref) => StockRepository(
    FirebaseFirestore.instance,
    ref.watch(productionCommandRepositoryProvider),
  ),
);

final suppliersProvider = StreamProvider<List<StockSupplier>>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(const <StockSupplier>[]);
  return ref.watch(stockRepositoryProvider).watchSuppliers(scope);
});

final supplierProductsProvider = StreamProvider<List<SupplierProduct>>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(const <SupplierProduct>[]);
  return ref.watch(stockRepositoryProvider).watchSupplierProducts(scope);
});

final purchaseOrdersProvider = StreamProvider<List<StockPurchaseOrder>>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(const <StockPurchaseOrder>[]);
  return ref.watch(stockRepositoryProvider).watchPurchaseOrders(scope);
});

final stockMovementsProvider = StreamProvider<List<StockMovement>>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(const <StockMovement>[]);
  return ref.watch(stockRepositoryProvider).watchStockMovements(scope);
});

class StockRepository {
  StockRepository(this._firestore, this._commands);

  final FirebaseFirestore _firestore;
  final ProductionCommandRepository _commands;

  Stream<List<StockSupplier>> watchSuppliers(VenueScope scope) => _firestore
      .collection('tenants/${scope.tenantId}/suppliers')
      .where('venueId', isEqualTo: scope.venueId)
      .snapshots()
      .map((snapshot) {
        final items =
            snapshot.docs
                .map((document) {
                  final data = document.data();
                  return StockSupplier(
                    id: document.id,
                    name: data['name'] as String? ?? 'Unnamed supplier',
                    contactName: data['contactName'] as String? ?? '',
                    email: data['email'] as String? ?? '',
                    phone: data['phone'] as String? ?? '',
                    notes: data['notes'] as String? ?? '',
                    active: data['active'] as bool? ?? true,
                  );
                })
                .toList(growable: false)
              ..sort((a, b) => a.name.compareTo(b.name));
        return items;
      });

  Stream<List<SupplierProduct>> watchSupplierProducts(
    VenueScope scope,
  ) => _firestore
      .collection('tenants/${scope.tenantId}/supplierProducts')
      .where('venueId', isEqualTo: scope.venueId)
      .snapshots()
      .map((snapshot) {
        final items =
            snapshot.docs
                .map((document) {
                  final data = document.data();
                  return SupplierProduct(
                    id: document.id,
                    supplierId: data['supplierId'] as String? ?? '',
                    productId: data['productId'] as String? ?? '',
                    productName: data['productName'] as String? ?? 'Product',
                    packName: data['packName'] as String? ?? 'Pack',
                    stockUnitsPerPack:
                        (data['stockUnitsPerPack'] as num?)?.toDouble() ?? 1,
                    packCostMinor:
                        (data['packCostMinor'] as num?)?.toInt() ?? 0,
                    currencyCode: data['currencyCode'] as String? ?? 'GBP',
                    supplierSku: data['supplierSku'] as String? ?? '',
                    preferred: data['preferred'] as bool? ?? false,
                    active: data['active'] as bool? ?? true,
                  );
                })
                .toList(growable: false)
              ..sort((a, b) => a.productName.compareTo(b.productName));
        return items;
      });

  Stream<List<StockPurchaseOrder>> watchPurchaseOrders(VenueScope scope) =>
      _firestore
          .collection('tenants/${scope.tenantId}/purchaseOrders')
          .where('venueId', isEqualTo: scope.venueId)
          .snapshots()
          .map((snapshot) {
            final items = snapshot.docs.map(_purchaseOrder).toList()
              ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
            return items;
          });

  Stream<List<StockMovement>> watchStockMovements(
    VenueScope scope,
  ) => _firestore
      .collection('tenants/${scope.tenantId}/stockMovements')
      .where('venueId', isEqualTo: scope.venueId)
      .snapshots()
      .map((snapshot) {
        final items =
            snapshot.docs
                .map((document) {
                  final data = document.data();
                  final actor = data['actor'] is Map
                      ? Map<String, Object?>.from(data['actor'] as Map)
                      : data['createdByActor'] is Map
                      ? Map<String, Object?>.from(data['createdByActor'] as Map)
                      : const <String, Object?>{};
                  final createdAt = data['createdAt'];
                  return StockMovement(
                    id: document.id,
                    productId: data['productId'] as String? ?? '',
                    productName: data['productName'] as String? ?? 'Stock item',
                    quantity: (data['quantity'] as num?)?.toDouble() ?? 0,
                    stockUnit: data['stockUnit'] as String? ?? 'each',
                    reason:
                        data['adjustmentReason'] as String? ??
                        data['reason'] as String? ??
                        'Stock movement',
                    createdAt: createdAt is Timestamp
                        ? createdAt.toDate()
                        : DateTime.fromMillisecondsSinceEpoch(0),
                    actorName:
                        actor['displayName'] as String? ??
                        actor['email'] as String? ??
                        '',
                  );
                })
                .toList(growable: false)
              ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return items.take(100).toList(growable: false);
      });

  StockPurchaseOrder _purchaseOrder(
    QueryDocumentSnapshot<Map<String, dynamic>> document,
  ) {
    final data = document.data();
    final lines = (data['lines'] as List? ?? const [])
        .whereType<Map>()
        .map((raw) {
          final line = Map<String, Object?>.from(raw);
          return PurchaseOrderLine(
            id: line['id'] as String? ?? '',
            supplierProductId: line['supplierProductId'] as String? ?? '',
            productId: line['productId'] as String? ?? '',
            productName: line['productName'] as String? ?? 'Product',
            packName: line['packName'] as String? ?? 'Pack',
            orderedPacks: (line['orderedPacks'] as num?)?.toDouble() ?? 0,
            receivedPacks: (line['receivedPacks'] as num?)?.toDouble() ?? 0,
            stockUnitsPerPack:
                (line['stockUnitsPerPack'] as num?)?.toDouble() ?? 1,
            packCostMinor: (line['packCostMinor'] as num?)?.toInt() ?? 0,
            currencyCode: line['currencyCode'] as String? ?? 'GBP',
            recommendedPacks:
                (line['recommendedPacks'] as num?)?.toDouble() ?? 0,
            recentDailyUsage:
                (line['recentDailyUsage'] as num?)?.toDouble() ?? 0,
            priorYearDailyUsage: (line['priorYearDailyUsage'] as num?)
                ?.toDouble(),
          );
        })
        .where((line) => line.id.isNotEmpty && line.productId.isNotEmpty)
        .toList(growable: false);
    DateTime timestamp(Object? value) => value is Timestamp
        ? value.toDate()
        : DateTime.fromMillisecondsSinceEpoch(0);
    return StockPurchaseOrder(
      id: document.id,
      supplierId: data['supplierId'] as String? ?? '',
      supplierName: data['supplierName'] as String? ?? 'Supplier',
      status: purchaseOrderStatusFromWire(data['status'] as String?),
      coverageDays: (data['coverageDays'] as num?)?.toInt() ?? 0,
      lines: lines,
      createdAt: timestamp(data['createdAt']),
      orderedAt: data['orderedAt'] == null
          ? null
          : timestamp(data['orderedAt']),
      receivedAt: data['receivedAt'] == null
          ? null
          : timestamp(data['receivedAt']),
    );
  }

  Future<String> command({
    required VenueScope scope,
    required String operation,
    String? documentId,
    Map<String, Object?> values = const {},
  }) async {
    try {
      return await _commands.manageInventory(
        scope: scope,
        operation: operation,
        documentId: documentId,
        values: values,
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Inventory command $operation', error, stackTrace);
      rethrow;
    }
  }
}
