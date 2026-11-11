part of '../stock_management_page.dart';

class _InventoryTab extends ConsumerStatefulWidget {
  const _InventoryTab({required this.scope, required this.currencyCode});
  final VenueScope scope;
  final String currencyCode;

  @override
  ConsumerState<_InventoryTab> createState() => _InventoryTabState();
}

class _InventoryTabState extends ConsumerState<_InventoryTab> {
  final _search = TextEditingController();
  _StockStatusFilter _status = _StockStatusFilter.all;
  String _unit = 'all';
  String _location = 'all';
  _StockSort _sort = _StockSort.name;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ref
      .watch(menuProductsProvider)
      .when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) {
          AppLogger.error('Display inventory', error, stack);
          return Center(child: Text('Inventory could not be loaded: $error'));
        },
        data: (products) {
          final allTracked =
              products.where((product) => product.trackStock).toList()
                ..sort((a, b) => a.name.compareTo(b.name));
          final units =
              allTracked.map((item) => item.stockUnit).toSet().toList()..sort();
          final locations =
              allTracked
                  .map((item) => item.storageLocation.trim())
                  .where((item) => item.isNotEmpty)
                  .toSet()
                  .toList()
                ..sort();
          final query = _search.text.trim().toLowerCase();
          final tracked =
              allTracked
                  .where((product) {
                    final matchesSearch =
                        query.isEmpty ||
                        product.name.toLowerCase().contains(query) ||
                        product.storageLocation.toLowerCase().contains(query) ||
                        product.stockUnit.toLowerCase().contains(query);
                    final matchesUnit =
                        _unit == 'all' || product.stockUnit == _unit;
                    final matchesLocation =
                        _location == 'all' ||
                        product.storageLocation == _location;
                    final quantity = product.stockOnHand ?? 0;
                    final matchesStatus = switch (_status) {
                      _StockStatusFilter.all => true,
                      _StockStatusFilter.inStock =>
                        quantity > product.lowStockThreshold,
                      _StockStatusFilter.low =>
                        quantity > 0 && quantity <= product.lowStockThreshold,
                      _StockStatusFilter.outOfStock => quantity <= 0,
                      _StockStatusFilter.unavailable => !product.isAvailable,
                      _StockStatusFilter.belowMargin =>
                        product.isBelowTargetMargin,
                    };
                    return matchesSearch &&
                        matchesUnit &&
                        matchesLocation &&
                        matchesStatus;
                  })
                  .toList(growable: true)
                ..sort(
                  (a, b) => switch (_sort) {
                    _StockSort.name => a.name.compareTo(b.name),
                    _StockSort.quantityLow => (a.stockOnHand ?? 0).compareTo(
                      b.stockOnHand ?? 0,
                    ),
                    _StockSort.stockValueHigh =>
                      ((b.stockOnHand ?? 0) * (b.latestUnitCostMinor ?? 0))
                          .compareTo(
                            (a.stockOnHand ?? 0) * (a.latestUnitCostMinor ?? 0),
                          ),
                    _StockSort.marginLow =>
                      (a.estimatedMarginPercent ?? double.infinity).compareTo(
                        b.estimatedMarginPercent ?? double.infinity,
                      ),
                  },
                );
          if (allTracked.isEmpty) {
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
              TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search_rounded),
                  labelText: 'Search inventory',
                  hintText: 'Product, location or unit',
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          onPressed: () {
                            _search.clear();
                            setState(() {});
                          },
                          icon: const Icon(Icons.clear_rounded),
                        ),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  DropdownButton<_StockStatusFilter>(
                    value: _status,
                    onChanged: (value) =>
                        setState(() => _status = value ?? _status),
                    items: const [
                      DropdownMenuItem(
                        value: _StockStatusFilter.all,
                        child: Text('All stock'),
                      ),
                      DropdownMenuItem(
                        value: _StockStatusFilter.inStock,
                        child: Text('In stock'),
                      ),
                      DropdownMenuItem(
                        value: _StockStatusFilter.low,
                        child: Text('Low stock'),
                      ),
                      DropdownMenuItem(
                        value: _StockStatusFilter.outOfStock,
                        child: Text('Out of stock'),
                      ),
                      DropdownMenuItem(
                        value: _StockStatusFilter.unavailable,
                        child: Text('Unavailable'),
                      ),
                      DropdownMenuItem(
                        value: _StockStatusFilter.belowMargin,
                        child: Text('Below target margin'),
                      ),
                    ],
                  ),
                  DropdownButton<String>(
                    value: units.contains(_unit) ? _unit : 'all',
                    onChanged: (value) =>
                        setState(() => _unit = value ?? 'all'),
                    items: [
                      const DropdownMenuItem(
                        value: 'all',
                        child: Text('All units'),
                      ),
                      for (final unit in units)
                        DropdownMenuItem(value: unit, child: Text(unit)),
                    ],
                  ),
                  DropdownButton<String>(
                    value: locations.contains(_location) ? _location : 'all',
                    onChanged: (value) =>
                        setState(() => _location = value ?? 'all'),
                    items: [
                      const DropdownMenuItem(
                        value: 'all',
                        child: Text('All locations'),
                      ),
                      for (final location in locations)
                        DropdownMenuItem(
                          value: location,
                          child: Text(location),
                        ),
                    ],
                  ),
                  DropdownButton<_StockSort>(
                    value: _sort,
                    onChanged: (value) =>
                        setState(() => _sort = value ?? _sort),
                    items: const [
                      DropdownMenuItem(
                        value: _StockSort.name,
                        child: Text('Name A–Z'),
                      ),
                      DropdownMenuItem(
                        value: _StockSort.quantityLow,
                        child: Text('Lowest quantity'),
                      ),
                      DropdownMenuItem(
                        value: _StockSort.stockValueHigh,
                        child: Text('Highest stock value'),
                      ),
                      DropdownMenuItem(
                        value: _StockSort.marginLow,
                        child: Text('Lowest margin'),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (tracked.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: Text('No inventory items match these filters.'),
                  ),
                ),
              for (final product in tracked) ...[
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor:
                        (product.stockOnHand ?? 0) <= 0 ||
                            product.isBelowTargetMargin
                        ? Theme.of(context).colorScheme.errorContainer
                        : (product.stockOnHand ?? 0) <=
                              product.lowStockThreshold
                        ? Theme.of(context).colorScheme.tertiaryContainer
                        : null,
                    child: const Icon(Icons.inventory_2_outlined),
                  ),
                  title: Text(product.name),
                  subtitle: Text(
                    [
                      '${_quantity(product.stockOnHand ?? 0)} ${product.stockUnit} on hand',
                      if (product.lowStockThreshold > 0)
                        'low at ${_quantity(product.lowStockThreshold)}',
                      if (product.storageLocation.isNotEmpty)
                        product.storageLocation,
                      if (product.estimatedCostMinor != null)
                        'cost ${formatMoney(product.estimatedCostMinor!.round(), currencyCode: widget.currencyCode)}',
                      if (product.estimatedMarginPercent != null)
                        '${product.estimatedMarginPercent!.toStringAsFixed(1)}% margin${product.isBelowTargetMargin ? ' · BELOW TARGET' : ''}',
                    ].join(' · '),
                  ),
                  trailing: OutlinedButton.icon(
                    onPressed: () =>
                        _adjustStock(context, ref, widget.scope, product),
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
