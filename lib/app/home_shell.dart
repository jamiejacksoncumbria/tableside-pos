import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_logger.dart';
import '../core/tenant_scope.dart';
import '../features/order_flow/order_flow_page.dart';
import '../features/menu/menu_management_page.dart';
import '../features/notifications/notification_centre.dart';
import '../features/pos/domain.dart';
import '../features/pos/pos_controller.dart';
import '../features/pos/pos_page.dart';
import '../features/platform_admin/platform_admin_page.dart';
import '../features/printing/native_print_worker.dart';
import '../features/printing/queued_bluetooth_print_worker.dart';
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
    this.isPlatformAdmin = false,
    this.onSignOut,
  });

  final TenantProfile? profileOverride;
  final Venue? venueOverride;
  final bool persistCompanyProfile;
  final bool isPlatformAdmin;
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final section = ref.watch(homeSectionProvider);
    final unreadNotifications = ref.watch(
      appNotificationsProvider.select(unreadNotificationCount),
    );
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
      const _Destination(
        HomeSection.menu,
        Icons.restaurant_menu_rounded,
        'Menu',
      ),
      const _Destination(
        HomeSection.reports,
        Icons.bar_chart_rounded,
        'Reports',
      ),
      const _Destination(
        HomeSection.settings,
        Icons.settings_outlined,
        'Settings',
      ),
      if (isPlatformAdmin)
        const _Destination(
          HomeSection.platformAdmin,
          Icons.admin_panel_settings_outlined,
          'Platform',
        ),
    ];
    final index = destinations.indexWhere(
      (destination) => destination.section == section,
    );
    // Material NavigationBar intentionally supports at most five destinations.
    // Platform tools stay available on compact devices from the app bar rather
    // than making the entire mobile shell fail for a platform administrator.
    final compactDestinations = destinations
        .where((item) => item.section != HomeSection.platformAdmin)
        .toList(growable: false);
    final compactIndex = compactDestinations.indexWhere(
      (destination) => destination.section == section,
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
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  profile.displayName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  venueOverride?.name ?? 'Market Street',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ],
        ),
        actions: [
          if (isPlatformAdmin && !wide)
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
                Positioned.fill(child: _buildBody(section, profile)),
                const _QueuedPrintWorkerHost(),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
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
    );
  }

  Widget _buildBody(HomeSection section, TenantProfile profile) =>
      switch (section) {
        HomeSection.pos => PosPage(currencyCode: profile.currencyCode),
        HomeSection.orderFlow => const OrderFlowPage(),
        HomeSection.menu => MenuManagementPage(
          currencyCode: profile.currencyCode,
        ),
        HomeSection.reports => const _ReportsPage(),
        HomeSection.settings => SettingsPage(
          profileOverride: profileOverride,
          persistToFirebase: persistCompanyProfile,
        ),
        HomeSection.platformAdmin => const PlatformAdminPage(),
      };
}

class _QueuedPrintWorkerHost extends ConsumerStatefulWidget {
  const _QueuedPrintWorkerHost();

  @override
  ConsumerState<_QueuedPrintWorkerHost> createState() =>
      _QueuedPrintWorkerHostState();
}

class _QueuedPrintWorkerHostState
    extends ConsumerState<_QueuedPrintWorkerHost> {
  final QueuedBluetoothPrintWorker _worker = QueuedBluetoothPrintWorker();
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
      if (_queuedJobCount > 0) unawaited(_processAvailable(scope));
    });
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
          AppLogger.info('Queued Bluetooth printer: ticket printed.');
        } else {
          AppLogger.error(
            'Queued Bluetooth printer',
            StateError(
              'A queued ticket failed and will be retried or flagged.',
            ),
            StackTrace.current,
          );
          showAppNotification(
            context,
            ref: ref,
            title: 'Production ticket needs attention',
            message:
                'A production ticket could not print. It will retry automatically.',
            level: AppNotificationLevel.error,
          );
          // A failed job is requeued for a delayed retry, so do not spin on it.
          return;
        }
      }
    } on Object catch (error, stackTrace) {
      AppLogger.error('Queued Bluetooth print worker', error, stackTrace);
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

class _ReportsPage extends StatelessWidget {
  const _ReportsPage();

  @override
  Widget build(BuildContext context) {
    final metrics = [
      ('Closed sales', '£1,842.50', Icons.payments_outlined),
      ('Closed orders', '48', Icons.receipt_long_outlined),
      ('Open tabs', '6', Icons.tab_rounded),
      ('Avg. spend', '£38.39', Icons.trending_up_rounded),
    ];
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Today’s sales', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 6),
        const Text(
          'Closed orders only. Open tabs remain attached to their originating business day.',
        ),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 800 ? 4 : 2;
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: metrics.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisExtent: 130,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemBuilder: (context, index) {
                final metric = metrics[index];
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(metric.$3),
                        const Spacer(),
                        Text(
                          metric.$2,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        Text(
                          metric.$1,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
        const SizedBox(height: 20),
        Card(
          child: ListTile(
            leading: const Icon(Icons.calendar_month_outlined),
            title: const Text('Business-day rollover'),
            subtitle: const Text(
              'Keep tabs open; close them against the current business day when payment is taken.',
            ),
            trailing: TextButton(
              onPressed: () {},
              child: const Text('View open tabs'),
            ),
          ),
        ),
      ],
    );
  }
}
