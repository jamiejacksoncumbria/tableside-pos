import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../data/firestore_pos_repository.dart';
import '../../data/production_command_repository.dart';
import '../notifications/notification_centre.dart';
import '../pos/domain.dart';
import 'order_flow_sound.dart';

final orderFlowProvider = StreamProvider<List<OrderFlowOrder>>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(demoOrderFlow);
  return ref.watch(firestorePosRepositoryProvider).watchOrderFlow(scope);
});

/// Live, production-safe board used by kitchen/bar and managers. This screen
/// intentionally does not display money or customer contact information.
class OrderFlowPage extends ConsumerStatefulWidget {
  const OrderFlowPage({
    super.key,
    this.amberMinutes = 15,
    this.redMinutes = 25,
  });

  final int amberMinutes;
  final int redMinutes;

  @override
  ConsumerState<OrderFlowPage> createState() => _OrderFlowPageState();
}

class _OrderFlowPageState extends ConsumerState<OrderFlowPage> {
  Timer? _clock;
  Timer? _allergyAlarm;
  ProductionArea? _area;
  _FlowFilter _filter = _FlowFilter.all;
  final Map<String, OrderFlowOrder> _demoOverrides = {};
  final Set<String> _seenTicketIds = <String>{};
  final Set<String> _redAlertedTicketIds = <String>{};
  final Set<String> _activeAllergyTicketIds = <String>{};
  late final OrderFlowSound _sound;
  bool _receivedInitialOrders = false;

  @override
  void initState() {
    super.initState();
    _sound = OrderFlowSound();
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    _allergyAlarm?.cancel();
    unawaited(_sound.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = ref.watch(activeVenueScopeProvider);
    final flowValue = ref.watch(orderFlowProvider);
    final rawOrders = flowValue.when(
      data: (items) => items,
      loading: () => scope == null ? demoOrderFlow : const <OrderFlowOrder>[],
      error: (error, stackTrace) {
        AppLogger.error('Order Flow Board stream', error, stackTrace);
        return scope == null ? demoOrderFlow : const <OrderFlowOrder>[];
      },
    );
    final orders = rawOrders
        .map(
          (order) => scope == null ? _demoOverrides[order.id] ?? order : order,
        )
        .where(_matchesFilters)
        .toList(growable: false);
    final allOrders = rawOrders
        .map(
          (order) => scope == null ? _demoOverrides[order.id] ?? order : order,
        )
        .toList(growable: false);
    if (scope != null && flowValue.hasValue) {
      scheduleMicrotask(() {
        if (mounted) _observeOrderAlerts(allOrders);
      });
    }
    final scheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 12,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Order Flow',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Live kitchen, bar and manager view. Timers start when tickets are released.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              _BoardHealth(
                allOrders: allOrders,
                amberMinutes: widget.amberMinutes,
                redMinutes: widget.redMinutes,
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (_activeAllergyTicketIds.isNotEmpty) ...[
            Card(
              color: Colors.red.shade700,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: Colors.white),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Allergy alert: silence only after the kitchen has acknowledged it.',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                      ),
                    ),
                    TextButton(
                      onPressed: _silenceAllergyAlarm,
                      style: TextButton.styleFrom(foregroundColor: Colors.white),
                      child: const Text('Silence'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          _FilterBar(
            area: _area,
            filter: _filter,
            onAreaChanged: (area) => setState(() => _area = area),
            onFilterChanged: (filter) => setState(() => _filter = filter),
          ),
          const SizedBox(height: 18),
          if (flowValue.isLoading && scope != null && rawOrders.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(48),
                child: CircularProgressIndicator(),
              ),
            )
          else if (orders.isEmpty)
            _EmptyBoard(filter: _filter, area: _area)
          else
            Column(
              children: [
                for (final order in orders) ...[
                  _OrderFlowCard(
                    order: order,
                    now: DateTime.now(),
                    amberMinutes: widget.amberMinutes,
                    redMinutes: widget.redMinutes,
                    onAction: (action) => _applyAction(order, action),
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            ),
        ],
      ),
    );
  }

  void _observeOrderAlerts(List<OrderFlowOrder> orders) {
    final activeIds = orders.map((order) => order.id).toSet();
    if (!_receivedInitialOrders) {
      _receivedInitialOrders = true;
      _seenTicketIds.addAll(activeIds);
      return;
    }
    final newOrders = orders
        .where((order) => !_seenTicketIds.contains(order.id))
        .toList(growable: false);
    _seenTicketIds
      ..clear()
      ..addAll(activeIds);
    final newAllergyIds = newOrders
        .where((order) => order.hasAllergyAlert)
        .map((order) => order.id)
        .toSet();
    if (newAllergyIds.isNotEmpty) {
      _activeAllergyTicketIds.addAll(newAllergyIds);
      _startAllergyAlarm();
      if (mounted) setState(() {});
    } else if (newOrders.isNotEmpty) {
      unawaited(_sound.playNewOrder());
    }
    final newlyRed = orders
        .where(
          (order) =>
              _lateState(order, DateTime.now(), widget.amberMinutes, widget.redMinutes) ==
                  _LateState.red &&
              !_redAlertedTicketIds.contains(order.id),
        )
        .map((order) => order.id)
        .toSet();
    if (newlyRed.isNotEmpty) {
      _redAlertedTicketIds.addAll(newlyRed);
      unawaited(_sound.playLateOrder());
    }
  }

  void _startAllergyAlarm() {
    _allergyAlarm ??= Timer.periodic(const Duration(seconds: 4), (_) {
      if (_activeAllergyTicketIds.isNotEmpty) {
        unawaited(_sound.playAllergyAlert());
      }
    });
    unawaited(_sound.playAllergyAlert());
  }

  void _silenceAllergyAlarm() {
    _activeAllergyTicketIds.clear();
    _allergyAlarm?.cancel();
    _allergyAlarm = null;
    setState(() {});
  }

  bool _matchesFilters(OrderFlowOrder order) {
    if (_area != null && order.productionArea != _area) return false;
    return switch (_filter) {
      _FlowFilter.all => true,
      _FlowFilter.late =>
        _lateState(
              order,
              DateTime.now(),
              widget.amberMinutes,
              widget.redMinutes,
            ) !=
            _LateState.normal,
      _FlowFilter.allergy => order.hasAllergyAlert,
      _FlowFilter.ready => order.status == OrderFlowStatus.ready,
    };
  }

  Future<void> _applyAction(
    OrderFlowOrder order,
    _OrderFlowAction action,
  ) async {
    final updated = switch (action) {
      _OrderFlowAction.startPreparing => order.copyWith(
        status: OrderFlowStatus.preparing,
      ),
      _OrderFlowAction.markReady => order.copyWith(
        status: OrderFlowStatus.ready,
      ),
      _OrderFlowAction.markCollected => order.copyWith(
        status: OrderFlowStatus.collected,
      ),
      _OrderFlowAction.markServed => order.copyWith(
        status: OrderFlowStatus.served,
      ),
      _OrderFlowAction.toggleDelayed => order.copyWith(
        isDelayed: !order.isDelayed,
      ),
    };
    final scope = ref.read(activeVenueScopeProvider);
    if (scope == null) {
      setState(() => _demoOverrides[order.id] = updated);
      return;
    }
    try {
      await ref
          .read(productionCommandRepositoryProvider)
          .updateProductionTicket(
            scope: scope,
            ticketId: order.id,
            flowStatus: updated.status.name,
            isDelayed: updated.isDelayed,
          );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Update order flow status', error, stackTrace);
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Order flow update failed',
        message: 'The order status could not be updated. Please retry.',
        level: AppNotificationLevel.error,
      );
    }
  }
}

enum _FlowFilter { all, late, allergy, ready }

enum _OrderFlowAction {
  startPreparing,
  markReady,
  markCollected,
  markServed,
  toggleDelayed,
}

enum _LateState { normal, amber, red }

_LateState _lateState(
  OrderFlowOrder order,
  DateTime now,
  int amberMinutes,
  int redMinutes,
) {
  if (order.isDelayed) return _LateState.red;
  if (order.status.isTerminal) return _LateState.normal;
  final elapsed = now.difference(order.ticketReleasedAt);
  if (elapsed >= Duration(minutes: redMinutes)) return _LateState.red;
  if (elapsed >= Duration(minutes: amberMinutes)) return _LateState.amber;
  return _LateState.normal;
}

class _BoardHealth extends StatelessWidget {
  const _BoardHealth({
    required this.allOrders,
    required this.amberMinutes,
    required this.redMinutes,
  });

  final List<OrderFlowOrder> allOrders;
  final int amberMinutes;
  final int redMinutes;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
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
    required this.now,
    required this.amberMinutes,
    required this.redMinutes,
    required this.onAction,
  });

  final OrderFlowOrder order;
  final DateTime now;
  final int amberMinutes;
  final int redMinutes;
  final ValueChanged<_OrderFlowAction> onAction;

  @override
  Widget build(BuildContext context) {
    final late = _lateState(order, now, amberMinutes, redMinutes);
    final background = switch (late) {
      _LateState.red => Colors.red.shade800,
      _LateState.amber => Colors.orange.shade800,
      _LateState.normal => Colors.green.shade700,
    };
    final elapsed = now.difference(order.ticketReleasedAt);
    final location = order.tableLabel ?? order.tabName ?? 'Unassigned';

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
                Row(
                  children: [
                    _AreaIcon(area: order.productionArea),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${order.productionArea.label} · #${order.reference}',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    _OrderActions(order: order, onAction: onAction),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(
                      Icons.table_restaurant_outlined,
                      size: 18,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 5),
                    Expanded(child: Text(location)),
                    _StatusPill(status: order.status),
                  ],
                ),
                const SizedBox(height: 10),
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
                const SizedBox(height: 8),
                _PrimaryFlowAction(order: order, onAction: onAction),
                const SizedBox(height: 8),
                _AlertRow(
                  icon: late == _LateState.normal
                      ? Icons.timer_outlined
                      : Icons.priority_high_rounded,
                  text: '${_formatElapsed(elapsed)} since ticket release',
                  color: Colors.white,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PrimaryFlowAction extends StatelessWidget {
  const _PrimaryFlowAction({required this.order, required this.onAction});

  final OrderFlowOrder order;
  final ValueChanged<_OrderFlowAction> onAction;

  @override
  Widget build(BuildContext context) {
    final action = switch (order.status) {
      OrderFlowStatus.newOrder => _OrderFlowAction.startPreparing,
      OrderFlowStatus.preparing => _OrderFlowAction.markReady,
      OrderFlowStatus.ready => _OrderFlowAction.markCollected,
      OrderFlowStatus.collected => _OrderFlowAction.markServed,
      _ => null,
    };
    if (action == null) return const SizedBox.shrink();
    final label = switch (action) {
      _OrderFlowAction.startPreparing => 'Start preparing',
      _OrderFlowAction.markReady => 'Mark ready',
      _OrderFlowAction.markCollected => 'Mark collected',
      _OrderFlowAction.markServed => 'Mark served',
      _OrderFlowAction.toggleDelayed => '',
    };
    return SizedBox(
      width: double.infinity,
      child: FilledButton.tonal(
        onPressed: () => onAction(action),
        style: FilledButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: Theme.of(context).colorScheme.onSurface,
        ),
        child: Text(label),
      ),
    );
  }
}

/// Watches the same Firestore ticket stream as the KDS and raises a durable
/// in-app notification only when an existing ticket transitions to ready.
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
        final location =
            order.tableLabel ?? order.tabName ?? 'Unassigned order';
        showAppNotification(
          context,
          ref: ref,
          deduplicationKey: 'order-ready-${order.id}',
          title: '${order.productionArea.label} order ready',
          message: '$location · Order #${order.reference}',
          level: AppNotificationLevel.success,
        );
      }
    }
    _knownStatuses = {for (final order in orders) order.id: order.status};
  }
}

class _AreaIcon extends StatelessWidget {
  const _AreaIcon({required this.area});

  final ProductionArea area;

  @override
  Widget build(BuildContext context) => CircleAvatar(
    radius: 16,
    backgroundColor: Colors.white24,
    foregroundColor: Colors.white,
    child: Icon(switch (area) {
      ProductionArea.bar => Icons.local_bar_rounded,
      ProductionArea.kitchen => Icons.restaurant_rounded,
      ProductionArea.dessert => Icons.cake_outlined,
    }, size: 18),
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
    children: [
      Icon(icon, color: color, size: 18),
      const SizedBox(width: 5),
      Expanded(
        child: Text(
          text,
          maxLines: 1,
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
  const _OrderActions({required this.order, required this.onAction});

  final OrderFlowOrder order;
  final ValueChanged<_OrderFlowAction> onAction;

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
    return PopupMenuButton<_OrderFlowAction>(
      tooltip: 'Update order',
      icon: const Icon(Icons.more_vert_rounded),
      onSelected: onAction,
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
      ],
    );
  }
}

String _formatElapsed(Duration value) {
  final minutes = value.inMinutes;
  if (minutes < 60) return '${minutes}m';
  return '${minutes ~/ 60}h ${minutes % 60}m';
}
