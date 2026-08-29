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
    try {
      final pin = await showDialog<String>(
        context: context,
        builder: (context) => _PinPadDialog(
          title: Text('Enter PIN for ${staff.displayName}'),
          message: 'Enter your six-digit staff PIN.',
          confirmLabel: 'Unlock',
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
    try {
      final firstPin = await showDialog<String>(
        context: context,
        builder: (context) => const _PinPadDialog(
          title: const Text('Create your staff PIN'),
          message: 'Choose six digits. Do not share this PIN.',
          confirmLabel: 'Continue',
        ),
      );
      if (firstPin == null || !mounted) return;
      final confirmedPin = await showDialog<String>(
        context: context,
        builder: (context) => const _PinPadDialog(
          title: Text('Confirm your staff PIN'),
          message: 'Enter the same six digits again.',
          confirmLabel: 'Save PIN',
        ),
      );
      if (confirmedPin == null || !mounted) return;
      if (confirmedPin != firstPin) {
        setState(() => _error = 'The two PIN entries did not match. Try again.');
        return;
      }
      setState(() => _submitting = true);
      await _repository.setOwnStaffPin(scope: widget.scope, pin: firstPin);
      await _loadStaff();
    } on Object catch (error, stackTrace) {
      AppLogger.error('Set own staff PIN', error, stackTrace);
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
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Card(
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
                          'Tap your name, then enter your personal six-digit PIN.',
                        ),
                        const SizedBox(height: 20),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final columns = constraints.maxWidth >= 620
                                ? 4
                                : constraints.maxWidth >= 420
                                ? 3
                                : 2;
                            const spacing = 10.0;
                            final tileWidth =
                                (constraints.maxWidth -
                                    (spacing * (columns - 1))) /
                                columns;
                            return Wrap(
                              spacing: spacing,
                              runSpacing: spacing,
                              children: [
                                for (final item in staff)
                                  SizedBox(
                                    width: tileWidth,
                                    child: _StaffTile(
                                      staff: item,
                                      selected:
                                          item.userId == _selectedUserId,
                                      enabled: !_submitting,
                                      onTap: () async {
                                        setState(() {
                                          _selectedUserId = item.userId;
                                          _error = null;
                                        });
                                        if (item.pinLocked) return;
                                        if (item.hasPin) {
                                          await _enterPin(item);
                                        } else if (item.userId ==
                                            currentUserId) {
                                          await _setOwnPin();
                                        }
                                      },
                                    ),
                                  ),
                              ],
                            );
                          },
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
                          const Text(
                            ' Ask a manager or owner to unlock it from staff management.',
                          ),
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
        ),
      ),
    );
  }
}

class _StaffTile extends StatelessWidget {
  const _StaffTile({
    required this.staff,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final VenuePinStaff staff;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final role = staff.roles.isEmpty ? 'Staff' : staff.roles.first;
    return Card(
      margin: EdgeInsets.zero,
      color: selected ? scheme.primaryContainer : scheme.surfaceContainerHigh,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
          child: Column(
            children: [
              CircleAvatar(
                backgroundColor: staff.pinLocked
                    ? scheme.errorContainer
                    : selected
                    ? scheme.primary
                    : scheme.secondaryContainer,
                foregroundColor: staff.pinLocked
                    ? scheme.onErrorContainer
                    : selected
                    ? scheme.onPrimary
                    : scheme.onSecondaryContainer,
                child: Icon(
                  staff.pinLocked
                      ? Icons.lock_rounded
                      : Icons.person_rounded,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                staff.displayName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 3),
              Text(
                staff.pinLocked
                    ? 'Locked'
                    : staff.hasPin
                    ? role
                    : 'PIN not set',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PinPadDialog extends StatefulWidget {
  const _PinPadDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
  });

  final Widget title;
  final String message;
  final String confirmLabel;

  @override
  State<_PinPadDialog> createState() => _PinPadDialogState();
}

class _PinPadDialogState extends State<_PinPadDialog> {
  String _pin = '';
  final FocusNode _keyboardFocus = FocusNode(debugLabel: 'Staff PIN keypad');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _keyboardFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _keyboardFocus.dispose();
    super.dispose();
  }

  void _digit(String digit) {
    if (_pin.length >= 6) return;
    setState(() => _pin += digit);
    _keyboardFocus.requestFocus();
  }

  void _backspace() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
    _keyboardFocus.requestFocus();
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return;
    final character = event.character;
    if (character != null && RegExp(r'^\d$').hasMatch(character)) {
      _digit(character);
      return;
    }
    const numpadDigits = <LogicalKeyboardKey, String>{
      LogicalKeyboardKey.numpad0: '0',
      LogicalKeyboardKey.numpad1: '1',
      LogicalKeyboardKey.numpad2: '2',
      LogicalKeyboardKey.numpad3: '3',
      LogicalKeyboardKey.numpad4: '4',
      LogicalKeyboardKey.numpad5: '5',
      LogicalKeyboardKey.numpad6: '6',
      LogicalKeyboardKey.numpad7: '7',
      LogicalKeyboardKey.numpad8: '8',
      LogicalKeyboardKey.numpad9: '9',
    };
    final numpadDigit = numpadDigits[event.logicalKey];
    if (numpadDigit != null) {
      _digit(numpadDigit);
      return;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace ||
        event.logicalKey == LogicalKeyboardKey.delete) {
      _backspace();
      return;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return;
    }
    if ((event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        _pin.length == 6) {
      Navigator.of(context).pop(_pin);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: widget.title,
    content: KeyboardListener(
      focusNode: _keyboardFocus,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: SizedBox(
        width: 330,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.message),
            const SizedBox(height: 18),
            Semantics(
              label: '${_pin.length} of 6 PIN digits entered',
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  6,
                  (index) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 7),
                    child: Icon(
                      index < _pin.length
                          ? Icons.circle
                          : Icons.circle_outlined,
                      size: 17,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1.65,
              children: [
                for (final digit in const [
                  '1',
                  '2',
                  '3',
                  '4',
                  '5',
                  '6',
                  '7',
                  '8',
                  '9',
                ])
                  FilledButton.tonal(
                    onPressed: () => _digit(digit),
                    child: Text(
                      digit,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
              OutlinedButton(
                  onPressed: _pin.isEmpty
                      ? null
                      : () {
                          setState(() => _pin = '');
                          _keyboardFocus.requestFocus();
                        },
                  child: const Text('Clear'),
                ),
                FilledButton.tonal(
                  onPressed: () => _digit('0'),
                  child: Text(
                    '0',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: 'Delete last digit',
                  onPressed: _pin.isEmpty ? null : _backspace,
                  icon: const Icon(Icons.backspace_rounded),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _pin.length == 6
            ? () => Navigator.of(context).pop(_pin)
            : null,
        child: Text(widget.confirmLabel),
      ),
    ],
  );
}
