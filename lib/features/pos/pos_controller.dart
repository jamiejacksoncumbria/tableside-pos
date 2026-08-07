import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tenant_scope.dart';
import '../../data/firestore_pos_repository.dart';
import 'domain.dart';

final menuSectionsProvider = StreamProvider<List<MenuSection>>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(demoSections);
  return ref
      .watch(firestorePosRepositoryProvider)
      .watchMenuSections(scope.tenantId);
});

final menuProductsProvider = StreamProvider<List<MenuProduct>>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(demoProducts);
  return ref
      .watch(firestorePosRepositoryProvider)
      .watchProducts(scope.tenantId);
});

final diningTablesProvider = StreamProvider<List<DiningTable>>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(demoTables);
  return ref.watch(firestorePosRepositoryProvider).watchTables(scope);
});

final tenantProfileProvider =
    NotifierProvider<TenantProfileController, TenantProfile>(
      TenantProfileController.new,
    );

class TenantProfileController extends Notifier<TenantProfile> {
  @override
  TenantProfile build() => demoTenant;

  void update(TenantProfile profile) => state = profile;
}

final activeSectionProvider = NotifierProvider<ActiveSectionController, String>(
  ActiveSectionController.new,
);

class ActiveSectionController extends Notifier<String> {
  @override
  String build() => demoSections.first.id;

  void select(String sectionId) => state = sectionId;
}

final selectedTableProvider = NotifierProvider<SelectedTableController, String>(
  SelectedTableController.new,
);

class SelectedTableController extends Notifier<String> {
  @override
  String build() => 'table-2';

  void select(String tableId) => state = tableId;
}

final activeOrderProvider = NotifierProvider<ActiveOrderController, PosOrder>(
  ActiveOrderController.new,
);

class ActiveOrderController extends Notifier<PosOrder> {
  @override
  PosOrder build() {
    final scope = ref.watch(activeVenueScopeProvider);
    final tableId = ref.watch(selectedTableProvider);
    final now = DateTime.now();
    return PosOrder(
      id: 'order-1024',
      tenantId: scope?.tenantId ?? demoTenant.id,
      venueId: scope?.venueId ?? demoVenue.id,
      tableId: tableId,
      businessDate: DateTime(now.year, now.month, now.day),
      openedAt: now,
      status: OrderStatus.open,
      lines: scope == null ? _demoLines : const [],
    );
  }

  void addProduct(MenuProduct product) {
    final existingIndex = state.lines.indexWhere(
      (line) => line.productId == product.id,
    );
    final updatedLines = [...state.lines];
    if (existingIndex >= 0) {
      final line = updatedLines[existingIndex];
      updatedLines[existingIndex] = line.copyWith(quantity: line.quantity + 1);
    } else {
      updatedLines.add(
        OrderLine(
          id: '${product.id}-${DateTime.now().microsecondsSinceEpoch}',
          productId: product.id,
          productName: product.name,
          quantity: 1,
          unitPriceMinor: product.priceMinor,
          productionArea: product.productionArea,
          trackStock: product.trackStock,
        ),
      );
    }
    state = state.copyWith(lines: updatedLines, status: OrderStatus.open);
  }

  void reduceLine(String lineId) {
    final updatedLines = <OrderLine>[];
    for (final line in state.lines) {
      if (line.id != lineId) {
        updatedLines.add(line);
      } else if (line.quantity > 1) {
        updatedLines.add(line.copyWith(quantity: line.quantity - 1));
      }
    }
    state = state.copyWith(lines: updatedLines);
  }

  void markSent() => state = state.copyWith(status: OrderStatus.sent);

  void markPendingCustomerApproval() => state = state.copyWith(
    status: OrderStatus.pendingApproval,
    isCustomerOriginated: true,
  );
}

const _demoLines = [
  OrderLine(
    id: 'line-1',
    productId: 'house-red',
    productName: 'House red, glass',
    quantity: 2,
    unitPriceMinor: 650,
    productionArea: ProductionArea.bar,
    trackStock: true,
  ),
];
