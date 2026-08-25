import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/money.dart';
import '../../core/tenant_scope.dart';
import '../notifications/notification_centre.dart';
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
                                  showAppNotification(
                                    context,
                                    ref: ref,
                                    title: 'Could not switch table',
                                    message: '$error',
                                    level: AppNotificationLevel.error,
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
                                    showAppNotification(
                                      context,
                                      ref: ref,
                                      title: 'Could not open named tab',
                                      message: '$error',
                                      level: AppNotificationLevel.error,
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
                            onTap: () async {
                              try {
                                await ref
                                    .read(activeOrderProvider.notifier)
                                    .addProduct(products[index]);
                              } on Object catch (error, stackTrace) {
                                AppLogger.error(
                                  'Add item to shared draft order',
                                  error,
                                  stackTrace,
                                );
                                if (!context.mounted) return;
                                showAppNotification(
                                  context,
                                  ref: ref,
                                  title: 'Item was not added',
                                  message: '$error',
                                  level: AppNotificationLevel.error,
                                );
                              }
                            },
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
                        style: Theme.of(
                          context,
                        ).textTheme.labelSmall?.copyWith(color: scheme.error),
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

class _OrderPanel extends ConsumerStatefulWidget {
  const _OrderPanel({required this.currencyCode});

  final String currencyCode;

  @override
  ConsumerState<_OrderPanel> createState() => _OrderPanelState();
}

class _OrderPanelState extends ConsumerState<_OrderPanel> {
  final _lineScrollController = ScrollController();
  String? _lastOrderLinesKey;

  @override
  void dispose() {
    _lineScrollController.dispose();
    super.dispose();
  }

  void _showLatestLines(PosOrder order) {
    final latestLineId = order.lines.isEmpty ? '' : order.lines.last.id;
    final key = '${order.id}:${order.lines.length}:$latestLineId';
    if (_lastOrderLinesKey == key) return;
    _lastOrderLinesKey = key;
    if (order.lines.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_lineScrollController.hasClients) return;
      // The order list is chronological, so the most recently added line is
      // at the bottom. Jump there for both a newly opened order and a live
      // addition from another device.
      _lineScrollController.jumpTo(
        _lineScrollController.position.maxScrollExtent,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final order = ref.watch(activeOrderProvider);
    _showLatestLines(order);
    final hasUnsentLines = order.lines.any((line) => !line.isSentToProduction);
    final tableId = order.tableId ?? ref.watch(selectedTableProvider) ?? '';
    final tableLabel = tableId.isEmpty
        ? ''
        : ref
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
    final orderLocationLabel =
        order.tabName ??
        (tableLabel.isEmpty ? 'No table selected' : tableLabel);
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
                  : Scrollbar(
                      controller: _lineScrollController,
                      thumbVisibility: true,
                      child: ListView.separated(
                        controller: _lineScrollController,
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
                                    : () async {
                                        try {
                                          await ref
                                              .read(
                                                activeOrderProvider.notifier,
                                              )
                                              .reduceLine(line.id);
                                        } on Object catch (error, stackTrace) {
                                          AppLogger.error(
                                            'Remove item from shared draft order',
                                            error,
                                            stackTrace,
                                          );
                                          if (!context.mounted) return;
                                          showAppNotification(
                                            context,
                                            ref: ref,
                                            title: 'Item was not removed',
                                            message: '$error',
                                            level: AppNotificationLevel.error,
                                          );
                                        }
                                      },
                                icon: const Icon(
                                  Icons.remove_rounded,
                                  size: 18,
                                ),
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
                                      '${line.quantity} × ${formatMoney(line.unitPriceMinor, currencyCode: widget.currencyCode)}',
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
                                  currencyCode: widget.currencyCode,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
            ),
            const Divider(height: 24),
            Row(
              children: [
                Text('Total', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Text(
                  formatMoney(
                    order.totalMinor,
                    currencyCode: widget.currencyCode,
                  ),
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
                    label: const Text('Split'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: order.lines.isEmpty || hasUnsentLines
                        ? null
                        : () => _showCheckoutSheet(
                            context,
                            ref: ref,
                            order: order,
                            currencyCode: widget.currencyCode,
                          ),
                    icon: const Icon(Icons.payments_outlined),
                    label: const Text('Pay'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: !hasUnsentLines
                    ? null
                    : () async {
                        final printRequired = await _confirmProductionPrint(
                          context,
                        );
                        if (printRequired == null || !context.mounted) {
                          return;
                        }
                        try {
                          final printResult = await ref
                              .read(activeOrderProvider.notifier)
                              .sendToProduction(printRequired: printRequired);
                          if (!context.mounted) return;
                          final message = !printRequired
                              ? 'New items sent to the Order Flow Board without printing.'
                              : printResult.ticketsPrinted > 0
                              ? 'New items sent. ${printResult.ticketsPrinted} production ticket(s) printed.'
                              : 'New items sent to the Order Flow Board. Enable production routing on this device to print tickets.';
                          showAppNotification(
                            context,
                            ref: ref,
                            title: 'Order sent',
                            message: message,
                            level: AppNotificationLevel.success,
                          );
                        } on Object catch (error, stackTrace) {
                          AppLogger.error(
                            'Send order to production',
                            error,
                            stackTrace,
                          );
                          if (!context.mounted) return;
                          showAppNotification(
                            context,
                            ref: ref,
                            title: 'Order needs attention',
                            message:
                                'The order or its local ticket could not be completed. It remains open for a safe retry.',
                            level: AppNotificationLevel.error,
                          );
                        }
                      },
                icon: const Icon(Icons.print_rounded),
                label: Text(
                  order.status == OrderStatus.sent
                      ? 'Send additions'
                      : 'Send order',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _showCheckoutSheet(
  BuildContext pageContext, {
  required WidgetRef ref,
  required PosOrder order,
  required String currencyCode,
}) async {
  final terminalController = TextEditingController();
  await showModalBottomSheet<void>(
    context: pageContext,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      var method = PaymentMethod.cash;
      var cardApproved = false;
      var saving = false;
      return StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              24,
              0,
              24,
              24 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Take payment',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                Text(
                  order.tabName?.trim().isNotEmpty == true
                      ? 'Named tab: ${order.tabName}'
                      : 'Table bill',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        const Icon(Icons.receipt_long_outlined),
                        const SizedBox(width: 12),
                        const Expanded(child: Text('Amount due')),
                        Text(
                          formatMoney(
                            order.totalMinor,
                            currencyCode: currencyCode,
                          ),
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SegmentedButton<PaymentMethod>(
                  segments: const [
                    ButtonSegment(
                      value: PaymentMethod.cash,
                      icon: Icon(Icons.payments_outlined),
                      label: Text('Cash'),
                    ),
                    ButtonSegment(
                      value: PaymentMethod.cardTerminal,
                      icon: Icon(Icons.credit_card_rounded),
                      label: Text('Card'),
                    ),
                  ],
                  selected: {method},
                  onSelectionChanged: saving
                      ? null
                      : (selection) => setSheetState(() {
                          method = selection.first;
                          cardApproved = false;
                        }),
                ),
                if (method == PaymentMethod.cardTerminal) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: terminalController,
                    enabled: !saving,
                    maxLength: 120,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Card terminal used (optional)',
                      hintText: 'For example, Bar terminal',
                    ),
                  ),
                  CheckboxListTile(
                    value: cardApproved,
                    contentPadding: EdgeInsets.zero,
                    onChanged: saving
                        ? null
                        : (value) => setSheetState(
                            () => cardApproved = value ?? false,
                          ),
                    title: const Text('Card terminal approved the payment'),
                    subtitle: const Text(
                      'Only record this after Card Plus confirms approval.',
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  'This closes the whole bill. Split bills, mixed tender and foreign cash are the next checkout step.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: saving
                            ? null
                            : () => Navigator.of(sheetContext).pop(),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed:
                            saving ||
                                (method == PaymentMethod.cardTerminal &&
                                    !cardApproved)
                            ? null
                            : () async {
                                setSheetState(() => saving = true);
                                try {
                                  final result = await ref
                                      .read(activeOrderProvider.notifier)
                                      .closeBill(
                                        method: method,
                                        cardPaymentApproved: cardApproved,
                                        terminalLabel: terminalController.text
                                            .trim(),
                                      );
                                  if (!sheetContext.mounted) return;
                                  Navigator.of(sheetContext).pop();
                                  if (!pageContext.mounted) return;
                                  showAppNotification(
                                    pageContext,
                                    ref: ref,
                                    title: result.alreadyClosed
                                        ? 'Bill was already closed'
                                        : 'Payment recorded',
                                    message:
                                        'Receipt ${result.receiptNumber} closed at ${formatMoney(result.totalMinor, currencyCode: result.currencyCode)}.',
                                    level: AppNotificationLevel.success,
                                  );
                                } on Object catch (error, stackTrace) {
                                  AppLogger.error(
                                    'Close bill',
                                    error,
                                    stackTrace,
                                  );
                                  if (!sheetContext.mounted) return;
                                  setSheetState(() => saving = false);
                                  showAppNotification(
                                    sheetContext,
                                    ref: ref,
                                    title: 'Payment was not recorded',
                                    message: '$error',
                                    level: AppNotificationLevel.error,
                                  );
                                }
                              },
                        icon: saving
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.check_circle_outline_rounded),
                        label: Text(
                          saving
                              ? 'Recording…'
                              : method == PaymentMethod.cash
                              ? 'Record cash'
                              : 'Record card',
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  ).whenComplete(terminalController.dispose);
}

/// Always asks at the point an order leaves the basket. Bar staff often need
/// the order recorded and visible on the flow board without wasting a ticket.
Future<bool?> _confirmProductionPrint(BuildContext context) => showDialog<bool>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    icon: const Icon(Icons.print_outlined),
    title: const Text('Send order'),
    content: const Text(
      'Do you need a production ticket printed for these new items?',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(dialogContext).pop(),
        child: const Text('Cancel'),
      ),
      OutlinedButton(
        onPressed: () => Navigator.of(dialogContext).pop(false),
        child: const Text('Send without printing'),
      ),
      FilledButton.icon(
        onPressed: () => Navigator.of(dialogContext).pop(true),
        icon: const Icon(Icons.print_rounded),
        label: const Text('Send & print'),
      ),
    ],
  ),
);

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
              showAppNotification(
                context,
                ref: ref,
                title: 'Named tab ready',
                message: 'Named tab is ready.',
                level: AppNotificationLevel.success,
              );
            } on Object catch (error, stackTrace) {
              AppLogger.error('Open named tab', error, stackTrace);
              if (!dialogContext.mounted) return;
              showAppNotification(
                dialogContext,
                ref: ref,
                title: 'Could not open named tab',
                message: '$error',
                level: AppNotificationLevel.error,
              );
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
