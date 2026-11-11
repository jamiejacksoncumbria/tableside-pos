part of '../menu_management_page.dart';

class _SetupHint extends StatelessWidget {
  const _SetupHint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.secondaryContainer,
    child: Padding(
      padding: const EdgeInsets.all(14),
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

class _SectionIconOption {
  const _SectionIconOption(this.symbol, this.label);

  final String symbol;
  final String label;
}

const _sectionIconOptions = <_SectionIconOption>[
  _SectionIconOption('🍽️', 'Dining'),
  _SectionIconOption('🥤', 'Soft drinks'),
  _SectionIconOption('🍷', 'Wine'),
  _SectionIconOption('🍺', 'Beer'),
  _SectionIconOption('🥃', 'Spirits'),
  _SectionIconOption('🍸', 'Cocktails'),
  _SectionIconOption('☕', 'Hot drinks'),
  _SectionIconOption('🥗', 'Starters'),
  _SectionIconOption('🍛', 'Curry'),
  _SectionIconOption('🍗', 'Chicken'),
  _SectionIconOption('🥩', 'Meat'),
  _SectionIconOption('🍔', 'Burgers'),
  _SectionIconOption('🍕', 'Pizza'),
  _SectionIconOption('🍝', 'Pasta'),
  _SectionIconOption('🐟', 'Seafood'),
  _SectionIconOption('🥦', 'Vegetarian'),
  _SectionIconOption('🍰', 'Desserts'),
  _SectionIconOption('🍦', 'Ice cream'),
  _SectionIconOption('🧒', 'Children'),
  _SectionIconOption('🥡', 'Takeaway'),
  _SectionIconOption('⭐', 'Specials'),
];

Future<void> _showSectionDialog({
  required BuildContext context,
  required WidgetRef ref,
  required VenueScope scope,
  required List<MenuSection> sections,
  required int nextSortOrder,
  MenuSection? existing,
}) async {
  final name = TextEditingController(text: existing?.name ?? '');
  final formKey = GlobalKey<FormState>();
  // Older records may contain a historical self-parent value. It is never a
  // valid hierarchy, so editing that section should repair it rather than
  // making the editor impossible to save.
  String? parentId = existing?.parentSectionId == existing?.id
      ? null
      : existing?.parentSectionId;
  var selectedIcon = existing?.icon ?? '🍽️';
  final iconOptions = [
    if (!_sectionIconOptions.any((item) => item.symbol == selectedIcon))
      _SectionIconOption(selectedIcon, 'Current icon'),
    ..._sectionIconOptions,
  ];
  final parentOptions = sections.where((item) => item.id != existing?.id);
  try {
    await _showMenuDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            existing == null ? 'Add menu section' : 'Edit menu section',
          ),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextFormField(
                      controller: name,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Section name',
                      ),
                      validator: _requiredText,
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Category icon',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final option in iconOptions)
                          ChoiceChip(
                            avatar: Text(option.symbol),
                            label: Text(option.label),
                            selected: selectedIcon == option.symbol,
                            onSelected: (_) => setDialogState(
                              () => selectedIcon = option.symbol,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    DropdownButtonFormField<String?>(
                      initialValue: parentId,
                      decoration: const InputDecoration(
                        labelText: 'Parent category (optional)',
                        helperText:
                            'Choose Alcohol for a Beer, Wine or Spirits subcategory.',
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('Top-level category'),
                        ),
                        for (final item in parentOptions)
                          DropdownMenuItem<String?>(
                            value: item.id,
                            child: Text('${item.icon} ${item.name}'),
                          ),
                      ],
                      onChanged: (value) =>
                          setDialogState(() => parentId = value),
                    ),
                  ],
                ),
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
                if (!(formKey.currentState?.validate() ?? false)) return;
                try {
                  final repository = ref.read(firestorePosRepositoryProvider);
                  if (existing == null) {
                    await repository.createMenuSection(
                      scope: scope,
                      name: name.text,
                      icon: selectedIcon,
                      sortOrder: nextSortOrder,
                      parentSectionId: parentId,
                    );
                  } else {
                    await repository.updateMenuSection(
                      scope: scope,
                      sectionId: existing.id,
                      name: name.text,
                      icon: selectedIcon,
                      parentSectionId: parentId,
                    );
                  }
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                } on Object catch (error, stackTrace) {
                  AppLogger.error('Save menu section', error, stackTrace);
                  if (!dialogContext.mounted) return;
                  showAppNotification(
                    dialogContext,
                    ref: ref,
                    title: 'Could not save section',
                    message: 'The section could not be saved: $error',
                    level: AppNotificationLevel.error,
                  );
                }
              },
              child: Text(existing == null ? 'Save section' : 'Save changes'),
            ),
          ],
        ),
      ),
    );
  } finally {
    name.dispose();
  }
}
