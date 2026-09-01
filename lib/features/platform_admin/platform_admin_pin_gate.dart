import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/platform_admin_pin_session_store.dart';
import '../../data/platform_admin_repository.dart';

class PlatformAdminPinGate extends ConsumerStatefulWidget {
  const PlatformAdminPinGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<PlatformAdminPinGate> createState() =>
      _PlatformAdminPinGateState();
}

class _PlatformAdminPinGateState extends ConsumerState<PlatformAdminPinGate> {
  bool _loading = true;
  bool _configured = false;
  bool _submitting = false;
  String? _error;
  Timer? _expiryTimer;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    super.dispose();
  }

  void _scheduleExpiry(DateTime expiresAt) {
    _expiryTimer?.cancel();
    final delay = expiresAt.difference(DateTime.now());
    _expiryTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      PlatformAdminPinSessionStore.clear();
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadStatus() async {
    try {
      final configured = await ref
          .read(platformAdminRepositoryProvider)
          .hasPlatformAdminPin();
      if (!mounted) return;
      setState(() {
        _configured = configured;
        _loading = false;
        _error = null;
      });
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'Load platform administrator PIN status',
        error,
        stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<void> _unlock() async {
    final first = await _showPlatformPinDialog(
      context,
      title: _configured
          ? 'Platform administrator PIN'
          : 'Create platform administrator PIN',
      message: _configured
          ? 'Enter your six-digit PIN to unlock platform tools.'
          : 'Choose a six-digit PIN. This protects platform-wide administration.',
    );
    if (first == null || !mounted) return;
    var pin = first;
    if (!_configured) {
      final confirmation = await _showPlatformPinDialog(
        context,
        title: 'Confirm platform administrator PIN',
        message: 'Enter the same six-digit PIN again.',
      );
      if (confirmation == null || !mounted) return;
      if (confirmation != first) {
        setState(() => _error = 'The two PIN entries did not match.');
        return;
      }
      pin = confirmation;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final repository = ref.read(platformAdminRepositoryProvider);
      if (!_configured) {
        await repository.setPlatformAdminPin(pin);
      }
      final session = await repository.verifyPlatformAdminPin(pin);
      _scheduleExpiry(session.expiresAt);
      if (!mounted) return;
      setState(() {
        _configured = true;
        _submitting = false;
      });
    } on Object catch (error, stackTrace) {
      AppLogger.error('Unlock platform administration', error, stackTrace);
      PlatformAdminPinSessionStore.clear();
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = PlatformAdminPinSessionStore.current;
    if (session?.isValid == true) return widget.child;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 430),
        child: Card(
          margin: const EdgeInsets.all(24),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.admin_panel_settings_outlined, size: 46),
                const SizedBox(height: 14),
                Text(
                  _configured
                      ? 'Unlock platform administration'
                      : 'Secure platform administration',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  _configured
                      ? 'Your email sign-in is valid. Enter your separate platform PIN to continue.'
                      : 'Create a separate platform PIN before managing companies or users.',
                  textAlign: TextAlign.center,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _submitting ? null : _unlock,
                  icon: _submitting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.lock_open_rounded),
                  label: Text(_configured ? 'Enter PIN' : 'Create PIN'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<String?> _showPlatformPinDialog(
  BuildContext context, {
  required String title,
  required String message,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _PlatformPinDialog(title: title, message: message),
  );
}

class _PlatformPinDialog extends StatefulWidget {
  const _PlatformPinDialog({required this.title, required this.message});

  final String title;
  final String message;

  @override
  State<_PlatformPinDialog> createState() => _PlatformPinDialogState();
}

class _PlatformPinDialogState extends State<_PlatformPinDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _append(String digit) {
    if (_controller.text.length >= 6) return;
    setState(() => _controller.text += digit);
  }

  void _remove() {
    if (_controller.text.isEmpty) return;
    setState(
      () => _controller.text = _controller.text.substring(
        0,
        _controller.text.length - 1,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 330),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.message),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) => setState(() {}),
            onSubmitted: (value) {
              if (value.length == 6) Navigator.pop(context, value);
            },
            decoration: const InputDecoration(
              labelText: 'Six-digit PIN',
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          for (final row in const [
            ['1', '2', '3'],
            ['4', '5', '6'],
            ['7', '8', '9'],
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final digit in row)
                    SizedBox(
                      width: 72,
                      child: OutlinedButton(
                        onPressed: () => _append(digit),
                        child: Text(digit),
                      ),
                    ),
                ],
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              SizedBox(
                width: 72,
                child: OutlinedButton(
                  onPressed: _remove,
                  child: const Icon(Icons.backspace_outlined),
                ),
              ),
              SizedBox(
                width: 72,
                child: OutlinedButton(
                  onPressed: () => _append('0'),
                  child: const Text('0'),
                ),
              ),
              const SizedBox(width: 72),
            ],
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _controller.text.length == 6
            ? () => Navigator.pop(context, _controller.text)
            : null,
        child: const Text('Continue'),
      ),
    ],
  );
}
