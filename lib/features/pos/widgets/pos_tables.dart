part of '../pos_page.dart';

class _TablesPanel extends ConsumerWidget {
  const _TablesPanel({
    required this.currencyCode,
    this.compact = false,
    this.expanded = false,
    this.onToggleExpanded,
    this.onSelection,
  });

  final String currencyCode;
  final bool compact;
  final bool expanded;
  final VoidCallback? onToggleExpanded;
  final VoidCallback? onSelection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedTableId = ref.watch(selectedTableProvider);
    final activeOrder = ref.watch(activeOrderProvider);
    final isTraining = ref.watch(trainingModeProvider) != null;
    final trainingOrders = isTraining
        ? ref.watch(trainingOpenOrdersProvider).values.toList(growable: false)
        : const <PosOrder>[];
    final scope = ref.watch(activeVenueScopeProvider);
    final tables = ref
        .watch(diningTablesProvider)
        .when(
          data: (items) => items,
          loading: () => scope == null ? demoTables : const [],
          error: (_, _) => scope == null ? demoTables : const [],
        );
    final namedTabs = isTraining
        ? [
            for (final order in trainingOrders)
              if (order.tabName?.trim().isNotEmpty == true)
                OpenNamedTab(
                  id: order.id,
                  orderId: order.id,
                  name: order.tabName!.trim(),
                  openedAt: order.openedAt,
                ),
          ]
        : ref
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
    final fulfilmentOrders = isTraining
        ? trainingOrders
              .where((order) => order.channel != OrderChannel.dineIn)
              .toList(growable: false)
        : ref
                  .watch(fulfilmentOrdersProvider)
                  .value
                  ?.where((order) => order.status != OrderStatus.closed)
                  .toList(growable: false) ??
              const <PosOrder>[];
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final content = Column(
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
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (onToggleExpanded != null)
                          IconButton(
                            tooltip: expanded
                                ? 'Return to POS'
                                : 'Show all tables and tabs',
                            onPressed: onToggleExpanded,
                            icon: Icon(
                              expanded
                                  ? Icons.fullscreen_exit_rounded
                                  : Icons.fullscreen_rounded,
                            ),
                          ),
                        TextButton.icon(
                          onPressed: () => _showNamedTabDialog(context, ref),
                          icon: const Icon(Icons.person_add_alt_1_rounded),
                          label: const Text('Named tab'),
                        ),
                        if (constraints.maxWidth < 600)
                          SizedBox(
                            width: constraints.maxWidth,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: () => _showFulfilmentOrderDialog(
                                    context,
                                    OrderChannel.collection,
                                    onStarted: onSelection,
                                  ),
                                  icon: const Icon(Icons.shopping_bag_outlined),
                                  label: const Text('Collection'),
                                ),
                                const SizedBox(height: 6),
                                OutlinedButton.icon(
                                  onPressed: () => _showFulfilmentOrderDialog(
                                    context,
                                    OrderChannel.delivery,
                                    onStarted: onSelection,
                                  ),
                                  icon: const Icon(
                                    Icons.delivery_dining_outlined,
                                  ),
                                  label: const Text('Delivery'),
                                ),
                              ],
                            ),
                          )
                        else ...[
                          OutlinedButton.icon(
                            onPressed: () => _showFulfilmentOrderDialog(
                              context,
                              OrderChannel.collection,
                              onStarted: onSelection,
                            ),
                            icon: const Icon(Icons.shopping_bag_outlined),
                            label: const Text('Collection'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => _showFulfilmentOrderDialog(
                              context,
                              OrderChannel.delivery,
                              onStarted: onSelection,
                            ),
                            icon: const Icon(Icons.delivery_dining_outlined),
                            label: const Text('Delivery'),
                          ),
                        ],
                      ],
                    ),
                  ],
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
                                  compact: compact || !expanded,
                                  isTraining: isTraining,
                                  trainingOrder: isTraining
                                      ? trainingOrders
                                            .where(
                                              (order) =>
                                                  order.tableId == table.id,
                                            )
                                            .firstOrNull
                                      : null,
                                  onTap: () async {
                                    try {
                                      await ref
                                          .read(activeOrderProvider.notifier)
                                          .openTable(table.id);
                                      ref
                                          .read(selectedTableProvider.notifier)
                                          .select(table.id);
                                      if (context.mounted) onSelection?.call();
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
                                  onDeselect: selectedTableId == table.id
                                      ? () => ref
                                            .read(activeOrderProvider.notifier)
                                            .clearCurrentSelection()
                                      : null,
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
                                padding: const EdgeInsets.only(
                                  top: 6,
                                  bottom: 6,
                                ),
                                child: Text(
                                  _namedTabDateLabel(group.openedDate),
                                  style: Theme.of(
                                    context,
                                  ).textTheme.labelMedium,
                                ),
                              ),
                              _CategoryTilePanel(
                                children: [
                                  for (final tab in group.tabs)
                                    SizedBox(
                                      width: compact
                                          ? 118
                                          : expanded
                                          ? 180
                                          : 132,
                                      child: _NamedTabButton(
                                        tab: tab,
                                        scope: scope,
                                        currencyCode: currencyCode,
                                        selected: tab.orderId == activeOrder.id,
                                        onTap: () async {
                                          try {
                                            ref
                                                .read(
                                                  activeOrderProvider.notifier,
                                                )
                                                .openExistingNamedTab(tab);
                                            ref
                                                .read(
                                                  selectedTableProvider
                                                      .notifier,
                                                )
                                                .select('');
                                            if (context.mounted) {
                                              onSelection?.call();
                                            }
                                          } on Object catch (
                                            error,
                                            stackTrace
                                          ) {
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
                                        onDeselect:
                                            tab.orderId == activeOrder.id
                                            ? () => ref
                                                  .read(
                                                    activeOrderProvider
                                                        .notifier,
                                                  )
                                                  .clearCurrentSelection()
                                            : null,
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ],
                          if (fulfilmentOrders.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            if (compact)
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  for (final channel in const [
                                    OrderChannel.collection,
                                    OrderChannel.delivery,
                                  ]) ...[
                                    if (channel != OrderChannel.collection)
                                      const SizedBox(width: 8),
                                    Expanded(
                                      child: _FulfilmentOrderGroup(
                                        channel: channel,
                                        orders: fulfilmentOrders,
                                        scope: scope,
                                        currencyCode: currencyCode,
                                        activeOrderId: activeOrder.id,
                                        tileWidth: 118,
                                        onSelection: onSelection,
                                      ),
                                    ),
                                  ],
                                ],
                              )
                            else
                              for (final channel in const [
                                OrderChannel.collection,
                                OrderChannel.delivery,
                              ]) ...[
                                if (channel != OrderChannel.collection)
                                  const SizedBox(height: 16),
                                _FulfilmentOrderGroup(
                                  channel: channel,
                                  orders: fulfilmentOrders,
                                  scope: scope,
                                  currencyCode: currencyCode,
                                  activeOrderId: activeOrder.id,
                                  tileWidth: expanded ? 180 : 132,
                                  onSelection: onSelection,
                                ),
                              ],
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
            // TabBarView lays out inactive tabs too. When an amount/name
            // keyboard opens, the viewport can become shorter than this
            // panel's fixed header even while the Order tab is visible. Give
            // the panel a scrollable minimum canvas so it cannot overflow and
            // trigger repeated InputBorder paint assertions.
            if (constraints.maxHeight >= 260) return content;
            return SingleChildScrollView(
              child: SizedBox(height: 260, child: content),
            );
          },
        ),
      ),
    );
  }
}

/// Keeps collection and delivery work visible as two predictable columns on
/// compact/tablet layouts. Each column owns its own wrapping tile grid, so a
/// busy collection list cannot push deliveries below the visible viewport.
class _FulfilmentOrderGroup extends ConsumerWidget {
  const _FulfilmentOrderGroup({
    required this.channel,
    required this.orders,
    required this.scope,
    required this.currencyCode,
    required this.activeOrderId,
    required this.tileWidth,
    this.onSelection,
  });

  final OrderChannel channel;
  final List<PosOrder> orders;
  final VenueScope? scope;
  final String currencyCode;
  final String activeOrderId;
  final double tileWidth;
  final VoidCallback? onSelection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final matching = orders
        .where((order) => order.channel == channel)
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          channel == OrderChannel.collection ? 'Collections' : 'Deliveries',
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 8),
        if (matching.isEmpty)
          Text('None open', style: Theme.of(context).textTheme.bodySmall)
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final order in matching)
                SizedBox(
                  width: tileWidth,
                  child: _FulfilmentOrderButton(
                    order: order,
                    scope: scope,
                    currencyCode: currencyCode,
                    selected: order.id == activeOrderId,
                    onTap: () {
                      try {
                        ref
                            .read(activeOrderProvider.notifier)
                            .openFulfilmentOrder(order);
                        if (context.mounted) onSelection?.call();
                      } on Object catch (error, stackTrace) {
                        AppLogger.error(
                          'Open fulfilment order',
                          error,
                          stackTrace,
                        );
                        if (!context.mounted) return;
                        showAppNotification(
                          context,
                          ref: ref,
                          title: 'Could not open order',
                          message: '$error',
                          level: AppNotificationLevel.error,
                        );
                      }
                    },
                    onDeselect: order.id == activeOrderId
                        ? () => ref
                              .read(activeOrderProvider.notifier)
                              .clearCurrentSelection()
                        : null,
                  ),
                ),
            ],
          ),
      ],
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
    required this.isTraining,
    this.trainingOrder,
    required this.onTap,
    this.onDeselect,
  });

  final DiningTable table;
  final VenueScope? scope;
  final String currencyCode;
  final bool selected;
  final bool compact;
  final bool isTraining;
  final PosOrder? trainingOrder;
  final VoidCallback onTap;
  final VoidCallback? onDeselect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final openOrderValue =
        isTraining || scope == null || table.currentOrderId == null
        ? null
        : ref.watch(tableOpenOrderProvider(table.currentOrderId!));
    final openOrder = isTraining
        ? trainingOrder
        : openOrderValue?.when(
            data: (order) => order,
            loading: () => null,
            error: (_, _) => null,
          );
    final amountDueMinor = openOrder?.balanceDueMinor;
    final needsAttention = openOrder?.hasPendingProductionLines == true;
    final isOpen = isTraining ? trainingOrder != null : table.hasOpenOrder;
    final openGreen = Theme.of(context).brightness == Brightness.dark
        ? Colors.green.shade700
        : Colors.green.shade600;
    // Blue always means selected. Green means open but not selected.
    final background = selected
        ? scheme.primary
        : isOpen
        ? openGreen
        : scheme.surfaceContainerHighest;
    final foreground = isOpen || selected ? Colors.white : scheme.onSurface;
    final titleColor = needsAttention ? Colors.orangeAccent : foreground;
    final width = compact ? 72.0 : 104.0;
    return Semantics(
      button: true,
      selected: selected,
      label: isOpen
          ? 'Table ${table.label}, open${needsAttention ? ', pending items not sent' : ''}, ${amountDueMinor == null ? 'amount loading' : formatMoney(amountDueMinor, currencyCode: currencyCode)} owed'
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
            border: selected ? Border.all(color: Colors.white, width: 2) : null,
          ),
          child: Stack(
            children: [
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      table.label,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: titleColor,
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
              if (onDeselect != null)
                Positioned(
                  top: 0,
                  right: 0,
                  child: IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Deselect table',
                    onPressed: onDeselect,
                    icon: const Icon(Icons.close_rounded, size: 17),
                    color: Colors.white,
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
    this.onDeselect,
  });

  final OpenNamedTab tab;
  final VenueScope? scope;
  final String currencyCode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onDeselect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trainingOrder = ref.watch(trainingModeProvider) == null
        ? null
        : ref.watch(trainingOpenOrdersProvider)[tab.orderId];
    final liveOrder =
        trainingOrder ??
        (scope == null
            ? null
            : ref
                  .watch(tableOpenOrderProvider(tab.orderId))
                  .when(
                    data: (order) => order,
                    loading: () => null,
                    error: (_, _) => null,
                  ));
    final totalMinor = liveOrder?.balanceDueMinor;
    final needsAttention = liveOrder?.hasPendingProductionLines == true;
    // Every item here represents a live named tab. Make that operational
    // state as obvious as an open table, not merely the currently selected
    // tab.
    final background = selected
        ? Theme.of(context).colorScheme.primary
        : Colors.green.shade600;
    final foreground = Colors.white;
    return Semantics(
      button: true,
      selected: selected,
      label:
          'Open tab for ${tab.name}${needsAttention ? ', pending items not sent' : ''}${totalMinor == null ? '' : ', ${formatMoney(totalMinor, currencyCode: currencyCode)} owed'}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(12),
            border: selected ? Border.all(color: Colors.white, width: 2) : null,
          ),
          child: Row(
            children: [
              Icon(Icons.person_outline_rounded, size: 18, color: foreground),
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
                        color: needsAttention
                            ? Colors.orangeAccent
                            : foreground,
                      ),
                    ),
                    if (totalMinor != null)
                      Text(
                        formatMoney(totalMinor, currencyCode: currencyCode),
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: foreground.withValues(alpha: .88),
                            ),
                      ),
                  ],
                ),
              ),
              if (onDeselect != null)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Deselect named tab',
                  onPressed: onDeselect,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  color: Colors.white,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FulfilmentOrderButton extends ConsumerWidget {
  const _FulfilmentOrderButton({
    required this.order,
    required this.scope,
    required this.currencyCode,
    required this.selected,
    required this.onTap,
    this.onDeselect,
  });

  final PosOrder order;
  final VenueScope? scope;
  final String currencyCode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onDeselect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final liveOrder = scope == null
        ? null
        : ref.watch(tableOpenOrderProvider(order.id)).value;
    final displayedOrder = liveOrder ?? order;
    final amount = displayedOrder.balanceDueMinor;
    final needsAttention = displayedOrder.hasPendingProductionLines;
    final scheduled = order.scheduledFor;
    final background = selected
        ? Theme.of(context).colorScheme.primary
        : Colors.green.shade600;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(12),
          border: selected ? Border.all(color: Colors.white, width: 2) : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  order.channel == OrderChannel.delivery
                      ? Icons.delivery_dining_rounded
                      : Icons.shopping_bag_rounded,
                  size: 18,
                  color: Colors.white,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    order.customerName ?? 'Customer',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700)
                        .copyWith(
                          color: needsAttention
                              ? Colors.orangeAccent
                              : Colors.white,
                        ),
                  ),
                ),
                if (onDeselect != null)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Deselect order',
                    onPressed: onDeselect,
                    icon: const Icon(Icons.close_rounded, size: 18),
                    color: Colors.white,
                  ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              scheduled == null
                  ? 'ASAP · ${formatMoney(amount, currencyCode: currencyCode)}'
                  : '${scheduled.hour.toString().padLeft(2, '0')}:${scheduled.minute.toString().padLeft(2, '0')} · ${formatMoney(amount, currencyCode: currencyCode)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
          ],
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

String _namedTabDateLabel(DateTime? date) {
  if (date == null) return 'Earlier tabs';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  if (date == today) return 'Today';
  if (date == today.subtract(const Duration(days: 1))) return 'Yesterday';
  return formatAppDate(date);
}
