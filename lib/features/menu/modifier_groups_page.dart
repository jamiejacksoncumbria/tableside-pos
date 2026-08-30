import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/money.dart';
import '../../core/tenant_scope.dart';
import '../../data/firestore_pos_repository.dart';
import '../notifications/notification_centre.dart';
import '../pos/domain.dart';
import '../pos/pos_controller.dart';

/// Venue-level reusable choices which can be attached to one or many products.
class ModifierGroupsPage extends ConsumerWidget {
  const ModifierGroupsPage({super.key, required this.currencyCode});

  final String currencyCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(activeVenueScopeProvider);
    final groupsValue = ref.watch(menuModifierGroupsProvider);
    final groups = groupsValue.when(
      data: (items) => items,
      loading: () => const <MenuModifierGroup>[],
      error: (error, stackTrace) {
        AppLogger.error('Display modifier groups', error, stackTrace);
        return const <MenuModifierGroup>[];
      },
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Product options')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: scope == null
            ? null
            : () => _showModifierGroupDialog(
                context: context,
                ref: ref,
                scope: scope,
                currencyCode: currencyCode,
              ),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add option group'),
      ),
      body: groupsValue.isLoading
          ? const Center(child: CircularProgressIndicator())
          : groupsValue.hasError
          ? const _PageMessage(
              icon: Icons.cloud_off_rounded,
              title: 'Could not load product options',
              detail: 'Check your connection and Firestore rules.',
            )
          : scope == null
          ? const _PageMessage(
              icon: Icons.storefront_outlined,
              title: 'Select a venue first',
              detail:
                  'Product options are configured separately for each venue.',
            )
          : groups.isEmpty
          ? const _PageMessage(
              icon: Icons.tune_rounded,
              title: 'No product options yet',
              detail:
                  'Create reusable groups such as Cooking preference, Spice level or Ice.',
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 104),
              itemCount: groups.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final group = groups[index];
                return Card(
                  child: ListTile(
                    leading: Icon(
                      group.isRequired
                          ? Icons.rule_folder_rounded
                          : Icons.tune_rounded,
                    ),
                    title: Text(group.name),
                    subtitle: Text(
                      '${_selectionRequirement(group)} · ${_optionsSummary(group, currencyCode)}',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    isThreeLine: true,
                    trailing: PopupMenuButton<_ModifierGroupAction>(
                      onSelected: (action) async {
                        if (action == _ModifierGroupAction.edit) {
                          await _showModifierGroupDialog(
                            context: context,
                            ref: ref,
                            scope: scope,
                            currencyCode: currencyCode,
                            existing: group,
                          );
                        } else {
                          await _confirmDeleteGroup(
                            context: context,
                            ref: ref,
                            scope: scope,
                            group: group,
                          );
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: _ModifierGroupAction.edit,
                          child: Text('Edit'),
                        ),
                        PopupMenuItem(
                          value: _ModifierGroupAction.delete,
                          child: Text('Delete'),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

enum _ModifierGroupAction { edit, delete }

Future<void> _showModifierGroupDialog({
  required BuildContext context,
  required WidgetRef ref,
  required VenueScope scope,
  required String currencyCode,
  MenuModifierGroup? existing,
}) async {
  final name = TextEditingController(text: existing?.name ?? '');
  final minimum = TextEditingController(
    text: '${existing?.minimumSelections ?? 0}',
  );
  final maximum = TextEditingController(
    text: '${existing?.maximumSelections ?? 1}',
  );
  final drafts = (existing?.options ?? const <MenuModifierOption>[])
      .map(
        (option) => _ModifierOptionDraft(
          id: option.id,
          name: option.name,
          priceDelta: _minorText(option.priceDeltaMinor),
        ),
      )
      .toList(growable: true);
  if (drafts.isEmpty) drafts.add(_ModifierOptionDraft.empty());
  String? validationMessage;

  try {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            existing == null ? 'Add product options' : 'Edit product options',
          ),
          content: SizedBox(
            width: 600,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: name,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Group name',
                      helperText:
                          'For example Cooking preference, Spice level or Ice.',
                    ),
                    onChanged: (_) =>
                        setDialogState(() => validationMessage = null),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: minimum,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Minimum choices',
                            helperText: '0 means optional.',
                          ),
                          onChanged: (_) =>
                              setDialogState(() => validationMessage = null),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: maximum,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Maximum choices',
                            helperText: 'Use 1 for one choice.',
                          ),
                          onChanged: (_) =>
                              setDialogState(() => validationMessage = null),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Choices',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Price adjustments are tax-inclusive and are added to the product base price ($currencyCode).',
                  ),
                  const SizedBox(height: 10),
                  for (var index = 0; index < drafts.length; index++) ...[
                    _ModifierOptionRow(
                      draft: drafts[index],
                      canRemove: drafts.length > 1,
                      onRemove: () =>
                          setDialogState(() => drafts.removeAt(index)),
                      onChanged: () =>
                          setDialogState(() => validationMessage = null),
                    ),
                    const SizedBox(height: 8),
                  ],
                  TextButton.icon(
                    onPressed: drafts.length >= 50
                        ? null
                        : () => setDialogState(
                            () => drafts.add(_ModifierOptionDraft.empty()),
                          ),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Add another choice'),
                  ),
                  if (validationMessage != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      validationMessage!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final minimumSelections = int.tryParse(minimum.text.trim());
                final maximumSelections = int.tryParse(maximum.text.trim());
                final options = <MenuModifierOption>[];
                final optionNames = <String>{};
                for (final draft in drafts) {
                  final optionName = draft.name.text.trim();
                  final priceDelta = _signedMinorFromText(
                    draft.priceDelta.text,
                  );
                  if (optionName.isEmpty || priceDelta == null) {
                    setDialogState(
                      () => validationMessage =
                          'Every choice needs a name and valid price adjustment.',
                    );
                    return;
                  }
                  if (!optionNames.add(optionName.toLowerCase())) {
                    setDialogState(
                      () => validationMessage = 'Choice names must be unique.',
                    );
                    return;
                  }
                  options.add(
                    MenuModifierOption(
                      id: draft.id,
                      name: optionName,
                      priceDeltaMinor: priceDelta,
                    ),
                  );
                }
                if (name.text.trim().isEmpty ||
                    minimumSelections == null ||
                    maximumSelections == null ||
                    minimumSelections < 0 ||
                    maximumSelections < minimumSelections ||
                    maximumSelections > options.length) {
                  setDialogState(
                    () => validationMessage =
                        'Set valid selection limits between 0 and ${options.length}.',
                  );
                  return;
                }
                try {
                  final repository = ref.read(firestorePosRepositoryProvider);
                  if (existing == null) {
                    await repository.createModifierGroup(
                      scope: scope,
                      name: name.text,
                      minimumSelections: minimumSelections,
                      maximumSelections: maximumSelections,
                      options: options,
                    );
                  } else {
                    await repository.updateModifierGroup(
                      scope: scope,
                      groupId: existing.id,
                      name: name.text,
                      minimumSelections: minimumSelections,
                      maximumSelections: maximumSelections,
                      options: options,
                    );
                  }
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                } on Object catch (error, stackTrace) {
                  AppLogger.error(
                    'Save product option group',
                    error,
                    stackTrace,
                  );
                  if (!dialogContext.mounted) return;
                  setDialogState(
                    () => validationMessage = 'Could not save: $error',
                  );
                }
              },
              child: Text(existing == null ? 'Save options' : 'Save changes'),
            ),
          ],
        ),
      ),
    );
  } finally {
    name.dispose();
    minimum.dispose();
    maximum.dispose();
    for (final draft in drafts) {
      draft.dispose();
    }
  }
}

Future<void> _confirmDeleteGroup({
  required BuildContext context,
  required WidgetRef ref,
  required VenueScope scope,
  required MenuModifierGroup group,
}) async {
  final delete = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Delete ${group.name}?'),
      content: const Text(
        'This is only allowed when no products use the option group.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton.tonal(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (delete != true) return;
  try {
    await ref
        .read(firestorePosRepositoryProvider)
        .deleteModifierGroup(scope: scope, group: group);
  } on Object catch (error, stackTrace) {
    AppLogger.error('Delete product option group', error, stackTrace);
    if (!context.mounted) return;
    showAppNotification(
      context,
      ref: ref,
      title: 'Could not delete options',
      message: '$error',
      level: AppNotificationLevel.error,
    );
  }
}

class _ModifierOptionRow extends StatelessWidget {
  const _ModifierOptionRow({
    required this.draft,
    required this.canRemove,
    required this.onRemove,
    required this.onChanged,
  });

  final _ModifierOptionDraft draft;
  final bool canRemove;
  final VoidCallback onRemove;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        flex: 3,
        child: TextField(
          controller: draft.name,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Choice name'),
          onChanged: (_) => onChanged(),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        flex: 2,
        child: TextField(
          controller: draft.priceDelta,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Price +/-'),
          onChanged: (_) => onChanged(),
        ),
      ),
      IconButton(
        tooltip: 'Remove choice',
        onPressed: canRemove ? onRemove : null,
        icon: const Icon(Icons.delete_outline_rounded),
      ),
    ],
  );
}

class _ModifierOptionDraft {
  _ModifierOptionDraft({
    required this.id,
    required String name,
    required String priceDelta,
  }) : name = TextEditingController(text: name),
       priceDelta = TextEditingController(text: priceDelta);

  factory _ModifierOptionDraft.empty() => _ModifierOptionDraft(
    id: _nextOptionDraftId(),
    name: '',
    priceDelta: '0.00',
  );

  final String id;
  final TextEditingController name;
  final TextEditingController priceDelta;

  void dispose() {
    name.dispose();
    priceDelta.dispose();
  }
}

class _PageMessage extends StatelessWidget {
  const _PageMessage({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 42),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(detail, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

String _optionsSummary(MenuModifierGroup group, String currencyCode) => group
    .options
    .map((option) {
      if (option.priceDeltaMinor == 0) return option.name;
      final sign = option.priceDeltaMinor.isNegative ? '' : '+';
      return '${option.name} ($sign${formatMoney(option.priceDeltaMinor, currencyCode: currencyCode)})';
    })
    .join(', ');

String _selectionRequirement(MenuModifierGroup group) {
  if (group.minimumSelections == group.maximumSelections) {
    return group.minimumSelections == 1
        ? 'Choose one'
        : 'Choose ${group.minimumSelections}';
  }
  if (group.minimumSelections == 0) {
    return 'Optional, up to ${group.maximumSelections}';
  }
  return 'Choose ${group.minimumSelections}–${group.maximumSelections}';
}

double? _decimal(String value) =>
    double.tryParse(value.trim().replaceAll(',', '.'));

int? _signedMinorFromText(String value) {
  final parsed = _decimal(value);
  if (parsed == null || !parsed.isFinite) return null;
  final minor = (parsed * 100).round();
  return minor.abs() <= 100000000 ? minor : null;
}

String _minorText(int minor) {
  final sign = minor.isNegative ? '-' : '';
  final absolute = minor.abs();
  return '$sign${absolute ~/ 100}.${(absolute % 100).toString().padLeft(2, '0')}';
}

var _optionDraftCounter = 0;

String _nextOptionDraftId() =>
    'option-${DateTime.now().microsecondsSinceEpoch}-${_optionDraftCounter++}';
