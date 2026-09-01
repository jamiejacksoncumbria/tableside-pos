import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostic_log_store.dart';
import '../auth/staff_pin_gate.dart';
import '../notifications/notification_centre.dart';

class DiagnosticsPage extends ConsumerWidget {
  const DiagnosticsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(activeStaffPinSessionProvider);
    final canManage =
        session?.roles.any((role) => role == 'owner' || role == 'manager') ??
        false;
    return Scaffold(
      appBar: AppBar(title: const Text('Device diagnostics')),
      body: canManage
          ? const _DiagnosticLogBody()
          : const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Manager or owner access is required to view device diagnostics.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
    );
  }
}

class _DiagnosticLogBody extends StatefulWidget {
  const _DiagnosticLogBody();

  @override
  State<_DiagnosticLogBody> createState() => _DiagnosticLogBodyState();
}

class _DiagnosticLogBodyState extends State<_DiagnosticLogBody> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _copy(BuildContext context) async {
    final text = DiagnosticLogStore.instance.copyText;
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    showAppNotification(
      context,
      title: 'Diagnostics copied',
      message: '${DiagnosticLogStore.instance.lines.length} log lines copied.',
      level: AppNotificationLevel.success,
    );
  }

  Future<void> _clear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear local diagnostics?'),
        content: const Text(
          'This permanently removes the diagnostic history from this device only.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await DiagnosticLogStore.instance.clear();
    if (!context.mounted) return;
    showAppNotification(
      context,
      title: 'Diagnostics cleared',
      message: 'The local diagnostic history was removed.',
      level: AppNotificationLevel.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: DiagnosticLogStore.instance.revision,
      builder: (context, _, _) {
        final allLines = DiagnosticLogStore.instance.lines;
        final query = _query.trim().toLowerCase();
        final filtered = query.isEmpty
            ? allLines
            : allLines
                  .where((line) => line.toLowerCase().contains(query))
                  .toList(growable: false);
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '${allLines.length} / ${DiagnosticLogStore.maximumLines} local lines',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  FilledButton.tonalIcon(
                    onPressed: allLines.isEmpty ? null : () => _copy(context),
                    icon: const Icon(Icons.copy_all_rounded),
                    label: const Text('Copy all'),
                  ),
                  OutlinedButton.icon(
                    onPressed: allLines.isEmpty ? null : () => _clear(context),
                    icon: const Icon(Icons.delete_sweep_outlined),
                    label: const Text('Clear'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Stored on this device only. Authentication secrets, email addresses and token-like values are automatically redacted.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _search,
                decoration: InputDecoration(
                  labelText: 'Search diagnostics',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                          icon: const Icon(Icons.clear_rounded),
                        ),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Card(
                  margin: EdgeInsets.zero,
                  child: filtered.isEmpty
                      ? Center(
                          child: Text(
                            allLines.isEmpty
                                ? 'No diagnostics have been recorded yet.'
                                : 'No diagnostic lines match this search.',
                          ),
                        )
                      : SelectionArea(
                          child: ListView.builder(
                            reverse: true,
                            padding: const EdgeInsets.all(12),
                            itemCount: filtered.length,
                            itemBuilder: (context, index) {
                              final line =
                                  filtered[filtered.length - 1 - index];
                              final isError =
                                  line.contains('[ERROR]') ||
                                  line.contains('[STACK]');
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 5),
                                child: Text(
                                  line,
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                    color: isError
                                        ? Theme.of(context).colorScheme.error
                                        : null,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
