import 'package:flutter/material.dart';

import '../../core/money.dart';
import 'domain.dart';

/// Lets staff choose a product variant, reusable option groups and an
/// optional kitchen-safe note before an order line is created. The same data
/// is independently validated and priced by the server function.
Future<ProductConfigurationSelection?> showProductConfigurationSheet({
  required BuildContext context,
  required MenuProduct product,
  required List<MenuModifierGroup> availableGroups,
  required String currencyCode,
}) async {
  final note = TextEditingController();
  final groupsById = <String, MenuModifierGroup>{
    for (final group in availableGroups) group.id: group,
  };
  final groups = product.modifierGroupIds
      .map((id) => groupsById[id])
      .whereType<MenuModifierGroup>()
      .toList(growable: false);
  final missingGroupCount = product.modifierGroupIds.length - groups.length;
  final variants = product.variants
      .where((variant) => variant.isAvailable)
      .toList(growable: false);
  MenuProductVariant? selectedVariant = variants.length == 1
      ? variants.single
      : null;
  final selectedOptionIds = <String, Set<String>>{
    for (final group in groups) group.id: <String>{},
  };
  String? validationMessage;

  try {
    return await showModalBottomSheet<ProductConfigurationSelection>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final selectedModifiers = <OrderModifierSelection>[
            for (final group in groups)
              for (final option in group.options)
                if (selectedOptionIds[group.id]?.contains(option.id) == true)
                  OrderModifierSelection(
                    groupId: group.id,
                    groupName: group.name,
                    optionId: option.id,
                    optionName: option.name,
                    priceDeltaMinor: option.priceDeltaMinor,
                  ),
          ];
          final priceDeltaMinor =
              (selectedVariant?.priceDeltaMinor ?? 0) +
              selectedModifiers.fold<int>(
                0,
                (total, selection) => total + selection.priceDeltaMinor,
              );
          final totalMinor = product.priceMinor + priceDeltaMinor;
          final hasUnavailableVariant =
              product.variants.isNotEmpty && variants.isEmpty;

          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 720),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                product.name,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Configure this item before adding it to the order.',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Cancel',
                          onPressed: () => Navigator.pop(sheetContext),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (hasUnavailableVariant)
                            const _ConfigurationNotice(
                              message:
                                  'This product has no available variants. Ask a manager to update the menu before selling it.',
                              isError: true,
                            )
                          else if (variants.isNotEmpty) ...[
                            Text(
                              'Size / variant *',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 4),
                            const Text('Choose one option.'),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final variant in variants)
                                  ChoiceChip(
                                    label: Text(
                                      _priceChoiceLabel(
                                        variant.name,
                                        variant.priceDeltaMinor,
                                        currencyCode,
                                      ),
                                    ),
                                    selected: selectedVariant?.id == variant.id,
                                    onSelected: (_) => setSheetState(() {
                                      selectedVariant = variant;
                                      validationMessage = null;
                                    }),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 20),
                          ],
                          if (missingGroupCount > 0)
                            const _ConfigurationNotice(
                              message:
                                  'One or more product option groups are unavailable. Ask a manager to review this product.',
                              isError: true,
                            ),
                          for (final group in groups) ...[
                            _GroupChooser(
                              group: group,
                              selectedOptionIds:
                                  selectedOptionIds[group.id] ?? const {},
                              currencyCode: currencyCode,
                              onChanged: (optionId, isSelected) {
                                setSheetState(() {
                                  final ids = selectedOptionIds[group.id]!;
                                  if (isSelected) {
                                    if (ids.length < group.maximumSelections) {
                                      ids.add(optionId);
                                    }
                                  } else {
                                    ids.remove(optionId);
                                  }
                                  validationMessage = null;
                                });
                              },
                            ),
                            const SizedBox(height: 20),
                          ],
                          Text(
                            'Item note',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 4),
                          TextField(
                            controller: note,
                            minLines: 1,
                            maxLines: 3,
                            maxLength: 500,
                            textCapitalization: TextCapitalization.sentences,
                            decoration: const InputDecoration(
                              hintText:
                                  'Optional instruction for kitchen or bar, for example “allergy discussed”.',
                            ),
                            onChanged: (_) {
                              if (validationMessage != null) {
                                setSheetState(() => validationMessage = null);
                              }
                            },
                          ),
                          if (validationMessage != null) ...[
                            const SizedBox(height: 8),
                            _ConfigurationNotice(
                              message: validationMessage!,
                              isError: true,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Total: ${formatMoney(totalMinor, currencyCode: currencyCode)}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        FilledButton.icon(
                          onPressed:
                              hasUnavailableVariant ||
                                  missingGroupCount > 0 ||
                                  totalMinor < 0
                              ? null
                              : () {
                                  if (variants.isNotEmpty &&
                                      selectedVariant == null) {
                                    setSheetState(
                                      () => validationMessage =
                                          'Choose a size or variant.',
                                    );
                                    return;
                                  }
                                  for (final group in groups) {
                                    final selected =
                                        selectedOptionIds[group.id]?.length ??
                                        0;
                                    if (!group.isAvailable) {
                                      setSheetState(
                                        () => validationMessage =
                                            '${group.name} is currently unavailable.',
                                      );
                                      return;
                                    }
                                    if (selected < group.minimumSelections ||
                                        selected > group.maximumSelections) {
                                      setSheetState(
                                        () => validationMessage =
                                            '${group.name}: choose ${_selectionRequirement(group)}.',
                                      );
                                      return;
                                    }
                                  }
                                  Navigator.pop(
                                    sheetContext,
                                    ProductConfigurationSelection(
                                      variant: selectedVariant,
                                      modifiers: selectedModifiers,
                                      itemNote: note.text.trim(),
                                    ),
                                  );
                                },
                          icon: const Icon(Icons.add_shopping_cart_rounded),
                          label: const Text('Add to order'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  } finally {
    note.dispose();
  }
}

class _GroupChooser extends StatelessWidget {
  const _GroupChooser({
    required this.group,
    required this.selectedOptionIds,
    required this.currencyCode,
    required this.onChanged,
  });

  final MenuModifierGroup group;
  final Set<String> selectedOptionIds;
  final String currencyCode;
  final void Function(String optionId, bool isSelected) onChanged;

  @override
  Widget build(BuildContext context) {
    final options = group.options
        .where((option) => option.isAvailable)
        .toList();
    final selectionLimitReached =
        selectedOptionIds.length >= group.maximumSelections;
    return Opacity(
      opacity: group.isAvailable ? 1 : 0.55,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(group.name, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            group.isAvailable
                ? 'Choose ${_selectionRequirement(group)}.'
                : 'This option group is currently unavailable.',
          ),
          if (options.isEmpty) ...[
            const SizedBox(height: 6),
            const Text('No options are currently available.'),
          ] else ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in options)
                  FilterChip(
                    label: Text(
                      _priceChoiceLabel(
                        option.name,
                        option.priceDeltaMinor,
                        currencyCode,
                      ),
                    ),
                    selected: selectedOptionIds.contains(option.id),
                    onSelected:
                        !group.isAvailable ||
                            (!selectedOptionIds.contains(option.id) &&
                                selectionLimitReached)
                        ? null
                        : (selected) => onChanged(option.id, selected),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ConfigurationNotice extends StatelessWidget {
  const _ConfigurationNotice({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = isError ? scheme.error : scheme.primary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(message, style: TextStyle(color: color)),
    );
  }
}

String _priceChoiceLabel(String name, int deltaMinor, String currencyCode) {
  if (deltaMinor == 0) return name;
  final sign = deltaMinor.isNegative ? '' : '+';
  return '$name ($sign${formatMoney(deltaMinor, currencyCode: currencyCode)})';
}

String _selectionRequirement(MenuModifierGroup group) {
  if (group.minimumSelections == group.maximumSelections) {
    return group.minimumSelections == 1
        ? 'one option'
        : '${group.minimumSelections} options';
  }
  if (group.minimumSelections == 0) {
    return 'up to ${group.maximumSelections} option${group.maximumSelections == 1 ? '' : 's'}';
  }
  return '${group.minimumSelections}–${group.maximumSelections} options';
}
