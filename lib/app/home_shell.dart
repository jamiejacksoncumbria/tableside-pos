import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/safe_dialog.dart';
import '../core/app_environment.dart';
import '../core/app_logger.dart';
import '../core/app_theme_controller.dart';
import '../core/firebase_runtime_config.dart';
import '../core/tenant_scope.dart';
import '../core/training_mode.dart';
import '../data/production_command_repository.dart';
import '../features/bookings/booking_calendar_page.dart';
import '../features/fulfilment/fulfilment_management_page.dart';
import '../features/order_flow/order_flow_page.dart';
import '../features/auth/staff_pin_gate.dart';
import '../features/menu/menu_management_page.dart';
import '../features/notifications/notification_centre.dart';
import '../features/notifications/push_notification_host.dart';
import '../features/pos/domain.dart';
import '../features/pos/pos_controller.dart';
import '../features/pos/pos_page.dart';
import '../features/pos/pos_quick_search_field.dart';
import '../features/platform_admin/platform_admin_page.dart';
import '../features/printing/print_delivery_monitor.dart';
import '../features/reports/reports_page.dart';
import '../features/settings/settings_page.dart';
import '../features/settings/venue_offline_hub_page.dart';
import '../features/training/training_mode_page.dart';
import '../offline/venue_hub_client_cache.dart';
import '../offline/venue_hub_client_registry.dart';
import '../offline/venue_hub_availability.dart';
import '../offline/venue_hub_backup_monitor.dart';
import '../offline/venue_hub_realtime_client.dart';
import '../offline/venue_hub_runtime.dart';

part 'widgets/home_hub_status_hosts.dart';
part 'widgets/home_actions.dart';
part 'widgets/home_navigation_chrome.dart';

enum HomeSection {
  pos,
  bookings,
  orderFlow,
  fulfilment,
  menu,
  reports,
  settings,
  platformAdmin,
}

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
    final trainingSession = ref.watch(trainingModeProvider);
    final trainingModeActive = trainingSession != null;
    final venueScope = ref.watch(activeVenueScopeProvider);
    // Shared terminals use the verified PIN identity for authority. The
    // Firebase email account only keeps the device online; it must never grant
    // platform tools to a different selected member.
    final canOpenPlatformTools = staffSession?.isPlatformAdmin == true;
    final canManageVenue =
        staffSession?.roles.any(
          (role) => role == 'owner' || role == 'manager',
        ) ??
        false;
    final canUseFulfilment =
        staffSession?.roles.any(
          (role) => const {
            'owner',
            'manager',
            'waiter',
            'cashier',
            'driver',
          }.contains(role),
        ) ??
        false;
    final protectedVenueSection =
        section == HomeSection.menu ||
        section == HomeSection.reports ||
        section == HomeSection.settings;
    final visibleSection = trainingModeActive
        ? HomeSection.pos
        : (section == HomeSection.platformAdmin && !canOpenPlatformTools) ||
              (protectedVenueSection && !canManageVenue)
        ? HomeSection.pos
        : section;
    final compactPosTab = ref.watch(posCompactTabProvider);
    final TenantProfile profile =
        profileOverride ?? ref.watch(tenantProfileProvider);
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final immersiveCompactPosMenu =
        !wide &&
        visibleSection == HomeSection.pos &&
        (compactPosTab == 1 || compactPosTab == 2);
    final destinations = [
      const _Destination(HomeSection.pos, Icons.point_of_sale_rounded, 'POS'),
      if (!trainingModeActive)
        const _Destination(
          HomeSection.bookings,
          Icons.event_note_rounded,
          'Bookings',
        ),
      if (!trainingModeActive)
        const _Destination(
          HomeSection.orderFlow,
          Icons.monitor_heart_outlined,
          'Order flow',
        ),
      if (canUseFulfilment && !trainingModeActive)
        const _Destination(
          HomeSection.fulfilment,
          Icons.delivery_dining_outlined,
          'Collect / deliver',
        ),
      if (canManageVenue && !trainingModeActive)
        const _Destination(
          HomeSection.menu,
          Icons.restaurant_menu_rounded,
          'Menu',
        ),
      if (canManageVenue && !trainingModeActive)
        const _Destination(
          HomeSection.reports,
          Icons.bar_chart_rounded,
          'Reports',
        ),
      if (canManageVenue && !trainingModeActive)
        const _Destination(
          HomeSection.settings,
          Icons.settings_outlined,
          'Settings',
        ),
      if (canOpenPlatformTools && !trainingModeActive)
        const _Destination(
          HomeSection.platformAdmin,
          Icons.admin_panel_settings_outlined,
          'Platform',
        ),
    ];
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
      appBar: immersiveCompactPosMenu
          ? null
          : AppBar(
              titleSpacing: wide ? 20 : 12,
              title: Row(
                children: [
                  _VenueLogo(url: profile.logoUrl),
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
                if (trainingModeActive)
                  IconButton(
                    tooltip: 'End or manage training mode',
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const TrainingModePage(),
                      ),
                    ),
                    icon: const Icon(Icons.school_rounded),
                  ),
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
                if (staffSession != null &&
                    ref.watch(activeVenueScopeProvider) != null)
                  IconButton(
                    tooltip: 'My appearance',
                    onPressed: () => _changeOwnAppearance(
                      context: context,
                      ref: ref,
                      scope: ref.read(activeVenueScopeProvider)!,
                    ),
                    icon: const Icon(Icons.brightness_6_outlined),
                  ),
                if (staffSession != null &&
                    ref.watch(activeVenueScopeProvider) != null)
                  IconButton(
                    tooltip: 'Change my PIN',
                    onPressed: () => changeCurrentStaffPin(
                      context: context,
                      ref: ref,
                      scope: ref.read(activeVenueScopeProvider)!,
                    ),
                    icon: const Icon(Icons.pin_outlined),
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
              bottom: const _HomeAppBarBottom(),
            ),
      body: Row(
        children: [
          if (wide)
            _ScrollableHomeRail(
              destinations: destinations,
              selectedSection: visibleSection,
              onSelected: (section) =>
                  ref.read(homeSectionProvider.notifier).select(section),
            ),
          Expanded(
            // The print worker is intentionally invisible. A default loose
            // Stack sizes itself from non-positioned children, so this stack
            // could collapse to the worker's zero height inside the outer Row
            // and hide every venue screen. Expand to the workspace bounds.
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: Column(
                    children: [
                      if (trainingModeActive)
                        Container(
                          width: double.infinity,
                          color: Colors.red.shade800,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Flexible(
                                child: Text(
                                  'TRAINING MODE · NO REAL SALES OR STOCK',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              FilledButton.tonalIcon(
                                onPressed: venueScope == null
                                    ? null
                                    : () => _endTrainingFromWorkspace(
                                        context: context,
                                        ref: ref,
                                        scope: venueScope,
                                        session: trainingSession,
                                      ),
                                icon: const Icon(Icons.exit_to_app_rounded),
                                label: const Text('Exit'),
                              ),
                            ],
                          ),
                        ),
                      Expanded(child: _buildBody(visibleSection, profile)),
                    ],
                  ),
                ),
                if (Firebase.apps.isNotEmpty) const PrintDeliveryMonitorHost(),
                if (Firebase.apps.isNotEmpty) const OrderFlowNotificationHost(),
                if (Firebase.apps.isNotEmpty)
                  const OperationalNotificationHost(),
                if (Firebase.apps.isNotEmpty) const PushNotificationHost(),
                const _VenueHubAccessNotificationHost(),
                const _VenueHubSynchronizationNotificationHost(),
                const _VenueHubRealtimeStatusHost(),
                const _VenueHubTakeoverPromptHost(),
              ],
            ),
          ),
        ],
      ),
      // Notifications live in the scaffold's bottom area rather than as a
      // floating SnackBar. This reserves layout space, so a message can never
      // cover a POS control or require staff to dismiss it before continuing.
      bottomNavigationBar: immersiveCompactPosMenu
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _BottomNotificationTray(),
                if (!wide)
                  NavigationBar(
                    height: 60,
                    labelBehavior:
                        NavigationDestinationLabelBehavior.alwaysHide,
                    selectedIndex: compactIndex < 0 ? 0 : compactIndex,
                    onDestinationSelected: (selected) => ref
                        .read(homeSectionProvider.notifier)
                        .select(compactDestinations[selected].section),
                    destinations: [
                      for (final item in compactDestinations)
                        NavigationDestination(
                          // Explicit centring prevents short labels/icons from
                          // inheriting asymmetric space on narrow Android
                          // navigation bars.
                          icon: Center(child: Icon(item.icon)),
                          selectedIcon: Center(child: Icon(item.icon)),
                          label: item.label,
                        ),
                    ],
                  ),
              ],
            ),
    );
  }

  Widget _buildBody(HomeSection section, TenantProfile profile) =>
      switch (section) {
        HomeSection.pos => PosPage(currencyCode: profile.currencyCode),
        HomeSection.bookings =>
          Firebase.apps.isEmpty
              ? const _CloudFeatureUnavailable(feature: 'Bookings')
              : BookingCalendarPage(
                  defaultDurationMinutes:
                      venueOverride?.defaultBookingDurationMinutes ?? 120,
                ),
        HomeSection.orderFlow => OrderFlowPage(
          amberMinutes: venueOverride?.orderFlowAmberMinutes ?? 15,
          redMinutes: venueOverride?.orderFlowRedMinutes ?? 25,
        ),
        HomeSection.fulfilment => const FulfilmentOperationsPage(),
        HomeSection.menu =>
          Firebase.apps.isEmpty
              ? const _CloudFeatureUnavailable(feature: 'Menu management')
              : MenuManagementPage(currencyCode: profile.currencyCode),
        HomeSection.reports =>
          Firebase.apps.isEmpty
              ? const _CloudFeatureUnavailable(feature: 'Reports')
              : ReportsPage(
                  currencyCode: profile.currencyCode,
                  businessDayCutoffMinutes:
                      venueOverride?.businessDayCutoffMinutes ?? 240,
                ),
        HomeSection.settings => SettingsPage(
          profileOverride: profileOverride,
          venueOverride: venueOverride,
          persistToFirebase: persistCompanyProfile,
        ),
        HomeSection.platformAdmin =>
          Firebase.apps.isEmpty
              ? const _CloudFeatureUnavailable(
                  feature: 'Platform administration',
                )
              : const PlatformAdminPage(),
      };
}

/// Starts the browser's RTDB presence listener as soon as the unlocked venue
/// workspace appears. Previously this was effectively lazy: if the PIN path's
/// fire-and-forget setup raced a rebuild, hub status remained "unknown" until
/// an order command happened to configure the same channel.
