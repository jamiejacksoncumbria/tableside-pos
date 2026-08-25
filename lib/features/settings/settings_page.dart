import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../data/tenant_profile_repository.dart';
import '../notifications/notification_centre.dart';
import '../printing/bluetooth_printer_setup_page.dart';
import '../printing/venue_printer_routing_page.dart';
import '../pos/domain.dart';
import '../pos/pos_controller.dart';
import '../tables/table_management_page.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({
    super.key,
    this.profileOverride,
    this.persistToFirebase = false,
  });

  final TenantProfile? profileOverride;
  final bool persistToFirebase;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final TextEditingController _displayName;
  late final TextEditingController _legalName;
  late final TextEditingController _address;
  late final List<TextEditingController> _phoneNumbers;
  late final TextEditingController _footer;
  Uint8List? _logoBytes;
  String? _logoName;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final TenantProfile profile =
        widget.profileOverride ?? ref.read(tenantProfileProvider);
    _displayName = TextEditingController(text: profile.displayName);
    _legalName = TextEditingController(text: profile.legalName);
    _address = TextEditingController(text: profile.address);
    final phones = profile.phoneNumbers.isEmpty
        ? (profile.phone.trim().isEmpty ? const <String>[] : [profile.phone])
        : profile.phoneNumbers;
    _phoneNumbers = List<TextEditingController>.generate(
      3,
      (index) => TextEditingController(
        text: index < phones.length ? phones[index] : '',
      ),
    );
    _footer = TextEditingController(text: profile.receiptFooter);
  }

  @override
  void dispose() {
    _displayName.dispose();
    _legalName.dispose();
    _address.dispose();
    for (final controller in _phoneNumbers) {
      controller.dispose();
    }
    _footer.dispose();
    super.dispose();
  }

  Future<void> _selectLogo() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
      allowMultiple: false,
    );
    final file = result?.files.single;
    if (file?.bytes == null || !mounted) return;
    setState(() {
      _logoBytes = file!.bytes;
      _logoName = file.name;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final TenantProfile profile =
          widget.profileOverride ?? ref.read(tenantProfileProvider);
      var updated = profile.copyWith(
        displayName: _displayName.text.trim(),
        legalName: _legalName.text.trim(),
        address: _address.text.trim(),
        phoneNumbers: _phoneNumbers
            .map((controller) => controller.text.trim())
            .where((number) => number.isNotEmpty)
            .take(3)
            .toList(growable: false),
        receiptFooter: _footer.text.trim(),
      );
      if (widget.persistToFirebase) {
        final repository = TenantProfileRepository(
          FirebaseFirestore.instance,
          FirebaseStorage.instance,
        );
        if (_logoBytes != null && _logoName != null) {
          final logoUrl = await repository.uploadLogo(
            tenantId: updated.id,
            bytes: _logoBytes!,
            fileName: _logoName!,
            contentType: _contentTypeFor(_logoName!),
          );
          updated = updated.copyWith(logoUrl: logoUrl);
        }
        await repository.saveProfile(updated);
      } else {
        ref.read(tenantProfileProvider.notifier).update(updated);
      }
      if (mounted) {
        showAppNotification(
          context,
          ref: ref,
          title: 'Company profile saved',
          message: widget.persistToFirebase
              ? 'Company profile saved to Firebase.'
              : 'Company profile saved locally in this starter.',
          level: AppNotificationLevel.success,
        );
      }
    } on Object catch (error, stackTrace) {
      AppLogger.error('Save company profile', error, stackTrace);
      if (mounted) {
        showAppNotification(
          context,
          ref: ref,
          title: 'Could not save company profile',
          message: 'Could not save company profile: $error',
          level: AppNotificationLevel.error,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _contentTypeFor(String fileName) {
    final name = fileName.toLowerCase();
    if (name.endsWith('.png')) return 'image/png';
    if (name.endsWith('.webp')) return 'image/webp';
    if (name.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg';
  }

  @override
  Widget build(BuildContext context) {
    final TenantProfile profile =
        widget.profileOverride ?? ref.watch(tenantProfileProvider);
    final venueScope = ref.watch(activeVenueScopeProvider);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Organisation settings',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        const Text(
          'These details are stored per tenant and can be snapshotted on receipts.',
        ),
        const SizedBox(height: 20),
        Center(
          child: Column(
            children: [
              CircleAvatar(
                radius: 44,
                foregroundImage: _logoBytes == null
                    ? null
                    : MemoryImage(_logoBytes!),
                backgroundImage: _logoBytes == null && profile.logoUrl != null
                    ? NetworkImage(profile.logoUrl!)
                    : null,
                child: _logoBytes == null && profile.logoUrl == null
                    ? const Icon(Icons.storefront_rounded, size: 40)
                    : null,
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _selectLogo,
                icon: const Icon(Icons.upload_file_rounded),
                label: Text(
                  _logoName == null
                      ? 'Upload company logo'
                      : 'Selected: $_logoName',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _SettingsCard(
          title: 'Company profile',
          child: LayoutBuilder(
            builder: (context, constraints) {
              final twoColumns = constraints.maxWidth >= 700;
              final fields = [
                TextField(
                  controller: _displayName,
                  decoration: const InputDecoration(labelText: 'Trading name'),
                ),
                TextField(
                  controller: _legalName,
                  decoration: const InputDecoration(
                    labelText: 'Legal company name',
                  ),
                ),
                TextField(
                  controller: _address,
                  decoration: const InputDecoration(labelText: 'Address'),
                ),
                for (var index = 0; index < _phoneNumbers.length; index++)
                  TextField(
                    controller: _phoneNumbers[index],
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      labelText: index == 0
                          ? 'Phone number'
                          : 'Additional phone number ${index + 1}',
                    ),
                  ),
              ];
              if (!twoColumns) {
                return Column(
                  children: [
                    for (final field in fields) ...[
                      field,
                      const SizedBox(height: 12),
                    ],
                    TextField(
                      controller: _footer,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Receipt footer',
                      ),
                    ),
                  ],
                );
              }
              return Column(
                children: [
                  Row(
                    children: [
                      Expanded(child: fields[0]),
                      const SizedBox(width: 12),
                      Expanded(child: fields[1]),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: fields[2]),
                      const SizedBox(width: 12),
                      Expanded(child: fields[3]),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: fields[4]),
                      const SizedBox(width: 12),
                      Expanded(child: fields[5]),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _footer,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Receipt footer',
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        _SettingsCard(
          title: 'Venues and devices',
          child: Column(
            children: [
              ListTile(
                leading: Icon(Icons.store_outlined),
                title: const Text('Venue tables'),
                subtitle: const Text(
                  'Create and safely manage table numbers and names.',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const TableManagementPage(),
                  ),
                ),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.print_outlined),
                title: const Text('Bluetooth printer setup'),
                subtitle: const Text(
                  'Pair a 58 mm ESC/POS printer and send a test ticket.',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => BluetoothPrinterSetupPage(
                      restaurantName: profile.displayName,
                      venueRoutingKey: venueScope == null
                          ? 'demo'
                          : '${venueScope.tenantId}_${venueScope.venueId}',
                    ),
                  ),
                ),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.account_tree_outlined),
                title: const Text('Shared printer routes'),
                subtitle: const Text(
                  'Register this device and route bar, kitchen, and dessert tickets.',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const VenuePrinterRoutingPage(),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save company details'),
          ),
        ),
      ],
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}
