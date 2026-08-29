import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../data/tenant_profile_repository.dart';
import '../../data/production_command_repository.dart';
import '../auth/staff_pin_gate.dart';
import '../notifications/notification_centre.dart';
import '../printing/bluetooth_printer_setup_page.dart';
import '../printing/print_queue_recovery_page.dart';
import '../printing/venue_printer_routing_page.dart';
import '../printing/windows_printer_setup_page.dart';
import '../pos/domain.dart';
import '../pos/pos_controller.dart';
import '../tables/table_management_page.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({
    super.key,
    this.profileOverride,
    this.venueOverride,
    this.persistToFirebase = false,
  });

  final TenantProfile? profileOverride;
  final Venue? venueOverride;
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
  late final TextEditingController _notificationRetentionSeconds;
  late final TextEditingController _orderFlowAmberMinutes;
  late final TextEditingController _orderFlowRedMinutes;
  late int _businessDayCutoffMinutes;
  Uint8List? _logoBytes;
  String? _logoName;
  bool _saving = false;
  bool _savingNotificationRetention = false;

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
    _notificationRetentionSeconds = TextEditingController(
      text: '${widget.venueOverride?.notificationRetentionSeconds ?? 5}',
    );
    _orderFlowAmberMinutes = TextEditingController(
      text: '${widget.venueOverride?.orderFlowAmberMinutes ?? 15}',
    );
    _orderFlowRedMinutes = TextEditingController(
      text: '${widget.venueOverride?.orderFlowRedMinutes ?? 25}',
    );
    _businessDayCutoffMinutes =
        widget.venueOverride?.pendingBusinessDayCutoffMinutes ??
        widget.venueOverride?.businessDayCutoffMinutes ??
        240;
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
    _notificationRetentionSeconds.dispose();
    _orderFlowAmberMinutes.dispose();
    _orderFlowRedMinutes.dispose();
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
        final repository = TenantProfileRepository();
        final scope = ref.read(activeVenueScopeProvider);
        if (scope == null) {
          throw StateError('Choose a venue before saving company details.');
        }
        if (_logoBytes != null && _logoName != null) {
          final logoUrl = await repository.uploadLogo(
            scope: scope,
            bytes: _logoBytes!,
            fileName: _logoName!,
            contentType: _contentTypeFor(_logoName!),
          );
          updated = updated.copyWith(logoUrl: logoUrl);
        }
        await repository.saveProfile(scope: scope, profile: updated);
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

  Future<void> _saveVenueNotificationRetention(VenueScope scope) async {
    if (_savingNotificationRetention) return;
    final seconds = int.tryParse(_notificationRetentionSeconds.text.trim());
    final amberMinutes = int.tryParse(_orderFlowAmberMinutes.text.trim());
    final redMinutes = int.tryParse(_orderFlowRedMinutes.text.trim());
    if (seconds == null || seconds < 1 || seconds > 60) {
      showAppNotification(
        context,
        ref: ref,
        title: 'Enter a valid notification time',
        message: 'Choose a whole number from 1 to 60 seconds.',
        level: AppNotificationLevel.warning,
      );
      return;
    }
    if (amberMinutes == null ||
        amberMinutes < 1 ||
        amberMinutes > 240 ||
        redMinutes == null ||
        redMinutes <= amberMinutes ||
        redMinutes > 480) {
      showAppNotification(
        context,
        ref: ref,
        title: 'Enter valid order warning times',
        message:
            'Amber must be 1–240 minutes and red must be later than amber (up to 480 minutes).',
        level: AppNotificationLevel.warning,
      );
      return;
    }
    setState(() => _savingNotificationRetention = true);
    try {
      await ref
          .read(productionCommandRepositoryProvider)
          .updateVenueOperationalSettings(
            scope: scope,
            seconds: seconds,
            orderFlowAmberMinutes: amberMinutes,
            orderFlowRedMinutes: redMinutes,
            businessDayCutoffMinutes: _businessDayCutoffMinutes,
          );
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Venue notification timing saved',
        message:
            'Notifications dismiss after $seconds seconds; orders warn at $amberMinutes/$redMinutes minutes. The day-end setting was saved safely.',
        level: AppNotificationLevel.success,
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Save venue notification timing', error, stackTrace);
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Could not save notification timing',
        message: '$error',
        level: AppNotificationLevel.error,
      );
    } finally {
      if (mounted) setState(() => _savingNotificationRetention = false);
    }
  }

  Future<void> _pickBusinessDayCutoff() async {
    final selected = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: _businessDayCutoffMinutes ~/ 60,
        minute: _businessDayCutoffMinutes % 60,
      ),
      helpText: 'Select venue business-day cut-off',
    );
    if (selected == null || !mounted) return;
    setState(() {
      _businessDayCutoffMinutes = selected.hour * 60 + selected.minute;
    });
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
    final staffSession = ref.watch(activeStaffPinSessionProvider);
    final canManageVenue =
        venueScope != null &&
        (staffSession?.roles.any(
              (role) => role == 'owner' || role == 'manager',
            ) ??
            false);
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
              if (!kIsWeb &&
                  defaultTargetPlatform == TargetPlatform.android) ...[
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.bluetooth_rounded),
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
              ],
              if (!kIsWeb &&
                  defaultTargetPlatform == TargetPlatform.windows) ...[
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.print_rounded),
                  title: const Text('Windows USB/network printer setup'),
                  subtitle: const Text(
                    'Choose an installed Windows printer and send a test ticket.',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => WindowsPrinterSetupPage(
                        restaurantName: profile.displayName,
                      ),
                    ),
                  ),
                ),
              ],
              const Divider(),
              ListTile(
                leading: const Icon(Icons.restart_alt_rounded),
                title: const Text('Print queue recovery'),
                subtitle: const Text(
                  'See live printer failures and let a manager reprint safely.',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PrintQueueRecoveryPage(),
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
        if (venueScope != null && canManageVenue) ...[
          const SizedBox(height: 16),
          _SettingsCard(
            title: 'Venue operational settings',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Notification retention for ${widget.venueOverride?.name ?? 'this venue'}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 6),
                const Text(
                  'The bell centre and temporary app messages clear automatically after this time.',
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _notificationRetentionSeconds,
                  keyboardType: TextInputType.number,
                  enabled: !_savingNotificationRetention,
                  decoration: const InputDecoration(
                    labelText: 'Notification display time (seconds)',
                    helperText: '1 to 60 seconds; the default is 5 seconds.',
                    suffixText: 'seconds',
                  ),
                ),
                const SizedBox(height: 14),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final amberField = TextField(
                      controller: _orderFlowAmberMinutes,
                      keyboardType: TextInputType.number,
                      enabled: !_savingNotificationRetention,
                      decoration: const InputDecoration(
                        labelText: 'Order amber warning',
                        helperText: 'Default: 15 minutes',
                        suffixText: 'minutes',
                      ),
                    );
                    final redField = TextField(
                      controller: _orderFlowRedMinutes,
                      keyboardType: TextInputType.number,
                      enabled: !_savingNotificationRetention,
                      decoration: const InputDecoration(
                        labelText: 'Order red warning',
                        helperText: 'Must be later than amber',
                        suffixText: 'minutes',
                      ),
                    );
                    if (constraints.maxWidth < 560) {
                      return Column(
                        children: [
                          amberField,
                          const SizedBox(height: 12),
                          redField,
                        ],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: amberField),
                        const SizedBox(width: 12),
                        Expanded(child: redField),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 14),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule_rounded),
                  title: const Text('Business-day cut-off'),
                  subtitle: Text(
                    '${_formatClockMinutes(_businessDayCutoffMinutes)} · changes apply from the next business day and never alter closed bills'
                    '${widget.venueOverride?.pendingBusinessDayCutoffEffectiveDate == null ? '' : '\nPending from ${widget.venueOverride!.pendingBusinessDayCutoffEffectiveDate}'}',
                  ),
                  trailing: OutlinedButton(
                    onPressed: _savingNotificationRetention
                        ? null
                        : _pickBusinessDayCutoff,
                    child: const Text('Change'),
                  ),
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: _savingNotificationRetention
                        ? null
                        : () => _saveVenueNotificationRetention(venueScope),
                    icon: const Icon(Icons.timer_outlined),
                    label: Text(
                      _savingNotificationRetention
                          ? 'Saving…'
                          : 'Save venue timings',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
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

String _formatClockMinutes(int minutes) {
  final safe = minutes.clamp(0, 1439);
  final hour = safe ~/ 60;
  final minute = safe % 60;
  return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
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
