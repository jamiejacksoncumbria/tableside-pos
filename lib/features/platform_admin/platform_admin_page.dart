import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../data/platform_admin_repository.dart';
import '../auth/session_providers.dart';

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
                          subtitle: SelectableText(tenant.id),
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
                              SelectableText(user.uid),
                            ],
                          ),
                          isThreeLine: true,
                          trailing: Wrap(
                            spacing: 4,
                            children: [
                              if (user.email.isNotEmpty)
                                TextButton(
                                  onPressed: () => _sendPasswordReset(
                                    context,
                                    ref,
                                    user.email,
                                  ),
                                  child: const Text('Send reset'),
                                ),
                              if (tenantItems.isNotEmpty)
                                TextButton(
                                  onPressed: () => _showAssignUserDialog(
                                    context,
                                    ref,
                                    user,
                                    tenantItems,
                                  ),
                                  child: const Text('Assign'),
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

Future<void> _showCreateRestaurantDialog(
  BuildContext context,
  WidgetRef ref,
  List<PlatformAuthUser> users,
) async {
  final formKey = GlobalKey<FormState>();
  final tradingName = TextEditingController();
  final legalName = TextEditingController();
  final venueName = TextEditingController();
  final timeZone = TextEditingController(text: 'Europe/London');
  var ownerUid = users.first.uid;
  var submitting = false;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('Create restaurant company'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: tradingName,
                    decoration: const InputDecoration(labelText: 'Trading name'),
                    validator: (value) =>
                        _requiredField(value, 'Trading name'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: legalName,
                    decoration: const InputDecoration(labelText: 'Legal name'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: venueName,
                    decoration: const InputDecoration(labelText: 'First venue'),
                    validator: (value) => _requiredField(value, 'First venue'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: timeZone,
                    decoration: const InputDecoration(labelText: 'Time zone'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: ownerUid,
                    decoration: const InputDecoration(labelText: 'Company owner'),
                    items: [
                      for (final user in users)
                        DropdownMenuItem(
                          value: user.uid,
                          child: Text(
                            user.email.isEmpty ? user.uid : user.email,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: submitting
                        ? null
                        : (value) => setDialogState(() => ownerUid = value!),
                  ),
                ],
              ),
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
                    if (!(formKey.currentState?.validate() ?? false)) return;
                    setDialogState(() => submitting = true);
                    try {
                      await ref
                          .read(platformAdminRepositoryProvider)
                          .createTenant(
                            displayName: tradingName.text.trim(),
                            legalName: legalName.text.trim(),
                            venueName: venueName.text.trim(),
                            timeZone: timeZone.text.trim(),
                            ownerUid: ownerUid,
                          );
                      ref.invalidate(platformTenantsProvider);
                      if (context.mounted) Navigator.pop(context);
                      if (dialogContext.mounted) {
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                          const SnackBar(content: Text('Restaurant created.')),
                        );
                      }
                    } on Exception catch (error, stackTrace) {
                      AppLogger.error(
                        'Create restaurant company',
                        error,
                        stackTrace,
                      );
                      setDialogState(() => submitting = false);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Could not create restaurant: $error',
                            ),
                          ),
                        );
                      }
                    }
                  },
            child: Text(submitting ? 'Creating…' : 'Create'),
          ),
        ],
      ),
    ),
  );
  tradingName.dispose();
  legalName.dispose();
  venueName.dispose();
  timeZone.dispose();
}

Future<void> _showCreateStaffDialog(BuildContext context, WidgetRef ref) async {
  final email = TextEditingController();
  final displayName = TextEditingController();
  var submitting = false;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('Create staff account'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: displayName,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email address'),
              ),
              const SizedBox(height: 12),
              const Text(
                'Firebase will email this address a password-reset link so the staff member chooses their own password.',
              ),
            ],
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
                    setDialogState(() => submitting = true);
                    try {
                      final user = await ref
                          .read(platformAdminRepositoryProvider)
                          .createStaffUser(
                            email: email.text.trim(),
                            displayName: displayName.text.trim(),
                          );
                      ref.invalidate(platformAuthUsersProvider);
                      var message =
                          'Account created for ${user.email}. Firebase accepted the password-reset email request.';
                      try {
                        await ref
                            .read(platformAdminRepositoryProvider)
                            .sendPasswordResetEmail(user.email);
                      } on Exception catch (error, stackTrace) {
                        AppLogger.error(
                          'Send initial password reset email',
                          error,
                          stackTrace,
                        );
                        message =
                            'Account created, but Firebase could not request the password-reset email: $error. Use Send reset after closing this dialog to retry.';
                      }
                      final messenger = ScaffoldMessenger.of(dialogContext);
                      if (context.mounted) Navigator.pop(context);
                      messenger.showSnackBar(SnackBar(content: Text(message)));
                    } on Exception catch (error, stackTrace) {
                      AppLogger.error(
                        'Create staff account',
                        error,
                        stackTrace,
                      );
                      setDialogState(() => submitting = false);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Could not create account: $error'),
                          ),
                        );
                      }
                    }
                  },
            child: Text(submitting ? 'Creating…' : 'Create account'),
          ),
        ],
      ),
    ),
  );
  email.dispose();
  displayName.dispose();
}

String? _requiredField(String? value, String label) {
  if (value == null || value.trim().isEmpty) return '$label is required.';
  return null;
}

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
  } on Exception catch (error, stackTrace) {
    AppLogger.error('Send password reset email', error, stackTrace);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not request a password reset: $error')),
      );
    }
  }
}

Future<void> _showAssignUserDialog(
  BuildContext context,
  WidgetRef ref,
  PlatformAuthUser user,
  List<PlatformTenantSummary> tenants,
) async {
  var tenantId = tenants.first.id;
  var role = 'waiter';
  var submitting = false;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text('Assign ${user.email.isEmpty ? user.uid : user.email}'),
        content: SizedBox(
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
                    : (value) => setDialogState(() => tenantId = value!),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: role,
                decoration: const InputDecoration(labelText: 'Role'),
                items: const [
                  DropdownMenuItem(value: 'owner', child: Text('Owner')),
                  DropdownMenuItem(value: 'manager', child: Text('Manager')),
                  DropdownMenuItem(value: 'waiter', child: Text('Waiter')),
                  DropdownMenuItem(
                    value: 'printer',
                    child: Text('Printer device'),
                  ),
                ],
                onChanged: submitting
                    ? null
                    : (value) => setDialogState(() => role = value!),
              ),
            ],
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
                    setDialogState(() => submitting = true);
                    try {
                      await ref
                          .read(platformAdminRepositoryProvider)
                          .assignUserToTenant(
                            tenantId: tenantId,
                            userUid: user.uid,
                            role: role,
                          );
                      if (context.mounted) Navigator.pop(context);
                      if (dialogContext.mounted) {
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                          const SnackBar(content: Text('Access assigned.')),
                        );
                      }
                    } on Exception catch (error, stackTrace) {
                      AppLogger.error('Assign staff access', error, stackTrace);
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
            child: Text(submitting ? 'Assigning…' : 'Assign'),
          ),
        ],
      ),
    ),
  );
}

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
