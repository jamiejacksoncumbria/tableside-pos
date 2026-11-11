part of '../platform_admin_page.dart';

Future<void> _showCreateStaffDialog(BuildContext context, WidgetRef ref) async {
  final email = TextEditingController();
  final displayName = TextEditingController();
  var submitting = false;

  await showAppDialog<void>(
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

Future<List<PlatformLocationEntry>?> _loadPlatformLocations(
  BuildContext context,
  PlatformAdminRepository repository,
) async {
  try {
    return await repository.listPlatformLocations();
  } on Object catch (error, stackTrace) {
    AppLogger.error('Load platform locations', error, stackTrace);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load countries and towns: $error')),
      );
    }
    return null;
  }
}

Future<void> _showPlatformLocations(BuildContext context, WidgetRef ref) async {
  final repository = ref.read(platformAdminRepositoryProvider);
  var locations = await _loadPlatformLocations(context, repository);
  if (locations == null || !context.mounted) return;
  await showAppDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('Countries, districts & towns'),
        content: SizedBox(
          width: 620,
          height: 480,
          child: locations!.isEmpty
              ? const Center(
                  child: Text(
                    'No custom locations yet. North Cyprus remains available by default.',
                  ),
                )
              : ListView.builder(
                  itemCount: locations!.length,
                  itemBuilder: (_, index) {
                    final item = locations![index];
                    return ListTile(
                      leading: const Icon(Icons.location_on_outlined),
                      title: Text(item.town),
                      subtitle: Text('${item.district} · ${item.country}'),
                      trailing: IconButton(
                        tooltip: 'Remove location',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          await repository.deletePlatformLocation(item.id);
                          if (!context.mounted) return;
                          setDialogState(
                            () => locations = [
                              for (final value in locations!)
                                if (value.id != item.id) value,
                            ],
                          );
                        },
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            onPressed: () async {
              final added = await _addPlatformLocation(context, repository);
              if (added != null && context.mounted) {
                setDialogState(() {
                  locations = [...locations!, added]
                    ..sort(
                      (a, b) => '${a.country}${a.district}${a.town}'.compareTo(
                        '${b.country}${b.district}${b.town}',
                      ),
                    );
                });
              }
            },
            icon: const Icon(Icons.add_location_alt_outlined),
            label: const Text('Add location'),
          ),
        ],
      ),
    ),
  );
}

Future<PlatformLocationEntry?> _addPlatformLocation(
  BuildContext context,
  PlatformAdminRepository repository,
) async {
  final country = TextEditingController();
  final district = TextEditingController();
  final town = TextEditingController();
  final key = GlobalKey<FormState>();
  try {
    final save = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add platform location'),
        content: Form(
          key: key,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: country,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Country'),
                validator: (value) => _requiredField(value, 'Country'),
              ),
              TextFormField(
                controller: district,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'City / district'),
                validator: (value) => _requiredField(value, 'City / district'),
              ),
              TextFormField(
                controller: town,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Town / area'),
                validator: (value) => _requiredField(value, 'Town / area'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (key.currentState?.validate() == true) {
                Navigator.pop(dialogContext, true);
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (save != true) return null;
    return await repository.savePlatformLocation(
      country: country.text,
      district: district.text,
      town: town.text,
    );
  } finally {
    country.dispose();
    district.dispose();
    town.dispose();
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
