import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/money.dart';
import '../../core/tenant_scope.dart';
import 'domain.dart';
import 'pos_controller.dart';

class PosPage extends ConsumerWidget {
  const PosPage({super.key, required this.currencyCode});

  final String currencyCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Three simultaneously visible panels need both a genuinely wide and
        // tall workspace. On a phone or a compact Windows window, stacking
        // tables, menu and order made the menu grid receive almost no height
        // at all, despite its Firestore data having loaded successfully.
        if (constraints.maxWidth >= 1100 && constraints.maxHeight >= 700) {
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(width: 238, child: _TablesPanel()),
                const SizedBox(width: 16),
                Expanded(child: _MenuPanel(currencyCode: currencyCode)),
                const SizedBox(width: 16),
                SizedBox(
                  width: 360,
                  child: _OrderPanel(currencyCode: currencyCode),
                ),
              ],
            ),
          );
        }

        // Phones, tablets, and compact desktop windows use one full-height
        // workspace at a time. Menu is the default tab because it is the
        // primary waiter action; tables and the live order stay one tap away.
        return Padding(
          padding: const EdgeInsets.all(12),
          child: DefaultTabController(
            length: 3,
            initialIndex: 1,
            child: Column(
              children: [
                const TabBar(
                  tabs: [
                    Tab(
                      icon: Icon(Icons.table_restaurant_rounded),
                      text: 'Tables',
                    ),
                    Tab(
                      icon: Icon(Icons.restaurant_menu_rounded),
                      text: 'Menu',
                    ),
                    Tab(icon: Icon(Icons.receipt_long_rounded), text: 'Order'),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: TabBarView(
                    children: [
                      const _TablesPanel(compact: true),
                      _MenuPanel(currencyCode: currencyCode),
                      _OrderPanel(currencyCode: currencyCode),
                    ],
                  ),
                ),
              ],
            ),
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
    final activeOrder = ref.watch(activeOrderProvider);
    final scope = ref.watch(activeVenueScopeProvider);
    final tables = ref
        .watch(diningTablesProvider)
        .when(
          data: (items) => items,
          loading: () => scope == null ? demoTables : const [],
          error: (_, _) => scope == null ? demoTables : const [],
        );
    final namedTabs = ref
        .watch(openNamedTabsProvider)
        .when(
          data: (items) => items,
          loading: () => const <OpenNamedTab>[],
          error: (error, stackTrace) {
            AppLogger.error('Load open named tabs', error, stackTrace);
            return const <OpenNamedTab>[];
          },
        );
    final namedTabGroups = _groupOpenNamedTabs(namedTabs);
    // A new live venue will not have the demo's `table-2` ID. As soon as its
    // table stream arrives, open the first available table rather than leaving
    // a hidden invalid selection that would fail only when Send is pressed.
    if (activeOrder.tabName == null &&
        tables.isNotEmpty &&
        !tables.any((table) => table.id == selectedTableId)) {
      final firstTable = tables.first;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          await ref.read(activeOrderProvider.notifier).openTable(firstTable.id);
          ref.read(selectedTableProvider.notifier).select(firstTable.id);
        } on Object catch (error, stackTrace) {
          AppLogger.error('Open initial venue table', error, stackTrace);
        }
      });
    }
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 0,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'Tables & tabs',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                TextButton.icon(
                  onPressed: () => _showNamedTabDialog(context, ref),
                  icon: const Icon(Icons.person_add_alt_1_rounded),
                  label: const Text('Named tab'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              activeOrder.tabName == null
                  ? 'Select a table or open a named tab'
                  : 'Current tab: ${activeOrder.tabName}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: Scrollbar(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final table in tables)
                            _TableButton(
                              table: table,
                              selected:
                                  activeOrder.tabName == null &&
                                  table.id == selectedTableId,
                              compact: compact,
                              onTap: () async {
                                try {
                                  await ref
                                      .read(activeOrderProvider.notifier)
                                      .openTable(table.id);
                                  ref
                                      .read(selectedTableProvider.notifier)
                                      .select(table.id);
                                } on Object catch (error, stackTrace) {
                                  AppLogger.error(
                                    'Switch selected table',
                                    error,
                                    stackTrace,
                                  );
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('$error')),
                                  );
                                }
                              },
                            ),
                        ],
                      ),
                      if (namedTabGroups.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(
                          'Open named tabs',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        const SizedBox(height: 6),
                        for (final group in namedTabGroups) ...[
                          Padding(
                            padding: const EdgeInsets.only(top: 6, bottom: 6),
                            child: Text(
                              _namedTabDateLabel(context, group.openedDate),
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                          ),
                          for (final tab in group.tabs)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: _NamedTabButton(
                                tab: tab,
                                selected: tab.orderId == activeOrder.id,
                                onTap: () async {
                                  try {
                                    await ref
                                        .read(activeOrderProvider.notifier)
                                        .openNamedTab(tab.name);
                                    ref
                                        .read(selectedTableProvider.notifier)
                                        .select('');
                                  } on Object catch (error, stackTrace) {
                                    AppLogger.error(
                                      'Open listed named tab',
                                      error,
                                      stackTrace,
                                    );
                                    if (!context.mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('$error')),
                                    );
                                  }
                                },
                              ),
                            ),
                        ],
                      ],
                    ],
                  ),
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

class _NamedTabButton extends StatelessWidget {
  const _NamedTabButton({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final OpenNamedTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = selected
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    return Semantics(
      button: true,
      selected: selected,
      label: 'Open tab for ${tab.name}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(
                Icons.person_outline_rounded,
                size: 18,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tab.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              if (selected)
                Icon(Icons.check_circle_rounded, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

class _NamedTabDateGroup {
  const _NamedTabDateGroup({required this.openedDate, required this.tabs});

  final DateTime? openedDate;
  final List<OpenNamedTab> tabs;
}

List<_NamedTabDateGroup> _groupOpenNamedTabs(List<OpenNamedTab> tabs) {
  final datedTabs = <DateTime, List<OpenNamedTab>>{};
  final undatedTabs = <OpenNamedTab>[];
  for (final tab in tabs) {
    final openedAt = tab.openedAt;
    if (openedAt == null) {
      undatedTabs.add(tab);
      continue;
    }
    final date = DateTime(openedAt.year, openedAt.month, openedAt.day);
    (datedTabs[date] ??= <OpenNamedTab>[]).add(tab);
  }
  final dates = datedTabs.keys.toList()..sort((a, b) => b.compareTo(a));
  return [
    for (final date in dates)
      _NamedTabDateGroup(openedDate: date, tabs: datedTabs[date]!),
    if (undatedTabs.isNotEmpty)
      _NamedTabDateGroup(openedDate: null, tabs: undatedTabs),
  ];
}

String _namedTabDateLabel(BuildContext context, DateTime? date) {
  if (date == null) return 'Earlier tabs';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  if (date == today) return 'Today';
  if (date == today.subtract(const Duration(days: 1))) return 'Yesterday';
  return MaterialLocalizations.of(context).formatMediumDate(date);
}

class _MenuPanel extends ConsumerWidget {
  const _MenuPanel({required this.currencyCode});

  final String currencyCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedSection = ref.watch(activeSectionProvider);
    final selectedSubsection = ref.watch(activeSubsectionProvider);
    final activeOrder = ref.watch(activeOrderProvider);
    final scope = ref.watch(activeVenueScopeProvider);
    final sectionsState = ref.watch(menuSectionsProvider);
    final catalogState = ref.watch(menuProductsProvider);
    final sections = sectionsState.when(
      data: (items) => items,
      loading: () => scope == null ? demoSections : const [],
      error: (error, stackTrace) {
        AppLogger.error('Display menu sections', error, stackTrace);
        return scope == null ? demoSections : const [];
      },
    );
    final catalog = catalogState.when(
      data: (items) => items,
      loading: () => scope == null ? demoProducts : const [],
      error: (error, stackTrace) {
        AppLogger.error('Display menu products', error, stackTrace);
        return scope == null ? demoProducts : const [];
      },
    );
    final loading = sectionsState.isLoading || catalogState.isLoading;
    final menuError = sectionsState.when<Object?>(
      data: (_) => catalogState.when<Object?>(
        data: (_) => null,
        loading: () => null,
        error: (error, _) => error,
      ),
      loading: () => null,
      error: (error, _) => error,
    );
    final topLevelSections = sections
        .where((section) => section.parentSectionId == null)
        .toList(growable: false);
    final effectiveSection =
        topLevelSections.any((section) => section.id == selectedSection)
        ? selectedSection
        : null;
    final subsections = effectiveSection == null
        ? const <MenuSection>[]
        : sections
              .where((section) => section.parentSectionId == effectiveSection)
              .toList(growable: false);
    final effectiveSubsection =
        subsections.any((section) => section.id == selectedSubsection)
        ? selectedSubsection
        : null;
    final includedSectionIds = effectiveSection == null
        ? const <String>{}
        : <String>{
            effectiveSection,
            ...subsections.map((section) => section.id),
          };
    final products = catalog
        .where((product) {
          if (effectiveSubsection != null) {
            return product.sectionIds.contains(effectiveSubsection);
          }
          if (effectiveSection == null) return true;
          return product.sectionIds.any(includedSectionIds.contains);
        })
        .toList(growable: false);
    final section = effectiveSection == null
        ? null
        : topLevelSections.firstWhere((item) => item.id == effectiveSection);

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
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: const Text('All'),
                      selected: effectiveSection == null,
                      onSelected: (_) {
                        ref.read(activeSectionProvider.notifier).select(null);
                        ref
                            .read(activeSubsectionProvider.notifier)
                            .select(null);
                      },
                    ),
                  ),
                  for (final item in topLevelSections)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text('${item.icon} ${item.name}'),
                        selected: item.id == effectiveSection,
                        onSelected: (_) {
                          ref
                              .read(activeSectionProvider.notifier)
                              .select(item.id);
                          ref
                              .read(activeSubsectionProvider.notifier)
                              .select(null);
                        },
                      ),
                    ),
                ],
              ),
            ),
            if (subsections.isNotEmpty) ...[
              const SizedBox(height: 10),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text('All ${section?.name ?? ''}'),
                        selected: effectiveSubsection == null,
                        onSelected: (_) => ref
                            .read(activeSubsectionProvider.notifier)
                            .select(null),
                      ),
                    ),
                    for (final item in subsections)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: FilterChip(
                          label: Text('${item.icon} ${item.name}'),
                          selected: item.id == effectiveSubsection,
                          onSelected: (_) => ref
                              .read(activeSubsectionProvider.notifier)
                              .select(item.id),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            Text(
              effectiveSubsection == null
                  ? section?.name ?? 'All menu items'
                  : subsections
                        .firstWhere((item) => item.id == effectiveSubsection)
                        .name,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : menuError != null
                  ? _MenuStateMessage(
                      icon: Icons.cloud_off_rounded,
                      title: 'Could not load this venue’s menu',
                      detail: '$menuError',
                    )
                  : products.isEmpty
                  ? const _MenuStateMessage(
                      icon: Icons.menu_book_outlined,
                      title: 'No menu items are available',
                      detail:
                          'Add a product in Menu management, or choose a different category.',
                    )
                  : LayoutBuilder(
                      builder: (context, _) {
                        return GridView.builder(
                          itemCount: products.length,
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 180,
                                crossAxisSpacing: 12,
                                mainAxisSpacing: 12,
                                mainAxisExtent: 126,
                              ),
                          itemBuilder: (context, index) => _ProductTile(
                            product: products[index],
                            currencyCode: currencyCode,
                            canAdd: activeOrder.canAddProduct(products[index]),
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

class _MenuStateMessage extends StatelessWidget {
  const _MenuStateMessage({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: scheme.primary),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({
    required this.product,
    required this.currencyCode,
    required this.canAdd,
    required this.onTap,
  });

  final MenuProduct product;
  final String currencyCode;
  final bool canAdd;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final unavailable = !canAdd;
    final unavailableLabel = product.isAvailable ? 'Sold out' : 'Unavailable';
    return Semantics(
      button: true,
      enabled: !unavailable,
      label: unavailable
          ? '${product.name}, $unavailableLabel'
          : 'Add ${product.name}',
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
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Phone grids intentionally use a short tile. Keep its most
                // useful information visible without causing a layout overflow.
                final compact = constraints.maxHeight < 120;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      product.productionArea == ProductionArea.bar
                          ? Icons.local_bar_rounded
                          : Icons.restaurant_rounded,
                      size: compact ? 20 : null,
                      color: unavailable ? scheme.outline : scheme.primary,
                    ),
                    if (compact) const SizedBox(height: 4) else const Spacer(),
                    Text(
                      product.name,
                      maxLines: compact ? 1 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    SizedBox(height: compact ? 2 : 4),
                    Text(
                      formatMoney(
                        product.priceMinor,
                        currencyCode: currencyCode,
                      ),
                    ),
                    if (unavailable)
                      Text(
                        unavailableLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall
                            ?.copyWith(color: scheme.error),
                      ),
                    if (!compact && product.trackStock)
                      Text(
                        '${_formatStock(product.stockOnHand ?? 0)} ${product.stockUnit} left',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

String _formatStock(double quantity) {
  if (quantity == quantity.roundToDouble()) return quantity.toStringAsFixed(0);
  return quantity
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

class _OrderPanel extends ConsumerWidget {
  const _OrderPanel({required this.currencyCode});

  final String currencyCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final order = ref.watch(activeOrderProvider);
    final hasUnsentLines = order.lines.any((line) => !line.isSentToProduction);
    final tableId = ref.watch(selectedTableProvider);
    final tableLabel = ref
        .watch(diningTablesProvider)
        .when(
          data: (tables) {
            for (final table in tables) {
              if (table.id == tableId) return table.label;
            }
            return tableId;
          },
          loading: () => tableId,
          error: (_, _) => tableId,
        );
    final orderLocationLabel = order.tabName ?? tableLabel;
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
                  orderLocationLabel,
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
                              onPressed: line.isSentToProduction
                                  ? null
                                  : () => ref
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
                                    '${line.quantity} × ${formatMoney(line.unitPriceMinor, currencyCode: currencyCode)}',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                  if (line.isSentToProduction)
                                    Text(
                                      'Sent to production',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.labelSmall,
                                    ),
                                ],
                              ),
                            ),
                            Text(
                              formatMoney(
                                line.totalMinor,
                                currencyCode: currencyCode,
                              ),
                            ),
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
                  formatMoney(order.totalMinor, currencyCode: currencyCode),
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
                    onPressed: !hasUnsentLines
                        ? null
                        : () async {
                            try {
                              final printResult = await ref
                                  .read(activeOrderProvider.notifier)
                                  .sendToProduction();
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    printResult.ticketsPrinted > 0
                                        ? 'New items sent. ${printResult.ticketsPrinted} production ticket(s) printed.'
                                        : 'New items sent to the Order Flow Board. Enable production routing on this device to print tickets.',
                                  ),
                                ),
                              );
                            } on Object catch (error, stackTrace) {
                              AppLogger.error(
                                'Send order to production',
                                error,
                                stackTrace,
                              );
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'The order or its local ticket could not be completed. It remains open for a safe retry.',
                                  ),
                                ),
                              );
                            }
                          },
                    icon: const Icon(Icons.print_rounded),
                    label: Text(
                      order.status == OrderStatus.sent
                          ? 'Send additions'
                          : 'Send',
                    ),
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

void _showNamedTabDialog(BuildContext context, WidgetRef ref) {
  final nameController = TextEditingController();
  showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: const Icon(Icons.person_outline_rounded),
      title: const Text('Open named tab'),
      content: TextField(
        controller: nameController,
        autofocus: true,
        maxLength: 80,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(
          labelText: 'Customer or tab name',
          hintText: 'For example, John N',
          helperText:
              'Entering an existing open name returns to that tab instead.',
        ),
        onSubmitted: (_) {},
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: () async {
            try {
              await ref
                  .read(activeOrderProvider.notifier)
                  .openNamedTab(nameController.text);
              ref.read(selectedTableProvider.notifier).select('');
              if (!dialogContext.mounted) return;
              Navigator.of(dialogContext).pop();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Named tab is ready.')),
              );
            } on Object catch (error, stackTrace) {
              AppLogger.error('Open named tab', error, stackTrace);
              if (!dialogContext.mounted) return;
              ScaffoldMessenger.of(
                dialogContext,
              ).showSnackBar(SnackBar(content: Text('$error')));
            }
          },
          icon: const Icon(Icons.open_in_new_rounded),
          label: const Text('Open tab'),
        ),
      ],
    ),
  ).whenComplete(nameController.dispose);
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
