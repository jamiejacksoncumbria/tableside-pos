import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../data/production_command_repository.dart';
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
  String? _unlockingUserId;

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
    setState(() => _unlockingUserId = staff.userId);
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
      if (mounted) setState(() => _unlockingUserId = null);
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
            onPressed: _unlockingUserId == null ? _load : null,
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
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Card(
          child: ListTile(
            leading: Icon(Icons.security_rounded),
            title: Text('Manager-controlled PIN recovery'),
            subtitle: Text(
              'Blocked staff keep their private PIN. Unlocking clears failed attempts, invalidates earlier sessions, and creates an audit record.',
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
                trailing: member.pinLocked
                    ? FilledButton.icon(
                        onPressed: _unlockingUserId == null
                            ? () => _unlock(member)
                            : null,
                        icon: _unlockingUserId == member.userId
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.lock_open_rounded),
                        label: const Text('Unlock'),
                      )
                    : null,
              ),
            ),
      ],
    );
  }
}
