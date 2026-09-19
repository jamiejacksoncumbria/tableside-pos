import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../notifications/notification_centre.dart';
import 'fulfilment_domain.dart';
import 'fulfilment_repository.dart';

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
  final existingAddress = existing?.addresses.firstOrNull;
  final addressLabel = TextEditingController(
    text: existingAddress?.label ?? 'Home',
  );
  final country = TextEditingController(
    text: existingAddress?.country ?? 'North Cyprus',
  );
  final town = TextEditingController(text: existingAddress?.town);
  final area = TextEditingController(text: existingAddress?.area);
  final addressLines = TextEditingController(
    text: existingAddress?.addressLines,
  );

  try {
    return await showDialog<VenueCustomer>(
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
                      TextField(
                        controller: addressLabel,
                        decoration: const InputDecoration(
                          labelText: 'Address label',
                        ),
                      ),
                      TextFormField(
                        controller: country,
                        decoration: const InputDecoration(labelText: 'Country'),
                        validator: (value) =>
                            (requireAddress ||
                                    addressLines.text.trim().isNotEmpty) &&
                                value?.trim().isEmpty != false
                            ? 'Enter the country.'
                            : null,
                      ),
                      TextFormField(
                        controller: town,
                        decoration: const InputDecoration(labelText: 'Town'),
                        validator: (value) =>
                            (requireAddress ||
                                    addressLines.text.trim().isNotEmpty) &&
                                value?.trim().isEmpty != false
                            ? 'Enter the town.'
                            : null,
                      ),
                      TextFormField(
                        controller: area,
                        decoration: const InputDecoration(labelText: 'Area'),
                        validator: (value) =>
                            (requireAddress ||
                                    addressLines.text.trim().isNotEmpty) &&
                                value?.trim().isEmpty != false
                            ? 'Enter the area.'
                            : null,
                      ),
                      TextFormField(
                        controller: addressLines,
                        maxLines: 2,
                        decoration: InputDecoration(
                          labelText: requireAddress
                              ? 'Delivery address'
                              : 'Address (optional)',
                        ),
                        validator: (value) =>
                            requireAddress && value?.trim().isEmpty != false
                            ? 'Enter the delivery address.'
                            : null,
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
                        final hasAddress = addressLines.text.trim().isNotEmpty;
                        final addresses = hasAddress
                            ? <CustomerAddress>[
                                CustomerAddress(
                                  id: existingAddress?.id.isNotEmpty == true
                                      ? existingAddress!.id
                                      : '${DateTime.now().microsecondsSinceEpoch}',
                                  label: addressLabel.text.trim().isEmpty
                                      ? 'Home'
                                      : addressLabel.text.trim(),
                                  country: country.text.trim(),
                                  town: town.text.trim(),
                                  area: area.text.trim(),
                                  addressLines: addressLines.text.trim(),
                                ),
                              ]
                            : const <CustomerAddress>[];
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
    addressLabel.dispose();
    country.dispose();
    town.dispose();
    area.dispose();
    addressLines.dispose();
  }
}
