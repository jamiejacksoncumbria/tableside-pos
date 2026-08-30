import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_logger.dart';
import '../core/tenant_scope.dart';
import '../features/order_flow/order_flow_page.dart';
import '../features/auth/staff_pin_gate.dart';
import '../features/menu/menu_management_page.dart';
import '../features/notifications/notification_centre.dart';
import '../features/pos/domain.dart';
import '../features/pos/pos_controller.dart';
import '../features/pos/pos_page.dart';
import '../features/platform_admin/platform_admin_page.dart';
import '../features/printing/native_print_worker.dart';
import '../features/printing/queued_bluetooth_print_worker.dart';
import '../features/printing/print_delivery_monitor.dart';
import '../features/reports/reports_page.dart';
import '../features/settings/settings_page.dart';

enum HomeSection { pos, orderFlow, menu, reports, settings, platformAdmin }

final homeSectionProvider =
    NotifierProvider<HomeSectionController, HomeSection>(
      HomeSectionController.new,
    );

class HomeSectionController extends Notifier<HomeSection> {
  @override
  HomeSection build() => HomeSection.pos;

  void select(HomeSection section) => state = section;
}

class HomeShell extends ConsumerWidget {
  const HomeShell({
    super.key,
    this.profileOverride,
    this.venueOverride,
    this.persistCompanyProfile = false,
    this.onSwitchVenue,
    this.onSignOut,
  });

  final TenantProfile? profileOverride;
  final Venue? venueOverride;
  final bool persistCompanyProfile;
  final VoidCallback? onSwitchVenue;
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final section = ref.watch(homeSectionProvider);
    final unreadNotifications = ref.watch(
      appNotificationsProvider.select(unreadNotificationCount),
    );
    final staffSession = ref.watch(activeStaffPinSessionProvider);
    // Shared terminals use the verified PIN identity for authority. The
    // Firebase email account only keeps the device online; it must never grant
    // platform tools to a different selected member.
    final canOpenPlatformTools = staffSession?.isPlatformAdmin == true;
    final canManageVenue =
        staffSession?.roles.any(
          (role) => role == 'owner' || role == 'manager',
        ) ??
        false;
    final protectedVenueSection =
        section == HomeSection.menu ||
        section == HomeSection.reports ||
        section == HomeSection.settings;
    final visibleSection =
        (section == HomeSection.platformAdmin && !canOpenPlatformTools) ||
            (protectedVenueSection && !canManageVenue)
        ? HomeSection.pos
        : section;
    final TenantProfile profile =
        profileOverride ?? ref.watch(tenantProfileProvider);
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final destinations = [
      const _Destination(HomeSection.pos, Icons.point_of_sale_rounded, 'POS'),
      const _Destination(
        HomeSection.orderFlow,
        Icons.monitor_heart_outlined,
        'Order flow',
      ),
      if (canManageVenue)
        const _Destination(
          HomeSection.menu,
          Icons.restaurant_menu_rounded,
          'Menu',
        ),
      if (canManageVenue)
        const _Destination(
          HomeSection.reports,
          Icons.bar_chart_rounded,
          'Reports',
        ),
      if (canManageVenue)
        const _Destination(
          HomeSection.settings,
          Icons.settings_outlined,
          'Settings',
        ),
      if (canOpenPlatformTools)
        const _Destination(
          HomeSection.platformAdmin,
          Icons.admin_panel_settings_outlined,
          'Platform',
        ),
    ];
    final index = destinations.indexWhere(
      (destination) => destination.section == visibleSection,
    );
    // Material NavigationBar intentionally supports at most five destinations.
    // Platform tools stay available on compact devices from the app bar rather
    // than making the entire mobile shell fail for a platform administrator.
    final compactDestinations = destinations
        .where((item) => item.section != HomeSection.platformAdmin)
        .toList(growable: false);
    final compactIndex = compactDestinations.indexWhere(
      (destination) => destination.section == visibleSection,
    );

    return Scaffold(
      appBar: AppBar(
        titleSpacing: wide ? 20 : 12,
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              foregroundImage: profile.logoUrl == null
                  ? null
                  : NetworkImage(profile.logoUrl!),
              child: profile.logoUrl == null
                  ? const Icon(Icons.storefront_rounded, size: 18)
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    venueOverride?.name ?? 'Market Street',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (onSwitchVenue != null)
            wide
                ? TextButton.icon(
                    onPressed: onSwitchVenue,
                    icon: const Icon(Icons.storefront_rounded),
                    label: const Text('Switch venue'),
                  )
                : IconButton(
                    tooltip: 'Switch venue',
                    onPressed: onSwitchVenue,
                    icon: const Icon(Icons.storefront_rounded),
                  ),
          if (staffSession != null)
            wide
                ? TextButton.icon(
                    onPressed: () => ref
                        .read(activeStaffPinSessionProvider.notifier)
                        .lock(),
                    icon: const Icon(Icons.switch_account_rounded),
                    label: Text(staffSession.displayName),
                  )
                : IconButton(
                    tooltip: 'Switch staff: ${staffSession.displayName}',
                    onPressed: () => ref
                        .read(activeStaffPinSessionProvider.notifier)
                        .lock(),
                    icon: const Icon(Icons.switch_account_rounded),
                  ),
          if (canOpenPlatformTools && !wide)
            IconButton(
              tooltip: 'Platform administration',
              onPressed: () => ref
                  .read(homeSectionProvider.notifier)
                  .select(HomeSection.platformAdmin),
              icon: const Icon(Icons.admin_panel_settings_outlined),
            ),
          IconButton(
            tooltip: 'Notifications',
            onPressed: () => openNotificationCentre(context),
            icon: unreadNotifications == 0
                ? const Icon(Icons.notifications_none_rounded)
                : Badge.count(
                    count: unreadNotifications,
                    child: const Icon(Icons.notifications_none_rounded),
                  ),
          ),
          if (onSignOut != null)
            IconButton(
              tooltip: 'Sign out',
              onPressed: onSignOut,
              icon: const Icon(Icons.logout_rounded),
            ),
          const SizedBox(width: 8),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(42),
          child: _CurrentOrderLocationIndicator(),
        ),
      ),
      body: Row(
        children: [
          if (wide)
            NavigationRail(
              selectedIndex: index,
              labelType: NavigationRailLabelType.all,
              onDestinationSelected: (selected) => ref
                  .read(homeSectionProvider.notifier)
                  .select(destinations[selected].section),
              destinations: [
                for (final item in destinations)
                  NavigationRailDestination(
                    icon: Icon(item.icon),
                    selectedIcon: Icon(item.icon),
                    label: Text(item.label),
                  ),
              ],
            ),
          Expanded(
            // The print worker is intentionally invisible. A default loose
            // Stack sizes itself from non-positioned children, so this stack
            // could collapse to the worker's zero height inside the outer Row
            // and hide every venue screen. Expand to the workspace bounds.
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(child: _buildBody(visibleSection, profile)),
                const _QueuedPrintWorkerHost(),
                const PrintDeliveryMonitorHost(),
                const OrderFlowNotificationHost(),
              ],
            ),
          ),
        ],
      ),
      // Notifications live in the scaffold's bottom area rather than as a
      // floating SnackBar. This reserves layout space, so a message can never
      // cover a POS control or require staff to dismiss it before continuing.
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _BottomNotificationTray(),
          if (!wide)
            NavigationBar(
              selectedIndex: compactIndex < 0 ? 0 : compactIndex,
              onDestinationSelected: (selected) => ref
                  .read(homeSectionProvider.notifier)
                  .select(compactDestinations[selected].section),
              destinations: [
                for (final item in compactDestinations)
                  NavigationDestination(
                    icon: Icon(item.icon),
                    label: item.label,
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildBody(
    HomeSection section,
    TenantProfile profile,
  ) => switch (section) {
    HomeSection.pos => PosPage(currencyCode: profile.currencyCode),
    HomeSection.orderFlow => OrderFlowPage(
      amberMinutes: venueOverride?.orderFlowAmberMinutes ?? 15,
      redMinutes: venueOverride?.orderFlowRedMinutes ?? 25,
    ),
    HomeSection.menu => MenuManagementPage(currencyCode: profile.currencyCode),
    HomeSection.reports => ReportsPage(
      currencyCode: profile.currencyCode,
      businessDayCutoffMinutes: venueOverride?.businessDayCutoffMinutes ?? 240,
    ),
    HomeSection.settings => SettingsPage(
      profileOverride: profileOverride,
      venueOverride: venueOverride,
      persistToFirebase: persistCompanyProfile,
    ),
    HomeSection.platformAdmin => const PlatformAdminPage(),
  };
}

/// Keeps the currently selected service location unmistakable on every screen.
/// A venue deliberately starts with no table selected to prevent accidental
/// orders being attached to the first table in the list.
class _CurrentOrderLocationIndicator extends ConsumerWidget {
  const _CurrentOrderLocationIndicator();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final order = ref.watch(activeOrderProvider);
    final tabName = order.tabName?.trim();
    final tableId = order.tableId;
    final scheme = Theme.of(context).colorScheme;
    final (icon, label) = tabName?.isNotEmpty == true
        ? (Icons.person_outline_rounded, 'Current tab: $tabName')
        : tableId == null
        ? (Icons.table_restaurant_outlined, 'No table or tab selected')
        : (
            Icons.table_restaurant_rounded,
            'Current table: ${_tableLabel(ref, tableId)}',
          );
    return Semantics(
      liveRegion: true,
      label: label,
      child: Container(
        width: double.infinity,
        color: scheme.surfaceContainerLow,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _tableLabel(WidgetRef ref, String tableId) => ref
      .watch(diningTablesProvider)
      .when(
        data: (tables) {
          for (final table in tables) {
            if (table.id == tableId) return table.label;
          }
          return tableId;
        },
        loading: () => 'Loading…',
        error: (_, _) => tableId,
      );
}

/// A layout-reserving tray for the latest notification. It intentionally sits
/// inside the bottom navigation area, never over the order controls.
class _BottomNotificationTray extends ConsumerWidget {
  const _BottomNotificationTray();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifications = ref.watch(appNotificationsProvider);
    if (notifications.isEmpty) return const SizedBox.shrink();
    final notification = notifications.first;
    final controller = ref.read(appNotificationsProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final (icon, colour) = switch (notification.level) {
      AppNotificationLevel.success => (
        Icons.check_circle_outline_rounded,
        Colors.green.shade700,
      ),
      AppNotificationLevel.information => (
        Icons.info_outline_rounded,
        scheme.primary,
      ),
      AppNotificationLevel.warning => (
        Icons.warning_amber_rounded,
        Colors.orange.shade800,
      ),
      AppNotificationLevel.error => (Icons.error_outline_rounded, scheme.error),
    };
    return SafeArea(
      top: false,
      bottom: false,
      child: Material(
        color: scheme.surfaceContainerHigh,
        child: InkWell(
          onTap: () {
            controller.markRead(notification.id);
            openNotificationCentre(context);
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: [
                Icon(icon, color: colour),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        notification.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        notification.message,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Dismiss notification',
                  onPressed: () => controller.dismiss(notification.id),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QueuedPrintWorkerHost extends ConsumerStatefulWidget {
  const _QueuedPrintWorkerHost();

  @override
  ConsumerState<_QueuedPrintWorkerHost> createState() =>
      _QueuedPrintWorkerHostState();
}

class _QueuedPrintWorkerHostState
    extends ConsumerState<_QueuedPrintWorkerHost> {
  final QueuedNativePrintWorker _worker = QueuedNativePrintWorker();
  Timer? _retryTimer;
  StreamSubscription<int>? _queuedJobsSubscription;
  VenueScope? _scope;
  bool _processing = false;
  int _queuedJobCount = 0;

  @override
  void dispose() {
    _retryTimer?.cancel();
    _queuedJobsSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = ref.watch(activeVenueScopeProvider);
    if (scope != _scope) {
      scheduleMicrotask(() => _configure(scope));
    }
    return const SizedBox.shrink();
  }

  void _configure(VenueScope? scope) {
    if (!mounted || scope == _scope) return;
    _retryTimer?.cancel();
    _queuedJobsSubscription?.cancel();
    _scope = scope;
    _queuedJobCount = 0;
    if (scope == null) return;
    _queuedJobsSubscription = _worker
        .watchQueuedJobCount(scope)
        .listen(
          (queuedCount) {
            _queuedJobCount = queuedCount;
            AppLogger.info(
              'Queued printer stream: $queuedCount queued job(s) for this venue.',
            );
            if (queuedCount > 0) unawaited(_processAvailable(scope));
          },
          onError: (Object error, StackTrace stackTrace) {
            AppLogger.error('Queued printer stream', error, stackTrace);
            if (!mounted) return;
            showAppNotification(
              context,
              ref: ref,
              title: 'Printer queue connection failed',
              message:
                  'Could not watch the printer queue. Check the connection.',
              level: AppNotificationLevel.error,
            );
          },
        );
    // Failed tickets deliberately wait ten seconds before their next allowed
    // attempt. This is not normal polling: it is only the retry wake-up for
    // work that was already observed by the stream.
    _retryTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      // A registered printer reports its health even while idle. Other tills
      // use the heartbeat to distinguish a short queue hand-off from an
      // actually offline kitchen/bar printer.
      unawaited(_worker.maintainHeartbeat(scope));
      if (_queuedJobCount > 0) unawaited(_processAvailable(scope));
    });
    unawaited(_worker.maintainHeartbeat(scope));
    unawaited(_processAvailable(scope));
  }

  Future<void> _processAvailable(VenueScope scope) async {
    if (_processing || !mounted || _scope != scope) return;
    _processing = true;
    try {
      while (mounted && _scope == scope) {
        final result = await _worker.processNext(scope);
        if (!mounted || _scope != scope) return;
        if (result == PrintWorkerResult.noWork) return;
        if (result == PrintWorkerResult.printed) {
          AppLogger.info('Queued native printer: ticket printed.');
        } else {
          AppLogger.error(
            'Queued native printer',
            StateError(
              'A queued ticket failed and will be retried or flagged.',
            ),
            StackTrace.current,
          );
          showAppNotification(
            context,
            ref: ref,
            title: 'Printer job needs attention',
            message:
                'A queued ticket or paid receipt could not print. It will retry automatically.',
            level: AppNotificationLevel.error,
          );
          // A failed job is requeued for a delayed retry, so do not spin on it.
          return;
        }
      }
    } on Object catch (error, stackTrace) {
      AppLogger.error('Queued native print worker', error, stackTrace);
      if (mounted) {
        showAppNotification(
          context,
          ref: ref,
          title: 'Printer worker failed',
          message: 'The printer worker encountered an error and will retry.',
          level: AppNotificationLevel.error,
        );
      }
    } finally {
      _processing = false;
    }
  }
}

class _Destination {
  const _Destination(this.section, this.icon, this.label);

  final HomeSection section;
  final IconData icon;
  final String label;
}
