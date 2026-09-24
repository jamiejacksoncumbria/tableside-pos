import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/safe_dialog.dart';
import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../offline/venue_hub_offline_view.dart';
import '../notifications/notification_centre.dart';
import '../auth/session_providers.dart';
import 'fulfilment_domain.dart';
import 'fulfilment_repository.dart';
import 'delivery_location_catalogue.dart';

/// Creates or edits a venue customer without leaving the current workflow.
/// Writes remain server mediated so duplicate telephone and permission checks
/// cannot be bypassed by a modified client.
Future<VenueCustomer?> showVenueCustomerEditor({
  required BuildContext context,
  required WidgetRef ref,
  required VenueScope scope,
  VenueCustomer? existing,
  bool requireAddress = false,
}) async {
  final formKey = GlobalKey<FormState>();
  final name = TextEditingController(text: existing?.displayName);
  final phone = TextEditingController(
    text: existing?.phoneNumbers.elementAtOrNull(0),
  );
  final phoneTwo = TextEditingController(
    text: existing?.phoneNumbers.elementAtOrNull(1),
  );
  final phoneThree = TextEditingController(
    text: existing?.phoneNumbers.elementAtOrNull(2),
  );
  final email = TextEditingController(text: existing?.email);
  final addresses = <CustomerAddress>[...?existing?.addresses];
  final venues = ref.read(venuesProvider(scope.tenantId)).value;
  final venue = venues?.where((item) => item.id == scope.venueId).firstOrNull;
  final offlineView = VenueHubOfflineView.instance;
  final venueCountry = venue?.country.trim().isNotEmpty == true
      ? venue!.country.trim()
      : offlineView.venueCountry;
  final venueLocations = venue?.deliveryLocations.isNotEmpty == true
      ? venue!.deliveryLocations
      : offlineView.deliveryLocations.isNotEmpty
      ? offlineView.deliveryLocations
      : venueCountry == northernCyprusCountryName
      ? northernCyprusDeliveryLocations
      : const <String, List<String>>{};

  try {
    return await showAppDialog<VenueCustomer>(
      context: context,
      builder: (dialogContext) {
        var saving = false;
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(
              existing == null ? 'Add telephone customer' : 'Edit customer',
            ),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: name,
                        autofocus: existing == null,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: 'Customer name',
                        ),
                        validator: (value) => value?.trim().isEmpty != false
                            ? 'Enter the customer name.'
                            : null,
                      ),
                      TextFormField(
                        controller: phone,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'Telephone number',
                        ),
                        validator: (value) => value?.trim().isEmpty != false
                            ? 'Enter a telephone number.'
                            : null,
                      ),
                      TextField(
                        controller: phoneTwo,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'Second number (optional)',
                        ),
                      ),
                      TextField(
                        controller: phoneThree,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'Third number (optional)',
                        ),
                      ),
                      TextField(
                        controller: email,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Email (optional)',
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Divider(),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Saved addresses',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      if (addresses.isEmpty)
                        const ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.location_off_outlined),
                          title: Text('No saved address'),
                        )
                      else
                        for (var index = 0; index < addresses.length; index++)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              addresses[index].isDefault
                                  ? Icons.home_rounded
                                  : Icons.location_on_outlined,
                            ),
                            title: Text(
                              '${addresses[index].label}${addresses[index].isDefault ? ' · Default' : ''}',
                            ),
                            subtitle: Text(
                              '${addresses[index].oneLine}${addresses[index].latitude == null ? '' : '\nMap pin: ${addresses[index].latitude}, ${addresses[index].longitude}'}',
                            ),
                            isThreeLine: addresses[index].latitude != null,
                            trailing: Wrap(
                              spacing: 2,
                              children: [
                                IconButton(
                                  tooltip: 'Edit address',
                                  onPressed: saving
                                      ? null
                                      : () async {
                                          final edited =
                                              await _showCustomerAddressEditor(
                                                context,
                                                existing: addresses[index],
                                                countryName: venueCountry,
                                                deliveryLocations:
                                                    venueLocations,
                                              );
                                          if (edited == null) return;
                                          setDialogState(() {
                                            if (edited.isDefault) {
                                              for (
                                                var other = 0;
                                                other < addresses.length;
                                                other++
                                              ) {
                                                if (other != index) {
                                                  addresses[other] =
                                                      _withDefault(
                                                        addresses[other],
                                                        false,
                                                      );
                                                }
                                              }
                                            }
                                            addresses[index] = edited;
                                          });
                                        },
                                  icon: const Icon(Icons.edit_outlined),
                                ),
                                IconButton(
                                  tooltip: 'Remove address',
                                  onPressed: saving
                                      ? null
                                      : () => setDialogState(() {
                                          final removedDefault =
                                              addresses[index].isDefault;
                                          addresses.removeAt(index);
                                          if (removedDefault &&
                                              addresses.isNotEmpty) {
                                            addresses[0] = _withDefault(
                                              addresses[0],
                                              true,
                                            );
                                          }
                                        }),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ],
                            ),
                          ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: saving || addresses.length >= 10
                              ? null
                              : () async {
                                  final added =
                                      await _showCustomerAddressEditor(
                                        context,
                                        makeDefault: addresses.isEmpty,
                                        countryName: venueCountry,
                                        deliveryLocations: venueLocations,
                                      );
                                  if (added == null) return;
                                  setDialogState(() {
                                    if (added.isDefault) {
                                      for (
                                        var index = 0;
                                        index < addresses.length;
                                        index++
                                      ) {
                                        addresses[index] = _withDefault(
                                          addresses[index],
                                          false,
                                        );
                                      }
                                    }
                                    addresses.add(added);
                                  });
                                },
                          icon: const Icon(Icons.add_location_alt_outlined),
                          label: const Text('Add address'),
                        ),
                      ),
                      if (requireAddress && addresses.isEmpty)
                        Text(
                          'Add at least one delivery address.',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      const SizedBox(height: 8),
                      const Text(
                        'This creates an unclaimed venue record. The customer can later claim it using a verified phone number or email.',
                      ),
                      if (saving) ...[
                        const SizedBox(height: 12),
                        const LinearProgressIndicator(),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: saving
                    ? null
                    : () async {
                        if (formKey.currentState?.validate() != true) return;
                        setDialogState(() => saving = true);
                        final phones =
                            [phone.text, phoneTwo.text, phoneThree.text]
                                .map((value) => value.trim())
                                .where((value) => value.isNotEmpty)
                                .toList(growable: false);
                        if (requireAddress && addresses.isEmpty) {
                          setDialogState(() => saving = false);
                          return;
                        }
                        try {
                          final id = await ref
                              .read(fulfilmentRepositoryProvider)
                              .saveCustomer(
                                scope: scope,
                                customerId: existing?.id,
                                displayName: name.text,
                                phoneNumbers: phones,
                                email: email.text.trim().isEmpty
                                    ? null
                                    : email.text,
                                addresses: addresses,
                              );
                          if (!dialogContext.mounted) return;
                          Navigator.pop(
                            dialogContext,
                            VenueCustomer(
                              id: id,
                              displayName: name.text.trim(),
                              phoneNumbers: phones,
                              email: email.text.trim().isEmpty
                                  ? null
                                  : email.text.trim(),
                              addresses: addresses,
                              claimStatus: existing?.claimStatus ?? 'unclaimed',
                              globalCustomerId: existing?.globalCustomerId,
                              createdAt: existing?.createdAt,
                            ),
                          );
                        } on Object catch (error, stackTrace) {
                          AppLogger.error(
                            'Save venue customer',
                            error,
                            stackTrace,
                          );
                          if (!dialogContext.mounted) return;
                          setDialogState(() => saving = false);
                          showAppNotification(
                            dialogContext,
                            ref: ref,
                            title: 'Customer was not saved',
                            message: '$error',
                            level: AppNotificationLevel.error,
                          );
                        }
                      },
                child: const Text('Save customer'),
              ),
            ],
          ),
        );
      },
    );
  } finally {
    name.dispose();
    phone.dispose();
    phoneTwo.dispose();
    phoneThree.dispose();
    email.dispose();
  }
}

CustomerAddress _withDefault(CustomerAddress value, bool isDefault) =>
    CustomerAddress(
      id: value.id,
      label: value.label,
      country: value.country,
      town: value.town,
      area: value.area,
      addressLines: value.addressLines,
      notes: value.notes,
      isDefault: isDefault,
      latitude: value.latitude,
      longitude: value.longitude,
    );

/// Edits one delivery address and its optional map pin. Coordinates are kept
/// as numeric snapshots so a future driver app can open the exact location
/// even where conventional postcodes are unavailable.
Future<CustomerAddress?> _showCustomerAddressEditor(
  BuildContext context, {
  CustomerAddress? existing,
  bool makeDefault = false,
  required String countryName,
  required Map<String, List<String>> deliveryLocations,
}) async {
  final key = GlobalKey<FormState>();
  final label = TextEditingController(text: existing?.label ?? 'Home');
  final country = TextEditingController(text: countryName);
  final town = TextEditingController(text: existing?.town);
  final area = TextEditingController(text: existing?.area);
  String? selectedDistrict = deliveryLocations.containsKey(existing?.area)
      ? existing!.area
      : null;
  String? selectedTown =
      selectedDistrict != null &&
          (deliveryLocations[selectedDistrict] ?? const []).contains(
            existing?.town,
          )
      ? existing!.town
      : null;
  final lines = TextEditingController(text: existing?.addressLines);
  final notes = TextEditingController(text: existing?.notes);
  final latitude = TextEditingController(
    text: existing?.latitude?.toString() ?? '',
  );
  final longitude = TextEditingController(
    text: existing?.longitude?.toString() ?? '',
  );
  var isDefault = existing?.isDefault ?? makeDefault;
  try {
    return await showAppDialog<CustomerAddress>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          scrollable: true,
          title: Text(existing == null ? 'Add address' : 'Edit address'),
          content: SizedBox(
            width: 500,
            child: Form(
              key: key,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: label,
                    decoration: const InputDecoration(
                      labelText: 'Address label',
                      hintText: 'Home, Work or Villa',
                    ),
                    validator: _requiredAddressValue,
                  ),
                  InputDecorator(
                    decoration: const InputDecoration(labelText: 'Country'),
                    child: Text(countryName),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: selectedDistrict,
                    decoration: const InputDecoration(labelText: 'District'),
                    items: [
                      for (final value in deliveryLocations.keys)
                        DropdownMenuItem(value: value, child: Text(value)),
                    ],
                    validator: (value) =>
                        value == null ? 'Choose a district.' : null,
                    onChanged: (value) => setState(() {
                      selectedDistrict = value;
                      selectedTown = null;
                      area.text = value ?? '';
                      town.clear();
                    }),
                  ),
                  DropdownButtonFormField<String>(
                    key: ValueKey(selectedDistrict),
                    initialValue: selectedTown,
                    decoration: const InputDecoration(labelText: 'Town'),
                    items: [
                      for (final value
                          in deliveryLocations[selectedDistrict] ??
                              const <String>[])
                        DropdownMenuItem(value: value, child: Text(value)),
                    ],
                    validator: (value) =>
                        value == null ? 'Choose a town.' : null,
                    onChanged: selectedDistrict == null
                        ? null
                        : (value) => setState(() {
                            selectedTown = value;
                            town.text = value ?? '';
                          }),
                  ),
                  TextFormField(
                    controller: lines,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Full delivery address',
                    ),
                    validator: _requiredAddressValue,
                  ),
                  TextField(
                    controller: notes,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Driver directions (optional)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: latitude,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                            signed: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Map latitude (optional)',
                          ),
                          validator: (value) => _coordinateError(
                            value,
                            longitude.text,
                            minimum: -90,
                            maximum: 90,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextFormField(
                          controller: longitude,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                            signed: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Map longitude (optional)',
                          ),
                          validator: (value) => _coordinateError(
                            value,
                            latitude.text,
                            minimum: -180,
                            maximum: 180,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Text(
                    'Enter both coordinates to save an exact map pin for the driver.',
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: isDefault,
                    onChanged: (value) =>
                        setState(() => isDefault = value ?? false),
                    title: const Text('Default delivery address'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (key.currentState?.validate() != true) return;
                Navigator.pop(
                  dialogContext,
                  CustomerAddress(
                    id: existing?.id.isNotEmpty == true
                        ? existing!.id
                        : '${DateTime.now().microsecondsSinceEpoch}',
                    label: label.text.trim(),
                    country: country.text.trim(),
                    town: town.text.trim(),
                    area: area.text.trim(),
                    addressLines: lines.text.trim(),
                    notes: notes.text.trim(),
                    isDefault: isDefault,
                    latitude: double.tryParse(latitude.text.trim()),
                    longitude: double.tryParse(longitude.text.trim()),
                  ),
                );
              },
              child: const Text('Save address'),
            ),
          ],
        ),
      ),
    );
  } finally {
    label.dispose();
    country.dispose();
    town.dispose();
    area.dispose();
    lines.dispose();
    notes.dispose();
    latitude.dispose();
    longitude.dispose();
  }
}

String? _requiredAddressValue(String? value) =>
    value?.trim().isEmpty != false ? 'This address field is required.' : null;

String? _coordinateError(
  String? value,
  String companion, {
  required double minimum,
  required double maximum,
}) {
  final text = value?.trim() ?? '';
  if (text.isEmpty && companion.trim().isEmpty) return null;
  if (text.isEmpty) return 'Enter both coordinates.';
  final number = double.tryParse(text);
  if (number == null || number < minimum || number > maximum) {
    return 'Enter a value from $minimum to $maximum.';
  }
  return null;
}
