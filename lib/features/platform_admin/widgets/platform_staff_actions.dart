part of '../platform_admin_page.dart';

Future<void> _sendPasswordReset(
  BuildContext context,
  WidgetRef ref,
  String email,
) async {
  try {
    await ref
        .read(platformAdminRepositoryProvider)
        .sendPasswordResetEmail(email);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Firebase accepted the password-reset email request.'),
        ),
      );
    }
  } on Object catch (error, stackTrace) {
    AppLogger.error('Send password reset email', error, stackTrace);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not request a password reset: $error')),
      );
    }
  }
}

Future<void> _confirmRetireStaffUser(
  BuildContext context,
  WidgetRef ref,
  PlatformAuthUser user,
) async {
  var retiring = false;
  await showAppDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('Delete staff account?'),
        content: Text(
          'Delete ${user.email.isEmpty ? user.uid : user.email}? This safely disables sign-in and removes restaurant access. The UID and staff profile are retained so past orders, bills, and sales remain attributed correctly.',
        ),
        actions: [
          TextButton(
            onPressed: retiring ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: retiring
                ? null
                : () async {
                    setDialogState(() => retiring = true);
                    try {
                      await ref
                          .read(platformAdminRepositoryProvider)
                          .retireStaffUser(user.uid);
                      ref.invalidate(platformAuthUsersProvider);
                      final messenger = ScaffoldMessenger.of(dialogContext);
                      if (context.mounted) Navigator.pop(context);
                      messenger.showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Staff account deleted safely. Historical records were retained.',
                          ),
                        ),
                      );
                    } on Object catch (error, stackTrace) {
                      AppLogger.error(
                        'Delete staff account',
                        error,
                        stackTrace,
                      );
                      setDialogState(() => retiring = false);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Could not delete account: $error'),
                          ),
                        );
                      }
                    }
                  },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: Text(retiring ? 'Deleting…' : 'Delete safely'),
          ),
        ],
      ),
    ),
  );
}

Future<void> _showAssignUserDialog(
  BuildContext context,
  WidgetRef ref,
  PlatformAuthUser user,
  List<PlatformTenantSummary> tenants,
) async {
  final repository = ref.read(platformAdminRepositoryProvider);
  late final List<PlatformStaffMembership> memberships;
  try {
    memberships = await repository.listUserMemberships(user.uid);
  } on Object catch (error, stackTrace) {
    AppLogger.error('Load staff roles for editing', error, stackTrace);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load staff roles: $error')),
      );
    }
    return;
  }
  if (!context.mounted) return;

  final membershipByTenant = <String, PlatformStaffMembership>{
    for (final membership in memberships) membership.tenantId: membership,
  };
  PlatformTenantSummary? firstAssignedTenant;
  for (final tenant in tenants) {
    if (membershipByTenant.containsKey(tenant.id)) {
      firstAssignedTenant = tenant;
      break;
    }
  }
  var tenantId = firstAssignedTenant?.id ?? tenants.first.id;
  var roles = <String>{...?membershipByTenant[tenantId]?.roles};
  var submitting = false;

  await showAppDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text(
          'Manage roles: ${user.email.isEmpty ? user.uid : user.email}',
        ),
        content: SingleChildScrollView(
          child: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: tenantId,
                  decoration: const InputDecoration(
                    labelText: 'Restaurant company',
                  ),
                  items: [
                    for (final tenant in tenants)
                      DropdownMenuItem(
                        value: tenant.id,
                        child: Text(tenant.displayName),
                      ),
                  ],
                  onChanged: submitting
                      ? null
                      : (value) => setDialogState(() {
                          tenantId = value!;
                          roles = <String>{
                            ...?membershipByTenant[tenantId]?.roles,
                          };
                        }),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    membershipByTenant.containsKey(tenantId)
                        ? 'Saved roles: ${membershipByTenant[tenantId]!.roles.map((role) => _staffRoleLabels[role] ?? role).join(', ')}'
                        : 'No access has been assigned to this restaurant yet.',
                  ),
                ),
                const SizedBox(height: 8),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Roles — select one or more'),
                ),
                const SizedBox(height: 4),
                for (final entry in _staffRoleLabels.entries)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(entry.value),
                    value: roles.contains(entry.key),
                    onChanged: submitting
                        ? null
                        : (selected) => setDialogState(() {
                            if (selected ?? false) {
                              roles.add(entry.key);
                            } else {
                              roles.remove(entry.key);
                            }
                          }),
                  ),
                const SizedBox(height: 8),
                const Text(
                  'Saving replaces this user’s roles for the selected restaurant. Choose another restaurant to give them access there too.',
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: submitting ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: submitting
                ? null
                : () async {
                    if (roles.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Select at least one role.'),
                        ),
                      );
                      return;
                    }
                    setDialogState(() => submitting = true);
                    try {
                      await repository.assignUserToTenant(
                        tenantId: tenantId,
                        userUid: user.uid,
                        roles: roles.toList(growable: false),
                      );
                      final messenger = ScaffoldMessenger.of(dialogContext);
                      if (context.mounted) Navigator.pop(context);
                      messenger.showSnackBar(
                        const SnackBar(content: Text('Staff roles saved.')),
                      );
                    } on Object catch (error, stackTrace) {
                      AppLogger.error('Save staff roles', error, stackTrace);
                      setDialogState(() => submitting = false);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Could not assign access: $error'),
                          ),
                        );
                      }
                    }
                  },
            child: Text(submitting ? 'Saving…' : 'Save roles'),
          ),
        ],
      ),
    ),
  );
}

const _staffRoleLabels = <String, String>{
  'owner': 'Owner',
  'manager': 'Manager',
  'waiter': 'Waiter',
  'cashier': 'Cashier',
  'kitchen': 'Kitchen',
  'driver': 'Delivery driver',
  'printer': 'Printer device',
};

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          child,
        ],
      ),
    ),
  );
}
