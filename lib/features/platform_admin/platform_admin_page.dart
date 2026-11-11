import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/safe_dialog.dart';
import '../../core/app_logger.dart';
import '../../data/platform_admin_repository.dart';
import '../auth/session_providers.dart';

part 'widgets/platform_restaurant_editor.dart';
part 'widgets/platform_staff_location_editor.dart';
part 'widgets/platform_staff_actions.dart';

class PlatformAdminPage extends ConsumerWidget {
  const PlatformAdminPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final users = ref.watch(platformAuthUsersProvider);
    final tenants = ref.watch(platformTenantsProvider);
    final userItems = users.value ?? const <PlatformAuthUser>[];
    final tenantItems = tenants.value ?? const <PlatformTenantSummary>[];

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Platform administration',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Create restaurant companies, provision staff accounts, and assign access safely.',
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: () {
                ref.invalidate(platformAuthUsersProvider);
                ref.invalidate(platformTenantsProvider);
              },
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              onPressed: userItems.isEmpty
                  ? null
                  : () => _showCreateRestaurantDialog(context, ref, userItems),
              icon: const Icon(Icons.add_business_outlined),
              label: const Text('Create restaurant'),
            ),
            OutlinedButton.icon(
              onPressed: () => _showCreateStaffDialog(context, ref),
              icon: const Icon(Icons.person_add_alt_1_outlined),
              label: const Text('Create staff account'),
            ),
            OutlinedButton.icon(
              onPressed: () => _showPlatformLocations(context, ref),
              icon: const Icon(Icons.public_rounded),
              label: const Text('Countries & towns'),
            ),
          ],
        ),
        if (userItems.isEmpty && !users.isLoading) ...[
          const SizedBox(height: 10),
          const Text(
            'Create the first staff or owner account before creating a restaurant.',
          ),
        ],
        const SizedBox(height: 24),
        _SectionCard(
          title: 'Restaurant companies',
          child: tenants.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Text('Could not load restaurants: $error'),
            data: (items) => items.isEmpty
                ? const Text('No restaurant companies have been created yet.')
                : Column(
                    children: [
                      for (final tenant in items)
                        ListTile(
                          leading: const Icon(Icons.storefront_outlined),
                          title: Text(tenant.displayName),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (tenant.legalName.isNotEmpty)
                                Text(tenant.legalName),
                              Text('Currency: ${tenant.currencyCode}'),
                              SelectableText(tenant.id),
                            ],
                          ),
                          isThreeLine: true,
                          trailing: TextButton(
                            onPressed: () =>
                                _showEditRestaurantDialog(context, ref, tenant),
                            child: const Text('Edit'),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: 'Firebase accounts',
          child: users.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Text('Could not load accounts: $error'),
            data: (items) => items.isEmpty
                ? const Text('No Firebase Authentication accounts were found.')
                : Column(
                    children: [
                      for (final user in items)
                        ListTile(
                          leading: CircleAvatar(
                            child: Icon(
                              user.isPlatformAdmin
                                  ? Icons.admin_panel_settings_outlined
                                  : Icons.person_outline_rounded,
                            ),
                          ),
                          title: Text(
                            user.displayName.isEmpty
                                ? (user.email.isEmpty
                                      ? 'Unnamed account'
                                      : user.email)
                                : user.displayName,
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (user.email.isNotEmpty) Text(user.email),
                              if (user.disabled)
                                const Text(
                                  'Retired — sign-in and restaurant access disabled',
                                ),
                              SelectableText(user.uid),
                            ],
                          ),
                          isThreeLine: true,
                          trailing: Wrap(
                            spacing: 4,
                            children: [
                              if (!user.disabled && user.email.isNotEmpty)
                                TextButton(
                                  onPressed: () => _sendPasswordReset(
                                    context,
                                    ref,
                                    user.email,
                                  ),
                                  child: const Text('Send reset'),
                                ),
                              if (!user.disabled && tenantItems.isNotEmpty)
                                TextButton(
                                  onPressed: () => _showAssignUserDialog(
                                    context,
                                    ref,
                                    user,
                                    tenantItems,
                                  ),
                                  child: const Text('Manage roles'),
                                ),
                              if (!user.disabled && !user.isPlatformAdmin)
                                TextButton(
                                  onPressed: () => _confirmRetireStaffUser(
                                    context,
                                    ref,
                                    user,
                                  ),
                                  child: const Text('Delete'),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}
