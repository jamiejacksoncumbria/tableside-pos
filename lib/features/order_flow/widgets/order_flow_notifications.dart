part of '../order_flow_page.dart';

class OrderFlowNotificationHost extends ConsumerStatefulWidget {
  const OrderFlowNotificationHost({super.key});

  @override
  ConsumerState<OrderFlowNotificationHost> createState() =>
      _OrderFlowNotificationHostState();
}

class _OrderFlowNotificationHostState
    extends ConsumerState<OrderFlowNotificationHost> {
  String? _scopeKey;
  bool _seeded = false;
  Map<String, OrderFlowStatus> _knownStatuses = const {};

  @override
  Widget build(BuildContext context) {
    final scope = ref.watch(activeVenueScopeProvider);
    final scopeKey = scope == null
        ? null
        : '${scope.tenantId}/${scope.venueId}';
    if (_scopeKey != scopeKey) {
      _scopeKey = scopeKey;
      _seeded = false;
      _knownStatuses = const {};
    }
    ref.listen<AsyncValue<List<OrderFlowOrder>>>(orderFlowProvider, (_, next) {
      next.whenData(_handleOrders);
    });
    return const SizedBox.shrink();
  }

  void _handleOrders(List<OrderFlowOrder> orders) {
    if (!_seeded) {
      _knownStatuses = {for (final order in orders) order.id: order.status};
      _seeded = true;
      return;
    }
    for (final order in orders) {
      final previous = _knownStatuses[order.id];
      if (previous != null &&
          previous != OrderFlowStatus.ready &&
          order.status == OrderFlowStatus.ready) {
        // Fulfilment orders intentionally have no table. Use the customer or
        // channel reference so a collection-ready alert is never described as
        // an unassigned delivery.
        final location =
            order.tableLabel ??
            order.tabName ??
            order.customerName ??
            order.reference;
        showAppNotification(
          context,
          ref: ref,
          deduplicationKey: 'order-ready-${order.id}',
          title: '${order.productionArea.label} order ready',
          message: location,
          level: AppNotificationLevel.success,
        );
      }
    }
    _knownStatuses = {for (final order in orders) order.id: order.status};
  }
}

class _AreaIcon extends StatelessWidget {
  const _AreaIcon({required this.area, required this.channel});

  final ProductionArea area;
  final OrderChannel channel;

  @override
  Widget build(BuildContext context) => CircleAvatar(
    radius: 16,
    backgroundColor: Colors.white24,
    foregroundColor: Colors.white,
    child: Icon(
      channel == OrderChannel.delivery
          ? Icons.delivery_dining_rounded
          : channel == OrderChannel.collection
          ? Icons.shopping_bag_rounded
          : switch (area) {
              ProductionArea.bar => Icons.local_bar_rounded,
              ProductionArea.kitchen => Icons.restaurant_rounded,
              ProductionArea.dessert => Icons.cake_outlined,
            },
      size: 18,
    ),
  );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});

  final OrderFlowStatus status;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(20),
      color: Colors.white24,
    ),
    child: Text(
      status.label,
      style: Theme.of(
        context,
      ).textTheme.labelSmall?.copyWith(color: Colors.white),
    ),
  );
}

class _AlertRow extends StatelessWidget {
  const _AlertRow({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, color: color, size: 18),
      const SizedBox(width: 5),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: Text(
          text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: color),
        ),
      ),
    ],
  );
}

class _OrderActions extends StatelessWidget {
  const _OrderActions({
    required this.order,
    required this.onAction,
    this.onReprint,
    this.onPrintDriverTicket,
  });

  final OrderFlowOrder order;
  final ValueChanged<_OrderFlowAction> onAction;
  final VoidCallback? onReprint;
  final VoidCallback? onPrintDriverTicket;

  @override
  Widget build(BuildContext context) {
    final actions = <(_OrderFlowAction, String, IconData)>[
      if (order.status == OrderFlowStatus.newOrder)
        (
          _OrderFlowAction.startPreparing,
          'Start preparing',
          Icons.play_arrow_rounded,
        ),
      if (order.status == OrderFlowStatus.preparing)
        (_OrderFlowAction.markReady, 'Mark ready', Icons.check_rounded),
      if (order.status == OrderFlowStatus.ready)
        (
          _OrderFlowAction.markCollected,
          'Mark collected',
          Icons.shopping_bag_outlined,
        ),
      if (order.status == OrderFlowStatus.collected)
        (
          _OrderFlowAction.markServed,
          'Mark served',
          Icons.room_service_outlined,
        ),
      (
        _OrderFlowAction.toggleDelayed,
        order.isDelayed ? 'Clear delayed flag' : 'Mark delayed',
        Icons.priority_high_rounded,
      ),
    ];
    return PopupMenuButton<Object>(
      tooltip: 'Update order',
      icon: const Icon(Icons.more_vert_rounded),
      onSelected: (value) {
        if (value == 'reprint') {
          onReprint?.call();
        } else if (value == 'driverTicket') {
          onPrintDriverTicket?.call();
        } else if (value is _OrderFlowAction) {
          onAction(value);
        }
      },
      itemBuilder: (context) => [
        for (final action in actions)
          PopupMenuItem(
            value: action.$1,
            child: Row(
              children: [
                Icon(action.$3, size: 19),
                const SizedBox(width: 10),
                Text(action.$2),
              ],
            ),
          ),
        if (onReprint != null) ...[
          const PopupMenuDivider(),
          const PopupMenuItem<Object>(
            value: 'reprint',
            child: Row(
              children: [
                Icon(Icons.print_rounded, size: 19),
                SizedBox(width: 10),
                Text('Reprint order'),
              ],
            ),
          ),
        ],
        if (onPrintDriverTicket != null)
          const PopupMenuItem<Object>(
            value: 'driverTicket',
            child: Row(
              children: [
                Icon(Icons.receipt_long_outlined, size: 19),
                SizedBox(width: 10),
                Text('Print driver ticket'),
              ],
            ),
          ),
      ],
    );
  }
}

String _resolvedOrderLocation(OrderFlowOrder order, List<DiningTable> tables) {
  if (order.channel != OrderChannel.dineIn) {
    final customer = order.customerName?.trim();
    return customer?.isNotEmpty == true ? customer! : order.channel.label;
  }

  final tabName = order.tabName?.trim();
  if (tabName?.isNotEmpty == true) return tabName!;
  final stored = order.tableLabel?.trim();
  if (stored?.isNotEmpty != true) return 'Unassigned';
  for (final table in tables) {
    if (table.id == stored) return table.label;
  }
  return stored!;
}

String _formatElapsed(Duration value) {
  final minutes = value.inMinutes;
  if (minutes < 60) return '${minutes}m';
  return '${minutes ~/ 60}h ${minutes % 60}m';
}

String _formatVenueClock(DateTime value, int utcOffsetMinutes) {
  final venueTime = value.toUtc().add(Duration(minutes: utcOffsetMinutes));
  return '${venueTime.hour.toString().padLeft(2, '0')}:'
      '${venueTime.minute.toString().padLeft(2, '0')}';
}
