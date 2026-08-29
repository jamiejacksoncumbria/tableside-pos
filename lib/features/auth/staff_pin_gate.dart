import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../core/staff_pin_session_store.dart';
import '../../data/production_command_repository.dart';

final activeStaffPinSessionProvider =
    NotifierProvider<ActiveStaffPinSessionController, StaffPinVerification?>(
      ActiveStaffPinSessionController.new,
    );

class ActiveStaffPinSessionController extends Notifier<StaffPinVerification?> {
  @override
  StaffPinVerification? build() => null;

  void unlock(StaffPinVerification session) {
    StaffPinSessionStore.current = StaffPinSessionCredentials(
      sessionId: session.sessionId,
      sessionToken: session.sessionToken,
    );
    state = session;
  }

  void lock() {
    StaffPinSessionStore.current = null;
    state = null;
  }
}

class StaffPinGate extends ConsumerStatefulWidget {
  const StaffPinGate({super.key, required this.scope, required this.child});

  final VenueScope scope;
  final Widget child;

  @override
  ConsumerState<StaffPinGate> createState() => _StaffPinGateState();
}

class _StaffPinGateState extends ConsumerState<StaffPinGate> {
  final ProductionCommandRepository _repository = ProductionCommandRepository();
  List<VenuePinStaff>? _staff;
  String? _selectedUserId;
  bool _loading = true;
  bool _submitting = false;
  String? _error;
  Timer? _expiryTimer;

  @override
  void initState() {
    super.initState();
    _loadStaff();
  }

  @override
  void didUpdateWidget(covariant StaffPinGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope) {
      ref.read(activeStaffPinSessionProvider.notifier).lock();
      _loadStaff();
    }
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadStaff() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final staff = await _repository.listVenuePinStaff(widget.scope);
      if (!mounted) return;
      final currentUserId = FirebaseAuth.instance.currentUser?.uid;
      setState(() {
        _staff = staff;
        _selectedUserId = staff.any((item) => item.userId == currentUserId)
            ? currentUserId
            : staff.firstOrNull?.userId;
        _loading = false;
      });
    } on Object catch (error, stackTrace) {
      AppLogger.error('Load venue PIN staff', error, stackTrace);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<void> _enterPin(VenuePinStaff staff) async {
    final controller = TextEditingController();
    try {
      final pin = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Enter PIN for ${staff.displayName}'),
          content: TextField(
            controller: controller,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onSubmitted: (value) {
              if (value.length == 6) Navigator.of(context).pop(value);
            },
            decoration: const InputDecoration(
              labelText: 'Six-digit PIN',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (controller.text.length == 6) {
                  Navigator.of(context).pop(controller.text);
                }
              },
              child: const Text('Unlock'),
            ),
          ],
        ),
      );
      if (pin == null || !mounted) return;
      setState(() => _submitting = true);
      final session = await _repository.verifyStaffPin(
        scope: widget.scope,
        userId: staff.userId,
        pin: pin,
      );
      ref.read(activeStaffPinSessionProvider.notifier).unlock(session);
      _expiryTimer?.cancel();
      _expiryTimer = Timer(session.expiresAt.difference(DateTime.now()), () {
        ref.read(activeStaffPinSessionProvider.notifier).lock();
      });
      AppLogger.info('Shared device unlocked for staff=${staff.userId}.');
    } on Object catch (error, stackTrace) {
      AppLogger.error('Verify staff PIN', error, stackTrace);
      if (!mounted) return;
      setState(() => _error = '$error');
      await _loadStaff();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _setOwnPin() async {
    final first = TextEditingController();
    final second = TextEditingController();
    try {
      final pin = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Create your staff PIN'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Choose six digits. Do not share this PIN.'),
              const SizedBox(height: 16),
              for (final entry in [(first, 'New PIN'), (second, 'Confirm PIN')])
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TextField(
                    controller: entry.$1,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: entry.$2,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (first.text.length == 6 && first.text == second.text) {
                  Navigator.of(context).pop(first.text);
                }
              },
              child: const Text('Save PIN'),
            ),
          ],
        ),
      );
      if (pin == null || !mounted) return;
      setState(() => _submitting = true);
      await _repository.setOwnStaffPin(scope: widget.scope, pin: pin);
      await _loadStaff();
    } on Object catch (error, stackTrace) {
      AppLogger.error('Set own staff PIN', error, stackTrace);
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _unlockStaff(VenuePinStaff staff) async {
    setState(() => _submitting = true);
    try {
      await _repository.unlockStaffPin(
        scope: widget.scope,
        userId: staff.userId,
      );
      AppLogger.info('Manager unlocked staff PIN for user=${staff.userId}.');
      await _loadStaff();
    } on Object catch (error, stackTrace) {
      AppLogger.error('Unlock staff PIN', error, stackTrace);
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(activeStaffPinSessionProvider);
    if (session != null && session.expiresAt.isAfter(DateTime.now())) {
      return widget.child;
    }
    final staff = _staff ?? const <VenuePinStaff>[];
    final selected = staff
        .where((item) => item.userId == _selectedUserId)
        .firstOrNull;
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    final currentUser = staff
        .where((item) => item.userId == currentUserId)
        .firstOrNull;
    final currentUserCanUnlock = currentUser?.roles.any(
          (role) => role == 'owner' || role == 'manager',
        ) ??
        false;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Who is using this device?',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Select your name and enter your personal six-digit PIN.',
                        ),
                        const SizedBox(height: 20),
                        DropdownButtonFormField<String>(
                          initialValue: _selectedUserId,
                          decoration: const InputDecoration(
                            labelText: 'Staff member',
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            for (final item in staff)
                              DropdownMenuItem(
                                value: item.userId,
                                child: Text(item.displayName),
                              ),
                          ],
                          onChanged: _submitting
                              ? null
                              : (value) => setState(() => _selectedUserId = value),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        if (selected?.pinLocked == true) ...[
                          const Text(
                            'This PIN is locked after three failed attempts.',
                          ),
                          if (currentUserCanUnlock) ...[
                            const SizedBox(height: 10),
                            OutlinedButton.icon(
                              onPressed: _submitting
                                  ? null
                                  : () => _unlockStaff(selected!),
                              icon: const Icon(Icons.lock_reset_rounded),
                              label: const Text('Manager unlock'),
                            ),
                          ] else
                            const Text(' Ask a manager or owner to unlock it.'),
                        ]
                        else if (selected?.hasPin == true)
                          FilledButton.icon(
                            onPressed: _submitting ? null : () => _enterPin(selected!),
                            icon: const Icon(Icons.lock_open_rounded),
                            label: Text(_submitting ? 'Checking…' : 'Enter PIN'),
                          )
                        else if (selected?.userId == currentUserId)
                          FilledButton.icon(
                            onPressed: _submitting ? null : _setOwnPin,
                            icon: const Icon(Icons.pin_rounded),
                            label: const Text('Create my PIN'),
                          )
                        else
                          const Text(
                            'This staff member must sign in with email and create their PIN first.',
                          ),
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: _submitting ? null : _loadStaff,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('Refresh staff'),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
