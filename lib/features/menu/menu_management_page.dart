import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/money.dart';
import '../../core/tenant_scope.dart';
import '../../data/firestore_pos_repository.dart';
import '../notifications/notification_centre.dart';
import '../pos/domain.dart';
import '../pos/pos_controller.dart';
import 'modifier_groups_page.dart';

/// Venue-scoped menu setup. A product may be attached to several sections but
/// keeps one default production area, allowing separate food/bar tickets.
class MenuManagementPage extends ConsumerStatefulWidget {
  const MenuManagementPage({super.key, required this.currencyCode});

  final String currencyCode;

  @override
  ConsumerState<MenuManagementPage> createState() => _MenuManagementPageState();
}

class _MenuManagementPageState extends ConsumerState<MenuManagementPage> {
  final _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = ref.watch(activeVenueScopeProvider);
    final sectionsValue = ref.watch(menuSectionsProvider);
    final productsValue = ref.watch(menuProductsProvider);
    final taxRatesValue = ref.watch(taxRatesProvider);
    final modifierGroupsValue = ref.watch(menuModifierGroupsProvider);
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
    final taxRates = taxRatesValue.when(
      data: (items) => items,
      loading: () => const <TaxRate>[],
      error: (_, _) => const <TaxRate>[],
    );
    final modifierGroups = modifierGroupsValue.when(
      data: (items) => items,
      loading: () => const <MenuModifierGroup>[],
      error: (_, _) => const <MenuModifierGroup>[],
    );
    final filteredSections = sections.where((section) {
      final parentName = sections
          .where((candidate) => candidate.id == section.parentSectionId)
          .map((candidate) => candidate.name)
          .firstOrNull;
      return _matchesMenuSearch(
        _searchQuery,
        '${section.name} ${parentName ?? ''}',
      );
    }).toList();
    final filteredProducts = products.where((product) {
      final sectionNames = sections
          .where((section) => product.sectionIds.contains(section.id))
          .map((section) => section.name)
          .join(' ');
      return _matchesMenuSearch(_searchQuery, '${product.name} $sectionNames');
    }).toList();
    final isSearching = _searchQuery.trim().isNotEmpty;

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
                      : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ModifierGroupsPage(
                              currencyCode: widget.currencyCode,
                            ),
                          ),
                        ),
                  icon: const Icon(Icons.tune_rounded),
                  label: const Text('Product options'),
                ),
                OutlinedButton.icon(
                  onPressed: scope == null
                      ? null
                      : () => _showSectionDialog(
                          context: context,
                          ref: ref,
                          scope: scope,
                          sections: sections,
                          nextSortOrder: sections.length,
                        ),
                  icon: const Icon(Icons.segment_outlined),
                  label: const Text('Add section'),
                ),
                OutlinedButton.icon(
                  onPressed: scope == null
                      ? null
                      : () => _showTaxRateDialog(
                          context: context,
                          ref: ref,
                          scope: scope,
                        ),
                  icon: const Icon(Icons.percent_rounded),
                  label: const Text('Add tax rate'),
                ),
                FilledButton.icon(
                  onPressed: scope == null || sections.isEmpty
                      ? null
                      : () => _showProductDialog(
                          context: context,
                          ref: ref,
                          scope: scope,
                          sections: sections,
                          taxRates: [TaxRate.zero, ...taxRates],
                          modifierGroups: modifierGroups,
                          allProducts: products,
                          currencyCode: widget.currencyCode,
                        ),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add product'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _searchController,
          onChanged: (value) => setState(() => _searchQuery = value),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            labelText: 'Search sections and products',
            hintText: 'Type any part of a name, such as wine or large',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: isSearching
                ? IconButton(
                    tooltip: 'Clear search',
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _searchQuery = '');
                    },
                    icon: const Icon(Icons.clear_rounded),
                  )
                : null,
            border: const OutlineInputBorder(),
          ),
        ),
        if (isSearching) ...[
          const SizedBox(height: 8),
          Text(
            '${filteredSections.length} section${filteredSections.length == 1 ? '' : 's'} and '
            '${filteredProducts.length} product${filteredProducts.length == 1 ? '' : 's'} found',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (scope == null)
          const _SetupHint(
            icon: Icons.cloud_off_outlined,
            text:
                'Demo menu shown. Select a restaurant and venue after signing in to configure its live menu.',
          )
        else if (sectionsValue.hasError ||
            productsValue.hasError ||
            taxRatesValue.hasError)
          const _SetupHint(
            icon: Icons.error_outline_rounded,
            text:
                'The menu or tax rates could not be loaded. Check the debug console and your Firestore rules.',
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
          Card(
            child: ExpansionTile(
              key: ValueKey('menu-sections-search-$_searchQuery'),
              initiallyExpanded: isSearching,
              leading: const Icon(Icons.account_tree_outlined),
              title: Text(
                isSearching
                    ? '${filteredSections.length} matching categor${filteredSections.length == 1 ? 'y' : 'ies'}'
                    : 'Manage ${sections.length} categories',
              ),
              subtitle: const Text(
                'Expand to rename, nest or safely delete categories.',
              ),
              children: [
                if (filteredSections.isEmpty)
                  const ListTile(
                    leading: Icon(Icons.search_off_rounded),
                    title: Text('No matching sections'),
                  ),
                for (final section in filteredSections)
                  _SectionTile(
                    section: section,
                    allSections: sections,
                    canEdit: scope != null,
                    onEdit: scope == null
                        ? null
                        : () => _showSectionDialog(
                            context: context,
                            ref: ref,
                            scope: scope,
                            sections: sections,
                            nextSortOrder: sections.length,
                            existing: section,
                          ),
                    onDelete: scope == null
                        ? null
                        : () => _deleteSection(
                            context: context,
                            ref: ref,
                            scope: scope,
                            section: section,
                          ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 24),
        Text('Tax rates', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Card(
          child: ExpansionTile(
            key: ValueKey(
              'tax-rates-${taxRates.map((rate) => rate.id).join('-')}',
            ),
            initiallyExpanded: taxRates.isNotEmpty,
            leading: const Icon(Icons.percent_rounded),
            title: Text(
              taxRates.isEmpty
                  ? 'Only Zero rate is available'
                  : 'Manage ${taxRates.length} venue tax rate${taxRates.length == 1 ? '' : 's'}',
            ),
            subtitle: const Text(
              'Prices are inclusive. Editing a rate updates future product sales only; closed bills remain unchanged.',
            ),
            children: [
              ListTile(
                leading: const CircleAvatar(child: Text('0%')),
                title: Text(TaxRate.zero.name),
                subtitle: const Text('Built-in rate — cannot be removed'),
              ),
              for (final taxRate in taxRates)
                _TaxRateTile(
                  rate: taxRate,
                  onEdit: scope == null
                      ? null
                      : () => _showTaxRateDialog(
                          context: context,
                          ref: ref,
                          scope: scope,
                          existing: taxRate,
                        ),
                  onDelete: scope == null
                      ? null
                      : () => _deleteTaxRate(
                          context: context,
                          ref: ref,
                          scope: scope,
                          rate: taxRate,
                        ),
                ),
            ],
          ),
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
        else if (filteredProducts.isEmpty)
          const _SetupHint(
            icon: Icons.search_off_rounded,
            text: 'No products match this search.',
          )
        else
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final product in filteredProducts)
                  _ProductTile(
                    product: product,
                    sections: sections,
                    currencyCode: widget.currencyCode,
                    canEdit: scope != null,
                    onEdit: scope == null
                        ? null
                        : () => _showProductDialog(
                            context: context,
                            ref: ref,
                            scope: scope,
                            sections: sections,
                            taxRates: [TaxRate.zero, ...taxRates],
                            modifierGroups: modifierGroups,
                            allProducts: products,
                            currencyCode: widget.currencyCode,
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
                              showAppNotification(
                                context,
                                ref: ref,
                                title: 'Availability update failed',
                                message:
                                    'The availability could not be updated.',
                                level: AppNotificationLevel.error,
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

bool _matchesMenuSearch(String query, String value) {
  final terms = query
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty);
  if (terms.isEmpty) return true;
  final searchableValue = value.toLowerCase();
  return terms.every(searchableValue.contains);
}

class _SectionTile extends StatelessWidget {
  const _SectionTile({
    required this.section,
    required this.allSections,
    required this.canEdit,
    required this.onEdit,
    required this.onDelete,
  });

  final MenuSection section;
  final List<MenuSection> allSections;
  final bool canEdit;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    MenuSection? parent;
    for (final item in allSections) {
      if (item.id == section.parentSectionId) {
        parent = item;
        break;
      }
    }
    return ListTile(
      leading: CircleAvatar(child: Text(section.icon)),
      title: Text(section.name),
      subtitle: Text(
        parent == null ? 'Top-level category' : 'Subcategory of ${parent.name}',
      ),
      trailing: Wrap(
        children: [
          IconButton(
            tooltip: 'Edit category',
            onPressed: canEdit ? onEdit : null,
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: 'Delete category',
            onPressed: canEdit ? onDelete : null,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
    );
  }
}

Future<void> _deleteSection({
  required BuildContext context,
  required WidgetRef ref,
  required VenueScope scope,
  required MenuSection section,
}) async {
  final approved = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Delete menu section?'),
      content: Text(
        '“${section.name}” will be deleted only if no products or subcategories use it.',
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
  if (approved != true) return;
  try {
    await ref
        .read(firestorePosRepositoryProvider)
        .deleteMenuSection(scope: scope, sectionId: section.id);
  } on Object catch (error, stackTrace) {
    AppLogger.error('Delete menu section', error, stackTrace);
    if (!context.mounted) return;
    showAppNotification(
      context,
      ref: ref,
      title: 'Could not delete section',
      message: 'The section could not be deleted: $error',
      level: AppNotificationLevel.error,
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
      subtitle: Text(
        '$sectionNames\n${product.productionArea.label} · ${product.taxRateLabel} · $stock',
      ),
      trailing: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        children: [
          Text(formatMoney(product.priceMinor, currencyCode: currencyCode)),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                product.isAvailable ? 'For sale' : 'Unavailable',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              Switch(
                value: product.isAvailable,
                onChanged: onAvailabilityChanged,
              ),
            ],
          ),
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

class _TaxRateTile extends StatelessWidget {
  const _TaxRateTile({
    required this.rate,
    required this.onEdit,
    required this.onDelete,
  });

  final TaxRate rate;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: CircleAvatar(child: Text(rate.percentageLabel)),
    title: Text(rate.name),
    subtitle: const Text('Used for tax-inclusive menu prices'),
    trailing: Wrap(
      children: [
        IconButton(
          tooltip: 'Edit tax rate',
          onPressed: onEdit,
          icon: const Icon(Icons.edit_outlined),
        ),
        IconButton(
          tooltip: 'Delete tax rate',
          onPressed: onDelete,
          icon: const Icon(Icons.delete_outline_rounded),
        ),
      ],
    ),
  );
}

Future<void> _showTaxRateDialog({
  required BuildContext context,
  required WidgetRef ref,
  required VenueScope scope,
  TaxRate? existing,
}) async {
  final name = TextEditingController(text: existing?.name ?? '');
  final percentage = TextEditingController(
    text: _taxPercentText(existing?.basisPoints ?? 0),
  );
  final formKey = GlobalKey<FormState>();
  try {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(existing == null ? 'Add tax rate' : 'Edit tax rate'),
        content: SizedBox(
          width: 420,
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: name,
                  autofocus: true,
                  maxLength: 80,
                  decoration: const InputDecoration(
                    labelText: 'Tax rate name',
                    hintText: 'For example, Food VAT',
                  ),
                  validator: _requiredText,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: percentage,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Rate (%)',
                    helperText:
                        'Prices are inclusive. 20 means 20% of the price is tax-inclusive.',
                  ),
                  validator: (value) => _taxBasisPointsFromText(value) == null
                      ? 'Enter a rate from 0% to 1,000% with at most two decimals.'
                      : null,
                ),
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
              if (!(formKey.currentState?.validate() ?? false)) return;
              try {
                final basisPoints = _taxBasisPointsFromText(percentage.text)!;
                final repository = ref.read(firestorePosRepositoryProvider);
                if (existing == null) {
                  await repository.createTaxRate(
                    scope: scope,
                    name: name.text,
                    basisPoints: basisPoints,
                  );
                } else {
                  await repository.updateTaxRate(
                    scope: scope,
                    existing: existing,
                    name: name.text,
                    basisPoints: basisPoints,
                  );
                }
                ref.invalidate(taxRatesProvider);
                if (dialogContext.mounted) Navigator.pop(dialogContext);
                if (context.mounted) {
                  showAppNotification(
                    context,
                    ref: ref,
                    title: existing == null
                        ? 'Tax rate added'
                        : 'Tax rate updated',
                    message:
                        '${name.text.trim()} is now available for products.',
                    level: AppNotificationLevel.success,
                  );
                }
              } on Object catch (error, stackTrace) {
                AppLogger.error('Save tax rate', error, stackTrace);
                if (!dialogContext.mounted) return;
                showAppNotification(
                  dialogContext,
                  ref: ref,
                  title: 'Could not save tax rate',
                  message: '$error',
                  level: AppNotificationLevel.error,
                );
              }
            },
            child: Text(existing == null ? 'Save rate' : 'Save changes'),
          ),
        ],
      ),
    );
  } finally {
    name.dispose();
    percentage.dispose();
  }
}

Future<void> _deleteTaxRate({
  required BuildContext context,
  required WidgetRef ref,
  required VenueScope scope,
  required TaxRate rate,
}) async {
  final approved = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Delete tax rate?'),
      content: Text(
        '“${rate.name}” can be deleted only when no products use it. Closed bills always retain their own tax records.',
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
  if (approved != true) return;
  try {
    await ref
        .read(firestorePosRepositoryProvider)
        .deleteTaxRate(scope: scope, rate: rate);
    ref.invalidate(taxRatesProvider);
    if (context.mounted) {
      showAppNotification(
        context,
        ref: ref,
        title: 'Tax rate deleted',
        message: '${rate.name} is no longer available for new products.',
        level: AppNotificationLevel.success,
      );
    }
  } on Object catch (error, stackTrace) {
    AppLogger.error('Delete tax rate', error, stackTrace);
    if (!context.mounted) return;
    showAppNotification(
      context,
      ref: ref,
      title: 'Could not delete tax rate',
      message: '$error',
      level: AppNotificationLevel.error,
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
    await showDialog<void>(
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

Future<void> _showProductDialog({
  required BuildContext context,
  required WidgetRef ref,
  required VenueScope scope,
  required List<MenuSection> sections,
  required List<TaxRate> taxRates,
  required List<MenuModifierGroup> modifierGroups,
  required List<MenuProduct> allProducts,
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
  final lowStockThreshold = TextEditingController(
    text: '${existing?.lowStockThreshold ?? 0}',
  );
  final storageLocation = TextEditingController(
    text: existing?.storageLocation ?? '',
  );
  final targetMargin = TextEditingController(
    text: existing == null || existing.targetMarginBasisPoints == 0
        ? ''
        : (existing.targetMarginBasisPoints / 100).toStringAsFixed(2),
  );
  final formKey = GlobalKey<FormState>();
  final selectedSections = <String>{...?existing?.sectionIds};
  final selectedModifierGroupIds = <String>{...?existing?.modifierGroupIds};
  var variants = <MenuProductVariant>[...?existing?.variants];
  var stockComponents = <ProductStockComponent>[...?existing?.stockComponents];
  var productionArea = existing?.productionArea ?? ProductionArea.kitchen;
  var trackStock = existing?.trackStock ?? false;
  var stockUnit = existing?.stockUnit ?? 'each';
  var showOnOrderFlow = existing?.showOnOrderFlow ?? true;
  var selectedTaxRateId =
      taxRates.map((rate) => rate.id).contains(existing?.taxRateId)
      ? existing!.taxRateId!
      : TaxRate.zero.id;

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
                    DropdownButtonFormField<String>(
                      initialValue: selectedTaxRateId,
                      decoration: const InputDecoration(
                        labelText: 'Tax rate',
                        helperText:
                            'Inclusive prices contain the selected tax rate.',
                      ),
                      items: [
                        for (final rate in taxRates)
                          DropdownMenuItem(
                            value: rate.id,
                            child: Text(
                              '${rate.name} (${rate.percentageLabel})',
                            ),
                          ),
                      ],
                      onChanged: (value) => setDialogState(
                        () => selectedTaxRateId = value ?? TaxRate.zero.id,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Variants',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      variants.isEmpty
                          ? 'No variants. The base price is used.'
                          : '${variants.length} variant${variants.length == 1 ? '' : 's'} configured. Customers must choose one.',
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final next = await _showVariantsDialog(
                          context: dialogContext,
                          currencyCode: currencyCode,
                          initialVariants: variants,
                          stockProducts: allProducts
                              .where(
                                (item) =>
                                    item.trackStock && item.id != existing?.id,
                              )
                              .toList(growable: false),
                        );
                        if (next != null) {
                          setDialogState(() => variants = next);
                        }
                      },
                      icon: const Icon(Icons.straighten_rounded),
                      label: Text(
                        variants.isEmpty ? 'Add variants' : 'Edit variants',
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Product options',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 4),
                    if (modifierGroups.isEmpty)
                      const Text(
                        'Create reusable cooking, spice or drink options first.',
                      )
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final group in modifierGroups)
                            FilterChip(
                              label: Text(
                                '${group.name}${group.isRequired ? ' *' : ''}',
                              ),
                              selected: selectedModifierGroupIds.contains(
                                group.id,
                              ),
                              onSelected: (selected) => setDialogState(() {
                                selected
                                    ? selectedModifierGroupIds.add(group.id)
                                    : selectedModifierGroupIds.remove(group.id);
                              }),
                            ),
                        ],
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
                      title: const Text('Show on Order Flow board'),
                      subtitle: const Text(
                        'Turn this off for items such as drinks that should print but do not need preparing/ready tracking.',
                      ),
                      value: showOnOrderFlow,
                      onChanged: (value) =>
                          setDialogState(() => showOnOrderFlow = value),
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Track finished-product stock'),
                      subtitle: const Text(
                        'Stock reduces when the product is released to production.',
                      ),
                      value: trackStock,
                      onChanged: (value) {
                        setDialogState(() {
                          trackStock = value;
                          // An existing untracked product has no opening-stock
                          // value. Start it safely at zero when tracking is
                          // enabled so the form cannot fail validation silently.
                          if (value && stock.text.trim().isEmpty) {
                            stock.text = '0';
                          }
                          if (value && stockPerSale.text.trim().isEmpty) {
                            stockPerSale.text = '1';
                          }
                        });
                      },
                    ),
                    if (trackStock) ...[
                      DropdownButtonFormField<String>(
                        initialValue:
                            const [
                              'each',
                              'ml',
                              'cl',
                              'l',
                              'g',
                              'kg',
                              'portion',
                            ].contains(stockUnit)
                            ? stockUnit
                            : 'each',
                        decoration: const InputDecoration(
                          labelText: 'Base stock unit',
                          helperText:
                              'Use the smallest practical unit, such as ml for spirits.',
                        ),
                        items: const [
                          DropdownMenuItem(value: 'each', child: Text('Each')),
                          DropdownMenuItem(
                            value: 'ml',
                            child: Text('Millilitres (ml)'),
                          ),
                          DropdownMenuItem(
                            value: 'cl',
                            child: Text('Centilitres (cl)'),
                          ),
                          DropdownMenuItem(
                            value: 'l',
                            child: Text('Litres (l)'),
                          ),
                          DropdownMenuItem(
                            value: 'g',
                            child: Text('Grams (g)'),
                          ),
                          DropdownMenuItem(
                            value: 'kg',
                            child: Text('Kilograms (kg)'),
                          ),
                          DropdownMenuItem(
                            value: 'portion',
                            child: Text('Portions'),
                          ),
                        ],
                        onChanged: (value) =>
                            setDialogState(() => stockUnit = value ?? 'each'),
                      ),
                      const SizedBox(height: 12),
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
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: lowStockThreshold,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Low-stock warning (${stockUnit.trim()})',
                          helperText:
                              'Inventory is highlighted at or below this quantity.',
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
                        controller: storageLocation,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: 'Storage location',
                          helperText:
                              'For example Bar, Kitchen, Cellar or Storeroom.',
                        ),
                        maxLength: 80,
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: targetMargin,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Target gross margin %',
                        helperText:
                            'Optional. Stock costing will warn when estimated margin is below this target.',
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) return null;
                        final parsed = _decimal(value);
                        return parsed == null || parsed < 0 || parsed > 100
                            ? 'Enter a percentage from 0 to 100.'
                            : null;
                      },
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Ingredient stock recipe',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      stockComponents.isEmpty
                          ? 'Optional. Consume other stock products when this item is sold.'
                          : stockComponents
                                .map(
                                  (item) =>
                                      '${item.productName}: ${item.quantityPerSale} ${item.stockUnit}',
                                )
                                .join(' · '),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final available = allProducts
                            .where(
                              (product) =>
                                  product.trackStock &&
                                  product.id != existing?.id,
                            )
                            .toList(growable: false);
                        final next = await _showStockComponentsDialog(
                          context: dialogContext,
                          products: available,
                          initial: stockComponents,
                        );
                        if (next != null) {
                          setDialogState(() => stockComponents = next);
                        }
                      },
                      icon: const Icon(Icons.account_tree_outlined),
                      label: Text(
                        stockComponents.isEmpty
                            ? 'Add ingredient usage'
                            : 'Edit ingredient usage',
                      ),
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
                if (!(formKey.currentState?.validate() ?? false)) {
                  showAppNotification(
                    dialogContext,
                    ref: ref,
                    title: 'Check the product details',
                    message:
                        'Correct the highlighted fields before saving. Stock quantities must be valid numbers.',
                    level: AppNotificationLevel.warning,
                  );
                  return;
                }
                if (selectedSections.isEmpty) {
                  showAppNotification(
                    dialogContext,
                    ref: ref,
                    title: 'Select a menu section',
                    message: 'Select at least one menu section.',
                    level: AppNotificationLevel.warning,
                  );
                  return;
                }
                try {
                  final priceMinor = _minorFromPriceText(price.text)!;
                  final selectedTaxRate = taxRates.firstWhere(
                    (rate) => rate.id == selectedTaxRateId,
                    orElse: () => TaxRate.zero,
                  );
                  final currentStock = trackStock ? _decimal(stock.text) : null;
                  final unitStock = trackStock
                      ? _decimal(stockPerSale.text)!
                      : 1.0;
                  final lowStock = trackStock
                      ? _decimal(lowStockThreshold.text)!
                      : 0.0;
                  final targetMarginBasisPoints =
                      targetMargin.text.trim().isEmpty
                      ? 0
                      : (_decimal(targetMargin.text)! * 100).round();
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
                      stockUnit: stockUnit,
                      stockPerSale: unitStock,
                      lowStockThreshold: lowStock,
                      storageLocation: storageLocation.text,
                      targetMarginBasisPoints: targetMarginBasisPoints,
                      showOnOrderFlow: showOnOrderFlow,
                      taxRateBasisPoints: selectedTaxRate.basisPoints,
                      taxRateId: selectedTaxRate.id == TaxRate.zero.id
                          ? null
                          : selectedTaxRate.id,
                      taxRateName: selectedTaxRate.name,
                      variants: variants,
                      modifierGroupIds: selectedModifierGroupIds.toList(
                        growable: false,
                      ),
                      stockComponents: stockComponents,
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
                      stockUnit: stockUnit,
                      stockPerSale: unitStock,
                      lowStockThreshold: lowStock,
                      storageLocation: storageLocation.text,
                      targetMarginBasisPoints: targetMarginBasisPoints,
                      showOnOrderFlow: showOnOrderFlow,
                      taxRateBasisPoints: selectedTaxRate.basisPoints,
                      taxRateId: selectedTaxRate.id == TaxRate.zero.id
                          ? null
                          : selectedTaxRate.id,
                      taxRateName: selectedTaxRate.name,
                      variants: variants,
                      modifierGroupIds: selectedModifierGroupIds.toList(
                        growable: false,
                      ),
                      stockComponents: stockComponents,
                    );
                  }
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                } on Object catch (error, stackTrace) {
                  AppLogger.error('Save menu product', error, stackTrace);
                  if (!dialogContext.mounted) return;
                  showAppNotification(
                    dialogContext,
                    ref: ref,
                    title: 'Could not save product',
                    message: 'The product could not be saved.',
                    level: AppNotificationLevel.error,
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
    lowStockThreshold.dispose();
    storageLocation.dispose();
    targetMargin.dispose();
  }
}

String? _requiredText(String? value) =>
    value == null || value.trim().isEmpty ? 'This field is required.' : null;

Future<List<ProductStockComponent>?> _showStockComponentsDialog({
  required BuildContext context,
  required List<MenuProduct> products,
  required List<ProductStockComponent> initial,
}) async {
  if (products.isEmpty) {
    showAppNotification(
      context,
      title: 'No ingredient products available',
      message:
          'Create or edit stock-tracked products first, then attach them as ingredients.',
      level: AppNotificationLevel.warning,
    );
    return null;
  }
  final selected = <String>{for (final item in initial) item.productId};
  final quantities = <String, TextEditingController>{
    for (final product in products)
      product.id: TextEditingController(
        text: initial
            .where((item) => item.productId == product.id)
            .map((item) => '${item.quantityPerSale}')
            .firstOrNull,
      ),
  };
  try {
    return await showDialog<List<ProductStockComponent>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Ingredient usage per sale'),
          content: SizedBox(
            width: 540,
            child: ListView(
              shrinkWrap: true,
              children: [
                const Text(
                  'Quantities use each ingredient’s base stock unit. Example: 50 ml vodka and 333 ml mixer.',
                ),
                const SizedBox(height: 12),
                for (final product in products)
                  CheckboxListTile(
                    value: selected.contains(product.id),
                    title: Text(product.name),
                    subtitle: selected.contains(product.id)
                        ? TextField(
                            controller: quantities[product.id],
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: InputDecoration(
                              labelText: '${product.stockUnit} used per sale',
                            ),
                          )
                        : Text('Measured in ${product.stockUnit}'),
                    onChanged: (value) => setState(() {
                      value == true
                          ? selected.add(product.id)
                          : selected.remove(product.id);
                    }),
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
              onPressed: () {
                final result = <ProductStockComponent>[];
                for (final product in products.where(
                  (item) => selected.contains(item.id),
                )) {
                  final quantity = _decimal(quantities[product.id]?.text);
                  if (quantity == null || quantity <= 0) {
                    showAppNotification(
                      context,
                      title: 'Enter ingredient quantities',
                      message:
                          'Enter a positive quantity for every selected ingredient.',
                      level: AppNotificationLevel.warning,
                    );
                    return;
                  }
                  result.add(
                    ProductStockComponent(
                      productId: product.id,
                      productName: product.name,
                      quantityPerSale: quantity,
                      stockUnit: product.stockUnit,
                    ),
                  );
                }
                Navigator.pop(context, result);
              },
              child: const Text('Apply recipe'),
            ),
          ],
        ),
      ),
    );
  } finally {
    for (final controller in quantities.values) {
      controller.dispose();
    }
  }
}

Future<List<MenuProductVariant>?> _showVariantsDialog({
  required BuildContext context,
  required String currencyCode,
  required List<MenuProductVariant> initialVariants,
  required List<MenuProduct> stockProducts,
}) async {
  final drafts = initialVariants
      .map(
        (variant) => _VariantDraft(
          id: variant.id,
          name: variant.name,
          priceDelta: _priceText(variant.priceDeltaMinor),
          isAvailable: variant.isAvailable,
          stockComponents: variant.stockComponents,
        ),
      )
      .toList(growable: true);
  if (drafts.isEmpty) drafts.add(_VariantDraft.empty());
  String? validationMessage;

  try {
    return await showDialog<List<MenuProductVariant>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Product variants'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Examples: Small, Large, Glass or Bottle. Prices are adjustments from the product’s base price ($currencyCode).',
                  ),
                  const SizedBox(height: 12),
                  for (var index = 0; index < drafts.length; index++) ...[
                    _VariantDraftRow(
                      draft: drafts[index],
                      canRemove: drafts.length > 1,
                      onRemove: () =>
                          setDialogState(() => drafts.removeAt(index)),
                      onChanged: () =>
                          setDialogState(() => validationMessage = null),
                      onEditRecipe: () async {
                        final recipe = await _showStockComponentsDialog(
                          context: dialogContext,
                          products: stockProducts,
                          initial: drafts[index].stockComponents,
                        );
                        if (recipe != null) {
                          setDialogState(
                            () => drafts[index].stockComponents = recipe,
                          );
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                  ],
                  TextButton.icon(
                    onPressed: drafts.length >= 30
                        ? null
                        : () => setDialogState(
                            () => drafts.add(_VariantDraft.empty()),
                          ),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Add another variant'),
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
              onPressed: () {
                final variants = <MenuProductVariant>[];
                final names = <String>{};
                for (final draft in drafts) {
                  final variantName = draft.name.text.trim();
                  final priceDelta = _minorFromSignedPriceText(
                    draft.priceDelta.text,
                  );
                  if (variantName.isEmpty || priceDelta == null) {
                    setDialogState(
                      () => validationMessage =
                          'Every variant needs a name and valid price adjustment.',
                    );
                    return;
                  }
                  if (!names.add(variantName.toLowerCase())) {
                    setDialogState(
                      () => validationMessage = 'Variant names must be unique.',
                    );
                    return;
                  }
                  variants.add(
                    MenuProductVariant(
                      id: draft.id,
                      name: variantName,
                      priceDeltaMinor: priceDelta,
                      isAvailable: draft.isAvailable,
                      stockComponents: draft.stockComponents,
                    ),
                  );
                }
                Navigator.pop(dialogContext, variants);
              },
              child: const Text('Save variants'),
            ),
          ],
        ),
      ),
    );
  } finally {
    for (final draft in drafts) {
      draft.dispose();
    }
  }
}

class _VariantDraftRow extends StatelessWidget {
  const _VariantDraftRow({
    required this.draft,
    required this.canRemove,
    required this.onRemove,
    required this.onChanged,
    required this.onEditRecipe,
  });

  final _VariantDraft draft;
  final bool canRemove;
  final VoidCallback onRemove;
  final VoidCallback onChanged;
  final VoidCallback onEditRecipe;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: TextField(
              controller: draft.name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Variant name'),
              onChanged: (_) => onChanged(),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: TextField(
              controller: draft.priceDelta,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Price +/-'),
              onChanged: (_) => onChanged(),
            ),
          ),
          const SizedBox(width: 4),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Tooltip(
                message: draft.isAvailable ? 'Available' : 'Unavailable',
                child: Switch(
                  value: draft.isAvailable,
                  onChanged: (value) {
                    draft.isAvailable = value;
                    onChanged();
                  },
                ),
              ),
              IconButton(
                tooltip: 'Remove variant',
                onPressed: canRemove ? onRemove : null,
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ],
          ),
        ],
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: onEditRecipe,
          icon: const Icon(Icons.inventory_2_outlined, size: 18),
          label: Text(
            draft.stockComponents.isEmpty
                ? 'Set variant stock recipe'
                : '${draft.stockComponents.length} stock component${draft.stockComponents.length == 1 ? '' : 's'}',
          ),
        ),
      ),
    ],
  );
}

class _VariantDraft {
  _VariantDraft({
    required this.id,
    required String name,
    required String priceDelta,
    required this.isAvailable,
    this.stockComponents = const <ProductStockComponent>[],
  }) : name = TextEditingController(text: name),
       priceDelta = TextEditingController(text: priceDelta);

  factory _VariantDraft.empty() => _VariantDraft(
    id: _nextVariantDraftId(),
    name: '',
    priceDelta: '0.00',
    isAvailable: true,
  );

  final String id;
  final TextEditingController name;
  final TextEditingController priceDelta;
  bool isAvailable;
  List<ProductStockComponent> stockComponents;

  void dispose() {
    name.dispose();
    priceDelta.dispose();
  }
}

var _variantDraftCounter = 0;

String _nextVariantDraftId() =>
    'variant-${DateTime.now().microsecondsSinceEpoch}-${_variantDraftCounter++}';

double? _decimal(String? value) {
  if (value == null) return null;
  return double.tryParse(value.trim().replaceAll(',', '.'));
}

int? _taxBasisPointsFromText(String? value) {
  final percent = _decimal(value);
  if (percent == null || percent < 0 || percent > 1000) return null;
  final basisPoints = (percent * 100).round();
  return (basisPoints / 100 - percent).abs() < 0.00001 ? basisPoints : null;
}

String _taxPercentText(int basisPoints) {
  final percent = basisPoints / 100;
  return percent == percent.roundToDouble()
      ? percent.toStringAsFixed(0)
      : percent.toStringAsFixed(2);
}

int? _minorFromPriceText(String? value) {
  final parsed = _decimal(value);
  if (parsed == null || parsed < 0 || !parsed.isFinite) return null;
  final minor = (parsed * 100).round();
  return minor >= 0 ? minor : null;
}

int? _minorFromSignedPriceText(String? value) {
  final parsed = _decimal(value);
  if (parsed == null || !parsed.isFinite) return null;
  final minor = (parsed * 100).round();
  return minor.abs() <= 100000000 ? minor : null;
}

String _priceText(int minor) {
  final major = minor ~/ 100;
  final decimals = (minor % 100).toString().padLeft(2, '0');
  return '$major.$decimals';
}

String _formatQuantity(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toString();
