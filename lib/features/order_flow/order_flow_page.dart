import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../core/order_flow_display_mode.dart';
import '../../core/safe_dialog.dart';
import '../../core/trusted_clock.dart';
import '../../data/firestore_pos_repository.dart';
import '../../data/production_command_repository.dart';
import '../../data/printer_device_repository.dart';
import '../../offline/venue_hub_client_registry.dart';
import '../../offline/venue_hub_offline_view.dart';
import '../notifications/notification_centre.dart';
import '../auth/staff_pin_gate.dart';
import '../fulfilment/fulfilment_domain.dart';
import '../fulfilment/fulfilment_repository.dart';
import '../pos/domain.dart';
import '../pos/pos_controller.dart';
import 'order_flow_timing.dart';
import 'order_flow_sound.dart';

part 'widgets/order_flow_board_widgets.dart';
part 'widgets/order_flow_notifications.dart';

final orderFlowProvider = StreamProvider<List<OrderFlowOrder>>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(demoOrderFlow);
  // A venue hub remains the authoritative order source when the internet is
  // unavailable. Never construct a Firestore listener in that state: doing so
  // fails before the KDS can render and used to trigger a PIN-session lock.
  if (!kIsWeb && VenueHubClientRegistry.instance.hasUsableSession(scope)) {
    return VenueHubOfflineView.instance.orderFlowStream;
  }
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
  Timer? _lateAlarm;
  Timer? _sessionKeepAlive;
  ProductionArea? _area;
  _FlowFilter _filter = _FlowFilter.all;
  final Map<String, OrderFlowOrder> _optimisticOverrides = {};
  final Set<String> _pendingOrderIds = <String>{};
  final Set<String> _seenTicketIds = <String>{};
  final Set<String> _redAlertedTicketIds = <String>{};
  final Set<String> _activeAllergyTicketIds = <String>{};
  final Set<String> _currentLateTicketIds = <String>{};
  final Set<String> _dismissedLateTicketIds = <String>{};
  final Set<String> _expandedTicketIds = <String>{};
  late final OrderFlowSound _sound;
  late final OrderFlowDisplayModeController _displayModeController;
  bool _receivedInitialOrders = false;
  bool _audioMuted = false;
  bool _audioPreferenceLoaded = false;
  bool _refreshingPinSession = false;
  bool _releasingScheduledTickets = false;
  bool _compactFiltersExpanded = false;
  bool _compactStatusExpanded = false;
  static const _audioMutedPreferenceKey = 'tableside.orderFlow.audioMuted';

  @override
  void initState() {
    super.initState();
    _sound = OrderFlowSound();
    // Riverpod 3 deliberately rejects `ref.read` once a ConsumerState is
    // unmounting. Cache the controller while the element is live so dispose
    // can always clear the KDS keep-awake flag safely.
    _displayModeController = ref.read(orderFlowDisplayActiveProvider.notifier);
    scheduleMicrotask(() {
      if (mounted) {
        _displayModeController.setActive(true);
        unawaited(_refreshKdsPinSession());
      }
    });
    _sessionKeepAlive = Timer.periodic(
      const Duration(minutes: 10),
      (_) => unawaited(_refreshKdsPinSession()),
    );
    unawaited(_loadAudioPreference());
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) {
        setState(() {});
        unawaited(_releaseScheduledTickets());
      }
    });
    scheduleMicrotask(_releaseScheduledTickets);
  }

  @override
  void dispose() {
    _clock?.cancel();
    _allergyAlarm?.cancel();
    _lateAlarm?.cancel();
    _sessionKeepAlive?.cancel();
    // Riverpod rejects provider mutations while Flutter is finalising the
    // widget tree. Clear the KDS keep-awake state immediately after that frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _displayModeController.setActive(false);
    });
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
    final confirmedOverrideIds = rawOrders
        .where((order) {
          final optimistic = _optimisticOverrides[order.id];
          return optimistic != null && _sameVisibleState(order, optimistic);
        })
        .map((order) => order.id)
        .toList(growable: false);
    if (confirmedOverrideIds.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          for (final id in confirmedOverrideIds) {
            _optimisticOverrides.remove(id);
          }
        });
      });
    }
    final orders = rawOrders
        .map((order) => _optimisticOverrides[order.id] ?? order)
        .where(_matchesFilters)
        .toList(growable: false);
    final allOrders = rawOrders
        .map((order) => _optimisticOverrides[order.id] ?? order)
        .toList(growable: false);
    final tables =
        ref.watch(diningTablesProvider).value ?? const <DiningTable>[];
    final staffSession = ref.watch(activeStaffPinSessionProvider);
    final canReprint =
        staffSession?.roles.any(
          (role) => role == 'owner' || role == 'manager',
        ) ??
        false;
    final canAssignDrivers = canReprint;
    final venueUtcOffsetMinutes =
        scope != null &&
            !kIsWeb &&
            VenueHubClientRegistry.instance.hasUsableSession(scope)
        ? VenueHubOfflineView.instance.venueUtcOffsetMinutes
        : DateTime.now().timeZoneOffset.inMinutes;
    final drivers = canAssignDrivers
        ? (ref.watch(fulfilmentStaffProvider).value ??
                  const <FulfilmentStaffMember>[])
              .where((item) => item.roles.contains('driver'))
              .toList(growable: false)
        : const <FulfilmentStaffMember>[];
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
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 700;
              final heading = Column(
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
              );
              final audioButton = IconButton.filledTonal(
                tooltip: _audioMuted
                    ? 'Enable new-order and allergy audio on this device'
                    : 'Mute new-order and allergy audio; late alarms are dismissed on each ticket',
                visualDensity: compact
                    ? VisualDensity.compact
                    : VisualDensity.standard,
                onPressed: _toggleAudioMuted,
                icon: Icon(
                  _audioMuted
                      ? Icons.volume_off_rounded
                      : Icons.volume_up_rounded,
                ),
              );
              final status = _BoardHealth(
                allOrders: allOrders,
                amberMinutes: widget.amberMinutes,
                redMinutes: widget.redMinutes,
                now: TrustedClock.instance.nowUtc(),
              );

              if (compact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    heading,
                    const SizedBox(height: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        audioButton,
                        const SizedBox(width: 4),
                        TextButton.icon(
                          onPressed: () => setState(
                            () => _compactStatusExpanded =
                                !_compactStatusExpanded,
                          ),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          icon: Icon(
                            _compactStatusExpanded
                                ? Icons.expand_less_rounded
                                : Icons.monitor_heart_outlined,
                            size: 19,
                          ),
                          label: Text(
                            _compactStatusExpanded
                                ? 'Hide status'
                                : 'Show status',
                          ),
                        ),
                      ],
                    ),
                    if (_compactStatusExpanded) ...[
                      const SizedBox(height: 8),
                      status,
                    ],
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: heading),
                  const SizedBox(width: 16),
                  audioButton,
                  const SizedBox(width: 8),
                  Flexible(child: status),
                ],
              );
            },
          ),
          const SizedBox(height: 20),
          if (_activeAllergyTicketIds.isNotEmpty) ...[
            Card(
              color: Colors.red.shade700,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Allergy alert: silence only after the kitchen has acknowledged it.',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _silenceAllergyAlarm,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('Silence'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 700;
              final showFilters = !compact || _compactFiltersExpanded;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (compact)
                    TextButton.icon(
                      onPressed: () => setState(
                        () =>
                            _compactFiltersExpanded = !_compactFiltersExpanded,
                      ),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      icon: Icon(
                        showFilters
                            ? Icons.expand_less_rounded
                            : Icons.filter_list_rounded,
                        size: 19,
                      ),
                      label: Text(
                        showFilters ? 'Hide filters' : 'Show filters',
                      ),
                    ),
                  if (showFilters)
                    _FilterBar(
                      area: _area,
                      filter: _filter,
                      onAreaChanged: (area) => setState(() => _area = area),
                      onFilterChanged: (filter) =>
                          setState(() => _filter = filter),
                    ),
                ],
              );
            },
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
                    location: _resolvedOrderLocation(order, tables),
                    now: TrustedClock.instance.nowUtc(),
                    amberMinutes: widget.amberMinutes,
                    redMinutes: widget.redMinutes,
                    venueUtcOffsetMinutes: venueUtcOffsetMinutes,
                    onAction: (action) => _applyAction(order, action),
                    onReprint: canReprint ? () => _reprintOrder(order) : null,
                    onPrintDriverTicket:
                        canReprint &&
                            order.channel == OrderChannel.delivery &&
                            order.orderId != null
                        ? () => _printDriverTicket(order)
                        : null,
                    onAssignDriver:
                        canAssignDrivers &&
                            order.channel == OrderChannel.delivery &&
                            order.orderId != null &&
                            !order.status.isTerminal
                        ? () => _chooseDriver(order, drivers)
                        : null,
                    lateAlarmDismissed: _dismissedLateTicketIds.contains(
                      order.id,
                    ),
                    onDismissLateAlarm: () => _dismissTicketLateAlarm(order.id),
                    itemsExpanded: _expandedTicketIds.contains(order.id),
                    onToggleItems: () => setState(() {
                      if (!_expandedTicketIds.add(order.id)) {
                        _expandedTicketIds.remove(order.id);
                      }
                    }),
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
    if (!_audioPreferenceLoaded) return;
    final activeIds = orders.map((order) => order.id).toSet();
    final initialObservation = !_receivedInitialOrders;
    var newOrders = const <OrderFlowOrder>[];
    if (!_receivedInitialOrders) {
      _receivedInitialOrders = true;
      _seenTicketIds.addAll(activeIds);
    } else {
      newOrders = orders
          .where((order) => !_seenTicketIds.contains(order.id))
          .toList(growable: false);
      _seenTicketIds
        ..clear()
        ..addAll(activeIds);
    }
    final alertCandidates = initialObservation ? orders : newOrders;
    if (alertCandidates.isNotEmpty) {
      final now = TrustedClock.instance.nowUtc();
      final clock = TrustedClock.instance.snapshot;
      for (final order in alertCandidates) {
        AppLogger.info(
          'Order-flow clock: ticket=${order.id}, '
          'nowUtc=${now.toIso8601String()}, '
          'releasedUtc=${order.ticketReleasedAt.toUtc().toIso8601String()}, '
          'elapsedSeconds=${orderFlowElapsed(now, order.ticketReleasedAt).inSeconds}, '
          'authority=${clock.authority.name}, '
          'clockSkewMs=${clock.offset.inMilliseconds}.',
        );
      }
    }
    final newAllergyIds = alertCandidates
        .where((order) => order.hasAllergyAlert)
        .map((order) => order.id)
        .toSet();
    if (newAllergyIds.isNotEmpty) {
      _activeAllergyTicketIds.addAll(newAllergyIds);
      _startAllergyAlarm();
      if (mounted) setState(() {});
    } else if (newOrders.isNotEmpty) {
      if (!_audioMuted) unawaited(_sound.playNewOrder());
    }
    final currentRedIds = orders
        .where(
          (order) =>
              order.driverDeclined ||
              _lateState(
                    order,
                    TrustedClock.instance.nowUtc(),
                    widget.amberMinutes,
                    widget.redMinutes,
                  ) ==
                  _LateState.red,
        )
        .map((order) => order.id)
        .toSet();
    final newlyRed = currentRedIds.difference(_redAlertedTicketIds);
    if (newlyRed.isNotEmpty) {
      _redAlertedTicketIds.addAll(newlyRed);
    }
    final priorLateIds = Set<String>.of(_currentLateTicketIds);
    _currentLateTicketIds
      ..clear()
      ..addAll(currentRedIds);
    _dismissedLateTicketIds.retainAll(currentRedIds);
    final unsilenced = currentRedIds.difference(_dismissedLateTicketIds);
    if (unsilenced.isEmpty) {
      _lateAlarm?.cancel();
      _lateAlarm = null;
    } else {
      _startLateAlarm();
    }
    if ((!setEquals(priorLateIds, currentRedIds) || newlyRed.isNotEmpty) &&
        mounted) {
      setState(() {});
    }
  }

  void _startAllergyAlarm() {
    _allergyAlarm ??= Timer.periodic(const Duration(seconds: 4), (_) {
      if (_activeAllergyTicketIds.isNotEmpty) {
        if (!_audioMuted) unawaited(_sound.playAllergyAlert());
      }
    });
    if (!_audioMuted) unawaited(_sound.playAllergyAlert());
  }

  void _startLateAlarm() {
    if (_audioMuted) return;
    if (_lateAlarm != null) return;
    _lateAlarm = Timer.periodic(const Duration(seconds: 4), (_) {
      if (_currentLateTicketIds
              .difference(_dismissedLateTicketIds)
              .isNotEmpty &&
          mounted &&
          !_audioMuted) {
        unawaited(_sound.playLateOrder());
      }
    });
    unawaited(_sound.playLateOrder());
  }

  void _dismissTicketLateAlarm(String ticketId) {
    setState(() => _dismissedLateTicketIds.add(ticketId));
    if (_currentLateTicketIds.difference(_dismissedLateTicketIds).isEmpty) {
      _lateAlarm?.cancel();
      _lateAlarm = null;
    } else {
      _startLateAlarm();
    }
  }

  Future<void> _loadAudioPreference() async {
    try {
      final preferences = SharedPreferencesAsync();
      final muted =
          await preferences.getBool(_audioMutedPreferenceKey) ?? false;
      if (mounted) {
        setState(() {
          _audioMuted = muted;
          _audioPreferenceLoaded = true;
        });
      }
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'Load local order-flow audio preference',
        error,
        stackTrace,
      );
      if (mounted) setState(() => _audioPreferenceLoaded = true);
    }
  }

  Future<void> _toggleAudioMuted() async {
    final muted = !_audioMuted;
    setState(() => _audioMuted = muted);
    try {
      await SharedPreferencesAsync().setBool(_audioMutedPreferenceKey, muted);
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'Save local order-flow audio preference',
        error,
        stackTrace,
      );
    }
    if (!muted) {
      if (_activeAllergyTicketIds.isNotEmpty) _startAllergyAlarm();
      if (_currentLateTicketIds
          .difference(_dismissedLateTicketIds)
          .isNotEmpty) {
        _startLateAlarm();
      }
    } else {
      _lateAlarm?.cancel();
      _lateAlarm = null;
      await _sound.stopAll();
    }
  }

  void _silenceAllergyAlarm() {
    _activeAllergyTicketIds.clear();
    _allergyAlarm?.cancel();
    _allergyAlarm = null;
    setState(() {});
  }

  Future<void> _refreshKdsPinSession() async {
    final scope = ref.read(activeVenueScopeProvider);
    final session = ref.read(activeStaffPinSessionProvider);
    if (!mounted || scope == null || session == null || _refreshingPinSession) {
      return;
    }
    // The local hub PIN session is verified from the signed encrypted venue
    // snapshot and uses the trusted hub clock. It cannot be refreshed through
    // Firebase while the venue is offline, and a cloud failure must never lock
    // an otherwise valid kitchen display session.
    if (!kIsWeb && VenueHubClientRegistry.instance.hasUsableSession(scope)) {
      return;
    }
    _refreshingPinSession = true;
    try {
      final expiresAt = await ProductionCommandRepository()
          .refreshStaffPinSession(scope: scope);
      if (!mounted) return;
      ref.read(activeStaffPinSessionProvider.notifier).extendUntil(expiresAt);
      AppLogger.info('Order Flow display PIN session securely refreshed.');
    } on Object catch (error, stackTrace) {
      AppLogger.error('Refresh Order Flow PIN session', error, stackTrace);
      if (mounted) {
        ref.read(activeStaffPinSessionProvider.notifier).lock();
      }
    } finally {
      _refreshingPinSession = false;
    }
  }

  Future<void> _releaseScheduledTickets() async {
    if (!mounted || _releasingScheduledTickets) return;
    final scope = ref.read(activeVenueScopeProvider);
    if (scope == null || ref.read(activeStaffPinSessionProvider) == null) {
      return;
    }
    if (!kIsWeb && VenueHubClientRegistry.instance.hasUsableSession(scope)) {
      // Recalculate held-ticket lead-time boundaries from the trusted local
      // order projection. The periodic KDS timer calls this every 30 seconds.
      VenueHubOfflineView.instance.refreshOrderFlow();
      return;
    }
    _releasingScheduledTickets = true;
    try {
      await ref
          .read(productionCommandRepositoryProvider)
          .releaseDueFulfilmentTickets(scope);
    } on Object catch (error, stackTrace) {
      // A LAN-only hub can continue serving its current queue while Firebase
      // is unavailable. Do not cover the KDS with repetitive warnings; the
      // held ticket remains visible and can still be released manually.
      AppLogger.error(
        'Release scheduled fulfilment tickets',
        error,
        stackTrace,
      );
    } finally {
      _releasingScheduledTickets = false;
    }
  }

  bool _matchesFilters(OrderFlowOrder order) {
    if (_area != null && order.productionArea != _area) return false;
    return switch (_filter) {
      _FlowFilter.all => true,
      _FlowFilter.late =>
        _lateState(
              order,
              TrustedClock.instance.nowUtc(),
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
    if (_pendingOrderIds.contains(order.id)) return;
    final updated = switch (action) {
      _OrderFlowAction.releaseCourse => order.copyWith(
        status: OrderFlowStatus.newOrder,
      ),
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
    setState(() {
      _optimisticOverrides[order.id] = updated;
      _pendingOrderIds.add(order.id);
    });
    if (scope == null) {
      setState(() => _pendingOrderIds.remove(order.id));
      return;
    }
    try {
      await ref
          .read(productionCommandRepositoryProvider)
          .updateProductionTicket(
            scope: scope,
            ticketId: order.id,
            orderId: order.orderId,
            flowStatus: updated.status.name,
            isDelayed: updated.isDelayed,
            background: true,
          );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Update order flow status', error, stackTrace);
      if (!mounted) return;
      setState(() => _optimisticOverrides.remove(order.id));
      showAppNotification(
        context,
        ref: ref,
        title: 'Order flow update failed',
        message: '$error',
        level: AppNotificationLevel.error,
      );
    } finally {
      if (mounted) setState(() => _pendingOrderIds.remove(order.id));
    }
  }

  Future<void> _reprintOrder(OrderFlowOrder order) async {
    final scope = ref.read(activeVenueScopeProvider);
    if (scope == null) return;
    try {
      final devices = await PrinterDeviceRepository(FirebaseFirestore.instance)
          .watchVenueDevices(tenantId: scope.tenantId, venueId: scope.venueId)
          .first
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      final compatible = devices
          .where(
            (device) =>
                device.active &&
                device.productionAreas.contains(order.productionArea.name),
          )
          .toList(growable: false);
      if (compatible.isEmpty) {
        showAppNotification(
          context,
          ref: ref,
          title: 'No printer available',
          message:
              'Register an active ${order.productionArea.label.toLowerCase()} printer first.',
          level: AppNotificationLevel.warning,
        );
        return;
      }
      final selected = await showAppDialog<PrinterDevice>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Reprint order'),
          content: SizedBox(
            width: 460,
            child: ListView(
              shrinkWrap: true,
              children: [
                const Text(
                  'Choose the physical printer. The replacement ticket will be marked REPRINT and audited.',
                ),
                const SizedBox(height: 12),
                for (final device in compatible)
                  ListTile(
                    leading: const Icon(Icons.print_rounded),
                    title: Text(device.name),
                    subtitle: Text(device.platform),
                    onTap: () => Navigator.pop(dialogContext, device),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
      if (selected == null || !mounted) return;
      await ref
          .read(productionCommandRepositoryProvider)
          .reprintProductionTicket(
            scope: scope,
            ticketId: order.id,
            targetDeviceId: selected.id,
          );
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Reprint queued',
        message: 'The order was sent to ${selected.name}.',
        level: AppNotificationLevel.success,
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Reprint order-flow ticket', error, stackTrace);
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Could not reprint order',
        message: '$error',
        level: AppNotificationLevel.error,
      );
    }
  }

  Future<void> _chooseDriver(
    OrderFlowOrder order,
    List<FulfilmentStaffMember> drivers,
  ) async {
    final scope = ref.read(activeVenueScopeProvider);
    if (scope == null || order.orderId == null) return;
    if (drivers.isEmpty) {
      showAppNotification(
        context,
        ref: ref,
        title: 'No delivery drivers available',
        message:
            'Add an active staff member with the Driver role for this venue, then retry.',
        level: AppNotificationLevel.warning,
      );
      return;
    }
    final selected = await showAppDialog<FulfilmentStaffMember>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Assign delivery driver'),
        children: [
          for (final driver in drivers)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, driver),
              child: ListTile(
                leading: const Icon(Icons.delivery_dining_rounded),
                title: Text(driver.name),
              ),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    if (_pendingOrderIds.contains(order.id)) return;
    final updated = order.copyWith(
      assignedDriverName: selected.name,
      driverDeclined: false,
    );
    setState(() {
      _optimisticOverrides[order.id] = updated;
      _pendingOrderIds.add(order.id);
    });
    try {
      await ref
          .read(fulfilmentRepositoryProvider)
          .updateFulfilmentOrder(
            scope: scope,
            orderId: order.orderId!,
            status: FulfilmentStatus.assigned,
            driverId: selected.id,
            background: true,
          );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Assign driver from order flow', error, stackTrace);
      if (!mounted) return;
      setState(() => _optimisticOverrides.remove(order.id));
      showAppNotification(
        context,
        ref: ref,
        title: 'Driver was not assigned',
        message: '$error',
        level: AppNotificationLevel.error,
      );
    } finally {
      if (mounted) setState(() => _pendingOrderIds.remove(order.id));
    }
  }

  bool _sameVisibleState(OrderFlowOrder live, OrderFlowOrder optimistic) =>
      live.status == optimistic.status &&
      live.isDelayed == optimistic.isDelayed &&
      live.assignedDriverName == optimistic.assignedDriverName &&
      live.driverDeclined == optimistic.driverDeclined;

  /// Prints the address-bearing driver copy from the live order rather than
  /// the kitchen ticket. The server reconstructs prices, customer details and
  /// the delivery address, so the KDS cannot alter financial information.
  Future<void> _printDriverTicket(OrderFlowOrder order) async {
    final scope = ref.read(activeVenueScopeProvider);
    if (scope == null || order.orderId == null) return;
    try {
      final devices = await PrinterDeviceRepository(FirebaseFirestore.instance)
          .watchVenueDevices(tenantId: scope.tenantId, venueId: scope.venueId)
          .first
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      final printers = devices
          .where(
            (device) =>
                device.active && device.productionAreas.contains('receipt'),
          )
          .toList(growable: false);
      if (printers.isEmpty) {
        throw StateError('No active receipt printer is registered here.');
      }
      final selected = await showAppDialog<PrinterDevice>(
        context: context,
        builder: (dialogContext) => SimpleDialog(
          title: const Text('Print driver ticket'),
          children: [
            for (final printer in printers)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(dialogContext, printer),
                child: ListTile(
                  leading: const Icon(Icons.print_outlined),
                  title: Text(printer.name),
                  subtitle: Text(printer.platform),
                ),
              ),
          ],
        ),
      );
      if (selected == null || !mounted) return;
      await ref
          .read(productionCommandRepositoryProvider)
          .printFulfilmentDeliveryNote(
            scope: scope,
            orderId: order.orderId!,
            targetDeviceId: selected.id,
          );
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Driver ticket queued',
        message: 'The driver copy was sent to ${selected.name}.',
        level: AppNotificationLevel.success,
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Print driver ticket from order flow', error, stackTrace);
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Could not print driver ticket',
        message: '$error',
        level: AppNotificationLevel.error,
      );
    }
  }
}

enum _FlowFilter { all, late, allergy, ready }

enum _OrderFlowAction {
  releaseCourse,
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
  if (order.driverDeclined) return _LateState.normal;
  if (order.status == OrderFlowStatus.held) return _LateState.normal;
  if (order.isDelayed) return _LateState.red;
  if (order.status.isTerminal) return _LateState.normal;
  final elapsed = orderFlowElapsed(now, order.ticketReleasedAt);
  if (elapsed >= Duration(minutes: redMinutes)) return _LateState.red;
  if (elapsed >= Duration(minutes: amberMinutes)) return _LateState.amber;
  return _LateState.normal;
}
