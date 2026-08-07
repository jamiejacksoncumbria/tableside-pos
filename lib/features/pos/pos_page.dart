import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/tenant_scope.dart';
import 'domain.dart';
import 'pos_controller.dart';

class PosPage extends ConsumerWidget {
  const PosPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 1100) {
          return const Padding(
            padding: EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 238, child: _TablesPanel()),
                SizedBox(width: 16),
                Expanded(child: _MenuPanel()),
                SizedBox(width: 16),
                SizedBox(width: 360, child: _OrderPanel()),
              ],
            ),
          );
        }

        // Landscape tablets and compact desktop windows need a different
        // interaction model: stacking all three panels would make the order
        // panel inaccessible. Let the operator switch panels instead.
        if (constraints.maxHeight < 620) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: DefaultTabController(
              length: 3,
              child: Column(
                children: [
                  TabBar(
                    tabs: [
                      Tab(
                        icon: Icon(Icons.table_restaurant_rounded),
                        text: 'Tables',
                      ),
                      Tab(
                        icon: Icon(Icons.restaurant_menu_rounded),
                        text: 'Menu',
                      ),
                      Tab(
                        icon: Icon(Icons.receipt_long_rounded),
                        text: 'Order',
                      ),
                    ],
                  ),
                  SizedBox(height: 12),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _TablesPanel(compact: true),
                        _MenuPanel(),
                        _OrderPanel(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return const Padding(
          padding: EdgeInsets.all(12),
          child: Column(
            children: [
              SizedBox(height: 170, child: _TablesPanel(compact: true)),
              SizedBox(height: 12),
              Expanded(child: _MenuPanel()),
              SizedBox(height: 12),
              SizedBox(height: 280, child: _OrderPanel()),
            ],
          ),
        );
      },
    );
  }
}

class _TablesPanel extends ConsumerWidget {
  const _TablesPanel({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedTableId = ref.watch(selectedTableProvider);
    final scope = ref.watch(activeVenueScopeProvider);
    final tables = ref
        .watch(diningTablesProvider)
        .when(
          data: (items) => items,
          loading: () => scope == null ? demoTables : const [],
          error: (_, _) => scope == null ? demoTables : const [],
        );
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Tables', style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                Icon(Icons.tune_rounded, color: scheme.primary),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Market Street',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final table in tables)
                      _TableButton(
                        table: table,
                        selected: table.id == selectedTableId,
                        compact: compact,
                        onTap: () => ref
                            .read(selectedTableProvider.notifier)
                            .select(table.id),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TableButton extends StatelessWidget {
  const _TableButton({
    required this.table,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  final DiningTable table;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = selected
        ? scheme.primary
        : table.hasOpenOrder
        ? scheme.secondaryContainer
        : scheme.surfaceContainerHighest;
    final foreground = selected ? scheme.onPrimary : scheme.onSurface;
    final width = compact ? 62.0 : 96.0;
    return Semantics(
      button: true,
      selected: selected,
      label: 'Table ${table.label}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          width: width,
          height: compact ? 62 : 82,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                table.label,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: foreground,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '${table.seats} seats',
                style: TextStyle(
                  fontSize: 11,
                  color: foreground.withValues(alpha: .8),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuPanel extends ConsumerWidget {
  const _MenuPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedSection = ref.watch(activeSectionProvider);
    final scope = ref.watch(activeVenueScopeProvider);
    final sections = ref
        .watch(menuSectionsProvider)
        .when(
          data: (items) => items,
          loading: () => scope == null ? demoSections : const [],
          error: (_, _) => scope == null ? demoSections : const [],
        );
    final catalog = ref
        .watch(menuProductsProvider)
        .when(
          data: (items) => items,
          loading: () => scope == null ? demoProducts : const [],
          error: (_, _) => scope == null ? demoProducts : const [],
        );
    final effectiveSection = sections.any((item) => item.id == selectedSection)
        ? selectedSection
        : sections.isEmpty
        ? null
        : sections.first.id;
    final products = catalog
        .where((product) => product.sectionIds.contains(effectiveSection))
        .toList(growable: false);
    final section = effectiveSection == null
        ? null
        : sections.firstWhere((item) => item.id == effectiveSection);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'New order',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: 'Search menu',
                  onPressed: () {},
                  icon: const Icon(Icons.search_rounded),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final item in sections)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text('${item.icon} ${item.name}'),
                        selected: item.id == effectiveSection,
                        onSelected: (_) => ref
                            .read(activeSectionProvider.notifier)
                            .select(item.id),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text(
              section?.name ?? 'Menu',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 700
                      ? 3
                      : constraints.maxWidth >= 420
                      ? 2
                      : 1;
                  return GridView.builder(
                    itemCount: products.length,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: columns == 1 ? 4.2 : 1.32,
                    ),
                    itemBuilder: (context, index) => _ProductTile(
                      product: products[index],
                      onTap: () => ref
                          .read(activeOrderProvider.notifier)
                          .addProduct(products[index]),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({required this.product, required this.onTap});

  final MenuProduct product;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final unavailable =
        !product.isAvailable ||
        (product.trackStock && (product.stockOnHand ?? 0) <= 0);
    return Semantics(
      button: true,
      label: 'Add ${product.name}',
      child: InkWell(
        onTap: unavailable ? null : onTap,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          decoration: BoxDecoration(
            color: unavailable
                ? scheme.surfaceContainerHighest
                : scheme.primaryContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  product.productionArea == ProductionArea.bar
                      ? Icons.local_bar_rounded
                      : Icons.restaurant_rounded,
                  color: unavailable ? scheme.outline : scheme.primary,
                ),
                const Spacer(),
                Text(
                  product.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(formatMoney(product.priceMinor)),
                    const Spacer(),
                    if (product.trackStock)
                      Text(
                        '${product.stockOnHand ?? 0} left',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OrderPanel extends ConsumerWidget {
  const _OrderPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final order = ref.watch(activeOrderProvider);
    final tableId = ref.watch(selectedTableProvider);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Table $tableId',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Spacer(),
                _StatusChip(status: order.status),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Order #${order.id.split('-').last}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const Divider(height: 24),
            Expanded(
              child: order.lines.isEmpty
                  ? const Center(child: Text('Choose menu items to begin.'))
                  : ListView.separated(
                      itemCount: order.lines.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final line = order.lines[index];
                        return Row(
                          children: [
                            IconButton.filledTonal(
                              tooltip: 'Remove one ${line.productName}',
                              onPressed: () => ref
                                  .read(activeOrderProvider.notifier)
                                  .reduceLine(line.id),
                              icon: const Icon(Icons.remove_rounded, size: 18),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    line.productName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    '${line.quantity} × ${formatMoney(line.unitPriceMinor)}',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            Text(formatMoney(line.totalMinor)),
                          ],
                        );
                      },
                    ),
            ),
            const Divider(height: 24),
            Row(
              children: [
                Text('Total', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Text(
                  formatMoney(order.totalMinor),
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _showSplitBillSheet(context),
                    icon: const Icon(Icons.call_split_rounded),
                    label: const Text('Split bill'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: order.lines.isEmpty
                        ? null
                        : () {
                            ref.read(activeOrderProvider.notifier).markSent();
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Ticket intent saved. Assigned native devices will print it.',
                                ),
                              ),
                            );
                          },
                    icon: const Icon(Icons.print_rounded),
                    label: const Text('Send'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final OrderStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      OrderStatus.open => ('Open', Colors.orange),
      OrderStatus.pendingApproval => ('Awaiting approval', Colors.purple),
      OrderStatus.sent => ('Sent', Colors.green),
      OrderStatus.closed => ('Closed', Colors.blueGrey),
      OrderStatus.rolledOver => ('Rolled over', Colors.blue),
    };
    return Chip(
      avatar: CircleAvatar(backgroundColor: color, radius: 4),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}

void _showSplitBillSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Split this table',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'The final workflow will support split by item, cover, or custom amount.',
            ),
            const SizedBox(height: 18),
            ListTile(
              leading: const Icon(Icons.people_alt_outlined),
              title: const Text('Split evenly by covers'),
              onTap: () => Navigator.pop(context),
            ),
            ListTile(
              leading: const Icon(Icons.checklist_rounded),
              title: const Text('Assign individual items'),
              onTap: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    ),
  );
}
