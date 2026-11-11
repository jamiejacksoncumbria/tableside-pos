part of '../platform_admin_page.dart';

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
  final locations = await _loadPlatformLocations(context, repository);
  if (locations == null || !context.mounted) return;
  final countries = <String>{
    'Kuzey Kıbrıs Türk Cumhuriyeti',
    ...locations.map((item) => item.country),
  }.toList()..sort();

  final formKey = GlobalKey<FormState>();
  final tradingName = TextEditingController();
  final legalName = TextEditingController();
  final venueName = TextEditingController();
  var timeZone = _preferredTimeZone(timeZones);
  var currencyCode = _preferredCurrencyCode(currencyCodes);
  var ownerUid = users.first.uid;
  var country = countries.first;
  var submitting = false;

  await showAppDialog<void>(
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
                    initialValue: country,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Venue country',
                      helperText:
                          'Controls customer addresses and delivery locations',
                    ),
                    items: [
                      for (final option in countries)
                        DropdownMenuItem(value: option, child: Text(option)),
                    ],
                    onChanged: submitting
                        ? null
                        : (value) => setDialogState(() => country = value!),
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
                        country: country,
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

  await showAppDialog<void>(
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
  final locations = await _loadPlatformLocations(context, repository);
  if (locations == null || !context.mounted) return null;
  final countries = <String>{
    'Kuzey Kıbrıs Türk Cumhuriyeti',
    ...locations.map((item) => item.country),
    if (venue != null) venue.country,
  }.toList()..sort();

  final formKey = GlobalKey<FormState>();
  final name = TextEditingController(text: venue?.name ?? '');
  var timeZone = _preferredTimeZone(timeZones, venue?.timeZone);
  var country = venue?.country ?? countries.first;
  var saving = false;
  final saved = await showAppDialog<PlatformVenueSummary>(
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
                  initialValue: country,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Country'),
                  items: [
                    for (final option in countries)
                      DropdownMenuItem(value: option, child: Text(option)),
                  ],
                  onChanged: saving
                      ? null
                      : (value) => setDialogState(() => country = value!),
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
                              country: country,
                            )
                          : await repository.updateVenue(
                              tenantId: tenantId,
                              venueId: venue.id,
                              name: name.text.trim(),
                              timeZone: timeZone,
                              country: country,
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
  final confirmed = await showAppDialog<bool>(
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
