import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tenant_scope.dart';
import '../../data/firestore_pos_repository.dart';
import '../../data/production_command_repository.dart';
import 'domain.dart';

final menuSectionsProvider = StreamProvider<List<MenuSection>>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(demoSections);
  return ref.watch(firestorePosRepositoryProvider).watchMenuSections(scope);
});

final menuProductsProvider = StreamProvider<List<MenuProduct>>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(demoProducts);
  return ref.watch(firestorePosRepositoryProvider).watchProducts(scope);
});

final diningTablesProvider = StreamProvider<List<DiningTable>>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(demoTables);
  return ref.watch(firestorePosRepositoryProvider).watchTables(scope);
});

final openNamedTabsProvider = StreamProvider<List<OpenNamedTab>>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(const []);
  return ref.watch(firestorePosRepositoryProvider).watchOpenNamedTabs(scope);
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

final activeSectionProvider =
    NotifierProvider<ActiveSectionController, String?>(
      ActiveSectionController.new,
    );

class ActiveSectionController extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? sectionId) => state = sectionId;
}

final activeSubsectionProvider =
    NotifierProvider<ActiveSubsectionController, String?>(
      ActiveSubsectionController.new,
    );

class ActiveSubsectionController extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? sectionId) => state = sectionId;
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
    // An active order must not be recreated whenever an operator merely taps
    // another table or the venue scope refreshes.
    final scope = ref.read(activeVenueScopeProvider);
    final tableId = ref.read(selectedTableProvider);
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
    // Keep each tap visible as a separate line in the live order. This makes
    // late additions unmistakable to staff; a future final bill/receipt can
    // still consolidate matching lines to save paper.
    final updatedLines = [...state.lines];
    updatedLines.add(
      OrderLine(
        id: '${product.id}-${DateTime.now().microsecondsSinceEpoch}',
        productId: product.id,
        productName: product.name,
        quantity: 1,
        unitPriceMinor: product.priceMinor,
        productionArea: product.productionArea,
        trackStock: product.trackStock,
        stockPerSale: product.stockPerSale,
      ),
    );
    state = state.copyWith(
      lines: updatedLines,
      status: state.status == OrderStatus.sent
          ? OrderStatus.sent
          : OrderStatus.open,
    );
  }

  void reduceLine(String lineId) {
    final updatedLines = <OrderLine>[];
    for (final line in state.lines) {
      if (line.id != lineId) {
        updatedLines.add(line);
      } else if (line.isSentToProduction) {
        updatedLines.add(line);
      } else if (line.quantity > 1) {
        updatedLines.add(line.copyWith(quantity: line.quantity - 1));
      }
    }
    state = state.copyWith(lines: updatedLines);
  }

  void markSent() => state = state.copyWith(status: OrderStatus.sent);

  /// Opens the selected table's current order if there is one; otherwise
  /// starts a clean order. We never silently discard unsent lines while a
  /// waiter is switching tables.
  Future<void> openTable(String tableId) async {
    if (state.tableId == tableId) return;
    if (state.lines.any((line) => !line.isSentToProduction)) {
      throw StateError(
        'Send or remove the unsent items before switching to another table.',
      );
    }
    final scope = ref.read(activeVenueScopeProvider);
    final existing = scope == null
        ? null
        : await ref
              .read(firestorePosRepositoryProvider)
              .fetchOpenOrder(scope: scope, tableId: tableId);
    if (existing != null) {
      state = existing;
      return;
    }
    final now = DateTime.now();
    state = PosOrder(
      id: 'order-${now.microsecondsSinceEpoch}',
      tenantId: scope?.tenantId ?? demoTenant.id,
      venueId: scope?.venueId ?? demoVenue.id,
      tableId: tableId,
      businessDate: DateTime(now.year, now.month, now.day),
      openedAt: now,
      status: OrderStatus.open,
      lines: const [],
    );
  }

  /// Opens or creates a venue-local named tab. The server owns the unique name
  /// reservation, so simultaneous devices can never create two live tabs for
  /// the same guest name.
  Future<void> openNamedTab(String tabName) async {
    final cleanedName = tabName.trim();
    if (cleanedName.isEmpty) throw StateError('Enter a name for the tab.');
    if (state.lines.any((line) => !line.isSentToProduction)) {
      throw StateError(
        'Send or remove the unsent items before opening another tab.',
      );
    }
    final scope = ref.read(activeVenueScopeProvider);
    if (scope == null) {
      final now = DateTime.now();
      state = PosOrder(
        id: 'order-${now.microsecondsSinceEpoch}',
        tenantId: demoTenant.id,
        venueId: demoVenue.id,
        tabName: cleanedName,
        businessDate: DateTime(now.year, now.month, now.day),
        openedAt: now,
        status: OrderStatus.open,
        lines: const [],
      );
      return;
    }
    final orderId = await ref
        .read(productionCommandRepositoryProvider)
        .openNamedTab(scope: scope, tabName: cleanedName);
    final order = await ref
        .read(firestorePosRepositoryProvider)
        .fetchOrder(scope: scope, orderId: orderId);
    if (order == null) {
      throw StateError('The named tab could not be loaded. Please retry.');
    }
    state = order;
  }

  Future<void> sendToProduction() async {
    final scope = ref.read(activeVenueScopeProvider);
    if (scope != null) {
      await ref
          .read(productionCommandRepositoryProvider)
          .sendNewLinesToProduction(scope: scope, order: state);
    }
    state = state.copyWith(
      status: OrderStatus.sent,
      lines: state.lines
          .map((line) => line.copyWith(isSentToProduction: true))
          .toList(growable: false),
    );
  }

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
