import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../data/production_command_repository.dart';
import '../notifications/notification_centre.dart';
import '../pos/domain.dart';
import '../pos/pos_controller.dart';

/// Adds, renames and retires the permanent numbered/named tables for a venue.
/// Server commands enforce a venue-local unique label and prevent deletion
/// while a table has an active order.
class TableManagementPage extends ConsumerWidget {
  const TableManagementPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(activeVenueScopeProvider);
    final tableValue = ref.watch(diningTablesProvider);
    final tables = tableValue.when(
      data: (items) => items,
      loading: () => scope == null ? demoTables : const <DiningTable>[],
      error: (_, _) => scope == null ? demoTables : const <DiningTable>[],
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Venue tables')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: scope == null
            ? null
            : () => _showTableDialog(context: context, ref: ref, scope: scope),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add table'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
        children: [
          Text('Tables', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 6),
          const Text(
            'Use permanent table names/numbers here. A named customer tab is created separately when an order is opened.',
          ),
          const SizedBox(height: 20),
          if (scope == null)
            const _TableHint(
              icon: Icons.cloud_off_outlined,
              text:
                  'Demo tables are shown. Select a live venue to manage its tables.',
            )
          else if (tableValue.hasError)
            const _TableHint(
              icon: Icons.error_outline_rounded,
              text:
                  'Tables could not be loaded. Check the debug console and Firestore rules.',
            )
          else if (tables.isEmpty)
            const _TableHint(
              icon: Icons.table_restaurant_outlined,
              text:
                  'No tables have been set up. Add Table 1, Table 2, Bar 1 or any names used by this venue.',
            )
          else
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (final table in tables)
                    _TableTile(
                      table: table,
                      onEdit: scope == null
                          ? null
                          : () => _showTableDialog(
                              context: context,
                              ref: ref,
                              scope: scope,
                              existing: table,
                            ),
                      onDelete: scope == null || table.hasOpenOrder
                          ? null
                          : () => _confirmDelete(
                              context: context,
                              ref: ref,
                              scope: scope,
                              table: table,
                            ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _TableTile extends StatelessWidget {
  const _TableTile({
    required this.table,
    required this.onEdit,
    required this.onDelete,
  });

  final DiningTable table;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: CircleAvatar(child: const Icon(Icons.table_restaurant_outlined)),
    title: Text(table.label),
    subtitle: Text(
      '${table.seats == 0 ? 'Capacity not set' : '${table.seats} covers'}${table.hasOpenOrder ? ' · Open order' : ''}',
    ),
    trailing: Wrap(
      children: [
        IconButton(
          tooltip: 'Edit table',
          onPressed: onEdit,
          icon: const Icon(Icons.edit_outlined),
        ),
        IconButton(
          tooltip: table.hasOpenOrder
              ? 'Close or move the open order before deleting'
              : 'Delete table',
          onPressed: onDelete,
          icon: const Icon(Icons.delete_outline_rounded),
        ),
      ],
    ),
  );
}

class _TableHint extends StatelessWidget {
  const _TableHint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.secondaryContainer,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(icon),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    ),
  );
}

Future<void> _showTableDialog({
  required BuildContext context,
  required WidgetRef ref,
  required VenueScope scope,
  DiningTable? existing,
}) async {
  final label = TextEditingController(text: existing?.label ?? '');
  final seats = TextEditingController(
    text: existing == null || existing.seats == 0 ? '' : '${existing.seats}',
  );
  final formKey = GlobalKey<FormState>();
  try {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(existing == null ? 'Add table' : 'Edit table'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: label,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Table name or number',
                  helperText: 'Examples: Table 1, Terrace 2, Bar 1',
                ),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Enter a unique table name or number.'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: seats,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Typical covers (optional)',
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) return null;
                  final parsed = int.tryParse(value.trim());
                  return parsed == null || parsed < 0
                      ? 'Enter zero or a positive whole number.'
                      : null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              if (!(formKey.currentState?.validate() ?? false)) return;
              try {
                final count = seats.text.trim().isEmpty
                    ? 0
                    : int.parse(seats.text.trim());
                final commands = ref.read(productionCommandRepositoryProvider);
                if (existing == null) {
                  await commands.createTable(
                    scope: scope,
                    label: label.text,
                    seats: count,
                  );
                } else {
                  await commands.updateTable(
                    scope: scope,
                    tableId: existing.id,
                    label: label.text,
                    seats: count,
                  );
                }
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              } on Object catch (error, stackTrace) {
                AppLogger.error('Save venue table', error, stackTrace);
                if (!dialogContext.mounted) return;
                showAppNotification(
                  dialogContext,
                  ref: ref,
                  title: 'Could not save table',
                  message: 'The table could not be saved: $error',
                  level: AppNotificationLevel.error,
                );
              }
            },
            child: Text(existing == null ? 'Add table' : 'Save changes'),
          ),
        ],
      ),
    );
  } finally {
    label.dispose();
    seats.dispose();
  }
}

Future<void> _confirmDelete({
  required BuildContext context,
  required WidgetRef ref,
  required VenueScope scope,
  required DiningTable table,
}) async {
  final approved = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Delete table?'),
      content: Text('“${table.label}” will be removed from future service.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton.tonal(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Delete table'),
        ),
      ],
    ),
  );
  if (approved != true) return;
  try {
    await ref
        .read(productionCommandRepositoryProvider)
        .deleteTable(scope: scope, tableId: table.id);
  } on Object catch (error, stackTrace) {
    AppLogger.error('Delete venue table', error, stackTrace);
    if (!context.mounted) return;
    showAppNotification(
      context,
      ref: ref,
      title: 'Could not delete table',
      message: 'The table could not be deleted: $error',
      level: AppNotificationLevel.error,
    );
  }
}
