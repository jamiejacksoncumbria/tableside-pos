part of '../pos_page.dart';

class _OrderPanel extends ConsumerStatefulWidget {
  const _OrderPanel({required this.currencyCode});

  final String currencyCode;

  @override
  ConsumerState<_OrderPanel> createState() => _OrderPanelState();
}

class _OrderPanelState extends ConsumerState<_OrderPanel> {
  final _lineScrollController = ScrollController();
  final Set<String> _selectedLineIds = {};
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

  Future<void> _closeEmptyOrder() async {
    final reason = TextEditingController(text: 'All items removed');
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Close empty order?'),
        content: TextField(
          controller: reason,
          autofocus: true,
          maxLength: 240,
          decoration: const InputDecoration(
            labelText: 'Reason',
            helperText: 'Required and saved in the audit trail.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep open'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Close order'),
          ),
        ],
      ),
    );
    final cancellationReason = reason.text.trim();
    reason.dispose();
    if (confirmed != true || !mounted) return;
    if (cancellationReason.length < 3) {
      showAppNotification(
        context,
        ref: ref,
        title: 'Order remains open',
        message: 'Enter a short reason for closing the empty order.',
        level: AppNotificationLevel.warning,
      );
      return;
    }
    try {
      await ref
          .read(activeOrderProvider.notifier)
          .cancelEmptyOrder(reason: cancellationReason);
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Empty order closed',
        message: 'The table or tab is available again.',
        level: AppNotificationLevel.success,
      );
      ref.read(posCompactTabProvider.notifier).select(0);
    } on Object catch (error, stackTrace) {
      AppLogger.error('Close empty order', error, stackTrace);
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Order remains open',
        message: '$error',
        level: AppNotificationLevel.error,
      );
    }
  }

  Future<void> _adjustLine(OrderLine line, String operation) async {
    final reason = TextEditingController();
    final value = TextEditingController(
      text: operation == 'setUnitPrice'
          ? _moneyInputFromMinor(line.unitPriceMinor, widget.currencyCode)
          : '',
    );
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(switch (operation) {
          'remove' => 'Remove ${line.productName}',
          'setUnitPrice' => 'Change item price',
          'discountPercent' => 'Discount item by percentage',
          _ => 'Discount item by amount',
        }),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (operation != 'remove')
              TextField(
                controller: value,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: operation == 'setUnitPrice'
                      ? 'New price per item (${widget.currencyCode})'
                      : operation == 'discountPercent'
                      ? 'Percentage discount'
                      : 'Discount per item (${widget.currencyCode})',
                  suffixText: operation == 'discountPercent' ? '%' : null,
                ),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: reason,
              maxLength: 240,
              decoration: const InputDecoration(
                labelText: 'Reason',
                helperText: 'Required and saved in the audit trail.',
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
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      reason.dispose();
      value.dispose();
      return;
    }
    var serverOperation = operation;
    final parsedValue = operation == 'remove'
        ? null
        : value.text.trim() == '0'
        ? 0
        : _minorFromMoneyInput(value.text, widget.currencyCode);
    int? valueMinor = parsedValue;
    if (operation == 'discountPercent') {
      final percentage = double.tryParse(
        value.text.trim().replaceAll(',', '.'),
      );
      if (percentage != null && percentage > 0 && percentage <= 100) {
        valueMinor = (line.unitPriceMinor * (100 - percentage) / 100).round();
        serverOperation = 'setUnitPrice';
      } else {
        valueMinor = null;
      }
    }
    if (reason.text.trim().isEmpty ||
        (operation != 'remove' && valueMinor == null)) {
      showAppNotification(
        context,
        ref: ref,
        title: 'Adjustment not saved',
        message: 'Enter a valid amount and a reason.',
        level: AppNotificationLevel.error,
      );
      reason.dispose();
      value.dispose();
      return;
    }
    try {
      await ref
          .read(activeOrderProvider.notifier)
          .managerAdjustLine(
            lineId: line.id,
            operation: serverOperation,
            reason: reason.text.trim(),
            valueMinor: valueMinor,
          );
    } catch (error, stackTrace) {
      AppLogger.error('Manager sale item adjustment', error, stackTrace);
      if (mounted) {
        showAppNotification(
          context,
          ref: ref,
          title: 'Adjustment failed',
          message: '$error',
          level: AppNotificationLevel.error,
        );
      }
    } finally {
      reason.dispose();
      value.dispose();
    }
  }

  Future<void> _bulkAdjust(String operation, PosOrder order) async {
    final selected = order.lines
        .where((line) => _selectedLineIds.contains(line.id))
        .toList();
    if (selected.isEmpty) return;
    if (operation == 'remove' && selected.length == order.lines.length) {
      showAppNotification(
        context,
        ref: ref,
        title: 'Keep one item',
        message:
            'Cancel the whole order separately rather than removing every item in bulk.',
        level: AppNotificationLevel.warning,
      );
      return;
    }
    final value = TextEditingController();
    final reason = TextEditingController();
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          operation == 'remove'
              ? 'Remove ${selected.length} items'
              : 'Discount ${selected.length} items',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (operation != 'remove')
              TextField(
                controller: value,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: operation == 'discountPercent'
                      ? 'Percentage discount'
                      : 'Discount per item',
                  suffixText: operation == 'discountPercent'
                      ? '%'
                      : widget.currencyCode,
                ),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: reason,
              maxLength: 240,
              decoration: const InputDecoration(
                labelText: 'Reason',
                helperText: 'Required for the audit trail.',
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
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      value.dispose();
      reason.dispose();
      return;
    }
    final percentage = operation == 'discountPercent'
        ? double.tryParse(value.text.trim().replaceAll(',', '.'))
        : null;
    final fixedMinor = operation == 'discountUnitAmount'
        ? _minorFromMoneyInput(value.text, widget.currencyCode)
        : null;
    if (reason.text.trim().isEmpty ||
        (operation == 'discountPercent' &&
            (percentage == null || percentage <= 0 || percentage > 100)) ||
        (operation == 'discountUnitAmount' && fixedMinor == null)) {
      showAppNotification(
        context,
        ref: ref,
        title: 'Bulk change not saved',
        message: 'Enter a valid discount and reason.',
        level: AppNotificationLevel.error,
      );
      value.dispose();
      reason.dispose();
      return;
    }
    var completed = 0;
    try {
      for (final line in selected) {
        await ref
            .read(activeOrderProvider.notifier)
            .managerAdjustLine(
              lineId: line.id,
              operation: operation == 'discountPercent'
                  ? 'setUnitPrice'
                  : operation,
              reason: reason.text.trim(),
              valueMinor: operation == 'discountPercent'
                  ? (line.unitPriceMinor * (100 - percentage!) / 100).round()
                  : fixedMinor,
            );
        completed++;
      }
      if (mounted) setState(_selectedLineIds.clear);
    } catch (error, stackTrace) {
      AppLogger.error('Bulk manager sale adjustment', error, stackTrace);
      if (mounted) {
        showAppNotification(
          context,
          ref: ref,
          title: 'Bulk change partly completed',
          message: '$completed of ${selected.length} items changed. $error',
          level: AppNotificationLevel.error,
        );
      }
    } finally {
      value.dispose();
      reason.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = ref.watch(activeOrderProvider);
    final trainingSession = ref.watch(trainingModeProvider);
    final isTraining = trainingSession != null;
    final persistedOrderId = ref.watch(activePersistedOrderIdProvider);
    final canCloseEmptyOrder =
        order.lines.isEmpty &&
        order.payments.isEmpty &&
        persistedOrderId == order.id;
    final currentLineIds = order.lines.map((line) => line.id).toSet();
    _selectedLineIds.removeWhere((id) => !currentLineIds.contains(id));
    final splitOrdersValue = order.isSplitOrder || isTraining
        ? null
        : ref.watch(openSplitOrdersProvider(order.id));
    final openSplitOrders = isTraining && !order.isSplitOrder
        ? ref
              .watch(trainingOpenOrdersProvider)
              .values
              .where((item) => item.splitFromOrderId == order.id)
              .toList(growable: false)
        : splitOrdersValue?.when(
                data: (orders) => orders,
                loading: () => const <PosOrder>[],
                error: (error, stackTrace) {
                  AppLogger.error(
                    'Display open split bills',
                    error,
                    stackTrace,
                  );
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
    final orderLocationLabel = order.channel == OrderChannel.collection
        ? 'Collection · ${order.customerName ?? 'Customer'}'
        : order.channel == OrderChannel.delivery
        ? 'Delivery · ${order.customerName ?? 'Customer'}'
        : order.tabName ??
              (tableLabel.isEmpty ? 'No table selected' : tableLabel);
    final scheme = Theme.of(context).colorScheme;
    final orderTitleColor = hasUnsentLines
        ? (Theme.of(context).brightness == Brightness.dark
              ? Colors.orangeAccent
              : Colors.orange.shade800)
        : null;
    final staff = ref.watch(activeStaffPinSessionProvider);
    final canAdjustSale =
        staff?.roles.any((role) => role == 'owner' || role == 'manager') ??
        false;
    final compactOutlinedButtonStyle = OutlinedButton.styleFrom(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      minimumSize: const Size(0, 32),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      textStyle: Theme.of(context).textTheme.labelMedium,
    );
    final compactFilledButtonStyle = FilledButton.styleFrom(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      minimumSize: const Size(0, 32),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      textStyle: Theme.of(context).textTheme.labelMedium,
    );
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        // Keep the order controls usable on medium-height tablets. The line
        // list remains the flexible region, while compact vertical spacing
        // prevents the fixed totals and action controls overflowing below it.
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    orderLocationLabel,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.titleMedium?.copyWith(color: orderTitleColor),
                  ),
                ),
                const SizedBox(width: 8),
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
            if (order.channel != OrderChannel.dineIn)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  order.scheduledFor == null
                      ? '${order.channel.label} time: ASAP'
                      : '${order.channel.label} time: ${formatAppDateTime(order.scheduledFor!)}',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            if (order.channel == OrderChannel.delivery &&
                order.deliveryAddress?.trim().isNotEmpty == true)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${order.deliveryAddressLabel?.trim().isNotEmpty == true ? '${order.deliveryAddressLabel}: ' : ''}${order.deliveryAddress}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
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
                              'Bill ${splitOrder.splitSequence ?? ''} · ${formatMoney(splitOrder.balanceDueMinor, currencyCode: widget.currencyCode)} due',
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
            const Divider(height: 16),
            if (_selectedLineIds.isNotEmpty && canAdjustSale) ...[
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '${_selectedLineIds.length} selected',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _bulkAdjust('discountPercent', order),
                    icon: const Icon(Icons.percent_rounded),
                    label: const Text('Percentage'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _bulkAdjust('discountUnitAmount', order),
                    icon: const Icon(Icons.discount_outlined),
                    label: const Text('Amount'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _bulkAdjust('remove', order),
                    icon: const Icon(Icons.remove_shopping_cart_outlined),
                    label: const Text('Remove'),
                  ),
                  IconButton(
                    tooltip: 'Clear selection',
                    onPressed: () => setState(_selectedLineIds.clear),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            Expanded(
              flex: 3,
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
                          final selected = _selectedLineIds.contains(line.id);
                          return InkWell(
                            onLongPress: canAdjustSale
                                ? () => setState(() {
                                    selected
                                        ? _selectedLineIds.remove(line.id)
                                        : _selectedLineIds.add(line.id);
                                  })
                                : null,
                            child: ColoredBox(
                              color: selected
                                  ? scheme.secondaryContainer
                                  : Colors.transparent,
                              child: Row(
                                children: [
                                  if (_selectedLineIds.isNotEmpty &&
                                      canAdjustSale)
                                    Checkbox(
                                      value: selected,
                                      onChanged: (_) => setState(() {
                                        selected
                                            ? _selectedLineIds.remove(line.id)
                                            : _selectedLineIds.add(line.id);
                                      }),
                                    ),
                                  IconButton.filledTonal(
                                    tooltip: 'Remove one ${line.productName}',
                                    onPressed: line.isSentToProduction
                                        ? null
                                        : () async {
                                            try {
                                              await ref
                                                  .read(
                                                    activeOrderProvider
                                                        .notifier,
                                                  )
                                                  .reduceLine(line.id);
                                            } on Object catch (
                                              error,
                                              stackTrace
                                            ) {
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
                                                level:
                                                    AppNotificationLevel.error,
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
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
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
                                        if (line.addedLocalDateTime
                                                ?.trim()
                                                .isNotEmpty ==
                                            true)
                                          Text(
                                            'Added ${formatVenueDateTimeSnapshot(line.addedLocalDateTime!)}',
                                            style: Theme.of(
                                              context,
                                            ).textTheme.labelSmall,
                                          )
                                        else if (line.addedAt != null)
                                          Text(
                                            'Added ${formatAppDateTime(line.addedAt!)}',
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
                                  if (canAdjustSale)
                                    PopupMenuButton<String>(
                                      tooltip: 'Manager item actions',
                                      onSelected: (operation) =>
                                          _adjustLine(line, operation),
                                      itemBuilder: (_) => const [
                                        PopupMenuItem(
                                          value: 'discountUnitAmount',
                                          child: Text('Discount by amount'),
                                        ),
                                        PopupMenuItem(
                                          value: 'discountPercent',
                                          child: Text('Discount by percentage'),
                                        ),
                                        PopupMenuItem(
                                          value: 'setUnitPrice',
                                          child: Text('Change item price'),
                                        ),
                                        PopupMenuItem(
                                          value: 'remove',
                                          child: Text('Remove from sale'),
                                        ),
                                      ],
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
            ),
            // Tablets and desktop tills pin totals/actions below the list, so
            // staff never have to scroll past order items to reach payment or
            // sending controls. Phones retain the safe scroll fallback.
            _AdaptiveOrderFooter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (order.channel == OrderChannel.delivery &&
                      order.deliveryFeeMinor > 0) ...[
                    const Divider(height: 20),
                    Row(
                      children: [
                        Text(
                          order.serviceAreaName?.trim().isNotEmpty == true
                              ? 'Delivery · ${order.serviceAreaName}'
                              : 'Delivery fee',
                        ),
                        const Spacer(),
                        Text(
                          formatMoney(
                            order.deliveryFeeMinor,
                            currencyCode: widget.currencyCode,
                          ),
                        ),
                      ],
                    ),
                  ],
                  const Divider(height: 16),
                  Row(
                    children: [
                      Text(
                        'Total',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      Text(
                        formatMoney(
                          order.totalMinor,
                          currencyCode: widget.currencyCode,
                        ),
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        key: const ValueKey('order-view-bill-button'),
                        onPressed: order.lines.isEmpty
                            ? null
                            : () => _showCheckoutBillPreview(
                                context,
                                order: order,
                                currencyCode: widget.currencyCode,
                                pendingPaymentMinor: 0,
                              ),
                        style: compactOutlinedButtonStyle,
                        icon: const Icon(Icons.list_alt_rounded, size: 17),
                        label: const Text('Items'),
                      ),
                    ],
                  ),
                  if (order.paidMinor > 0) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Text('Payments received'),
                        const Spacer(),
                        Text(
                          formatMoney(
                            order.paidMinor,
                            currencyCode: widget.currencyCode,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Text(
                          'Balance due',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const Spacer(),
                        Text(
                          formatMoney(
                            order.balanceDueMinor,
                            currencyCode: widget.currencyCode,
                          ),
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ],
                    ),
                    if (order.payments.length > 2)
                      Text(
                        '+ ${order.payments.length - 2} earlier payment${order.payments.length == 3 ? '' : 's'}',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    for (final payment in order.payments.skip(
                      order.payments.length > 2 ? order.payments.length - 2 : 0,
                    ))
                      Text(
                        '${payment.recordedLocalDateTime?.trim().isNotEmpty == true ? formatVenueDateTimeSnapshot(payment.recordedLocalDateTime!) : formatAppDateTime(payment.recordedAt)} · ${payment.method} · ${formatMoney(payment.tenderedAmountMinor, currencyCode: payment.tenderedCurrencyCode)}',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                  ],
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: compactOutlinedButtonStyle,
                          onPressed:
                              order.isSplitOrder ||
                                  order.payments.isNotEmpty ||
                                  order.lines.isEmpty ||
                                  hasUnsentLines
                              ? null
                              : () => _showSplitBillSheet(
                                  context,
                                  ref: ref,
                                  order: order,
                                  currencyCode: widget.currencyCode,
                                ),
                          icon: const Icon(Icons.call_split_rounded, size: 17),
                          label: const Text('Split bill'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          style: compactOutlinedButtonStyle,
                          onPressed: hasUnsentLines
                              ? () => _showPendingOrderItems(
                                  context,
                                  order: order,
                                  currencyCode: widget.currencyCode,
                                )
                              : null,
                          icon: const Icon(
                            Icons.pending_actions_rounded,
                            size: 17,
                          ),
                          label: Text(
                            'Pending (${order.lines.where((line) => !line.isSentToProduction).fold<int>(0, (total, line) => total + line.quantity)})',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: compactOutlinedButtonStyle,
                          onPressed:
                              isTraining ||
                                  order.lines.isEmpty ||
                                  hasUnsentLines
                              ? null
                              : () async {
                                  try {
                                    final queued = await ref
                                        .read(activeOrderProvider.notifier)
                                        .printPreReceipt();
                                    if (!context.mounted) return;
                                    showAppNotification(
                                      context,
                                      ref: ref,
                                      title: queued
                                          ? 'Pre receipt queued'
                                          : 'Pre receipt not queued',
                                      message: queued
                                          ? 'The unpaid bill has been sent to the receipt printer.'
                                          : 'No receipt printer accepted the pre receipt.',
                                    );
                                  } on Object catch (error, stackTrace) {
                                    AppLogger.error(
                                      'Print pre receipt',
                                      error,
                                      stackTrace,
                                    );
                                    if (!context.mounted) return;
                                    showAppNotification(
                                      context,
                                      ref: ref,
                                      title: 'Pre receipt was not printed',
                                      message: '$error',
                                      level: AppNotificationLevel.error,
                                    );
                                  }
                                },
                          icon: const Icon(
                            Icons.receipt_long_outlined,
                            size: 17,
                          ),
                          label: const Text('Pre receipt'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          style: compactFilledButtonStyle,
                          onPressed:
                              order.lines.isEmpty ||
                                  hasUnsentLines ||
                                  (!order.isSplitOrder &&
                                      openSplitOrders.isNotEmpty)
                              ? null
                              : () => _showCheckoutSheet(
                                  context,
                                  ref: ref,
                                  order: order,
                                  currencyCode: widget.currencyCode,
                                ),
                          icon: const Icon(Icons.payments_outlined, size: 17),
                          label: const Text('Pay'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (canCloseEmptyOrder) ...[
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        style: compactOutlinedButtonStyle,
                        onPressed: _closeEmptyOrder,
                        icon: const Icon(Icons.cancel_outlined, size: 17),
                        label: const Text('Close empty order'),
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: compactFilledButtonStyle,
                      onPressed: !hasUnsentLines
                          ? null
                          : () async {
                              final printRequired =
                                  await _confirmProductionPrint(context);
                              if (printRequired == null || !context.mounted) {
                                return;
                              }
                              try {
                                final printResult = await ref
                                    .read(activeOrderProvider.notifier)
                                    .sendToProduction(
                                      printRequired: printRequired,
                                    );
                                if (!context.mounted) return;
                                final message = isTraining
                                    ? (printRequired &&
                                              trainingSession.targetDeviceId !=
                                                  null
                                          ? 'Training order saved and a clearly marked training ticket was queued.'
                                          : 'Training order saved without printing. No live order or stock was changed.')
                                    : !printRequired
                                    ? 'New items sent to the Order Flow Board without printing.'
                                    : printResult.ticketsPrinted > 0
                                    ? 'New items sent. ${printResult.ticketsPrinted} production ticket(s) printed.'
                                    : 'New items sent to the Order Flow Board. Enable production routing on this device to print tickets.';
                                showAppNotification(
                                  context,
                                  ref: ref,
                                  title: isTraining
                                      ? 'Training order sent'
                                      : 'Order sent',
                                  message: message,
                                  level: AppNotificationLevel.success,
                                );
                                ref
                                    .read(activeOrderProvider.notifier)
                                    .clearSelectionAfterSend();
                                ref
                                    .read(posCompactTabProvider.notifier)
                                    .select(0);
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
                      icon: const Icon(Icons.print_rounded, size: 17),
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
          ],
        ),
      ),
    );
  }
}

/// Keeps the order controls permanently visible where the display has enough
/// room, while retaining a scrollable safety fallback on compact phones.
///
/// The order-line list above this footer is already an [Expanded] [ListView],
/// so tablet and desktop tills scroll only the items rather than moving the
/// payment and production controls off screen.
class _AdaptiveOrderFooter extends StatelessWidget {
  const _AdaptiveOrderFooter({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final pinActions = size.shortestSide >= 600 || size.width >= 1000;
    if (pinActions) return child;

    return Flexible(flex: 2, child: SingleChildScrollView(child: child));
  }
}

Future<void> _showPendingOrderItems(
  BuildContext context, {
  required PosOrder order,
  required String currencyCode,
}) {
  final pending = order.lines
      .where((line) => !line.isSentToProduction)
      .toList(growable: false);
  return showAppDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        'Pending items · ${pending.length} line${pending.length == 1 ? '' : 's'}',
      ),
      content: SizedBox(
        width: 520,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: pending.length,
          separatorBuilder: (_, _) => const Divider(),
          itemBuilder: (context, index) {
            final line = pending[index];
            return ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(child: Text('${line.quantity}')),
              title: Text(line.productName),
              subtitle: line.productionDetails.isEmpty
                  ? null
                  : Text(line.productionDetails.join(' · ')),
              trailing: Text(
                formatMoney(line.totalMinor, currencyCode: currencyCode),
              ),
            );
          },
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Order checked'),
        ),
      ],
    ),
  );
}

/// Shows the complete bill without leaving the order or payment screen. This
/// is deliberately read-only: staff can read every item and price back to the
/// customer while the authoritative order and prepared payments stay intact.
Future<void> _showCheckoutBillPreview(
  BuildContext context, {
  required PosOrder order,
  required String currencyCode,
  required int pendingPaymentMinor,
}) async {
  final itemSubtotalMinor = order.lines.fold<int>(
    0,
    (total, line) => total + line.totalMinor,
  );
  final deliveryFeeMinor = order.channel == OrderChannel.delivery
      ? order.deliveryFeeMinor
      : 0;
  final pendingBalanceMinor = (order.balanceDueMinor - pendingPaymentMinor)
      .clamp(0, order.totalMinor)
      .toInt();
  await showAppDialog<void>(
    context: context,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      return Dialog(
        key: const ValueKey('checkout-bill-preview'),
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900, maxHeight: 760),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 8, 12),
                child: Row(
                  children: [
                    const Icon(Icons.receipt_long_rounded),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Full bill',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            '${order.lines.length} item line${order.lines.length == 1 ? '' : 's'}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close bill view',
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: order.lines.isEmpty
                    ? const Center(
                        child: Text('There are no items on this bill.'),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        itemCount: order.lines.length,
                        separatorBuilder: (_, _) => const Divider(height: 20),
                        itemBuilder: (context, index) {
                          final line = order.lines[index];
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              CircleAvatar(
                                radius: 18,
                                child: Text('${line.quantity}'),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      line.productName,
                                      style: theme.textTheme.titleSmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${line.quantity} × ${formatMoney(line.unitPriceMinor, currencyCode: currencyCode)}',
                                      style: theme.textTheme.bodySmall,
                                    ),
                                    if (line.productionDetails.isNotEmpty) ...[
                                      const SizedBox(height: 3),
                                      Text(
                                        line.productionDetails.join(' · '),
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                formatMoney(
                                  line.totalMinor,
                                  currencyCode: currencyCode,
                                ),
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
                child: Column(
                  children: [
                    _BillPreviewTotalRow(
                      label: 'Items subtotal',
                      amountMinor: itemSubtotalMinor,
                      currencyCode: currencyCode,
                    ),
                    if (deliveryFeeMinor > 0)
                      _BillPreviewTotalRow(
                        label: 'Delivery charge',
                        amountMinor: deliveryFeeMinor,
                        currencyCode: currencyCode,
                      ),
                    _BillPreviewTotalRow(
                      label: 'Bill total',
                      amountMinor: order.totalMinor,
                      currencyCode: currencyCode,
                      emphasize: true,
                    ),
                    if (order.paidMinor > 0)
                      _BillPreviewTotalRow(
                        label: 'Already paid',
                        amountMinor: order.paidMinor,
                        currencyCode: currencyCode,
                      ),
                    if (pendingPaymentMinor > 0)
                      _BillPreviewTotalRow(
                        label: 'Prepared payments',
                        amountMinor: pendingPaymentMinor,
                        currencyCode: currencyCode,
                      ),
                    const Divider(height: 18),
                    _BillPreviewTotalRow(
                      label: 'Remaining after prepared payments',
                      amountMinor: pendingBalanceMinor,
                      currencyCode: currencyCode,
                      emphasize: true,
                    ),
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

class _BillPreviewTotalRow extends StatelessWidget {
  const _BillPreviewTotalRow({
    required this.label,
    required this.amountMinor,
    required this.currencyCode,
    this.emphasize = false,
  });

  final String label;
  final int amountMinor;
  final String currencyCode;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final style = emphasize
        ? Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)
        : Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          const SizedBox(width: 12),
          Text(
            formatMoney(amountMinor, currencyCode: currencyCode),
            style: style,
          ),
        ],
      ),
    );
  }
}
