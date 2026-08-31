import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/money.dart';
import '../../core/tenant_scope.dart';
import '../../data/production_command_repository.dart';
import '../notifications/notification_centre.dart';
import 'domain.dart';
import 'pos_controller.dart';
import 'product_configuration_sheet.dart';

class PosPage extends ConsumerWidget {
  const PosPage({super.key, required this.currencyCode});

  final String currencyCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final compactTab = ref.watch(posCompactTabProvider);
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
                SizedBox(
                  width: 238,
                  child: _TablesPanel(currencyCode: currencyCode),
                ),
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
            key: ValueKey(compactTab),
            length: 3,
            initialIndex: compactTab,
            child: Column(
              children: [
                TabBar(
                  onTap: (index) => ref
                      .read(posCompactTabProvider.notifier)
                      .select(index),
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
                      _TablesPanel(currencyCode: currencyCode, compact: true),
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
  const _TablesPanel({required this.currencyCode, this.compact = false});

  final String currencyCode;
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
                              scope: scope,
                              currencyCode: currencyCode,
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
                                scope: scope,
                                currencyCode: currencyCode,
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

class _TableButton extends ConsumerWidget {
  const _TableButton({
    required this.table,
    required this.scope,
    required this.currencyCode,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  final DiningTable table;
  final VenueScope? scope;
  final String currencyCode;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final openOrderValue = scope == null || table.currentOrderId == null
        ? null
        : ref.watch(tableOpenOrderProvider(table.currentOrderId!));
    final amountDueMinor = openOrderValue?.when(
      data: (order) => order?.totalMinor,
      loading: () => null,
      error: (_, _) => null,
    );
    final isOpen = table.hasOpenOrder;
    final openGreen = Theme.of(context).brightness == Brightness.dark
        ? Colors.green.shade700
        : Colors.green.shade600;
    final background = isOpen
        ? openGreen
        : selected
        ? scheme.primary
        : scheme.surfaceContainerHighest;
    final foreground = isOpen || selected ? Colors.white : scheme.onSurface;
    final width = compact ? 72.0 : 104.0;
    return Semantics(
      button: true,
      selected: selected,
      label: isOpen
          ? 'Table ${table.label}, open, ${amountDueMinor == null ? 'amount loading' : formatMoney(amountDueMinor, currencyCode: currencyCode)} owed'
          : 'Table ${table.label}, available',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          width: width,
          height: compact ? 72 : 92,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(14),
            border: selected
                ? Border.all(
                    color: isOpen ? Colors.white : scheme.primary,
                    width: 2,
                  )
                : null,
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
              if (isOpen) ...[
                Text(
                  'OPEN',
                  style: TextStyle(
                    fontSize: compact ? 9 : 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .6,
                    color: foreground.withValues(alpha: .84),
                  ),
                ),
                const SizedBox(height: 2),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      amountDueMinor == null
                          ? 'Loading...'
                          : formatMoney(
                              amountDueMinor,
                              currencyCode: currencyCode,
                            ),
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: compact ? 11 : 13,
                        fontWeight: FontWeight.w800,
                        color: foreground,
                      ),
                    ),
                  ),
                ),
              ] else
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

class _NamedTabButton extends ConsumerWidget {
  const _NamedTabButton({
    required this.tab,
    required this.scope,
    required this.currencyCode,
    required this.selected,
    required this.onTap,
  });

  final OpenNamedTab tab;
  final VenueScope? scope;
  final String currencyCode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final totalMinor = scope == null
        ? null
        : ref.watch(tableOpenOrderProvider(tab.orderId)).when(
            data: (order) => order?.totalMinor,
            loading: () => null,
            error: (_, _) => null,
          );
    // Every item here represents a live named tab. Make that operational
    // state as obvious as an open table, not merely the currently selected
    // tab.
    final background = Colors.green.shade600;
    final foreground = Colors.white;
    return Semantics(
      button: true,
      selected: selected,
      label: 'Open tab for ${tab.name}${totalMinor == null ? '' : ', ${formatMoney(totalMinor, currencyCode: currencyCode)} owed'}',
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
                color: foreground,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tab.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: foreground,
                      ),
                    ),
                    if (totalMinor != null)
                      Text(
                        formatMoney(totalMinor, currencyCode: currencyCode),
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(color: foreground.withValues(alpha: .88)),
                      ),
                  ],
                ),
              ),
              if (selected) const Icon(Icons.check_circle_rounded, color: Colors.white),
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
    final modifierGroupsState = ref.watch(menuModifierGroupsProvider);
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
    final modifierGroups = modifierGroupsState.when(
      data: (items) => items,
      loading: () => const <MenuModifierGroup>[],
      error: (error, stackTrace) {
        AppLogger.error('Display menu modifier groups', error, stackTrace);
        return const <MenuModifierGroup>[];
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

    Future<void> addSelectedProduct(
      MenuProduct product, {
      required bool forceConfiguration,
    }) async {
      try {
        if (!await _ensureOrderLocation(context, ref)) return;
        final selection = forceConfiguration || product.requiresConfiguration
            ? await showProductConfigurationSheet(
                context: context,
                product: product,
                availableGroups: modifierGroups,
                currencyCode: currencyCode,
              )
            : const ProductConfigurationSelection();
        if (selection == null) return;
        await ref
            .read(activeOrderProvider.notifier)
            .addProduct(product, selection: selection);
      } on Object catch (error, stackTrace) {
        AppLogger.error('Add item to shared draft order', error, stackTrace);
        if (!context.mounted) return;
        showAppNotification(
          context,
          ref: ref,
          title: 'Item was not added',
          message: '$error',
          level: AppNotificationLevel.error,
        );
      }
    }

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
                            onTap: () => addSelectedProduct(
                              products[index],
                              forceConfiguration: false,
                            ),
                            onLongPress: () => addSelectedProduct(
                              products[index],
                              forceConfiguration: true,
                            ),
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
    required this.onLongPress,
  });

  final MenuProduct product;
  final String currencyCode;
  final bool canAdd;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

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
        onLongPress: unavailable ? null : onLongPress,
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
                    if (!compact && product.requiresConfiguration)
                      const Align(
                        alignment: Alignment.centerRight,
                        child: Icon(Icons.tune_rounded, size: 16),
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
    final splitOrdersValue = order.isSplitOrder
        ? null
        : ref.watch(openSplitOrdersProvider(order.id));
    final openSplitOrders =
        splitOrdersValue?.when(
          data: (orders) => orders,
          loading: () => const <PosOrder>[],
          error: (error, stackTrace) {
            AppLogger.error('Display open split bills', error, stackTrace);
            return const <PosOrder>[];
          },
        ) ??
        const <PosOrder>[];
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
            if (order.isSplitOrder)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Separate bill ${order.splitSequence ?? ''}'.trim(),
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(color: scheme.primary),
                ),
              ),
            if (!order.isSplitOrder && openSplitOrders.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${openSplitOrders.length} unpaid separate bill${openSplitOrders.length == 1 ? '' : 's'}',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        for (final splitOrder in openSplitOrders)
                          ActionChip(
                            avatar: const Icon(Icons.receipt_long_rounded),
                            label: Text(
                              'Bill ${splitOrder.splitSequence ?? ''} · ${formatMoney(splitOrder.totalMinor, currencyCode: widget.currencyCode)}',
                            ),
                            onPressed: () {
                              try {
                                ref
                                    .read(activeOrderProvider.notifier)
                                    .openSplitOrder(splitOrder);
                              } on Object catch (error, stackTrace) {
                                AppLogger.error(
                                  'Open unpaid split bill',
                                  error,
                                  stackTrace,
                                );
                                showAppNotification(
                                  context,
                                  ref: ref,
                                  title: 'Could not open split bill',
                                  message: '$error',
                                  level: AppNotificationLevel.error,
                                );
                              }
                            },
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
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
                                    if (line.productionDetails.isNotEmpty)
                                      Text(
                                        line.productionDetails.join(' · '),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.labelSmall,
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
                    onPressed:
                        order.isSplitOrder ||
                            order.lines.isEmpty ||
                            hasUnsentLines
                        ? null
                        : () => _showSplitBillSheet(
                            context,
                            ref: ref,
                            order: order,
                            currencyCode: widget.currencyCode,
                          ),
                    icon: const Icon(Icons.call_split_rounded),
                    label: const Text('Split'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed:
                        order.lines.isEmpty ||
                            hasUnsentLines ||
                            (!order.isSplitOrder && openSplitOrders.isNotEmpty)
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
                          ref
                              .read(activeOrderProvider.notifier)
                              .clearSelectionAfterSend();
                          ref.read(posCompactTabProvider.notifier).select(0);
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
  final baseCurrencyCode = currencyCode.trim().toUpperCase();
  final tenderedAmountController = TextEditingController(
    text: _moneyInputFromMinor(order.totalMinor, currencyCode),
  );
  final exchangeRateController = TextEditingController(text: '1');
  final currencyChoices = checkoutTenderCurrencies(baseCurrencyCode);
  await showModalBottomSheet<void>(
    context: pageContext,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      var method = PaymentMethod.cash;
      var tenderedCurrencyCode = baseCurrencyCode;
      var cardApproved = false;
      var saving = false;
      // Paid receipts are normally required in a restaurant. Staff can still
      // opt out for a particular payment, but the safe operational default is
      // to queue one to the venue's dedicated receipt printer.
      var printReceipt = defaultPrintPaidReceipt;
      var loadingOfficialRate = false;
      ExchangeRateQuote? officialRateQuote;
      final paymentEntries = <_CheckoutPaymentDraft>[];
      return StatefulBuilder(
        builder: (context, setSheetState) {
          final tenderedMinor = _minorFromMoneyInput(
            tenderedAmountController.text,
            tenderedCurrencyCode,
          );
          final convertedBaseMinor = tenderedMinor == null
              ? null
              : _convertedBaseMinor(
                  tenderedMinor: tenderedMinor,
                  tenderedCurrencyCode: tenderedCurrencyCode,
                  baseCurrencyCode: baseCurrencyCode,
                  exchangeRateText: exchangeRateController.text,
                );
          final recordedBaseMinor = paymentEntries.fold<int>(
            0,
            (total, payment) => total + payment.baseAmountMinor,
          );
          final remainingBaseMinor = order.totalMinor - recordedBaseMinor;
          final cashChangeBaseMinor =
              method == PaymentMethod.cash &&
                  convertedBaseMinor != null &&
                  convertedBaseMinor > remainingBaseMinor
              ? convertedBaseMinor - remainingBaseMinor
              : 0;
          final appliedBaseMinor = convertedBaseMinor == null
              ? null
              : convertedBaseMinor - cashChangeBaseMinor;
          final amountFits =
              appliedBaseMinor != null &&
              appliedBaseMinor > 0 &&
              (method == PaymentMethod.cash ||
                  appliedBaseMinor <= remainingBaseMinor);
          final paymentsComplete =
              paymentEntries.isNotEmpty && remainingBaseMinor == 0;
          final isForeignCash = tenderedCurrencyCode != baseCurrencyCode;
          final hasAmountInput = tenderedAmountController.text
              .trim()
              .isNotEmpty;
          final validationMessage = tenderedMinor == null
              ? 'Enter a valid payment amount.'
              : isForeignCash && convertedBaseMinor == null
              ? 'Load the official rate or enter a valid manager rate.'
              : method != PaymentMethod.cash &&
                    convertedBaseMinor != null &&
                    convertedBaseMinor > remainingBaseMinor
              ? 'This payment allocation is more than the amount remaining.'
              : 'This payment cannot be added.';
          final loadedOfficialRate = officialRateQuote;
          return SafeArea(
            child: SingleChildScrollView(
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
                          const Expanded(child: Text('Amount remaining')),
                          Text(
                            formatMoney(
                              remainingBaseMinor,
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
                            if (method == PaymentMethod.cardTerminal) {
                              tenderedCurrencyCode = baseCurrencyCode;
                              exchangeRateController.text = '1';
                              tenderedAmountController.text =
                                  _moneyInputFromMinor(
                                    order.totalMinor,
                                    currencyCode,
                                  );
                            }
                            officialRateQuote = null;
                          }),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    method == PaymentMethod.cash
                        ? 'Cash currency'
                        : 'Card currency',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  if (method == PaymentMethod.cash)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final code in currencyChoices)
                          ChoiceChip(
                            label: Text(code),
                            selected: tenderedCurrencyCode == code,
                            onSelected: saving
                                ? null
                                : (selected) {
                                    if (!selected ||
                                        tenderedCurrencyCode == code) {
                                      return;
                                    }
                                    setSheetState(() {
                                      tenderedCurrencyCode = code;
                                      exchangeRateController.text =
                                          code == baseCurrencyCode ? '1' : '';
                                      tenderedAmountController.clear();
                                      officialRateQuote = null;
                                    });
                                  },
                          ),
                      ],
                    )
                  else
                    InputDecorator(
                      decoration: const InputDecoration(
                        helperText:
                            'Card terminal payments use the venue reporting currency.',
                      ),
                      child: Text(baseCurrencyCode),
                    ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: tenderedAmountController,
                    enabled: !saving,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Amount received ($tenderedCurrencyCode)',
                      helperText: isForeignCash
                          ? 'Enter the physical cash received in $tenderedCurrencyCode.'
                          : 'Enter the amount received.',
                    ),
                    onChanged: (_) => setSheetState(() {}),
                  ),
                  if (isForeignCash) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: exchangeRateController,
                      enabled: !saving,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText:
                            '1 $tenderedCurrencyCode = how many $currencyCode?',
                        helperText:
                            'Use the official rate as a starting point, then review or override it. The exact rate is retained on the bill.',
                      ),
                      onChanged: (_) =>
                          setSheetState(() => officialRateQuote = null),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: saving || loadingOfficialRate
                          ? null
                          : () async {
                              final scope = ref.read(activeVenueScopeProvider);
                              if (scope == null) {
                                showAppNotification(
                                  sheetContext,
                                  ref: ref,
                                  title: 'Rate not loaded',
                                  message:
                                      'Select a venue before looking up a rate.',
                                  level: AppNotificationLevel.error,
                                );
                                return;
                              }
                              setSheetState(() => loadingOfficialRate = true);
                              try {
                                final quote = await ref
                                    .read(productionCommandRepositoryProvider)
                                    .lookupExchangeRate(
                                      scope: scope,
                                      tenderCurrencyCode: tenderedCurrencyCode,
                                    );
                                if (!sheetContext.mounted) return;
                                setSheetState(() {
                                  exchangeRateController.text =
                                      quote.exchangeRateToBase;
                                  officialRateQuote = quote;
                                });
                              } on Object catch (error, stackTrace) {
                                AppLogger.error(
                                  'Load official exchange rate',
                                  error,
                                  stackTrace,
                                );
                                if (!sheetContext.mounted) return;
                                showAppNotification(
                                  sheetContext,
                                  ref: ref,
                                  title: 'Official rate unavailable',
                                  message:
                                      '$error Enter a manager rate manually.',
                                  level: AppNotificationLevel.error,
                                );
                              } finally {
                                if (sheetContext.mounted) {
                                  setSheetState(
                                    () => loadingOfficialRate = false,
                                  );
                                }
                              }
                            },
                      icon: loadingOfficialRate
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.currency_exchange_rounded),
                      label: Text(
                        loadingOfficialRate
                            ? 'Loading official rate…'
                            : 'Use official CBRT rate',
                      ),
                    ),
                    if (loadedOfficialRate != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '${loadedOfficialRate.source}${loadedOfficialRate.publishedDate == null ? '' : ' · ${loadedOfficialRate.publishedDate}'}. You can edit the rate before adding the payment.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                  ],
                  if (convertedBaseMinor != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Tender value: ${formatMoney(convertedBaseMinor, currencyCode: currencyCode)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: amountFits
                            ? Colors.green.shade700
                            : Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  if (cashChangeBaseMinor > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Change due: ${formatMoney(cashChangeBaseMinor, currencyCode: currencyCode)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                  if (hasAmountInput && !amountFits)
                    Text(
                      validationMessage,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  if (paymentEntries.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Payment allocations',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    for (var index = 0; index < paymentEntries.length; index++)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          paymentEntries[index].method == PaymentMethod.cash
                              ? Icons.payments_outlined
                              : Icons.credit_card_rounded,
                        ),
                        title: Text(
                          '${paymentEntries[index].method == PaymentMethod.cash ? 'Cash' : 'Card'} · ${formatMoney(paymentEntries[index].tenderedAmountMinor, currencyCode: paymentEntries[index].tenderedCurrencyCode)}',
                        ),
                        subtitle:
                            paymentEntries[index].tenderedCurrencyCode ==
                                    baseCurrencyCode &&
                                paymentEntries[index].cashChangeBaseMinor == 0
                            ? null
                            : Text(
                                '${paymentEntries[index].tenderedCurrencyCode == baseCurrencyCode ? 'Applied' : 'Rate ${paymentEntries[index].exchangeRateToBase} →'} ${formatMoney(paymentEntries[index].baseAmountMinor, currencyCode: currencyCode)}${paymentEntries[index].cashChangeBaseMinor > 0 ? ' after ${formatMoney(paymentEntries[index].cashChangeBaseMinor, currencyCode: currencyCode)} change' : ''}',
                              ),
                        trailing: IconButton(
                          tooltip: 'Remove payment allocation',
                          onPressed: saving
                              ? null
                              : () => setSheetState(
                                  () => paymentEntries.removeAt(index),
                                ),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ),
                  ],
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
                  CheckboxListTile(
                    value: printReceipt,
                    contentPadding: EdgeInsets.zero,
                    onChanged: saving
                        ? null
                        : (value) => setSheetState(
                            () => printReceipt = value ?? false,
                          ),
                    title: const Text('Print paid receipt'),
                    subtitle: const Text(
                      'Queues the full bill to this venue’s dedicated receipt printer after payment is recorded.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    isForeignCash
                        ? 'Foreign cash retains its tender amount and rate for audit/reporting. Any overpayment is shown as change in the reporting currency.'
                        : 'Add one or more payment allocations. The total must equal the remaining bill value.',
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
                                  paymentEntries.length >= 8 ||
                                  !amountFits ||
                                  tenderedMinor == null ||
                                  (method == PaymentMethod.cardTerminal &&
                                      !cardApproved)
                              ? null
                              : () => setSheetState(() {
                                  paymentEntries.add(
                                    _CheckoutPaymentDraft(
                                      method: method,
                                      tenderedAmountMinor: tenderedMinor,
                                      tenderedCurrencyCode:
                                          tenderedCurrencyCode,
                                      exchangeRateToBase: exchangeRateController
                                          .text
                                          .trim(),
                                      baseAmountMinor: appliedBaseMinor,
                                      cardPaymentApproved: cardApproved,
                                      terminalLabel: terminalController.text
                                          .trim(),
                                      cashChangeBaseMinor: cashChangeBaseMinor,
                                      exchangeRateSource:
                                          officialRateQuote?.source,
                                      exchangeRatePublishedDate:
                                          officialRateQuote?.publishedDate,
                                      exchangeRateFetchedAt:
                                          officialRateQuote?.fetchedAt,
                                    ),
                                  );
                                  final nextRemaining =
                                      order.totalMinor -
                                      paymentEntries.fold<int>(
                                        0,
                                        (total, payment) =>
                                            total + payment.baseAmountMinor,
                                      );
                                  method = PaymentMethod.cash;
                                  tenderedCurrencyCode = baseCurrencyCode;
                                  cardApproved = false;
                                  exchangeRateController.text = '1';
                                  officialRateQuote = null;
                                  terminalController.clear();
                                  tenderedAmountController.text =
                                      nextRemaining <= 0
                                      ? ''
                                      : _moneyInputFromMinor(
                                          nextRemaining,
                                          currencyCode,
                                        );
                                }),
                          icon: const Icon(Icons.add_card_rounded),
                          label: const Text('Add payment'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: saving || !paymentsComplete
                          ? null
                          : () async {
                              setSheetState(() => saving = true);
                              try {
                                final result = await ref
                                    .read(activeOrderProvider.notifier)
                                    .closeBill(
                                      payments: paymentEntries
                                          .map(
                                            (entry) => entry.toPaymentInput(),
                                          )
                                          .toList(growable: false),
                                      printReceipt: printReceipt,
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
                                      'Receipt ${result.receiptNumber} closed at ${formatMoney(result.totalMinor, currencyCode: result.currencyCode)}.${result.receiptPrintRequested ? (result.receiptPrintQueued ? ' Printing has been queued.' : ' No dedicated receipt printer is configured.') : ''}',
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
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check_circle_outline_rounded),
                      label: Text(
                        saving
                            ? 'Recording…'
                            : paymentsComplete
                            ? 'Close bill'
                            : 'Add payment allocation',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  ).whenComplete(() {
    terminalController.dispose();
    tenderedAmountController.dispose();
    exchangeRateController.dispose();
  });
}

class _CheckoutPaymentDraft {
  const _CheckoutPaymentDraft({
    required this.method,
    required this.tenderedAmountMinor,
    required this.tenderedCurrencyCode,
    required this.exchangeRateToBase,
    required this.baseAmountMinor,
    required this.cardPaymentApproved,
    this.terminalLabel,
    this.cashChangeBaseMinor = 0,
    this.exchangeRateSource,
    this.exchangeRatePublishedDate,
    this.exchangeRateFetchedAt,
  });

  final PaymentMethod method;
  final int tenderedAmountMinor;
  final String tenderedCurrencyCode;
  final String exchangeRateToBase;
  final int baseAmountMinor;
  final bool cardPaymentApproved;
  final String? terminalLabel;
  final int cashChangeBaseMinor;
  final String? exchangeRateSource;
  final String? exchangeRatePublishedDate;
  final String? exchangeRateFetchedAt;

  BillPaymentInput toPaymentInput() => BillPaymentInput(
    method: method,
    tenderedAmountMinor: tenderedAmountMinor,
    tenderedCurrencyCode: tenderedCurrencyCode,
    exchangeRateToBase: exchangeRateToBase,
    cardPaymentApproved: cardPaymentApproved,
    terminalLabel: terminalLabel,
    cashChangeBaseMinor: cashChangeBaseMinor,
    exchangeRateSource: exchangeRateSource,
    exchangeRatePublishedDate: exchangeRatePublishedDate,
    exchangeRateFetchedAt: exchangeRateFetchedAt,
  );
}

String _moneyInputFromMinor(int minorUnits, String currencyCode) {
  final digits = currencyDecimalDigits(currencyCode);
  final scale = _minorScale(digits);
  final major = minorUnits ~/ scale;
  if (digits == 0) return '$major';
  final fraction = (minorUnits.abs() % scale).toString().padLeft(digits, '0');
  return '$major.$fraction';
}

int? _minorFromMoneyInput(String raw, String currencyCode) {
  final value = raw.trim().replaceAll(',', '.');
  final digits = currencyDecimalDigits(currencyCode);
  final expression = digits == 0
      ? RegExp(r'^\d+$')
      : RegExp('^\\d+(?:\\.\\d{0,$digits})?\$');
  if (!expression.hasMatch(value)) return null;
  final pieces = value.split('.');
  final major = int.tryParse(pieces.first);
  if (major == null) return null;
  final scale = _minorScale(digits);
  final fraction = digits == 0 || pieces.length == 1
      ? 0
      : int.tryParse(pieces.last.padRight(digits, '0'));
  if (fraction == null) return null;
  final amount = (major * scale) + fraction;
  return amount > 0 && amount <= 100000000 ? amount : null;
}

int? _convertedBaseMinor({
  required int tenderedMinor,
  required String tenderedCurrencyCode,
  required String baseCurrencyCode,
  required String exchangeRateText,
}) {
  if (tenderedCurrencyCode == baseCurrencyCode) return tenderedMinor;
  final normalizedRate = exchangeRateText.trim();
  if (!RegExp(r'^(?:0|[1-9]\d{0,8})(?:\.\d{1,6})?$').hasMatch(normalizedRate)) {
    return null;
  }
  final pieces = normalizedRate.split('.');
  final major = int.tryParse(pieces.first);
  if (major == null) return null;
  final fractionalText = pieces.length == 1 ? '' : pieces.last;
  final fraction = int.tryParse(fractionalText.padRight(6, '0'));
  if (fraction == null) return null;
  // This mirrors the Cloud Function's fixed-scale integer calculation. The
  // earlier double calculation could differ by one minor unit, enabling the
  // Close bill button locally but making the server correctly reject the bill.
  final rateScaled = (major * 1000000) + fraction;
  if (rateScaled <= 0) return null;
  final tenderedScale = _minorScale(
    currencyDecimalDigits(tenderedCurrencyCode),
  );
  final baseScale = _minorScale(currencyDecimalDigits(baseCurrencyCode));
  final numerator = tenderedMinor * rateScaled * baseScale;
  final denominator = tenderedScale * 1000000;
  final result = (numerator + (denominator ~/ 2)) ~/ denominator;
  return result > 0 && result <= 100000000 ? result : null;
}

int _minorScale(int decimalDigits) {
  var result = 1;
  for (var index = 0; index < decimalDigits; index++) {
    result *= 10;
  }
  return result;
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

Future<bool> _ensureOrderLocation(BuildContext context, WidgetRef ref) async {
  // Demo mode has no venue-backed table or named-tab registry.
  if (ref.read(activeVenueScopeProvider) == null) return true;
  final order = ref.read(activeOrderProvider);
  if (order.tableId != null || order.tabName?.trim().isNotEmpty == true) {
    return true;
  }
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _OrderLocationDialog(),
      ) ??
      false;
}

class _OrderLocationDialog extends ConsumerStatefulWidget {
  const _OrderLocationDialog();

  @override
  ConsumerState<_OrderLocationDialog> createState() =>
      _OrderLocationDialogState();
}

class _OrderLocationDialogState extends ConsumerState<_OrderLocationDialog> {
  final _tabName = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _tabName.dispose();
    super.dispose();
  }

  Future<void> _selectTable(DiningTable table) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(activeOrderProvider.notifier).openTable(table.id);
      ref.read(selectedTableProvider.notifier).select(table.id);
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (error, stackTrace) {
      AppLogger.error('Choose table for new order', error, stackTrace);
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openNamedTab() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(activeOrderProvider.notifier).openNamedTab(_tabName.text);
      ref.read(selectedTableProvider.notifier).select('');
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (error, stackTrace) {
      AppLogger.error('Open named tab for new order', error, stackTrace);
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tables = ref.watch(diningTablesProvider).when(
          data: (items) => items,
          loading: () => const <DiningTable>[],
          error: (error, stackTrace) {
            AppLogger.error('Load tables for new order', error, stackTrace);
            return const <DiningTable>[];
          },
        );
    final tablesLoading = ref.watch(diningTablesProvider).isLoading;
    return AlertDialog(
      icon: const Icon(Icons.receipt_long_outlined),
      title: const Text('Start this order'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Choose the table, or open a named customer tab first.'),
            const SizedBox(height: 12),
            if (_error != null) ...[
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 8),
            ],
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 230),
              child: tablesLoading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: tables.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final table = tables[index];
                        return ListTile(
                          enabled: !_saving,
                          leading: const Icon(Icons.table_restaurant_rounded),
                          title: Text(table.label),
                          subtitle: Text('${table.seats} seats'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => _selectTable(table),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _tabName,
              enabled: !_saving,
              maxLength: 80,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Or open a named tab',
                hintText: 'For example, John N',
              ),
              onSubmitted: (_) {
                if (!_saving) _openNamedTab();
              },
            ),
            FilledButton.icon(
              onPressed: _saving ? null : _openNamedTab,
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: const Text('Open named tab'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

Future<void> _showNamedTabDialog(BuildContext context, WidgetRef ref) async {
  final nameController = TextEditingController();
  await showDialog<void>(
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

Future<void> _showSplitBillSheet(
  BuildContext pageContext, {
  required WidgetRef ref,
  required PosOrder order,
  required String currencyCode,
}) async {
  final selectedQuantities = <String, int>{
    for (final line in order.lines) line.id: 0,
  };
  var saving = false;
  await showModalBottomSheet<void>(
    context: pageContext,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (context, setSheetState) {
        final selectedQuantity = selectedQuantities.values.fold<int>(
          0,
          (total, quantity) => total + quantity,
        );
        final totalQuantity = order.lines.fold<int>(
          0,
          (total, line) => total + line.quantity,
        );
        final splitTotal = order.lines.fold<int>(0, (total, line) {
          return total +
              (selectedQuantities[line.id] ?? 0) * line.unitPriceMinor;
        });
        final canSplit =
            !saving && selectedQuantity > 0 && selectedQuantity < totalQuantity;

        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              0,
              20,
              20 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Create a separate bill',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Move the items one guest will pay for. The food has already been sent, so this does not print another kitchen or bar ticket.',
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      OutlinedButton.icon(
                        onPressed: saving
                            ? null
                            : () => setSheetState(() {
                                var remainingToSelect = totalQuantity ~/ 2;
                                for (final line in order.lines) {
                                  final selected = remainingToSelect
                                      .clamp(0, line.quantity)
                                      .toInt();
                                  selectedQuantities[line.id] = selected;
                                  remainingToSelect -= selected;
                                }
                              }),
                        icon: const Icon(Icons.balance_rounded),
                        label: const Text('Select half of items'),
                      ),
                      TextButton(
                        onPressed: saving
                            ? null
                            : () => setSheetState(() {
                                for (final line in order.lines) {
                                  selectedQuantities[line.id] = 0;
                                }
                              }),
                        child: const Text('Clear'),
                      ),
                    ],
                  ),
                  const Divider(height: 22),
                  Expanded(
                    child: ListView.separated(
                      itemCount: order.lines.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final line = order.lines[index];
                        final selected = selectedQuantities[line.id] ?? 0;
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(line.productName),
                          subtitle: Text(
                            '${line.quantity} available · ${formatMoney(line.unitPriceMinor, currencyCode: currencyCode)} each',
                          ),
                          trailing: SizedBox(
                            width: 140,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                IconButton(
                                  tooltip: 'Remove from split',
                                  onPressed: saving || selected == 0
                                      ? null
                                      : () => setSheetState(
                                          () => selectedQuantities[line.id] =
                                              selected - 1,
                                        ),
                                  icon: const Icon(Icons.remove_circle_outline),
                                ),
                                SizedBox(
                                  width: 24,
                                  child: Text(
                                    '$selected',
                                    textAlign: TextAlign.center,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleSmall,
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Add to split',
                                  onPressed: saving || selected >= line.quantity
                                      ? null
                                      : () => setSheetState(
                                          () => selectedQuantities[line.id] =
                                              selected + 1,
                                        ),
                                  icon: const Icon(Icons.add_circle_outline),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const Divider(height: 22),
                  Row(
                    children: [
                      const Text('Separate bill total'),
                      const Spacer(),
                      Text(
                        formatMoney(splitTotal, currencyCode: currencyCode),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: !canSplit
                          ? null
                          : () async {
                              setSheetState(() => saving = true);
                              try {
                                final result = await ref
                                    .read(activeOrderProvider.notifier)
                                    .splitBillByItems(selectedQuantities);
                                if (!sheetContext.mounted) return;
                                Navigator.pop(sheetContext);
                                if (!pageContext.mounted) return;
                                showAppNotification(
                                  pageContext,
                                  ref: ref,
                                  title: 'Separate bill ready',
                                  message:
                                      '${formatMoney(result.splitTotalMinor, currencyCode: currencyCode)} is ready for payment. The remaining items stay on the main table bill.',
                                  level: AppNotificationLevel.success,
                                );
                              } on Object catch (error, stackTrace) {
                                AppLogger.error(
                                  'Create separate bill',
                                  error,
                                  stackTrace,
                                );
                                if (!sheetContext.mounted) return;
                                setSheetState(() => saving = false);
                                showAppNotification(
                                  sheetContext,
                                  ref: ref,
                                  title: 'Could not split this bill',
                                  message: '$error',
                                  level: AppNotificationLevel.error,
                                );
                              }
                            },
                      icon: saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.call_split_rounded),
                      label: Text(
                        saving
                            ? 'Creating separate bill…'
                            : 'Create separate bill',
                      ),
                    ),
                  ),
                  if (selectedQuantity == totalQuantity) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'Use Pay to settle every item on this table; a split must leave items on the main bill.',
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}
