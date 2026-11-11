part of '../stock_management_page.dart';

class _SuppliersTab extends ConsumerWidget {
  const _SuppliersTab({required this.scope, required this.baseCurrencyCode});
  final VenueScope scope;
  final String baseCurrencyCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final suppliers = ref.watch(suppliersProvider);
    final mappings = ref.watch(supplierProductsProvider);
    final products = ref.watch(menuProductsProvider);
    if (mappings.hasError) {
      AppLogger.error(
        'Display supplier product links',
        mappings.error!,
        mappings.stackTrace ?? StackTrace.current,
      );
    }
    if (products.hasError) {
      AppLogger.error(
        'Display stock products for suppliers',
        products.error!,
        products.stackTrace ?? StackTrace.current,
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: () => _editSupplier(context, ref, scope),
              icon: const Icon(Icons.add_business_rounded),
              label: const Text('Add supplier'),
            ),
          ),
        ),
        Expanded(
          child: suppliers.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stack) {
              AppLogger.error('Display suppliers', error, stack);
              return Center(
                child: Text('Suppliers could not be loaded: $error'),
              );
            },
            data: (items) {
              if (items.isEmpty) {
                return const _EmptyMessage(
                  icon: Icons.local_shipping_outlined,
                  text:
                      'Add a supplier, then attach one or more stock products.',
                );
              }
              final links = mappings.value ?? const <SupplierProduct>[];
              final stockProducts = (products.value ?? const <MenuProduct>[])
                  .where((product) => product.trackStock)
                  .toList(growable: false);
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final supplier = items[index];
                  final supplied = links
                      .where((link) => link.supplierId == supplier.id)
                      .toList(growable: false);
                  return Card(
                    child: ExpansionTile(
                      leading: const Icon(Icons.local_shipping_outlined),
                      title: Text(supplier.name),
                      subtitle: Text('${supplied.length} linked products'),
                      trailing: Wrap(
                        spacing: 2,
                        children: [
                          IconButton(
                            tooltip: 'Add several products',
                            onPressed: stockProducts.isEmpty
                                ? null
                                : () => _bulkLinkProducts(
                                    context,
                                    ref,
                                    scope,
                                    supplier,
                                    stockProducts,
                                    baseCurrencyCode,
                                  ),
                            icon: const Icon(Icons.playlist_add_rounded),
                          ),
                          IconButton(
                            tooltip: 'Edit supplier',
                            onPressed: () =>
                                _editSupplier(context, ref, scope, supplier),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                        ],
                      ),
                      children: [
                        if (supplied.isEmpty)
                          const ListTile(
                            title: Text('No products linked yet.'),
                          ),
                        for (final link in supplied)
                          ListTile(
                            dense: true,
                            title: Text(link.productName),
                            subtitle: Text(
                              '${link.packName} = ${_quantity(link.stockUnitsPerPack)} stock units · ${formatMoney(link.packCostMinor, currencyCode: link.currencyCode)}${link.preferred ? ' · preferred' : ''}',
                            ),
                            trailing: IconButton(
                              tooltip: 'Edit pack and cost',
                              onPressed: () => _editSupplierProduct(
                                context,
                                ref,
                                scope,
                                supplier,
                                stockProducts.firstWhere(
                                  (product) => product.id == link.productId,
                                ),
                                baseCurrencyCode,
                                existing: link,
                              ),
                              icon: const Icon(Icons.price_change_outlined),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _OrdersTab extends ConsumerWidget {
  const _OrdersTab({required this.scope});
  final VenueScope scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final suppliers =
        ref.watch(suppliersProvider).value ?? const <StockSupplier>[];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: suppliers.isEmpty
                  ? null
                  : () =>
                        _createRecommendedOrder(context, ref, scope, suppliers),
              icon: const Icon(Icons.auto_graph_rounded),
              label: const Text('Create recommended order'),
            ),
          ),
        ),
        Expanded(
          child: ref
              .watch(purchaseOrdersProvider)
              .when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, stack) {
                  AppLogger.error('Display purchase orders', error, stack);
                  return Center(
                    child: Text('Purchase orders could not be loaded: $error'),
                  );
                },
                data: (orders) => orders.isEmpty
                    ? const _EmptyMessage(
                        icon: Icons.shopping_cart_outlined,
                        text:
                            'No purchase orders yet. Choose a supplier and the number of days to cover.',
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        itemCount: orders.length,
                        itemBuilder: (context, index) {
                          final order = orders[index];
                          final currency = order.lines.isEmpty
                              ? 'GBP'
                              : order.lines.first.currencyCode;
                          return Card(
                            child: ExpansionTile(
                              title: Text(
                                '${order.supplierName} · ${order.status.label}',
                              ),
                              subtitle: Text(
                                '${order.coverageDays} days · ${order.lines.length} products · ${formatMoney(order.totalMinor, currencyCode: currency)}',
                              ),
                              children: [
                                for (final line in order.lines)
                                  ListTile(
                                    dense: true,
                                    title: Text(line.productName),
                                    subtitle: Text(
                                      '${_quantity(line.orderedPacks)} ${line.packName} ordered · ${_quantity(line.receivedPacks)} received\nSuggested ${_quantity(line.recommendedPacks)} · recent use ${_quantity(line.recentDailyUsage)}/day${line.priorYearDailyUsage == null ? '' : ' · last year ${_quantity(line.priorYearDailyUsage!)}/day'}',
                                    ),
                                  ),
                                Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      if (order.status ==
                                          PurchaseOrderStatus.draft)
                                        OutlinedButton.icon(
                                          onPressed: () => _editDraftOrder(
                                            context,
                                            ref,
                                            scope,
                                            order,
                                          ),
                                          icon: const Icon(
                                            Icons.edit_note_rounded,
                                          ),
                                          label: const Text(
                                            'Review quantities',
                                          ),
                                        ),
                                      if (order.status ==
                                          PurchaseOrderStatus.draft)
                                        FilledButton.icon(
                                          onPressed: () => _orderAction(
                                            context,
                                            ref,
                                            scope,
                                            order,
                                            'markOrderOrdered',
                                          ),
                                          icon: const Icon(Icons.send_outlined),
                                          label: const Text('Mark ordered'),
                                        ),
                                      if (order.status ==
                                              PurchaseOrderStatus.ordered ||
                                          order.status ==
                                              PurchaseOrderStatus
                                                  .partiallyReceived)
                                        FilledButton.icon(
                                          onPressed: () => _receiveOrder(
                                            context,
                                            ref,
                                            scope,
                                            order,
                                          ),
                                          icon: const Icon(
                                            Icons.inventory_rounded,
                                          ),
                                          label: const Text('Receive stock'),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
        ),
      ],
    );
  }
}

class _EmptyMessage extends StatelessWidget {
  const _EmptyMessage({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 42),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

String _quantity(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value
          .toStringAsFixed(3)
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), '');

String _costText(int minor, String currencyCode) {
  final digits = currencyDecimalDigits(currencyCode);
  if (digits == 0) return '$minor';
  final scale = List.filled(digits, 10).fold<int>(1, (a, b) => a * b);
  return '${minor ~/ scale}.${(minor % scale).toString().padLeft(digits, '0')}';
}

int? _parseCostMinor(String value, String currencyCode) {
  final amount = double.tryParse(value.trim());
  if (amount == null || !amount.isFinite || amount < 0) return null;
  final digits = currencyDecimalDigits(currencyCode.trim().toUpperCase());
  final scale = List.filled(digits, 10).fold<int>(1, (a, b) => a * b);
  return (amount * scale).round();
}
