import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/date_formats.dart';
import '../../core/money.dart';
import '../../core/tenant_scope.dart';
import '../notifications/notification_centre.dart';
import '../pos/domain.dart';
import '../pos/pos_controller.dart';
import 'stock_domain.dart';
import 'stock_repository.dart';

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
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Stock & purchasing'),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(icon: Icon(Icons.inventory_2_outlined), text: 'Inventory'),
              Tab(icon: Icon(Icons.local_shipping_outlined), text: 'Suppliers'),
              Tab(icon: Icon(Icons.shopping_cart_outlined), text: 'Orders'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _InventoryTab(scope: scope),
            _SuppliersTab(scope: scope, baseCurrencyCode: baseCurrencyCode),
            _OrdersTab(scope: scope),
          ],
        ),
      ),
    );
  }
}

class _InventoryTab extends ConsumerWidget {
  const _InventoryTab({required this.scope});
  final VenueScope scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(menuProductsProvider)
      .when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) {
          AppLogger.error('Display inventory', error, stack);
          return Center(child: Text('Inventory could not be loaded: $error'));
        },
        data: (products) {
          final tracked =
              products.where((product) => product.trackStock).toList()
                ..sort((a, b) => a.name.compareTo(b.name));
          if (tracked.isEmpty) {
            return const _EmptyMessage(
              icon: Icons.inventory_2_outlined,
              text:
                  'No stock-tracked products. Enable stock tracking in Menu management first.',
            );
          }
          final movements = ref.watch(stockMovementsProvider);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final product in tracked) ...[
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: (product.stockOnHand ?? 0) <= 0
                        ? Theme.of(context).colorScheme.errorContainer
                        : null,
                    child: const Icon(Icons.inventory_2_outlined),
                  ),
                  title: Text(product.name),
                  subtitle: Text(
                    '${_quantity(product.stockOnHand ?? 0)} ${product.stockUnit} on hand · ${_quantity(product.stockPerSale)} per sale',
                  ),
                  trailing: OutlinedButton.icon(
                    onPressed: () => _adjustStock(context, ref, scope, product),
                    icon: const Icon(Icons.tune_rounded, size: 18),
                    label: const Text('Adjust'),
                  ),
                ),
                const Divider(height: 1),
              ],
              const SizedBox(height: 12),
              Card(
                child: ExpansionTile(
                  leading: const Icon(Icons.history_rounded),
                  title: const Text('Recent stock activity'),
                  subtitle: const Text(
                    'Immutable receipts, sales and adjustments',
                  ),
                  children: movements.when(
                    loading: () => const [
                      Padding(
                        padding: EdgeInsets.all(16),
                        child: CircularProgressIndicator(),
                      ),
                    ],
                    error: (error, stack) {
                      AppLogger.error('Display stock movements', error, stack);
                      return [
                        ListTile(
                          title: Text('Activity could not be loaded: $error'),
                        ),
                      ];
                    },
                    data: (items) => items.isEmpty
                        ? const [
                            ListTile(title: Text('No stock activity yet.')),
                          ]
                        : [
                            for (final movement in items)
                              ListTile(
                                dense: true,
                                leading: Icon(
                                  movement.quantity >= 0
                                      ? Icons.add_circle_outline_rounded
                                      : Icons.remove_circle_outline_rounded,
                                ),
                                title: Text(
                                  '${movement.productName}: ${movement.quantity >= 0 ? '+' : ''}${_quantity(movement.quantity)} ${movement.stockUnit}',
                                ),
                                subtitle: Text(
                                  '${movement.reason} · ${formatAppDateTime(movement.createdAt)}${movement.actorName.isEmpty ? '' : ' · ${movement.actorName}'}',
                                ),
                              ),
                          ],
                  ),
                ),
              ),
            ],
          );
        },
      );
}

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

Future<void> _runCommand(
  BuildContext context,
  WidgetRef ref,
  VenueScope scope,
  String operation, {
  String? documentId,
  Map<String, Object?> values = const {},
  String success = 'Saved',
}) async {
  try {
    await ref
        .read(stockRepositoryProvider)
        .command(
          scope: scope,
          operation: operation,
          documentId: documentId,
          values: values,
        );
    if (!context.mounted) return;
    showAppNotification(
      context,
      ref: ref,
      title: success,
      message: '$success successfully.',
      level: AppNotificationLevel.success,
    );
  } on Object catch (error, stack) {
    AppLogger.error('Stock management $operation', error, stack);
    if (!context.mounted) return;
    showAppNotification(
      context,
      ref: ref,
      title: 'Stock action failed',
      message: '$error',
      level: AppNotificationLevel.error,
    );
  }
}

Future<void> _adjustStock(
  BuildContext context,
  WidgetRef ref,
  VenueScope scope,
  MenuProduct product,
) async {
  final quantity = TextEditingController();
  final reason = TextEditingController();
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Adjust ${product.name}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: quantity,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            decoration: InputDecoration(
              labelText: 'Quantity change',
              helperText:
                  'Use a negative number to remove ${product.stockUnit}.',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: reason,
            decoration: const InputDecoration(labelText: 'Required reason'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Apply'),
        ),
      ],
    ),
  );
  final amount = double.tryParse(quantity.text.trim());
  if (confirmed == true &&
      amount != null &&
      amount != 0 &&
      reason.text.trim().isNotEmpty &&
      context.mounted) {
    await _runCommand(
      context,
      ref,
      scope,
      'adjustStock',
      values: {
        'productId': product.id,
        'quantity': amount,
        'reason': reason.text.trim(),
      },
      success: 'Stock adjusted',
    );
  }
  quantity.dispose();
  reason.dispose();
}

Future<void> _editSupplier(
  BuildContext context,
  WidgetRef ref,
  VenueScope scope, [
  StockSupplier? existing,
]) async {
  final name = TextEditingController(text: existing?.name);
  final contact = TextEditingController(text: existing?.contactName);
  final email = TextEditingController(text: existing?.email);
  final phone = TextEditingController(text: existing?.phone);
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(existing == null ? 'Add supplier' : 'Edit supplier'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Supplier name'),
            ),
            TextField(
              controller: contact,
              decoration: const InputDecoration(labelText: 'Contact name'),
            ),
            TextField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            TextField(
              controller: phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Phone'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (saved == true && name.text.trim().isNotEmpty && context.mounted) {
    await _runCommand(
      context,
      ref,
      scope,
      'saveSupplier',
      documentId: existing?.id,
      values: {
        'name': name.text.trim(),
        'contactName': contact.text.trim(),
        'email': email.text.trim(),
        'phone': phone.text.trim(),
        'active': true,
      },
      success: 'Supplier saved',
    );
  }
  name.dispose();
  contact.dispose();
  email.dispose();
  phone.dispose();
}

Future<void> _bulkLinkProducts(
  BuildContext context,
  WidgetRef ref,
  VenueScope scope,
  StockSupplier supplier,
  List<MenuProduct> products,
  String currencyCode,
) async {
  final selected = <String>{};
  final result = await showDialog<Set<String>>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('Add products to ${supplier.name}'),
        content: SizedBox(
          width: 480,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final product in products)
                CheckboxListTile(
                  value: selected.contains(product.id),
                  title: Text(product.name),
                  subtitle: Text(product.stockUnit),
                  onChanged: (value) => setState(
                    () => value == true
                        ? selected.add(product.id)
                        : selected.remove(product.id),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: selected.isEmpty
                ? null
                : () => Navigator.pop(context, {...selected}),
            child: const Text('Continue'),
          ),
        ],
      ),
    ),
  );
  if (result == null || !context.mounted) return;
  for (final product in products.where((item) => result.contains(item.id))) {
    if (!context.mounted) return;
    await _editSupplierProduct(
      context,
      ref,
      scope,
      supplier,
      product,
      currencyCode,
    );
  }
}

Future<void> _editSupplierProduct(
  BuildContext context,
  WidgetRef ref,
  VenueScope scope,
  StockSupplier supplier,
  MenuProduct product,
  String baseCurrencyCode, {
  SupplierProduct? existing,
}) async {
  final pack = TextEditingController(text: existing?.packName ?? 'Case');
  final units = TextEditingController(
    text: '${existing?.stockUnitsPerPack ?? 1}',
  );
  final cost = TextEditingController(
    text: existing == null
        ? ''
        : _costText(existing.packCostMinor, existing.currencyCode),
  );
  final currency = TextEditingController(
    text: existing?.currencyCode ?? baseCurrencyCode,
  );
  var preferred = existing?.preferred ?? false;
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('${supplier.name}: ${product.name}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: pack,
                decoration: const InputDecoration(
                  labelText: 'Pack name (case, bottle, bag)',
                ),
              ),
              TextField(
                controller: units,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: '${product.stockUnit} per pack',
                ),
              ),
              TextField(
                controller: cost,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Pack cost',
                  helperText: 'Example: 12.50.',
                ),
              ),
              TextField(
                controller: currency,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Currency code'),
              ),
              CheckboxListTile(
                value: preferred,
                title: const Text('Preferred supplier for this product'),
                onChanged: (value) =>
                    setState(() => preferred = value ?? false),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  final unitsValue = double.tryParse(units.text.trim());
  final costValue = _parseCostMinor(cost.text, currency.text);
  if (saved == true &&
      unitsValue != null &&
      unitsValue > 0 &&
      costValue != null &&
      costValue >= 0 &&
      context.mounted) {
    await _runCommand(
      context,
      ref,
      scope,
      'saveSupplierProduct',
      documentId: existing?.id,
      values: {
        'supplierId': supplier.id,
        'productId': product.id,
        'packName': pack.text.trim(),
        'stockUnitsPerPack': unitsValue,
        'packCostMinor': costValue,
        'currencyCode': currency.text.trim().toUpperCase(),
        'preferred': preferred,
        'active': true,
      },
      success: 'Supplier product saved',
    );
  }
  pack.dispose();
  units.dispose();
  cost.dispose();
  currency.dispose();
}

Future<void> _createRecommendedOrder(
  BuildContext context,
  WidgetRef ref,
  VenueScope scope,
  List<StockSupplier> suppliers,
) async {
  var supplierId = suppliers.first.id;
  final days = TextEditingController(text: '7');
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Create recommended order'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: supplierId,
              decoration: const InputDecoration(labelText: 'Supplier'),
              items: [
                for (final supplier in suppliers.where((item) => item.active))
                  DropdownMenuItem(
                    value: supplier.id,
                    child: Text(supplier.name),
                  ),
              ],
              onChanged: (value) =>
                  setState(() => supplierId = value ?? supplierId),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: days,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Days of stock to order',
                helperText:
                    'Uses the last 30 days and the same period last year when available.',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Calculate'),
          ),
        ],
      ),
    ),
  );
  final coverage = int.tryParse(days.text.trim());
  if (confirmed == true &&
      coverage != null &&
      coverage > 0 &&
      context.mounted) {
    await _runCommand(
      context,
      ref,
      scope,
      'createRecommendedOrder',
      values: {'supplierId': supplierId, 'coverageDays': coverage},
      success: 'Recommended draft created',
    );
  }
  days.dispose();
}

Future<void> _orderAction(
  BuildContext context,
  WidgetRef ref,
  VenueScope scope,
  StockPurchaseOrder order,
  String operation,
) => _runCommand(
  context,
  ref,
  scope,
  operation,
  documentId: order.id,
  success: 'Purchase order updated',
);

Future<void> _editDraftOrder(
  BuildContext context,
  WidgetRef ref,
  VenueScope scope,
  StockPurchaseOrder order,
) async {
  final controllers = {
    for (final line in order.lines)
      line.id: TextEditingController(text: _quantity(line.orderedPacks)),
  };
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Review recommended quantities'),
      content: SizedBox(
        width: 520,
        child: ListView(
          shrinkWrap: true,
          children: [
            const Text(
              'Recommendations are guidance. Confirm or change every pack quantity before marking the order as sent.',
            ),
            const SizedBox(height: 12),
            for (final line in order.lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: TextField(
                  controller: controllers[line.id],
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: '${line.productName} (${line.packName})',
                    helperText:
                        'Recommended ${_quantity(line.recommendedPacks)}',
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Save quantities'),
        ),
      ],
    ),
  );
  if (confirmed == true && context.mounted) {
    final lines = <Map<String, Object?>>[];
    var valid = true;
    for (final entry in controllers.entries) {
      final amount = double.tryParse(entry.value.text.trim());
      if (amount == null || amount < 0) {
        valid = false;
        showAppNotification(
          context,
          ref: ref,
          title: 'Invalid pack quantity',
          message: 'Use zero or a positive number for every order line.',
          level: AppNotificationLevel.warning,
        );
        break;
      }
      lines.add({'lineId': entry.key, 'orderedPacks': amount});
    }
    if (valid) {
      await _runCommand(
        context,
        ref,
        scope,
        'updateDraftOrder',
        documentId: order.id,
        values: {'lines': lines},
        success: 'Draft quantities saved',
      );
    }
  }
  for (final controller in controllers.values) {
    controller.dispose();
  }
}

Future<void> _receiveOrder(
  BuildContext context,
  WidgetRef ref,
  VenueScope scope,
  StockPurchaseOrder order,
) async {
  final controllers = {
    for (final line in order.lines.where((line) => line.remainingPacks > 0))
      line.id: TextEditingController(text: _quantity(line.remainingPacks)),
  };
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Receive delivered stock'),
      content: SizedBox(
        width: 520,
        child: ListView(
          shrinkWrap: true,
          children: [
            const Text(
              'Confirm actual packs received. Stock and cost history update only after this step.',
            ),
            const SizedBox(height: 12),
            for (final line in order.lines.where(
              (line) => line.remainingPacks > 0,
            ))
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: TextField(
                  controller: controllers[line.id],
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: '${line.productName} (${line.packName})',
                    helperText: '${_quantity(line.remainingPacks)} outstanding',
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Receive into stock'),
        ),
      ],
    ),
  );
  if (confirmed == true && context.mounted) {
    final lines = <Map<String, Object?>>[];
    for (final entry in controllers.entries) {
      final amount = double.tryParse(entry.value.text.trim());
      if (amount != null && amount > 0) {
        lines.add({'lineId': entry.key, 'receivedPacks': amount});
      }
    }
    if (lines.isNotEmpty) {
      await _runCommand(
        context,
        ref,
        scope,
        'receiveOrder',
        documentId: order.id,
        values: {'lines': lines},
        success: 'Stock received',
      );
    }
  }
  for (final controller in controllers.values) {
    controller.dispose();
  }
}
