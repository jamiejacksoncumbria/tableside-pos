part of '../staff_pin_gate.dart';

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
                  staff.pinLocked ? Icons.lock_rounded : Icons.person_rounded,
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
                    : staff.hasPin && !staff.offlineReady
                    ? 'Online setup required'
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

class _PasswordReauthenticationDialog extends StatefulWidget {
  const _PasswordReauthenticationDialog({required this.email});

  final String email;

  @override
  State<_PasswordReauthenticationDialog> createState() =>
      _PasswordReauthenticationDialogState();
}

class _PasswordReauthenticationDialogState
    extends State<_PasswordReauthenticationDialog> {
  final TextEditingController _passwordController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  void _submit() {
    final password = _passwordController.text;
    if (password.isNotEmpty) Navigator.of(context).pop(password);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('Verify your Firebase account'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Enter the password for ${widget.email}. It is sent directly to Firebase Authentication and is never stored by TableSideCY.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _passwordController,
            autofocus: true,
            obscureText: _obscurePassword,
            autofillHints: const [AutofillHints.password],
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Firebase account password',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
                icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Forgot the password? Cancel, sign out, and use Forgot password on the email sign-in screen.',
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Verify')),
    ],
  );
}

/// Exposes the production PIN entry surface to widget tests without making
/// its mutable state part of the application API.
@visibleForTesting
Widget buildStaffPinDialogForTest({
  String title = 'Enter PIN',
  String message = 'Enter your six-digit staff PIN.',
  String confirmLabel = 'Unlock',
}) => _PinPadDialog(
  title: Text(title),
  message: message,
  confirmLabel: confirmLabel,
);

/// Exposes the inline login keypad so tests can verify the exact transition
/// from a locked screen to the authenticated application shell.
@visibleForTesting
Widget buildStaffPinPanelForTest({
  required ValueChanged<String> onSubmitted,
  required VoidCallback onCancel,
  bool enabled = true,
}) => _PinPadPanel(
  title: const Text('Enter PIN'),
  message: 'Enter your six-digit staff PIN.',
  confirmLabel: 'Unlock',
  enabled: enabled,
  onCancel: onCancel,
  onSubmitted: onSubmitted,
);

class _PinPadDialog extends StatelessWidget {
  const _PinPadDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
  });

  final Widget title;
  final String message;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 390),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
        child: _PinPadPanel(
          title: title,
          message: message,
          confirmLabel: confirmLabel,
          onCancel: () => Navigator.of(context).pop(),
          onSubmitted: (pin) => Navigator.of(context).pop(pin),
        ),
      ),
    ),
  );
}

/// Reusable PIN keypad whose caller owns navigation and authentication.
///
/// The staff-login gate embeds this panel directly, avoiding a dialog route
/// being removed in the same frame that the entire authenticated shell is
/// mounted. Other workflows may safely host it inside [_PinPadDialog].
class _PinPadPanel extends StatefulWidget {
  const _PinPadPanel({
    super.key,
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.onCancel,
    required this.onSubmitted,
    this.enabled = true,
  });

  final Widget title;
  final String message;
  final String confirmLabel;
  final VoidCallback onCancel;
  final ValueChanged<String> onSubmitted;
  final bool enabled;

  @override
  State<_PinPadPanel> createState() => _PinPadPanelState();
}

class _PinPadPanelState extends State<_PinPadPanel> {
  String _pin = '';
  bool _submitted = false;
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
    if (!widget.enabled || _submitted || _pin.length >= 6) return;
    setState(() => _pin += digit);
    if (_pin.length == 6) _submit();
    _keyboardFocus.requestFocus();
  }

  void _submit() {
    if (!widget.enabled || _submitted || _pin.length != 6) return;
    _submitted = true;
    final completedPin = _pin;
    widget.onSubmitted(completedPin);
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
    final numpadDigits = <LogicalKeyboardKey, String>{
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
      if (widget.enabled) widget.onCancel();
      return;
    }
    if ((event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        _pin.length == 6) {
      _submit();
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final compact = viewport.height < 700 || viewport.width < 600;
    final gap = compact ? 4.0 : 10.0;
    final keySpacing = compact ? 4.0 : 5.0;
    final keyHeight = compact ? 38.0 : 48.0;
    final keyStyle = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size.zero),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const WidgetStatePropertyAll(EdgeInsets.zero),
      visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
    );
    return KeyboardListener(
      focusNode: _keyboardFocus,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DefaultTextStyle(
            style: compact
                ? Theme.of(context).textTheme.titleLarge!
                : Theme.of(context).textTheme.headlineSmall!,
            child: widget.title,
          ),
          SizedBox(height: gap),
          Text(widget.message),
          SizedBox(height: gap),
          Semantics(
            label: '${_pin.length} of 6 PIN digits entered',
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                6,
                (index) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: Icon(
                    index < _pin.length ? Icons.circle : Icons.circle_outlined,
                    size: compact ? 12 : 15,
                  ),
                ),
              ),
            ),
          ),
          SizedBox(height: gap),
          SizedBox(
            height: (keyHeight * 4) + (keySpacing * 3),
            child: GridView.builder(
              itemCount: 12,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisExtent: keyHeight,
                mainAxisSpacing: keySpacing,
                crossAxisSpacing: keySpacing,
              ),
              itemBuilder: (context, index) {
                if (index < 9) {
                  final digit = '${index + 1}';
                  return FilledButton.tonal(
                    style: keyStyle,
                    onPressed: () => _digit(digit),
                    child: Text(
                      digit,
                      style: compact
                          ? Theme.of(context).textTheme.titleMedium
                          : Theme.of(context).textTheme.titleLarge,
                    ),
                  );
                }
                if (index == 9) {
                  return OutlinedButton(
                    style: keyStyle,
                    onPressed: _pin.isEmpty
                        ? null
                        : () {
                            setState(() => _pin = '');
                            _keyboardFocus.requestFocus();
                          },
                    child: const Text('Clear'),
                  );
                }
                if (index == 10) {
                  return FilledButton.tonal(
                    style: keyStyle,
                    onPressed: () => _digit('0'),
                    child: Text(
                      '0',
                      style: compact
                          ? Theme.of(context).textTheme.titleMedium
                          : Theme.of(context).textTheme.titleLarge,
                    ),
                  );
                }
                return IconButton.filledTonal(
                  style: keyStyle,
                  tooltip: 'Delete last digit',
                  onPressed: _pin.isEmpty ? null : _backspace,
                  icon: const Icon(Icons.backspace_rounded),
                );
              },
            ),
          ),
          SizedBox(height: compact ? 4 : 8),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(
                onPressed: widget.enabled ? widget.onCancel : null,
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: widget.enabled && _pin.length == 6 && !_submitted
                    ? _submit
                    : null,
                child: widget.enabled
                    ? Text(widget.confirmLabel)
                    : const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
