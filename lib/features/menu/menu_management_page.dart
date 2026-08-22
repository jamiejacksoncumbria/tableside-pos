import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/money.dart';
import '../../core/tenant_scope.dart';
import '../../data/firestore_pos_repository.dart';
import '../pos/domain.dart';
import '../pos/pos_controller.dart';

/// Venue-scoped menu setup. A product may be attached to several sections but
/// keeps one default production area, allowing separate food/bar tickets.
class MenuManagementPage extends ConsumerWidget {
  const MenuManagementPage({super.key, required this.currencyCode});

  final String currencyCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(activeVenueScopeProvider);
    final sectionsValue = ref.watch(menuSectionsProvider);
    final productsValue = ref.watch(menuProductsProvider);
    final sections = sectionsValue.when(
      data: (items) => items,
      loading: () => scope == null ? demoSections : const <MenuSection>[],
      error: (_, _) => scope == null ? demoSections : const <MenuSection>[],
    );
    final products = productsValue.when(
      data: (items) => items,
      loading: () => scope == null ? demoProducts : const <MenuProduct>[],
      error: (_, _) => scope == null ? demoProducts : const <MenuProduct>[],
    );

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 12,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Menu management',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 4),
                const Text(
                  'Sections and products are specific to the selected venue.',
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: scope == null
                      ? null
                      : () => _showSectionDialog(
                          context: context,
                          ref: ref,
                          scope: scope,
                          nextSortOrder: sections.length,
                        ),
                  icon: const Icon(Icons.segment_outlined),
                  label: const Text('Add section'),
                ),
                FilledButton.icon(
                  onPressed: scope == null || sections.isEmpty
                      ? null
                      : () => _showProductDialog(
                          context: context,
                          ref: ref,
                          scope: scope,
                          sections: sections,
                          currencyCode: currencyCode,
                        ),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add product'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (scope == null)
          const _SetupHint(
            icon: Icons.cloud_off_outlined,
            text:
                'Demo menu shown. Select a restaurant and venue after signing in to configure its live menu.',
          )
        else if (sectionsValue.hasError || productsValue.hasError)
          const _SetupHint(
            icon: Icons.error_outline_rounded,
            text:
                'The menu could not be loaded. Check the debug console and your Firestore rules.',
          )
        else if (sections.isEmpty)
          const _SetupHint(
            icon: Icons.menu_book_outlined,
            text:
                'Create a section first, such as Drinks, Starters or Main courses.',
          ),
        const SizedBox(height: 20),
        Text('Sections', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        if (sections.isEmpty)
          const Text('No menu sections have been configured yet.')
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final section in sections)
                Chip(label: Text('${section.icon}  ${section.name}')),
            ],
          ),
        const SizedBox(height: 24),
        Text('Products', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        if (products.isEmpty)
          const _SetupHint(
            icon: Icons.restaurant_menu_outlined,
            text:
                'No products yet. Add a product and assign its sections, production area, price and optional stock tracking.',
          )
        else
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final product in products)
                  _ProductTile(
                    product: product,
                    sections: sections,
                    currencyCode: currencyCode,
                    canEdit: scope != null,
                    onEdit: scope == null
                        ? null
                        : () => _showProductDialog(
                            context: context,
                            ref: ref,
                            scope: scope,
                            sections: sections,
                            currencyCode: currencyCode,
                            existing: product,
                          ),
                    onAvailabilityChanged: scope == null
                        ? null
                        : (available) async {
                            try {
                              await ref
                                  .read(firestorePosRepositoryProvider)
                                  .setProductAvailability(
                                    scope: scope,
                                    productId: product.id,
                                    isAvailable: available,
                                  );
                            } on Object catch (error, stackTrace) {
                              AppLogger.error(
                                'Set product availability',
                                error,
                                stackTrace,
                              );
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'The availability could not be updated.',
                                  ),
                                ),
                              );
                            }
                          },
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({
    required this.product,
    required this.sections,
    required this.currencyCode,
    required this.canEdit,
    required this.onEdit,
    required this.onAvailabilityChanged,
  });

  final MenuProduct product;
  final List<MenuSection> sections;
  final String currencyCode;
  final bool canEdit;
  final VoidCallback? onEdit;
  final ValueChanged<bool>? onAvailabilityChanged;

  @override
  Widget build(BuildContext context) {
    final sectionNames = sections
        .where((section) => product.sectionIds.contains(section.id))
        .map((section) => section.name)
        .join(' · ');
    final stock = product.trackStock
        ? product.stockOnHand == null
              ? 'Stock tracking enabled'
              : '${_formatQuantity(product.stockOnHand!)} ${product.stockUnit} in stock'
        : 'Stock not tracked';
    return ListTile(
      isThreeLine: true,
      leading: CircleAvatar(
        child: Icon(switch (product.productionArea) {
          ProductionArea.bar => Icons.local_bar_rounded,
          ProductionArea.kitchen => Icons.restaurant_rounded,
          ProductionArea.dessert => Icons.cake_outlined,
        }),
      ),
      title: Text(product.name),
      subtitle: Text('$sectionNames\n${product.productionArea.label} · $stock'),
      trailing: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        children: [
          Text(formatMoney(product.priceMinor, currencyCode: currencyCode)),
          Switch(value: product.isAvailable, onChanged: onAvailabilityChanged),
          IconButton(
            tooltip: 'Edit product',
            onPressed: canEdit ? onEdit : null,
            icon: const Icon(Icons.edit_outlined),
          ),
        ],
      ),
    );
  }
}

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

Future<void> _showSectionDialog({
  required BuildContext context,
  required WidgetRef ref,
  required VenueScope scope,
  required int nextSortOrder,
}) async {
  final name = TextEditingController();
  final icon = TextEditingController(text: '🍽️');
  final formKey = GlobalKey<FormState>();
  try {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add menu section'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Section name'),
                validator: _requiredText,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: icon,
                decoration: const InputDecoration(
                  labelText: 'Icon (optional)',
                  helperText: 'For example: 🍷 or 🍛',
                ),
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
                await ref
                    .read(firestorePosRepositoryProvider)
                    .createMenuSection(
                      scope: scope,
                      name: name.text,
                      icon: icon.text,
                      sortOrder: nextSortOrder,
                    );
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              } on Object catch (error, stackTrace) {
                AppLogger.error('Create menu section', error, stackTrace);
                if (!dialogContext.mounted) return;
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(
                    content: Text('The section could not be saved.'),
                  ),
                );
              }
            },
            child: const Text('Save section'),
          ),
        ],
      ),
    );
  } finally {
    name.dispose();
    icon.dispose();
  }
}

Future<void> _showProductDialog({
  required BuildContext context,
  required WidgetRef ref,
  required VenueScope scope,
  required List<MenuSection> sections,
  required String currencyCode,
  MenuProduct? existing,
}) async {
  final name = TextEditingController(text: existing?.name ?? '');
  final price = TextEditingController(
    text: existing == null ? '' : _priceText(existing.priceMinor),
  );
  final stock = TextEditingController(
    text: existing?.stockOnHand == null ? '' : '${existing!.stockOnHand}',
  );
  final stockPerSale = TextEditingController(
    text: '${existing?.stockPerSale ?? 1}',
  );
  final formKey = GlobalKey<FormState>();
  final selectedSections = <String>{...?existing?.sectionIds};
  var productionArea = existing?.productionArea ?? ProductionArea.kitchen;
  var trackStock = existing?.trackStock ?? false;

  try {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'Add product' : 'Edit product'),
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
                        labelText: 'Product name',
                      ),
                      validator: _requiredText,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: price,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: 'Inclusive price ($currencyCode)',
                        helperText:
                            'Use 12.50 for twelve currency units and fifty.',
                      ),
                      validator: (value) => _minorFromPriceText(value) == null
                          ? 'Enter a valid non-negative price.'
                          : null,
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Menu sections',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final section in sections)
                          FilterChip(
                            label: Text('${section.icon} ${section.name}'),
                            selected: selectedSections.contains(section.id),
                            onSelected: (selected) => setDialogState(() {
                              selected
                                  ? selectedSections.add(section.id)
                                  : selectedSections.remove(section.id);
                            }),
                          ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Production area',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    Wrap(
                      spacing: 6,
                      children: [
                        for (final area in ProductionArea.values)
                          ChoiceChip(
                            label: Text(area.label),
                            selected: productionArea == area,
                            onSelected: (_) =>
                                setDialogState(() => productionArea = area),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Track finished-product stock'),
                      subtitle: const Text(
                        'Stock reduces when the product is released to production.',
                      ),
                      value: trackStock,
                      onChanged: (value) =>
                          setDialogState(() => trackStock = value),
                    ),
                    if (trackStock) ...[
                      TextFormField(
                        controller: stock,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Opening stock',
                          helperText:
                              'Decimals are supported, for example 12.5.',
                        ),
                        validator: (value) {
                          final parsed = _decimal(value);
                          return parsed == null || parsed < 0
                              ? 'Enter zero or a positive quantity.'
                              : null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: stockPerSale,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Stock used per sale',
                          helperText:
                              'Normally 1. Future cl/litre products can use decimals.',
                        ),
                        validator: (value) {
                          final parsed = _decimal(value);
                          return parsed == null || parsed <= 0
                              ? 'Enter a positive quantity.'
                              : null;
                        },
                      ),
                    ],
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
                if (selectedSections.isEmpty) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(
                      content: Text('Select at least one menu section.'),
                    ),
                  );
                  return;
                }
                try {
                  final priceMinor = _minorFromPriceText(price.text)!;
                  final currentStock = trackStock ? _decimal(stock.text) : null;
                  final unitStock = trackStock
                      ? _decimal(stockPerSale.text)!
                      : 1.0;
                  final repository = ref.read(firestorePosRepositoryProvider);
                  if (existing == null) {
                    await repository.createProduct(
                      scope: scope,
                      name: name.text,
                      priceMinor: priceMinor,
                      sectionIds: selectedSections.toList(growable: false),
                      productionArea: productionArea,
                      trackStock: trackStock,
                      stockOnHand: currentStock,
                      stockPerSale: unitStock,
                    );
                  } else {
                    await repository.updateProduct(
                      scope: scope,
                      productId: existing.id,
                      name: name.text,
                      priceMinor: priceMinor,
                      sectionIds: selectedSections.toList(growable: false),
                      productionArea: productionArea,
                      trackStock: trackStock,
                      stockOnHand: currentStock,
                      stockPerSale: unitStock,
                    );
                  }
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                } on Object catch (error, stackTrace) {
                  AppLogger.error('Save menu product', error, stackTrace);
                  if (!dialogContext.mounted) return;
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(
                      content: Text('The product could not be saved.'),
                    ),
                  );
                }
              },
              child: Text(existing == null ? 'Save product' : 'Save changes'),
            ),
          ],
        ),
      ),
    );
  } finally {
    name.dispose();
    price.dispose();
    stock.dispose();
    stockPerSale.dispose();
  }
}

String? _requiredText(String? value) =>
    value == null || value.trim().isEmpty ? 'This field is required.' : null;

double? _decimal(String? value) {
  if (value == null) return null;
  return double.tryParse(value.trim().replaceAll(',', '.'));
}

int? _minorFromPriceText(String? value) {
  final parsed = _decimal(value);
  if (parsed == null || parsed < 0 || !parsed.isFinite) return null;
  final minor = (parsed * 100).round();
  return minor >= 0 ? minor : null;
}

String _priceText(int minor) {
  final major = minor ~/ 100;
  final decimals = (minor % 100).toString().padLeft(2, '0');
  return '$major.$decimals';
}

String _formatQuantity(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toString();
