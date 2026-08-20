import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/money.dart';
import '../features/pos/domain.dart';
import '../features/pos/pos_controller.dart';
import '../features/pos/pos_page.dart';
import '../features/platform_admin/platform_admin_page.dart';
import '../features/settings/settings_page.dart';

enum HomeSection { pos, menu, reports, settings, platformAdmin }

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
    final TenantProfile profile =
        profileOverride ?? ref.watch(tenantProfileProvider);
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final destinations = [
      const _Destination(HomeSection.pos, Icons.point_of_sale_rounded, 'POS'),
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
          IconButton(
            tooltip: 'Notifications',
            onPressed: () {},
            icon: const Badge(child: Icon(Icons.notifications_none_rounded)),
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
          Expanded(child: _buildBody(section, profile)),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: index,
              onDestinationSelected: (selected) => ref
                  .read(homeSectionProvider.notifier)
                  .select(destinations[selected].section),
              destinations: [
                for (final item in destinations)
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
        HomeSection.menu => _MenuManagementPage(
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

class _Destination {
  const _Destination(this.section, this.icon, this.label);

  final HomeSection section;
  final IconData icon;
  final String label;
}

class _MenuManagementPage extends StatelessWidget {
  const _MenuManagementPage({required this.currencyCode});

  final String currencyCode;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Menu management',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            FilledButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add product'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'Products can belong to more than one section and route to a production area.',
        ),
        const SizedBox(height: 20),
        Card(
          child: Column(
            children: [
              for (final product in demoProducts)
                ListTile(
                  leading: CircleAvatar(
                    child: Icon(
                      product.productionArea == ProductionArea.bar
                          ? Icons.local_bar_rounded
                          : Icons.restaurant_rounded,
                    ),
                  ),
                  title: Text(product.name),
                  subtitle: Text(
                    '${product.sectionIds.join(' · ')}  •  ${product.trackStock ? 'stock tracked' : 'not tracked'}',
                  ),
                  trailing: Text(
                    formatMoney(product.priceMinor, currencyCode: currencyCode),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
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
