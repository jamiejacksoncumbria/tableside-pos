import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/safe_dialog.dart';
import '../../core/app_logger.dart';
import '../../core/date_formats.dart';
import '../../core/money.dart';
import '../../core/tenant_scope.dart';
import '../notifications/notification_centre.dart';
import '../pos/domain.dart';
import '../pos/pos_controller.dart';
import 'stock_domain.dart';
import 'stock_repository.dart';

part 'widgets/stock_inventory.dart';
part 'widgets/stock_suppliers_orders.dart';
part 'widgets/stock_command_dialogs.dart';

class StockManagementPage extends ConsumerWidget {
  const StockManagementPage({super.key, required this.baseCurrencyCode});

  final String baseCurrencyCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(activeVenueScopeProvider);
    if (scope == null) {
      return const Scaffold(body: Center(child: Text('Select a venue first.')));
    }
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Stock & purchasing'),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(icon: Icon(Icons.inventory_2_outlined), text: 'Inventory'),
              Tab(icon: Icon(Icons.local_shipping_outlined), text: 'Suppliers'),
              Tab(icon: Icon(Icons.shopping_cart_outlined), text: 'Orders'),
              Tab(icon: Icon(Icons.analytics_outlined), text: 'Reports'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _InventoryTab(scope: scope, currencyCode: baseCurrencyCode),
            _SuppliersTab(scope: scope, baseCurrencyCode: baseCurrencyCode),
            _OrdersTab(scope: scope),
            _StockReportsTab(currencyCode: baseCurrencyCode),
          ],
        ),
      ),
    );
  }
}

class _StockReportsTab extends ConsumerWidget {
  const _StockReportsTab({required this.currencyCode});

  final String currencyCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final products = ref.watch(menuProductsProvider);
    final orders = ref.watch(purchaseOrdersProvider);
    final movements = ref.watch(stockMovementsProvider);
    if (products.isLoading || orders.isLoading || movements.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (products.hasError || orders.hasError || movements.hasError) {
      final error = products.error ?? orders.error ?? movements.error;
      AppLogger.error(
        'Display stock and purchasing report',
        error!,
        products.stackTrace ??
            orders.stackTrace ??
            movements.stackTrace ??
            StackTrace.current,
      );
      return Center(child: Text('Stock reporting could not be loaded: $error'));
    }
    final tracked = (products.value ?? const <MenuProduct>[])
        .where((item) => item.trackStock)
        .toList(growable: false);
    final stockValue = tracked.fold<double>(
      0,
      (sum, item) =>
          sum + (item.stockOnHand ?? 0) * (item.latestUnitCostMinor ?? 0),
    );
    final low = tracked
        .where((item) => (item.stockOnHand ?? 0) <= item.lowStockThreshold)
        .toList(growable: false);
    final belowMargin = tracked
        .where((item) => item.isBelowTargetMargin)
        .toList(growable: false);
    final purchaseOrders = orders.value ?? const <StockPurchaseOrder>[];
    final openOrders = purchaseOrders
        .where(
          (item) =>
              item.status == PurchaseOrderStatus.draft ||
              item.status == PurchaseOrderStatus.ordered ||
              item.status == PurchaseOrderStatus.partiallyReceived,
        )
        .toList(growable: false);
    final recentAdjustments = movements.value ?? const <StockMovement>[];
    final wastage = recentAdjustments
        .where(
          (item) =>
              item.quantity < 0 &&
              (item.reason.toLowerCase().contains('wast') ||
                  item.reason.toLowerCase().contains('spill')),
        )
        .toList(growable: false);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Stock & purchasing report',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _StockReportMetric(
              label: 'Tracked products',
              value: '${tracked.length}',
            ),
            _StockReportMetric(
              label: 'Estimated stock value',
              value: formatMoney(
                stockValue.round(),
                currencyCode: currencyCode,
              ),
            ),
            _StockReportMetric(
              label: 'Low / out of stock',
              value: '${low.length}',
            ),
            _StockReportMetric(
              label: 'Below target margin',
              value: '${belowMargin.length}',
            ),
            _StockReportMetric(
              label: 'Open purchase orders',
              value: '${openOrders.length}',
            ),
          ],
        ),
        const SizedBox(height: 16),
        _StockReportSection(
          title: 'Low and out-of-stock products',
          rows: low
              .map(
                (item) =>
                    '${item.name}: ${_quantity(item.stockOnHand ?? 0)} ${item.stockUnit}',
              )
              .toList(),
        ),
        _StockReportSection(
          title: 'Products below target margin',
          rows: belowMargin
              .map(
                (item) =>
                    '${item.name}: ${item.estimatedMarginPercent?.toStringAsFixed(1) ?? 'unknown'}% vs ${(item.targetMarginBasisPoints / 100).toStringAsFixed(1)}% target',
              )
              .toList(),
        ),
        _StockReportSection(
          title: 'Recent wastage and spillage',
          rows: wastage
              .map(
                (item) =>
                    '${formatAppDateTime(item.createdAt)} · ${item.productName}: ${_quantity(item.quantity)} ${item.stockUnit} · ${item.reason}',
              )
              .toList(),
        ),
        _StockReportSection(
          title: 'Open purchasing',
          rows: openOrders
              .map(
                (item) =>
                    '${item.supplierName}: ${item.status.label} · ${item.lines.length} lines · ${formatMoney(item.totalMinor, currencyCode: item.lines.isEmpty ? currencyCode : item.lines.first.currencyCode)}',
              )
              .toList(),
        ),
      ],
    );
  }
}

class _StockReportMetric extends StatelessWidget {
  const _StockReportMetric({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 220,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label),
            const SizedBox(height: 6),
            Text(value, style: Theme.of(context).textTheme.titleLarge),
          ],
        ),
      ),
    ),
  );
}

class _StockReportSection extends StatelessWidget {
  const _StockReportSection({required this.title, required this.rows});
  final String title;
  final List<String> rows;

  @override
  Widget build(BuildContext context) => Card(
    child: ExpansionTile(
      title: Text(title),
      subtitle: Text('${rows.length} record${rows.length == 1 ? '' : 's'}'),
      children: rows.isEmpty
          ? const [ListTile(title: Text('No matching records.'))]
          : rows.map((row) => ListTile(dense: true, title: Text(row))).toList(),
    ),
  );
}

enum _StockStatusFilter {
  all,
  inStock,
  low,
  outOfStock,
  unavailable,
  belowMargin,
}

enum _StockSort { name, quantityLow, stockValueHigh, marginLow }
