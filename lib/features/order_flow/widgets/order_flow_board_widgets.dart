part of '../order_flow_page.dart';

class _BoardHealth extends StatelessWidget {
  const _BoardHealth({
    required this.allOrders,
    required this.amberMinutes,
    required this.redMinutes,
    required this.now,
  });

  final List<OrderFlowOrder> allOrders;
  final int amberMinutes;
  final int redMinutes;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final late = allOrders
        .where(
          (order) =>
              _lateState(order, now, amberMinutes, redMinutes) ==
              _LateState.red,
        )
        .length;
    final ready = allOrders
        .where((order) => order.status == OrderFlowStatus.ready)
        .length;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _MetricChip(
          label: '${allOrders.length} active',
          icon: Icons.receipt_long,
        ),
        _MetricChip(
          label: '$ready ready',
          icon: Icons.room_service_outlined,
          color: Theme.of(context).colorScheme.primaryContainer,
        ),
        _MetricChip(
          label: '$late late',
          icon: Icons.priority_high_rounded,
          color: late == 0
              ? null
              : Theme.of(context).colorScheme.errorContainer,
        ),
      ],
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.label, required this.icon, this.color});

  final String label;
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) => Chip(
    avatar: Icon(icon, size: 18),
    backgroundColor: color,
    label: Text(label),
  );
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.area,
    required this.filter,
    required this.onAreaChanged,
    required this.onFilterChanged,
  });

  final ProductionArea? area;
  final _FlowFilter filter;
  final ValueChanged<ProductionArea?> onAreaChanged;
  final ValueChanged<_FlowFilter> onFilterChanged;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      ChoiceChip(
        label: const Text('All areas'),
        selected: area == null,
        onSelected: (_) => onAreaChanged(null),
      ),
      for (final value in ProductionArea.values)
        ChoiceChip(
          label: Text(value.label),
          selected: area == value,
          onSelected: (_) => onAreaChanged(value),
        ),
      const SizedBox(width: 8),
      for (final value in _FlowFilter.values)
        FilterChip(
          label: Text(switch (value) {
            _FlowFilter.all => 'All orders',
            _FlowFilter.late => 'Late',
            _FlowFilter.allergy => 'Allergy alerts',
            _FlowFilter.ready => 'Ready to run',
          }),
          selected: filter == value,
          onSelected: (_) => onFilterChanged(value),
        ),
    ],
  );
}

class _EmptyBoard extends StatelessWidget {
  const _EmptyBoard({required this.filter, required this.area});

  final _FlowFilter filter;
  final ProductionArea? area;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          const Icon(Icons.check_circle_outline_rounded, size: 38),
          const SizedBox(height: 12),
          Text(
            'No matching live orders',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            area == null && filter == _FlowFilter.all
                ? 'All production areas are clear.'
                : 'Try clearing a filter to see other active orders.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}

class _OrderFlowCard extends StatelessWidget {
  const _OrderFlowCard({
    required this.order,
    required this.location,
    required this.now,
    required this.amberMinutes,
    required this.redMinutes,
    required this.venueUtcOffsetMinutes,
    required this.onAction,
    this.onReprint,
    this.onPrintDriverTicket,
    this.onAssignDriver,
    required this.itemsExpanded,
    required this.onToggleItems,
    required this.lateAlarmDismissed,
    required this.onDismissLateAlarm,
  });

  final OrderFlowOrder order;
  final String location;
  final DateTime now;
  final int amberMinutes;
  final int redMinutes;
  final int venueUtcOffsetMinutes;
  final ValueChanged<_OrderFlowAction> onAction;
  final VoidCallback? onReprint;
  final VoidCallback? onPrintDriverTicket;
  final VoidCallback? onAssignDriver;
  final bool itemsExpanded;
  final VoidCallback onToggleItems;
  final bool lateAlarmDismissed;
  final VoidCallback onDismissLateAlarm;

  @override
  Widget build(BuildContext context) {
    final late = _lateState(order, now, amberMinutes, redMinutes);
    final background =
        order.driverDeclined || order.status == OrderFlowStatus.held
        ? Colors.purple.shade700
        : switch (late) {
            _LateState.red => Colors.red.shade800,
            _LateState.amber => Colors.orange.shade800,
            _LateState.normal => Colors.green.shade700,
          };
    final elapsed = orderFlowElapsed(now, order.ticketReleasedAt);
    return Card(
      color: background,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: background, width: 2),
      ),
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: Colors.white),
        child: IconTheme.merge(
          data: const IconThemeData(color: Colors.white),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _AreaIcon(
                          area: order.productionArea,
                          channel: order.channel,
                        ),
                        const SizedBox(width: 7),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 180),
                          child: Text(
                            location,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                        ),
                      ],
                    ),
                    Text(order.productionArea.label),
                    _StatusPill(status: order.status),
                    if (late == _LateState.red && !lateAlarmDismissed)
                      Container(
                        padding: const EdgeInsets.only(left: 9),
                        decoration: BoxDecoration(
                          color: Colors.black26,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white54),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'LATE — NEEDS ATTENTION',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            _AnimatedAlarmBell(onPressed: onDismissLateAlarm),
                          ],
                        ),
                      ),
                    if (order.driverDeclined && !lateAlarmDismissed)
                      Container(
                        padding: const EdgeInsets.only(left: 9),
                        decoration: BoxDecoration(
                          color: Colors.black26,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white54),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'DRIVER DECLINED — CHOOSE ANOTHER',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            _AnimatedAlarmBell(onPressed: onDismissLateAlarm),
                          ],
                        ),
                      ),
                    _PrimaryFlowAction(order: order, onAction: onAction),
                    if (onAssignDriver != null)
                      FilledButton.tonalIcon(
                        onPressed: onAssignDriver,
                        icon: const Icon(Icons.person_pin_circle_outlined),
                        label: Text(
                          order.driverDeclined
                              ? 'Choose another driver'
                              : 'Assign driver',
                        ),
                      ),
                    if (order.scheduledFor != null &&
                        order.status != OrderFlowStatus.held)
                      _AlertRow(
                        icon: order.channel == OrderChannel.delivery
                            ? Icons.delivery_dining_rounded
                            : Icons.shopping_bag_outlined,
                        text:
                            '${order.channel.label} ${_formatVenueClock(order.scheduledFor!, venueUtcOffsetMinutes)}',
                        color: Colors.white,
                      ),
                    if (order.status == OrderFlowStatus.held)
                      _AlertRow(
                        icon: Icons.schedule_rounded,
                        text: order.scheduledFor == null
                            ? 'Held — release when preparation should start'
                            : 'Due ${_formatVenueClock(order.scheduledFor!, venueUtcOffsetMinutes)} · timer starts at the venue lead time',
                        color: Colors.white,
                      )
                    else
                      _AlertRow(
                        icon: late == _LateState.normal
                            ? Icons.timer_outlined
                            : Icons.priority_high_rounded,
                        text: '${_formatElapsed(elapsed)} since ticket release',
                        color: Colors.white,
                      ),
                    SizedBox.square(
                      dimension: 34,
                      child: IconButton(
                        tooltip: itemsExpanded
                            ? 'Hide order items'
                            : 'Show ${order.itemSummary.length} order items',
                        padding: EdgeInsets.zero,
                        onPressed: onToggleItems,
                        icon: Icon(
                          itemsExpanded
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                        ),
                      ),
                    ),
                    _OrderActions(
                      order: order,
                      onAction: onAction,
                      onReprint: onReprint,
                      onPrintDriverTicket: onPrintDriverTicket,
                    ),
                  ],
                ),
                if (itemsExpanded)
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final maximumItemWidth = constraints.maxWidth < 360
                          ? constraints.maxWidth
                          : 320.0;
                      return Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final item in order.itemSummary)
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: maximumItemWidth,
                              ),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 7,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white12,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.white24),
                                ),
                                child: Text(item),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                if (order.hasAllergyAlert) ...[
                  const SizedBox(height: 8),
                  _AlertRow(
                    icon: Icons.warning_amber_rounded,
                    text: order.note.isEmpty ? 'Allergy alert' : order.note,
                    color: Colors.white,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AnimatedAlarmBell extends StatefulWidget {
  const _AnimatedAlarmBell({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_AnimatedAlarmBell> createState() => _AnimatedAlarmBellState();
}

class _AnimatedAlarmBellState extends State<_AnimatedAlarmBell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  );

  @override
  void initState() {
    super.initState();
    _controller.repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 28,
    child: IconButton(
      tooltip: 'Dismiss this ticket alarm',
      onPressed: widget.onPressed,
      padding: EdgeInsets.zero,
      color: Colors.white,
      iconSize: 17,
      icon: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) => Transform.rotate(
          angle: (_controller.value - .5) * .45,
          child: child,
        ),
        child: const Icon(Icons.notifications_active_rounded),
      ),
    ),
  );
}

class _PrimaryFlowAction extends StatelessWidget {
  const _PrimaryFlowAction({required this.order, required this.onAction});

  final OrderFlowOrder order;
  final ValueChanged<_OrderFlowAction> onAction;

  @override
  Widget build(BuildContext context) {
    final action = switch (order.status) {
      OrderFlowStatus.held => _OrderFlowAction.releaseCourse,
      OrderFlowStatus.newOrder => _OrderFlowAction.startPreparing,
      OrderFlowStatus.preparing => _OrderFlowAction.markReady,
      OrderFlowStatus.ready => _OrderFlowAction.markCollected,
      OrderFlowStatus.collected => _OrderFlowAction.markServed,
      _ => null,
    };
    if (action == null) return const SizedBox.shrink();
    final label = switch (action) {
      _OrderFlowAction.releaseCourse => 'Release ${order.courseName}',
      _OrderFlowAction.startPreparing => 'Start preparing',
      _OrderFlowAction.markReady => 'Mark ready',
      _OrderFlowAction.markCollected => 'Mark collected',
      _OrderFlowAction.markServed => 'Mark served',
      _OrderFlowAction.toggleDelayed => '',
    };
    return FilledButton.tonal(
      onPressed: () => onAction(action),
      style: FilledButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      child: Text(label),
    );
  }
}

/// Watches the same Firestore ticket stream as the KDS and raises a durable
/// in-app notification only when an existing ticket transitions to ready.
