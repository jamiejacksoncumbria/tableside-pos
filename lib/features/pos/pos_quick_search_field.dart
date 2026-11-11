import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/safe_dialog.dart';
import 'pos_controller.dart';

/// Header search for the active POS menu workspace.
///
/// The query is device-local and is consumed by the POS menu panel. Keeping
/// this control in the location header recovers vertical menu space while
/// retaining native keyboard input, the touch keyboard and a clear action.
class PosQuickSearchField extends ConsumerStatefulWidget {
  const PosQuickSearchField({super.key});

  @override
  ConsumerState<PosQuickSearchField> createState() =>
      _PosQuickSearchFieldState();
}
class _PosQuickSearchFieldState extends ConsumerState<PosQuickSearchField> {
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode(debugLabel: 'POS product search');

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: ref.read(posMenuSearchQueryProvider),
    )..addListener(_queryChanged);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_queryChanged)
      ..dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _queryChanged() {
    ref.read(posMenuSearchQueryProvider.notifier).update(_controller.text);
  }

  void _replaceText(String text) {
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  Future<void> _showTouchKeyboard() async {
    const rows = <String>['QWERTYUIOP', 'ASDFGHJKL', 'ZXCVBNM'];
    await showAppDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Product search keyboard'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final row in rows)
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final key in row.split(''))
                      SizedBox(
                        width: 48,
                        child: FilledButton.tonal(
                          onPressed: () => _replaceText(
                            '${_controller.text}$key',
                          ),
                          child: Text(key),
                        ),
                      ),
                  ],
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () {
                      final value = _controller.text;
                      if (value.isNotEmpty) {
                        _replaceText(value.substring(0, value.length - 1));
                      }
                    },
                    icon: const Icon(Icons.backspace_outlined),
                    label: const Text('Delete'),
                  ),
                  OutlinedButton(
                    onPressed: () => _replaceText(''),
                    child: const Text('Clear'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted) _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(posMenuSearchQueryProvider);
    if (query != _controller.text) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && query != _controller.text) _replaceText(query);
      });
    }
    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Quick product search',
        prefixIcon: const Icon(Icons.search_rounded, size: 19),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Open touch keyboard',
              visualDensity: VisualDensity.compact,
              onPressed: _showTouchKeyboard,
              icon: const Icon(Icons.keyboard_alt_outlined, size: 19),
            ),
            if (query.trim().isNotEmpty)
              IconButton(
                tooltip: 'Clear search',
                visualDensity: VisualDensity.compact,
                onPressed: () => _replaceText(''),
                icon: const Icon(Icons.close_rounded, size: 19),
              ),
          ],
        ),
      ),
    );
  }
}
