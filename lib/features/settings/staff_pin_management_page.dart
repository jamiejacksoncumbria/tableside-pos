import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../data/production_command_repository.dart';
import '../auth/staff_pin_gate.dart';
import '../notifications/notification_centre.dart';

class StaffPinManagementPage extends ConsumerStatefulWidget {
  const StaffPinManagementPage({super.key});

  @override
  ConsumerState<StaffPinManagementPage> createState() =>
      _StaffPinManagementPageState();
}

class _StaffPinManagementPageState
    extends ConsumerState<StaffPinManagementPage> {
  List<VenuePinStaff>? _staff;
  Object? _error;
  String? _busyUserId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final scope = ref.read(activeVenueScopeProvider);
    if (scope == null) {
      setState(() => _error = StateError('Choose a venue first.'));
      return;
    }
    setState(() => _error = null);
    try {
      final staff = await ref
          .read(productionCommandRepositoryProvider)
          .listVenuePinStaff(scope);
      if (!mounted) return;
      staff.sort((a, b) {
        if (a.pinLocked != b.pinLocked) return a.pinLocked ? -1 : 1;
        return a.displayName.toLowerCase().compareTo(
          b.displayName.toLowerCase(),
        );
      });
      setState(() => _staff = staff);
    } on Object catch (error, stackTrace) {
      AppLogger.error('Load staff PIN access', error, stackTrace);
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _unlock(VenuePinStaff staff) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unlock staff PIN?'),
        content: Text(
          '${staff.displayName} will be able to use their existing PIN again. '
          'All earlier PIN sessions will be invalidated and this action will be audited.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.lock_open_rounded),
            label: const Text('Unlock PIN'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final scope = ref.read(activeVenueScopeProvider);
    if (scope == null) return;
    setState(() => _busyUserId = staff.userId);
    try {
      await ref
          .read(productionCommandRepositoryProvider)
          .unlockStaffPin(scope: scope, userId: staff.userId);
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Staff PIN unlocked',
        message:
            '${staff.displayName} can now sign in with their existing PIN.',
        level: AppNotificationLevel.success,
      );
      await _load();
    } on Object catch (error, stackTrace) {
      AppLogger.error('Unlock staff PIN', error, stackTrace);
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Could not unlock staff PIN',
        message: '$error',
        level: AppNotificationLevel.error,
      );
    } finally {
      if (mounted) setState(() => _busyUserId = null);
    }
  }

  Future<void> _lock(VenuePinStaff staff) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Lock staff PIN?'),
        content: Text(
          '${staff.displayName} will be unable to use the POS until a manager unlocks or resets the PIN. Existing PIN sessions will be invalidated.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.lock_rounded),
            label: const Text('Lock PIN'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final scope = ref.read(activeVenueScopeProvider);
    if (scope == null) return;
    setState(() => _busyUserId = staff.userId);
    try {
      await ref
          .read(productionCommandRepositoryProvider)
          .lockStaffPin(scope: scope, userId: staff.userId);
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Staff PIN locked',
        message: '${staff.displayName} can no longer unlock the POS.',
        level: AppNotificationLevel.success,
      );
      await _load();
    } on Object catch (error, stackTrace) {
      AppLogger.error('Lock staff PIN', error, stackTrace);
      if (mounted) {
        showAppNotification(
          context,
          ref: ref,
          title: 'Could not lock staff PIN',
          message: '$error',
          level: AppNotificationLevel.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busyUserId = null);
    }
  }

  Future<void> _reset(VenuePinStaff staff) async {
    final newPin = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          _ManagerResetPinDialog(staffName: staff.displayName),
    );
    if (newPin == null || !mounted) return;
    final scope = ref.read(activeVenueScopeProvider);
    if (scope == null) return;
    setState(() => _busyUserId = staff.userId);
    try {
      await ref
          .read(productionCommandRepositoryProvider)
          .resetStaffPin(scope: scope, userId: staff.userId, newPin: newPin);
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Staff PIN reset',
        message:
            '${staff.displayName} can now sign in using the replacement PIN.',
        level: AppNotificationLevel.success,
      );
      await _load();
    } on Object catch (error, stackTrace) {
      AppLogger.error('Reset staff PIN', error, stackTrace);
      if (mounted) {
        showAppNotification(
          context,
          ref: ref,
          title: 'Could not reset staff PIN',
          message: '$error',
          level: AppNotificationLevel.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busyUserId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Staff PIN access'),
        actions: [
          IconButton(
            tooltip: 'Refresh staff',
            onPressed: _busyUserId == null ? _load : null,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(onRefresh: _load, child: _body()),
    );
  }

  Widget _body() {
    if (_staff == null && _error == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Icon(Icons.error_outline_rounded, size: 48),
          const SizedBox(height: 12),
          Text(
            'Staff PIN access could not be loaded.\n$_error',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Center(
            child: FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try again'),
            ),
          ),
        ],
      );
    }

    final staff = _staff ?? const <VenuePinStaff>[];
    final activeStaffUserId = ref.read(activeStaffPinSessionProvider)?.userId;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Card(
          child: ListTile(
            leading: Icon(Icons.security_rounded),
            title: Text('Manager-controlled PIN recovery'),
            subtitle: Text(
              'Managers can lock, unlock, or securely replace staff PINs. Every action invalidates earlier sessions and creates an audit record. Only owners can manage another owner’s PIN.',
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (staff.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('No active staff are assigned to this venue.'),
          )
        else
          for (final member in staff)
            Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: member.pinLocked
                      ? Theme.of(context).colorScheme.errorContainer
                      : null,
                  child: Icon(
                    member.pinLocked
                        ? Icons.lock_rounded
                        : member.hasPin
                        ? Icons.verified_user_outlined
                        : Icons.pin_outlined,
                  ),
                ),
                title: Text(member.displayName),
                subtitle: Text(
                  member.pinLocked
                      ? 'PIN blocked after failed attempts'
                      : member.hasPin
                      ? 'PIN active'
                      : 'PIN has not been created',
                ),
                trailing: _busyUserId == member.userId
                    ? const SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : member.userId == activeStaffUserId
                    ? const Text('Use Change my PIN')
                    : PopupMenuButton<_PinAction>(
                        tooltip: 'Manage ${member.displayName} PIN',
                        enabled: _busyUserId == null,
                        onSelected: (action) {
                          switch (action) {
                            case _PinAction.unlock:
                              _unlock(member);
                            case _PinAction.lock:
                              _lock(member);
                            case _PinAction.reset:
                              _reset(member);
                          }
                        },
                        itemBuilder: (context) => [
                          if (member.pinLocked)
                            const PopupMenuItem(
                              value: _PinAction.unlock,
                              child: ListTile(
                                leading: Icon(Icons.lock_open_rounded),
                                title: Text('Unlock existing PIN'),
                              ),
                            )
                          else if (member.hasPin)
                            const PopupMenuItem(
                              value: _PinAction.lock,
                              child: ListTile(
                                leading: Icon(Icons.lock_rounded),
                                title: Text('Lock PIN'),
                              ),
                            ),
                          const PopupMenuItem(
                            value: _PinAction.reset,
                            child: ListTile(
                              leading: Icon(Icons.pin_outlined),
                              title: Text('Set replacement PIN'),
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

enum _PinAction { unlock, lock, reset }

class _ManagerResetPinDialog extends StatefulWidget {
  const _ManagerResetPinDialog({required this.staffName});

  final String staffName;

  @override
  State<_ManagerResetPinDialog> createState() => _ManagerResetPinDialogState();
}

class _ManagerResetPinDialogState extends State<_ManagerResetPinDialog> {
  final _pinController = TextEditingController();
  final _confirmationController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pinController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  void _submit() {
    final pin = _pinController.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
      setState(() => _error = 'Enter exactly six digits.');
      return;
    }
    if (_confirmationController.text.trim() != pin) {
      setState(() => _error = 'The two PIN entries do not match.');
      return;
    }
    Navigator.of(context).pop(pin);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Set PIN for ${widget.staffName}'),
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'This replaces the staff member’s PIN, unlocks the account, and invalidates every earlier PIN session.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _pinController,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            maxLength: 6,
            decoration: const InputDecoration(
              labelText: 'New six-digit PIN',
              border: OutlineInputBorder(),
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _confirmationController,
            obscureText: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            maxLength: 6,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(
              labelText: 'Confirm new PIN',
              border: OutlineInputBorder(),
              counterText: '',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Set PIN')),
    ],
  );
}
