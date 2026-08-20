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

Future<void> _showCreateRestaurantDialog(
  BuildContext context,
  WidgetRef ref,
  List<PlatformAuthUser> users,
) async {
  final repository = ref.read(platformAdminRepositoryProvider);
  final timeZones = await _loadSupportedTimeZones(context, repository);
  if (timeZones == null || !context.mounted) return;
  final currencyCodes = await _loadSupportedCurrencyCodes(context, repository);
  if (currencyCodes == null || !context.mounted) return;

  final formKey = GlobalKey<FormState>();
  final tradingName = TextEditingController();
  final legalName = TextEditingController();
  final venueName = TextEditingController();
  var timeZone = _preferredTimeZone(timeZones);
  var currencyCode = _preferredCurrencyCode(currencyCodes);
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
                    decoration: const InputDecoration(
                      labelText: 'Trading name',
                    ),
                    validator: (value) => _requiredField(value, 'Trading name'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: legalName,
                    decoration: const InputDecoration(labelText: 'Legal name'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: currencyCode,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Functional currency',
                      helperText:
                          'Used for menu prices, bills, tax and reports',
                    ),
                    items: [
                      for (final option in currencyCodes)
                        DropdownMenuItem(value: option, child: Text(option)),
                    ],
                    onChanged: submitting
                        ? null
                        : (value) =>
                              setDialogState(() => currencyCode = value!),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: venueName,
                    decoration: const InputDecoration(labelText: 'First venue'),
                    validator: (value) => _requiredField(value, 'First venue'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: timeZone,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Time zone',
                      helperText: 'Choose the venue’s IANA time zone',
                    ),
                    items: [
                      for (final option in timeZones)
                        DropdownMenuItem(value: option, child: Text(option)),
                    ],
                    onChanged: submitting
                        ? null
                        : (value) => setDialogState(() => timeZone = value!),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: ownerUid,
                    decoration: const InputDecoration(
                      labelText: 'Company owner',
                    ),
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
                      await repository.createTenant(
                        displayName: tradingName.text.trim(),
                        legalName: legalName.text.trim(),
                        currencyCode: currencyCode,
                        venueName: venueName.text.trim(),
                        timeZone: timeZone,
                        ownerUid: ownerUid,
                      );
                      ref.invalidate(platformTenantsProvider);
                      if (context.mounted) Navigator.pop(context);
                      if (dialogContext.mounted) {
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                          const SnackBar(content: Text('Restaurant created.')),
                        );
                      }
                    } on Object catch (error, stackTrace) {
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
}

Future<void> _showEditRestaurantDialog(
  BuildContext context,
  WidgetRef ref,
  PlatformTenantSummary tenant,
) async {
  final repository = ref.read(platformAdminRepositoryProvider);
  late final List<PlatformVenueSummary> venues;
  try {
    venues = (await repository.listTenantVenues(tenant.id)).toList();
  } on Object catch (error, stackTrace) {
    AppLogger.error('Load restaurant venues for editing', error, stackTrace);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not load venues: $error')));
    }
    return;
  }
  if (!context.mounted) return;

  final formKey = GlobalKey<FormState>();
  final tradingName = TextEditingController(text: tenant.displayName);
  final legalName = TextEditingController(text: tenant.legalName);
  var savingCompany = false;
  var changingVenues = false;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text('Edit ${tenant.displayName}'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFormField(
                    controller: tradingName,
                    decoration: const InputDecoration(
                      labelText: 'Trading name',
                    ),
                    validator: (value) => _requiredField(value, 'Trading name'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: legalName,
                    decoration: const InputDecoration(labelText: 'Legal name'),
                  ),
                  const SizedBox(height: 12),
                  InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Functional currency',
                      helperText:
                          'Used for prices, bills, tax and reports. It cannot be changed after restaurant creation.',
                    ),
                    child: Text(tenant.currencyCode),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Venues',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  if (venues.isEmpty)
                    const Text('No venues have been created yet.'),
                  for (final venue in venues)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.location_on_outlined),
                      title: Text(venue.name),
                      subtitle: Text(venue.timeZone),
                      trailing: Wrap(
                        spacing: 4,
                        children: [
                          TextButton(
                            onPressed: savingCompany || changingVenues
                                ? null
                                : () async {
                                    final saved = await _showVenueDialog(
                                      context,
                                      ref,
                                      tenant.id,
                                      venue: venue,
                                    );
                                    if (saved == null || !context.mounted) {
                                      return;
                                    }
                                    setDialogState(() {
                                      final index = venues.indexWhere(
                                        (item) => item.id == saved.id,
                                      );
                                      if (index >= 0) venues[index] = saved;
                                    });
                                  },
                            child: const Text('Edit'),
                          ),
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: Theme.of(
                                context,
                              ).colorScheme.error,
                            ),
                            onPressed: savingCompany || changingVenues
                                ? null
                                : () async {
                                    final confirmed = await _confirmDeleteVenue(
                                      context,
                                      venue,
                                    );
                                    if (!confirmed || !context.mounted) return;
                                    setDialogState(() => changingVenues = true);
                                    AppLogger.info(
                                      'Delete venue: checking ${venue.id}.',
                                    );
                                    try {
                                      await repository.deleteVenue(
                                        tenantId: tenant.id,
                                        venueId: venue.id,
                                      );
                                      ref.invalidate(platformTenantsProvider);
                                      if (context.mounted) {
                                        setDialogState(
                                          () => venues.removeWhere(
                                            (item) => item.id == venue.id,
                                          ),
                                        );
                                      }
                                      ScaffoldMessenger.of(
                                        dialogContext,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'Venue deleted safely.',
                                          ),
                                        ),
                                      );
                                    } on Object catch (error, stackTrace) {
                                      AppLogger.error(
                                        'Delete venue',
                                        error,
                                        stackTrace,
                                      );
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              'Could not delete venue: $error',
                                            ),
                                          ),
                                        );
                                      }
                                    } finally {
                                      if (context.mounted) {
                                        setDialogState(
                                          () => changingVenues = false,
                                        );
                                      }
                                    }
                                  },
                            child: const Text('Delete'),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 4),
                  OutlinedButton.icon(
                    onPressed: savingCompany || changingVenues
                        ? null
                        : () async {
                            final added = await _showVenueDialog(
                              context,
                              ref,
                              tenant.id,
                            );
                            if (added == null || !context.mounted) return;
                            setDialogState(() => venues.add(added));
                          },
                    icon: const Icon(Icons.add_location_alt_outlined),
                    label: const Text('Add venue'),
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: savingCompany || changingVenues
                ? null
                : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: savingCompany || changingVenues
                ? null
                : () async {
                    if (!(formKey.currentState?.validate() ?? false)) return;
                    setDialogState(() => savingCompany = true);
                    AppLogger.info(
                      'Update restaurant company: saving ${tenant.id}.',
                    );
                    try {
                      await repository.updateTenant(
                        tenantId: tenant.id,
                        displayName: tradingName.text.trim(),
                        legalName: legalName.text.trim(),
                        currencyCode: tenant.currencyCode,
                      );
                      ref.invalidate(platformTenantsProvider);
                      final messenger = ScaffoldMessenger.of(dialogContext);
                      if (context.mounted) Navigator.pop(context);
                      messenger.showSnackBar(
                        const SnackBar(content: Text('Restaurant updated.')),
                      );
                    } on Object catch (error, stackTrace) {
                      AppLogger.error(
                        'Update restaurant company',
                        error,
                        stackTrace,
                      );
                      setDialogState(() => savingCompany = false);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Could not update restaurant: $error',
                            ),
                          ),
                        );
                      }
                    }
                  },
            child: Text(savingCompany ? 'Saving…' : 'Save restaurant'),
          ),
        ],
      ),
    ),
  );
  tradingName.dispose();
  legalName.dispose();
}

Future<PlatformVenueSummary?> _showVenueDialog(
  BuildContext context,
  WidgetRef ref,
  String tenantId, {
  PlatformVenueSummary? venue,
}) async {
  final repository = ref.read(platformAdminRepositoryProvider);
  final timeZones = await _loadSupportedTimeZones(context, repository);
  if (timeZones == null || !context.mounted) return null;

  final formKey = GlobalKey<FormState>();
  final name = TextEditingController(text: venue?.name ?? '');
  var timeZone = _preferredTimeZone(timeZones, venue?.timeZone);
  var saving = false;
  final saved = await showDialog<PlatformVenueSummary>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text(venue == null ? 'Add venue' : 'Edit venue'),
        content: Form(
          key: formKey,
          child: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Venue name'),
                  validator: (value) => _requiredField(value, 'Venue name'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: timeZone,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Time zone',
                    helperText: 'Choose from the supported IANA time zones',
                  ),
                  items: [
                    for (final option in timeZones)
                      DropdownMenuItem(value: option, child: Text(option)),
                  ],
                  onChanged: saving
                      ? null
                      : (value) => setDialogState(() => timeZone = value!),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: saving ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: saving
                ? null
                : () async {
                    if (!(formKey.currentState?.validate() ?? false)) return;
                    setDialogState(() => saving = true);
                    try {
                      final savedVenue = venue == null
                          ? await repository.createVenue(
                              tenantId: tenantId,
                              name: name.text.trim(),
                              timeZone: timeZone,
                            )
                          : await repository.updateVenue(
                              tenantId: tenantId,
                              venueId: venue.id,
                              name: name.text.trim(),
                              timeZone: timeZone,
                            );
                      ref.invalidate(platformTenantsProvider);
                      if (context.mounted) Navigator.pop(context, savedVenue);
                    } on Object catch (error, stackTrace) {
                      AppLogger.error(
                        venue == null ? 'Create venue' : 'Update venue',
                        error,
                        stackTrace,
                      );
                      setDialogState(() => saving = false);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Could not save venue: $error'),
                          ),
                        );
                      }
                    }
                  },
            child: Text(saving ? 'Saving…' : 'Save venue'),
          ),
        ],
      ),
    ),
  );
  name.dispose();
  return saved;
}

Future<bool> _confirmDeleteVenue(
  BuildContext context,
  PlatformVenueSummary venue,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Delete ${venue.name}?'),
      content: const Text(
        'This action is permanent. The app will only delete the venue when it has no tables, orders, bills, payment requests, print jobs, or printer devices. A restaurant must always keep at least one venue.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(dialogContext).colorScheme.error,
            foregroundColor: Theme.of(dialogContext).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Delete venue'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
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
                      } on Object catch (error, stackTrace) {
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
                    } on Object catch (error, stackTrace) {
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

Future<List<String>?> _loadSupportedTimeZones(
  BuildContext context,
  PlatformAdminRepository repository,
) async {
  try {
    AppLogger.info('Load supported time zones for venue editing.');
    return await repository.listSupportedTimeZones();
  } on Object catch (error, stackTrace) {
    AppLogger.error('Load supported time zones', error, stackTrace);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load time zones: $error')),
      );
    }
    return null;
  }
}

Future<List<String>?> _loadSupportedCurrencyCodes(
  BuildContext context,
  PlatformAdminRepository repository,
) async {
  try {
    AppLogger.info('Load supported currencies for restaurant editing.');
    return await repository.listSupportedCurrencyCodes();
  } on Object catch (error, stackTrace) {
    AppLogger.error('Load supported currencies', error, stackTrace);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load currencies: $error')),
      );
    }
    return null;
  }
}

String _preferredTimeZone(List<String> timeZones, [String? current]) {
  if (current != null && timeZones.contains(current)) return current;
  if (timeZones.contains('Europe/London')) return 'Europe/London';
  return timeZones.first;
}

String _preferredCurrencyCode(List<String> currencyCodes, [String? current]) {
  if (current != null && currencyCodes.contains(current)) return current;
  if (currencyCodes.contains('GBP')) return 'GBP';
  return currencyCodes.first;
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
  await showDialog<void>(
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

  await showDialog<void>(
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
