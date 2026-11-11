part of '../home_shell.dart';

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
class _HomeAppBarBottom extends StatelessWidget implements PreferredSizeWidget {
  const _HomeAppBarBottom();

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: const [
      _VenueHubStatusStrip(),
      SizedBox(height: 46, child: _CurrentOrderLocationIndicator()),
    ],
  );
}

/// A reserved, full-width connection line beneath the app-bar actions. Unlike
/// the former floating badge, this strip participates in layout and therefore
/// can never cover venue, notification or POS controls.
class _VenueHubStatusStrip extends StatelessWidget {
  const _VenueHubStatusStrip();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: VenueHubAvailability.status,
    builder: (context, status, _) {
      final (background, foreground, icon) = switch (status.connectivity) {
        VenueHubConnectivity.online => (
          const Color(0xff2e7d32),
          Colors.white,
          Icons.cloud_done_rounded,
        ),
        VenueHubConnectivity.cloudOnly => (
          const Color(0xffef6c00),
          Colors.white,
          Icons.cloud_outlined,
        ),
        VenueHubConnectivity.lanOnly => (
          const Color(0xfff9a825),
          Colors.black,
          Icons.wifi_rounded,
        ),
        VenueHubConnectivity.unavailable => (
          Theme.of(context).colorScheme.error,
          Theme.of(context).colorScheme.onError,
          Icons.cloud_off_rounded,
        ),
        VenueHubConnectivity.checking => (
          Theme.of(context).colorScheme.surfaceContainerHighest,
          Theme.of(context).colorScheme.onSurfaceVariant,
          Icons.sync_rounded,
        ),
        VenueHubConnectivity.unknown => (
          Theme.of(context).colorScheme.surfaceContainerLow,
          Theme.of(context).colorScheme.onSurfaceVariant,
          Icons.hub_outlined,
        ),
      };
      final label = status.connectivity == VenueHubConnectivity.unknown
          ? 'Hub status unavailable'
          : status.shortLabel;
      final showStaging =
          FirebaseRuntimeConfig.enabled && AppEnvironment.isStaging;
      return Semantics(
        liveRegion: true,
        label: label,
        child: SizedBox(
          height: 18,
          child: Row(
            children: [
              if (showStaging)
                const Expanded(
                  child: _StatusStripSegment(
                    background: Color(0xffff9800),
                    foreground: Colors.black,
                    icon: Icons.science_outlined,
                    label: 'STAGING · TEST DATA ONLY',
                  ),
                ),
              Expanded(
                child: _StatusStripSegment(
                  background: background,
                  foreground: foreground,
                  icon: icon,
                  label: label,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _StatusStripSegment extends StatelessWidget {
  const _StatusStripSegment({
    required this.background,
    required this.foreground,
    required this.icon,
    required this.label,
  });

  final Color background;
  final Color foreground;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: background,
    child: Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: foreground),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: foreground,
                fontSize: 10,
                height: 1,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _CurrentOrderLocationIndicator extends ConsumerWidget {
  const _CurrentOrderLocationIndicator();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final order = ref.watch(activeOrderProvider);
    final homeSection = ref.watch(homeSectionProvider);
    final compactPosTab = ref.watch(posCompactTabProvider);
    final mediaSize = MediaQuery.sizeOf(context);
    final posUsesThreePanels =
        mediaSize.width >= 1200 && mediaSize.height >= 780;
    final showMenuSearch =
        homeSection == HomeSection.pos &&
        (posUsesThreePanels || compactPosTab == 1);
    final tabName = order.tabName?.trim();
    final tableId = order.tableId;
    final scheme = Theme.of(context).colorScheme;
    final needsAttention = order.hasPendingProductionLines;
    final identityColor = needsAttention
        ? (Theme.of(context).brightness == Brightness.dark
              ? Colors.orangeAccent
              : Colors.orange.shade800)
        : scheme.primary;
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Icon(icon, size: 18, color: identityColor),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: needsAttention ? identityColor : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (showMenuSearch)
                SizedBox(
                  width: (constraints.maxWidth * .42)
                      .clamp(260.0, 480.0)
                      .toDouble(),
                  height: 36,
                  child: const PosQuickSearchField(),
                ),
              if (showMenuSearch) const Spacer(),
            ],
          ),
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
