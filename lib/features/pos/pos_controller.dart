import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../data/firestore_pos_repository.dart';
import '../../data/production_command_repository.dart';
import '../printing/bluetooth_production_print_service.dart';
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

/// Identifies the server-owned order currently visible in the POS. A newly
/// started local basket has no document to listen to until it is first sent.
final activePersistedOrderIdProvider =
    NotifierProvider<ActivePersistedOrderIdController, String?>(
      ActivePersistedOrderIdController.new,
    );

class ActivePersistedOrderIdController extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? orderId) => state = orderId;
}

/// The active order must be live, just like the menu, tables and named tabs.
/// Every device watching the same sent order receives changes through this
/// stream rather than requiring the user to reopen the table.
final activeOrderStreamProvider = StreamProvider<PosOrder?>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  final orderId = ref.watch(activePersistedOrderIdProvider);
  if (scope == null || orderId == null) return Stream.value(null);
  return ref
      .watch(firestorePosRepositoryProvider)
      .watchOrder(scope: scope, orderId: orderId);
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
  String build() =>
      ref.watch(activeVenueScopeProvider) == null ? 'table-2' : '';

  void select(String tableId) => state = tableId;
}

final activeOrderProvider = NotifierProvider<ActiveOrderController, PosOrder>(
  ActiveOrderController.new,
);

class ActiveOrderController extends Notifier<PosOrder> {
  var _isSelectingInitialTable = false;
  var _pendingDraftMutations = 0;
  final _pendingDraftQuantities = <String, int>{};

  bool get _isSavingDraft => _pendingDraftMutations > 0;

  @override
  PosOrder build() {
    ref.listen<AsyncValue<PosOrder?>>(activeOrderStreamProvider, (_, next) {
      next.when(
        data: _applyLiveOrder,
        loading: () {},
        error: (error, stackTrace) =>
            AppLogger.error('Live active order', error, stackTrace),
      );
    });
    // This listener must live in the controller rather than the Tables tab.
    // On a phone the Menu tab opens first, so a hidden Tables tab cannot be
    // responsible for replacing the old demo table ID with a real Firestore
    // table ID.
    ref.listen<AsyncValue<List<DiningTable>>>(diningTablesProvider, (_, next) {
      next.when(
        data: _selectInitialLiveTable,
        loading: () {},
        error: (error, stackTrace) =>
            AppLogger.error('Load initial venue table', error, stackTrace),
      );
    });
    // An active order must not be recreated whenever an operator merely taps
    // another table or the venue scope refreshes.
    final scope = ref.read(activeVenueScopeProvider);
    final tableId = ref.read(selectedTableProvider);
    final now = DateTime.now();
    return PosOrder(
      id: 'order-1024',
      tenantId: scope?.tenantId ?? demoTenant.id,
      venueId: scope?.venueId ?? demoVenue.id,
      tableId: tableId.isEmpty ? null : tableId,
      businessDate: DateTime(now.year, now.month, now.day),
      openedAt: now,
      status: OrderStatus.open,
      lines: scope == null ? _demoLines : const [],
    );
  }

  Future<void> addProduct(MenuProduct product) async {
    if (!state.canAddProduct(product)) {
      AppLogger.info(
        'Stock prevented adding ${product.id} to active order ${state.id}.',
      );
      return;
    }
    final scope = ref.read(activeVenueScopeProvider);
    if (scope != null) _requireValidLiveOrderLocation();
    // Keep each tap visible as a separate line in the live order. This makes
    // late additions unmistakable to staff; a future final bill/receipt can
    // still consolidate matching lines to save paper.
    final line = OrderLine(
      id: '${product.id}-${DateTime.now().microsecondsSinceEpoch}',
      productId: product.id,
      productName: product.name,
      quantity: 1,
      unitPriceMinor: product.priceMinor,
      productionArea: product.productionArea,
      trackStock: product.trackStock,
      stockPerSale: product.stockPerSale,
    );
    state = state.copyWith(
      lines: [...state.lines, line],
      status: state.status == OrderStatus.sent
          ? OrderStatus.sent
          : OrderStatus.open,
    );
    if (scope == null) return;

    _pendingDraftMutations++;
    try {
      await ref
          .read(productionCommandRepositoryProvider)
          .addDraftLine(scope: scope, order: state, line: line);
      // From the very first item, the Firestore order is the shared source of
      // truth. It remains a draft until the waiter presses Send.
      _selectPersistedOrder(state.id);
      AppLogger.info('Draft line saved: ${line.id} on order ${state.id}.');
    } on Object catch (error, stackTrace) {
      state = state.copyWith(
        lines: state.lines
            .where((existing) => existing.id != line.id)
            .toList(growable: false),
      );
      await _reloadCurrentTableOrderIfPresent(scope);
      AppLogger.error('Save draft order line', error, stackTrace);
      rethrow;
    } finally {
      _pendingDraftMutations--;
    }
  }

  void _applyLiveOrder(PosOrder? remoteOrder) {
    if (remoteOrder == null) {
      _pendingDraftQuantities.clear();
      AppLogger.info('Live active order is no longer open.');
      return;
    }
    if (remoteOrder.id != state.id) return;

    // Do not lose a waiter’s locally added, unsent items if a Firestore
    // snapshot from another device arrives before this device sends them.
    final serverLines = <OrderLine>[];
    final remoteLineIds = remoteOrder.lines.map((line) => line.id).toSet();
    for (final line in remoteOrder.lines) {
      final pendingQuantity = _pendingDraftQuantities[line.id];
      if (pendingQuantity == null) {
        serverLines.add(line);
      } else if (pendingQuantity == line.quantity) {
        _pendingDraftQuantities.remove(line.id);
        serverLines.add(line);
      } else if (pendingQuantity > 0) {
        // Do not briefly restore a just-removed/decremented item while this
        // device is waiting for the server snapshot of its own change.
        serverLines.add(line.copyWith(quantity: pendingQuantity));
      }
    }
    _pendingDraftQuantities.removeWhere(
      (lineId, quantity) => quantity == 0 && !remoteLineIds.contains(lineId),
    );
    final displayedServerLineIds = serverLines.map((line) => line.id).toSet();
    final localOnlyUnsentLines = state.lines
        .where(
          (line) =>
              !line.isSentToProduction &&
              !displayedServerLineIds.contains(line.id) &&
              _pendingDraftQuantities[line.id] != 0,
        )
        .toList(growable: false);
    state = remoteOrder.copyWith(
      lines: [...serverLines, ...localOnlyUnsentLines],
    );
    AppLogger.info(
      'Live active order applied: ${remoteOrder.id}, ${state.lines.length} line(s).',
    );
  }

  void _selectInitialLiveTable(List<DiningTable> tables) {
    if (_isSelectingInitialTable || tables.isEmpty || state.tabName != null) {
      return;
    }
    final currentTableId = state.tableId;
    if (currentTableId != null &&
        tables.any((table) => table.id == currentTableId)) {
      return;
    }
    if (state.lines.any((line) => !line.isSentToProduction)) {
      AppLogger.info(
        'Initial table selection deferred because this basket has unsent items.',
      );
      return;
    }
    _isSelectingInitialTable = true;
    unawaited(_openInitialLiveTable(tables.first));
  }

  Future<void> _openInitialLiveTable(DiningTable table) async {
    try {
      // Select before the async lookup so the visible Order panel never shows
      // a demo/empty table ID while a live venue is open.
      ref.read(selectedTableProvider.notifier).select(table.id);
      await openTable(table.id);
      AppLogger.info('Initial live table selected: ${table.label}.');
    } on Object catch (error, stackTrace) {
      AppLogger.error('Open initial live table', error, stackTrace);
    } finally {
      _isSelectingInitialTable = false;
    }
  }

  Future<void> reduceLine(String lineId) async {
    if (_isSavingDraft) {
      throw StateError(
        'Please wait for the previous basket change to finish saving.',
      );
    }
    final original = state.lines.where((line) => line.id == lineId).firstOrNull;
    if (original == null || original.isSentToProduction) return;
    final updatedLines = <OrderLine>[];
    var nextQuantity = 0;
    for (final line in state.lines) {
      if (line.id != lineId) {
        updatedLines.add(line);
      } else if (line.isSentToProduction) {
        updatedLines.add(line);
      } else if (line.quantity > 1) {
        nextQuantity = line.quantity - 1;
        updatedLines.add(line.copyWith(quantity: nextQuantity));
      }
    }
    state = state.copyWith(lines: updatedLines);
    final scope = ref.read(activeVenueScopeProvider);
    if (scope == null) return;
    _requireValidLiveOrderLocation();

    _pendingDraftMutations++;
    _pendingDraftQuantities[lineId] = nextQuantity;
    try {
      await ref
          .read(productionCommandRepositoryProvider)
          .updateDraftLineQuantity(
            scope: scope,
            order: state,
            lineId: lineId,
            quantity: nextQuantity,
          );
      if (state.lines.isEmpty && state.tableId != null) {
        _pendingDraftQuantities.remove(lineId);
        _selectPersistedOrder(null);
      }
      AppLogger.info('Draft line updated: $lineId to $nextQuantity.');
    } on Object catch (error, stackTrace) {
      // Keep later, independent taps intact if this one failed to save.
      final restored = state.lines.any((line) => line.id == original.id)
          ? state.lines
                .map((line) => line.id == original.id ? original : line)
                .toList(growable: false)
          : [...state.lines, original];
      state = state.copyWith(lines: restored);
      _pendingDraftQuantities.remove(lineId);
      AppLogger.error('Update draft order line', error, stackTrace);
      rethrow;
    } finally {
      _pendingDraftMutations--;
    }
  }

  void markSent() => state = state.copyWith(status: OrderStatus.sent);

  /// Opens the selected table's current order if there is one; otherwise
  /// starts a clean order. We never silently discard unsent lines while a
  /// waiter is switching tables.
  Future<void> openTable(String tableId) async {
    if (state.tableId == tableId &&
        ref.read(activePersistedOrderIdProvider) == state.id) {
      return;
    }
    if (_hasUnsavedLocalDraft()) {
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
      _selectPersistedOrder(existing.id);
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
    _selectPersistedOrder(null);
  }

  /// Opens or creates a venue-local named tab. The server owns the unique name
  /// reservation, so simultaneous devices can never create two live tabs for
  /// the same guest name.
  Future<void> openNamedTab(String tabName) async {
    final cleanedName = tabName.trim();
    if (cleanedName.isEmpty) throw StateError('Enter a name for the tab.');
    if (_hasUnsavedLocalDraft()) {
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
      _selectPersistedOrder(null);
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
    _selectPersistedOrder(order.id);
  }

  Future<BluetoothProductionPrintResult> sendToProduction() async {
    if (_isSavingDraft) {
      throw StateError(
        'The basket is still saving. Please retry Send in a moment.',
      );
    }
    final scope = ref.read(activeVenueScopeProvider);
    if (scope != null) _requireValidLiveOrderLocation();
    final unsentLines = state.lines
        .where((line) => !line.isSentToProduction)
        .toList(growable: false);
    var printResult = const BluetoothProductionPrintResult();
    if (scope != null) {
      final dispatch = await ref
          .read(productionCommandRepositoryProvider)
          .sendNewLinesToProduction(scope: scope, order: state);
      // The order document is now server-owned, so subscribe before local
      // printing. This lets a second device see the order immediately even if
      // this device's Bluetooth printer is unavailable.
      _selectPersistedOrder(state.id);
      final locallyRoutedLines = unsentLines
          .where(
            (line) => !dispatch.queuedProductionAreas.contains(
              line.productionArea.name,
            ),
          )
          .toList(growable: false);
      final tableLabel = _tableLabelFor(state);
      final user = FirebaseAuth.instance.currentUser;
      AppLogger.info(
        'Bluetooth production printing: evaluating ${unsentLines.length} newly sent line(s).',
      );
      printResult = await BluetoothProductionPrintService().printNewLines(
        scope: scope,
        order: state,
        lines: locallyRoutedLines,
        restaurantName: ref.read(tenantProfileProvider).displayName,
        tableLabel: tableLabel,
        createdByName: user?.displayName?.trim().isNotEmpty == true
            ? user!.displayName!.trim()
            : user?.email ?? '',
      );
      AppLogger.info(
        'Bluetooth production printing: ${printResult.ticketsPrinted} ticket(s) sent to the local printer.',
      );
    }
    state = state.copyWith(
      status: OrderStatus.sent,
      lines: state.lines
          .map((line) => line.copyWith(isSentToProduction: true))
          .toList(growable: false),
    );
    return printResult;
  }

  void _requireValidLiveOrderLocation() {
    if (state.tabName?.trim().isNotEmpty == true) return;
    final tableId = state.tableId;
    final problem = ref
        .read(diningTablesProvider)
        .when(
          data: (tables) {
            if (tables.isEmpty) {
              return 'No tables are set up for this venue. Create a table or open a named tab before sending.';
            }
            if (tableId == null ||
                !tables.any((table) => table.id == tableId)) {
              return 'Select a valid table or open a named tab before sending this order.';
            }
            return null;
          },
          loading: () =>
              'Tables are still loading. Please wait a moment and retry.',
          error: (_, _) =>
              'Tables could not be verified. Check the connection and retry.',
        );
    if (problem != null) throw StateError(problem);
  }

  void _selectPersistedOrder(String? orderId) =>
      ref.read(activePersistedOrderIdProvider.notifier).select(orderId);

  bool _hasUnsavedLocalDraft() {
    if (_isSavingDraft) return true;
    if (ref.read(activeVenueScopeProvider) == null) {
      return state.lines.any((line) => !line.isSentToProduction);
    }
    return state.lines.any((line) => !line.isSentToProduction) &&
        ref.read(activePersistedOrderIdProvider) != state.id;
  }

  /// Resolves a race where another device opens the same table between this
  /// device selecting it and adding its first item. The server rejects the
  /// competing draft; immediately showing the winning live order lets the
  /// waiter continue without hunting for the table again.
  Future<void> _reloadCurrentTableOrderIfPresent(VenueScope scope) async {
    final tableId = state.tableId;
    if (tableId == null || state.tabName != null) return;
    try {
      final existing = await ref
          .read(firestorePosRepositoryProvider)
          .fetchOpenOrder(scope: scope, tableId: tableId);
      if (existing != null) {
        state = existing;
        _selectPersistedOrder(existing.id);
        AppLogger.info('Reloaded live order after draft save conflict.');
      }
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'Reload current table order after draft save error',
        error,
        stackTrace,
      );
    }
  }

  String _tableLabelFor(PosOrder order) {
    final tableId = order.tableId;
    if (tableId == null) return '';
    return ref
        .read(diningTablesProvider)
        .when(
          data: (tables) =>
              tables
                  .where((table) => table.id == tableId)
                  .map((table) => table.label)
                  .firstOrNull ??
              tableId,
          loading: () => tableId,
          error: (_, _) => tableId,
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
