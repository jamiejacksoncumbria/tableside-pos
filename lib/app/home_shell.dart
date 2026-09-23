import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/safe_dialog.dart';
import '../core/app_logger.dart';
import '../core/app_theme_controller.dart';
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
import '../features/platform_admin/platform_admin_page.dart';
import '../features/printing/print_delivery_monitor.dart';
import '../features/reports/reports_page.dart';
import '../features/settings/settings_page.dart';
import '../features/training/training_mode_page.dart';

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
          'Delivery',
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
              bottom: const PreferredSize(
                preferredSize: Size.fromHeight(42),
                child: _CurrentOrderLocationIndicator(),
              ),
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
    HomeSection.bookings => BookingCalendarPage(
      defaultDurationMinutes:
          venueOverride?.defaultBookingDurationMinutes ?? 120,
    ),
    HomeSection.orderFlow => OrderFlowPage(
      amberMinutes: venueOverride?.orderFlowAmberMinutes ?? 15,
      redMinutes: venueOverride?.orderFlowRedMinutes ?? 25,
    ),
    HomeSection.fulfilment => const FulfilmentOperationsPage(),
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

Future<void> _endTrainingFromWorkspace({
  required BuildContext context,
  required WidgetRef ref,
  required VenueScope scope,
  required TrainingModeSession session,
}) async {
  try {
    await ref
        .read(productionCommandRepositoryProvider)
        .endTrainingMode(scope: scope, trainingSessionId: session.id);
    ref.read(trainingModeProvider.notifier).clear();
    ref.read(trainingOpenOrdersProvider.notifier).clear();
    ref.read(homeSectionProvider.notifier).select(HomeSection.settings);
    if (!context.mounted) return;
    showAppNotification(
      context,
      ref: ref,
      title: 'Training mode ended',
      message: 'Returned to venue settings. No live sale data was changed.',
      level: AppNotificationLevel.success,
    );
  } on Object catch (error, stackTrace) {
    AppLogger.error('End training mode from POS', error, stackTrace);
    if (!context.mounted) return;
    showAppNotification(
      context,
      ref: ref,
      title: 'Could not end training mode',
      message: '$error',
      level: AppNotificationLevel.error,
    );
  }
}

Future<void> _changeOwnAppearance({
  required BuildContext context,
  required WidgetRef ref,
  required VenueScope scope,
}) async {
  final selected = await showAppDialog<String>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: const Text('My appearance'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(dialogContext, 'venue'),
          child: const ListTile(
            leading: Icon(Icons.storefront_outlined),
            title: Text('Venue default'),
          ),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(dialogContext, 'light'),
          child: const ListTile(
            leading: Icon(Icons.light_mode_outlined),
            title: Text('Light'),
          ),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(dialogContext, 'dark'),
          child: const ListTile(
            leading: Icon(Icons.dark_mode_outlined),
            title: Text('Dark'),
          ),
        ),
      ],
    ),
  );
  if (selected == null || !context.mounted) return;
  try {
    await ref
        .read(productionCommandRepositoryProvider)
        .updateOwnThemePreference(scope: scope, themeMode: selected);
    ref.read(appThemeControllerProvider.notifier).applyUserPreference(selected);
    if (context.mounted) {
      showAppNotification(
        context,
        ref: ref,
        title: 'Appearance updated',
        message: selected == 'venue'
            ? 'You are now using the venue default appearance.'
            : 'Your ${selected == 'dark' ? 'dark' : 'light'} appearance will follow you across devices.',
        level: AppNotificationLevel.success,
      );
    }
  } on Object catch (error, stackTrace) {
    AppLogger.error('Update own appearance', error, stackTrace);
    if (!context.mounted) return;
    showAppNotification(
      context,
      ref: ref,
      title: 'Could not update appearance',
      message: '$error',
      level: AppNotificationLevel.error,
    );
  }
}

class _VenueLogo extends StatelessWidget {
  const _VenueLogo({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final fallback = CircleAvatar(
      radius: 16,
      child: const Icon(Icons.storefront_rounded, size: 18),
    );
    final value = url?.trim();
    if (value == null || value.isEmpty) return fallback;
    return ClipOval(
      child: Image.network(
        value,
        width: 32,
        height: 32,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
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
    final customerName = order.customerName?.trim();
    final (icon, label) = order.channel == OrderChannel.delivery
        ? (
            Icons.delivery_dining_rounded,
            'Delivery · ${customerName?.isNotEmpty == true ? customerName : 'Customer'}',
          )
        : order.channel == OrderChannel.collection
        ? (
            Icons.shopping_bag_outlined,
            'Collection · ${customerName?.isNotEmpty == true ? customerName : 'Customer'}',
          )
        : tabName?.isNotEmpty == true
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

/// A compact navigation rail that remains usable when role-based destinations
/// outgrow the available window height.
///
/// Material's [NavigationRail] contains a flex child and therefore cannot be
/// placed in a vertical scroll view. Doing so gives it unbounded height and
/// prevents the entire authenticated workspace from laying out after PIN
/// entry. This rail uses a bounded [ListView] and keeps every destination
/// reachable on short Windows displays and landscape tablets.
class _ScrollableHomeRail extends StatelessWidget {
  const _ScrollableHomeRail({
    required this.destinations,
    required this.selectedSection,
    required this.onSelected,
  });

  final List<_Destination> destinations;
  final HomeSection selectedSection;
  final ValueChanged<HomeSection> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: SafeArea(
        right: false,
        child: SizedBox(
          width: 112,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            itemCount: destinations.length,
            separatorBuilder: (_, _) => const SizedBox(height: 4),
            itemBuilder: (context, index) {
              final destination = destinations[index];
              final selected = destination.section == selectedSection;
              return Semantics(
                selected: selected,
                button: true,
                label: destination.label,
                child: Tooltip(
                  message: destination.label,
                  child: Material(
                    color: selected
                        ? scheme.secondaryContainer
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => onSelected(destination.section),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 9,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              destination.icon,
                              color: selected
                                  ? scheme.onSecondaryContainer
                                  : scheme.onSurfaceVariant,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              destination.label,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(
                                    color: selected
                                        ? scheme.onSecondaryContainer
                                        : scheme.onSurfaceVariant,
                                    fontWeight: selected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Destination {
  const _Destination(this.section, this.icon, this.label);

  final HomeSection section;
  final IconData icon;
  final String label;
}
