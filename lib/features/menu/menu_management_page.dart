import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_logger.dart';
import '../../core/money.dart';
import '../../core/tenant_scope.dart';
import '../../data/firestore_pos_repository.dart';
import '../notifications/notification_centre.dart';
import '../fulfilment/fulfilment_repository.dart';
import '../pos/domain.dart';
import '../pos/pos_controller.dart';
import 'modifier_groups_page.dart';

part 'widgets/menu_management_catalogue.dart';
part 'widgets/menu_management_tax.dart';
part 'widgets/menu_management_sections.dart';
part 'widgets/menu_product_editor.dart';

/// Opens a menu-management dialog and does not complete until Flutter has
/// removed the route's overlay entries after its closing animation.
///
/// Several menu editors keep form controllers in their calling function. The
/// regular `showDialog` future resolves when the route is popped, which can be
/// before those text fields have left the overlay. Waiting for `completed`
/// prevents barrier dismissal or Cancel from disposing controllers while the
/// closing dialog can still lay out or paint them.
Future<T?> _showMenuDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) async {
  final route = DialogRoute<T>(context: context, builder: builder);
  final result = await Navigator.of(
    context,
    rootNavigator: true,
  ).push<T>(route);
  await route.completed;
  return result;
}

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
  String? _productCategoryFilter;
  String? _productSubcategoryFilter;
  final Set<String> _selectedProductIds = {};
  bool _savingBulkProducts = false;
  bool _savingDefaultTaxRate = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = ref.watch(activeVenueScopeProvider);
    final sectionsValue = ref.watch(menuSectionsProvider);
    final productsValue = ref.watch(allMenuProductsProvider);
    final taxRatesValue = ref.watch(taxRatesProvider);
    final defaultTaxRateIdValue = ref.watch(defaultTaxRateIdProvider);
    final modifierGroupsValue = ref.watch(menuModifierGroupsProvider);
    final variantSetsValue = ref.watch(menuVariantSetsProvider);
    final coursesValue = ref.watch(venueCoursesProvider);
    final sections = sectionsValue.when(
      data: (items) => items,
      loading: () => scope == null ? demoSections : const <MenuSection>[],
      error: (_, _) => scope == null ? demoSections : const <MenuSection>[],
    );
    final allProducts = productsValue.when(
      data: (items) => items,
      loading: () => scope == null ? demoProducts : const <MenuProduct>[],
      error: (_, _) => scope == null ? demoProducts : const <MenuProduct>[],
    );
    final products = allProducts
        .where((product) => !product.isArchived)
        .toList(growable: false);
    final archivedProducts = allProducts
        .where((product) => product.isArchived)
        .toList(growable: false);
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
    final variantSets = variantSetsValue.when(
      data: (items) => items,
      loading: () => const <MenuVariantSet>[],
      error: (_, _) => const <MenuVariantSet>[],
    );
    final courses = coursesValue.when(
      data: (items) =>
          items.where((item) => item.active).toList(growable: false),
      loading: () => const <MenuCourse>[],
      error: (_, _) => const <MenuCourse>[],
    );
    final configuredDefaultTaxRateId = defaultTaxRateIdValue.value;
    final defaultTaxRateId =
        taxRates.any((rate) => rate.id == configuredDefaultTaxRateId)
        ? configuredDefaultTaxRateId!
        : TaxRate.zero.id;
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
    final filterSubcategories = sections
        .where((section) => section.parentSectionId == _productCategoryFilter)
        .toList(growable: false);
    final filteredProducts = products.where((product) {
      final sectionNames = sections
          .where((section) => product.sectionIds.contains(section.id))
          .map((section) => section.name)
          .join(' ');
      if (_searchQuery.trim().isNotEmpty) {
        return _matchesMenuSearch(
          _searchQuery,
          '${product.name} $sectionNames',
        );
      }
      if (_productSubcategoryFilter != null) {
        return product.sectionIds.contains(_productSubcategoryFilter);
      }
      if (_productCategoryFilter == null) return true;
      final included = <String>{
        _productCategoryFilter!,
        ...filterSubcategories.map((section) => section.id),
      };
      return product.sectionIds.any(included.contains);
    }).toList();
    final isSearching = _searchQuery.trim().isNotEmpty;
    final visibleProductIds = filteredProducts.map((item) => item.id).toSet();
    final allVisibleSelected =
        visibleProductIds.isNotEmpty &&
        visibleProductIds.every(_selectedProductIds.contains);

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
                  onPressed: scope == null || sections.length < 2
                      ? null
                      : () => _showSectionOrderDialog(
                          context: context,
                          ref: ref,
                          scope: scope,
                          sections: sections,
                        ),
                  icon: const Icon(Icons.swap_vert_rounded),
                  label: const Text('Order sections'),
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
                          variantSets: variantSets,
                          allProducts: products,
                          currencyCode: widget.currencyCode,
                          defaultTaxRateId: defaultTaxRateId,
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
                'Expand to rename, nest or safely delete categories. Use Order sections to change their POS display order.',
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
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: DropdownButtonFormField<String>(
                  key: ValueKey(
                    'default-tax-rate-$defaultTaxRateId-$_savingDefaultTaxRate',
                  ),
                  initialValue: defaultTaxRateId,
                  decoration: const InputDecoration(
                    labelText: 'Default tax rate for new products',
                    helperText:
                        'Existing products and closed sales are not changed.',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final rate in [TaxRate.zero, ...taxRates])
                      DropdownMenuItem(
                        value: rate.id,
                        child: Text('${rate.name} (${rate.percentageLabel})'),
                      ),
                  ],
                  onChanged:
                      scope == null ||
                          _savingDefaultTaxRate ||
                          !defaultTaxRateIdValue.hasValue
                      ? null
                      : (value) =>
                            _setDefaultTaxRate(scope, value ?? TaxRate.zero.id),
                ),
              ),
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
        Row(
          children: [
            Expanded(
              child: Text(
                'Products · ${filteredProducts.length} found',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (scope != null && filteredProducts.isNotEmpty)
              TextButton.icon(
                onPressed: _savingBulkProducts
                    ? null
                    : () => setState(() {
                        if (allVisibleSelected) {
                          _selectedProductIds.removeAll(visibleProductIds);
                        } else {
                          _selectedProductIds.addAll(visibleProductIds);
                        }
                      }),
                icon: Icon(
                  allVisibleSelected
                      ? Icons.deselect_rounded
                      : Icons.select_all_rounded,
                ),
                label: Text(allVisibleSelected ? 'Deselect all' : 'Select all'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (!isSearching) ...[
          Wrap(
            spacing: 12,
            runSpacing: 10,
            children: [
              SizedBox(
                width: 280,
                child: DropdownButtonFormField<String>(
                  initialValue: _productCategoryFilter,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Filter products by category',
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: '',
                      child: Text('All categories'),
                    ),
                    for (final section in sections.where(
                      (item) => item.parentSectionId == null,
                    ))
                      DropdownMenuItem(
                        value: section.id,
                        child: Text(
                          '${section.name} (${products.where((product) {
                            final childIds = sections.where((item) => item.parentSectionId == section.id).map((item) => item.id).toSet();
                            return product.sectionIds.contains(section.id) || product.sectionIds.any(childIds.contains);
                          }).length})',
                        ),
                      ),
                  ],
                  onChanged: (value) => setState(() {
                    _productCategoryFilter = value == null || value.isEmpty
                        ? null
                        : value;
                    _productSubcategoryFilter = null;
                  }),
                ),
              ),
              if (filterSubcategories.isNotEmpty)
                SizedBox(
                  width: 280,
                  child: DropdownButtonFormField<String>(
                    initialValue: _productSubcategoryFilter,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Filter by subcategory',
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('All subcategories'),
                      ),
                      for (final section in filterSubcategories)
                        DropdownMenuItem(
                          value: section.id,
                          child: Text(
                            '${section.name} (${products.where((product) => product.sectionIds.contains(section.id)).length})',
                          ),
                        ),
                    ],
                    onChanged: (value) => setState(() {
                      _productSubcategoryFilter = value == null || value.isEmpty
                          ? null
                          : value;
                    }),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
        ] else
          const Text('The main search is overriding category filters.'),
        if (_selectedProductIds.isNotEmpty) ...[
          const SizedBox(height: 10),
          Card(
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Wrap(
                spacing: 10,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('${_selectedProductIds.length} products selected'),
                  FilledButton.tonalIcon(
                    onPressed: scope == null || _savingBulkProducts
                        ? null
                        : () => _showBulkProductEditor(
                            scope: scope,
                            sections: sections,
                            taxRates: [TaxRate.zero, ...taxRates],
                            modifierGroups: modifierGroups,
                            variantSets: variantSets,
                            courses: courses,
                          ),
                    icon: const Icon(Icons.edit_note_rounded),
                    label: const Text('Bulk change'),
                  ),
                  TextButton(
                    onPressed: _savingBulkProducts
                        ? null
                        : () => setState(_selectedProductIds.clear),
                    child: const Text('Clear'),
                  ),
                ],
              ),
            ),
          ),
        ],
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
                    selected: _selectedProductIds.contains(product.id),
                    onSelected: scope == null
                        ? null
                        : (selected) => setState(() {
                            selected
                                ? _selectedProductIds.add(product.id)
                                : _selectedProductIds.remove(product.id);
                          }),
                    onEdit: scope == null
                        ? null
                        : () => _showProductDialog(
                            context: context,
                            ref: ref,
                            scope: scope,
                            sections: sections,
                            taxRates: [TaxRate.zero, ...taxRates],
                            modifierGroups: modifierGroups,
                            variantSets: variantSets,
                            allProducts: products,
                            currencyCode: widget.currencyCode,
                            defaultTaxRateId: defaultTaxRateId,
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
                    onArchive: scope == null
                        ? null
                        : () => _setProductArchived(
                            context: context,
                            ref: ref,
                            scope: scope,
                            product: product,
                            archived: true,
                          ),
                  ),
              ],
            ),
          ),
        if (archivedProducts.isNotEmpty) ...[
          const SizedBox(height: 12),
          Card(
            child: ExpansionTile(
              leading: const Icon(Icons.inventory_2_outlined),
              title: Text(
                '${archivedProducts.length} archived product${archivedProducts.length == 1 ? '' : 's'}',
              ),
              subtitle: const Text(
                'Archived products are hidden from the POS but retained for historic records.',
              ),
              children: [
                for (final product in archivedProducts)
                  ListTile(
                    leading: const Icon(Icons.archive_outlined),
                    title: Text(product.name),
                    subtitle: const Text('Not available for sale'),
                    trailing: TextButton.icon(
                      onPressed: scope == null
                          ? null
                          : () => _setProductArchived(
                              context: context,
                              ref: ref,
                              scope: scope,
                              product: product,
                              archived: false,
                            ),
                      icon: const Icon(Icons.unarchive_outlined),
                      label: const Text('Restore'),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _showBulkProductEditor({
    required VenueScope scope,
    required List<MenuSection> sections,
    required List<TaxRate> taxRates,
    required List<MenuModifierGroup> modifierGroups,
    required List<MenuVariantSet> variantSets,
    required List<MenuCourse> courses,
  }) async {
    var replaceSections = false;
    var replaceOptions = false;
    var changeProductionArea = false;
    var changeMargin = false;
    var replaceVariants = false;
    String? selectedVariantSetId;
    var changeTaxRate = false;
    String? selectedTaxRateId = taxRates.firstOrNull?.id;
    var changeDefaultCourse = false;
    var selectedDefaultCourseChoice = 'standard';
    var orderFlowChoice = 'unchanged';
    var collectionChoice = 'unchanged';
    var deliveryChoice = 'unchanged';
    var removeCollectionPrice = false;
    var removeDeliveryPrice = false;
    var productionArea = ProductionArea.kitchen;
    final selectedSections = <String>{};
    final selectedGroups = <String>{};
    final margin = TextEditingController();
    final changes = await _showMenuDialog<_BulkProductChanges>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Change ${_selectedProductIds.length} products'),
          content: SizedBox(
            width: 620,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CheckboxListTile(
                    value: replaceSections,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Replace menu sections'),
                    subtitle: const Text(
                      'Every selected product will use exactly these categories.',
                    ),
                    onChanged: (value) =>
                        setDialogState(() => replaceSections = value ?? false),
                  ),
                  if (replaceSections)
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final section in sections)
                          FilterChip(
                            label: Text(section.name),
                            selected: selectedSections.contains(section.id),
                            onSelected: (selected) => setDialogState(() {
                              selected
                                  ? selectedSections.add(section.id)
                                  : selectedSections.remove(section.id);
                            }),
                          ),
                      ],
                    ),
                  const Divider(height: 28),
                  DropdownButtonFormField<String>(
                    initialValue: collectionChoice,
                    decoration: const InputDecoration(
                      labelText: 'Collection availability',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'unchanged',
                        child: Text('Leave unchanged'),
                      ),
                      DropdownMenuItem(value: 'yes', child: Text('Available')),
                      DropdownMenuItem(value: 'no', child: Text('Unavailable')),
                    ],
                    onChanged: (value) => setDialogState(
                      () => collectionChoice = value ?? 'unchanged',
                    ),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: removeCollectionPrice,
                    title: const Text('Remove collection price overrides'),
                    subtitle: const Text(
                      'Selected products will inherit their normal price.',
                    ),
                    onChanged: (value) => setDialogState(
                      () => removeCollectionPrice = value ?? false,
                    ),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: deliveryChoice,
                    decoration: const InputDecoration(
                      labelText: 'Delivery availability',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'unchanged',
                        child: Text('Leave unchanged'),
                      ),
                      DropdownMenuItem(value: 'yes', child: Text('Available')),
                      DropdownMenuItem(value: 'no', child: Text('Unavailable')),
                    ],
                    onChanged: (value) => setDialogState(
                      () => deliveryChoice = value ?? 'unchanged',
                    ),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: removeDeliveryPrice,
                    title: const Text('Remove delivery price overrides'),
                    subtitle: const Text(
                      'Selected products will inherit their normal price.',
                    ),
                    onChanged: (value) => setDialogState(
                      () => removeDeliveryPrice = value ?? false,
                    ),
                  ),
                  const Divider(height: 28),
                  CheckboxListTile(
                    value: changeTaxRate,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Change tax rate'),
                    subtitle: const Text(
                      'Applies the selected tax snapshot to every selected product.',
                    ),
                    onChanged: taxRates.isEmpty
                        ? null
                        : (value) => setDialogState(
                            () => changeTaxRate = value ?? false,
                          ),
                  ),
                  if (changeTaxRate)
                    DropdownButtonFormField<String>(
                      initialValue: selectedTaxRateId,
                      decoration: const InputDecoration(labelText: 'Tax rate'),
                      items: [
                        for (final rate in taxRates)
                          DropdownMenuItem(
                            value: rate.id,
                            child: Text(
                              '${rate.name} (${rate.percentageLabel})',
                            ),
                          ),
                      ],
                      onChanged: (value) =>
                          setDialogState(() => selectedTaxRateId = value),
                    ),
                  const Divider(height: 28),
                  CheckboxListTile(
                    value: replaceVariants,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Apply reusable variant set'),
                    subtitle: const Text(
                      'Copies the selected variants and stock rules to every selected product.',
                    ),
                    onChanged: variantSets.isEmpty
                        ? null
                        : (value) => setDialogState(
                            () => replaceVariants = value ?? false,
                          ),
                  ),
                  if (replaceVariants)
                    DropdownButtonFormField<String>(
                      initialValue: selectedVariantSetId,
                      decoration: const InputDecoration(
                        labelText: 'Reusable variant set',
                      ),
                      items: [
                        for (final set in variantSets)
                          DropdownMenuItem(
                            value: set.id,
                            child: Text('${set.name} (${set.variants.length})'),
                          ),
                      ],
                      onChanged: (value) =>
                          setDialogState(() => selectedVariantSetId = value),
                    ),
                  const Divider(height: 28),
                  CheckboxListTile(
                    value: changeDefaultCourse,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Change default course'),
                    subtitle: const Text(
                      'Sets the course used when these products are added to an order.',
                    ),
                    onChanged: (value) => setDialogState(
                      () => changeDefaultCourse = value ?? false,
                    ),
                  ),
                  if (changeDefaultCourse)
                    DropdownButtonFormField<String>(
                      initialValue: selectedDefaultCourseChoice,
                      decoration: const InputDecoration(
                        labelText: 'Default course',
                      ),
                      items: [
                        const DropdownMenuItem<String>(
                          value: 'standard',
                          child: Text('Standard (release immediately)'),
                        ),
                        for (final course in courses)
                          DropdownMenuItem<String>(
                            value: course.id,
                            child: Text(course.name),
                          ),
                      ],
                      onChanged: (value) => setDialogState(
                        () => selectedDefaultCourseChoice = value ?? 'standard',
                      ),
                    ),
                  const Divider(height: 28),
                  CheckboxListTile(
                    value: changeProductionArea,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Change printer/production area'),
                    onChanged: (value) => setDialogState(
                      () => changeProductionArea = value ?? false,
                    ),
                  ),
                  if (changeProductionArea)
                    DropdownButtonFormField<ProductionArea>(
                      initialValue: productionArea,
                      decoration: const InputDecoration(
                        labelText: 'Production area',
                      ),
                      items: [
                        for (final area in ProductionArea.values)
                          DropdownMenuItem(
                            value: area,
                            child: Text(area.label),
                          ),
                      ],
                      onChanged: (value) => setDialogState(
                        () => productionArea = value ?? productionArea,
                      ),
                    ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: orderFlowChoice,
                    decoration: const InputDecoration(
                      labelText: 'Order flow board',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'unchanged',
                        child: Text('Leave unchanged'),
                      ),
                      DropdownMenuItem(
                        value: 'show',
                        child: Text('Show selected products'),
                      ),
                      DropdownMenuItem(
                        value: 'hide',
                        child: Text('Exclude selected products'),
                      ),
                    ],
                    onChanged: (value) => setDialogState(
                      () => orderFlowChoice = value ?? 'unchanged',
                    ),
                  ),
                  const Divider(height: 28),
                  CheckboxListTile(
                    value: replaceOptions,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Replace product option groups'),
                    onChanged: (value) =>
                        setDialogState(() => replaceOptions = value ?? false),
                  ),
                  if (replaceOptions)
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final group in modifierGroups)
                          FilterChip(
                            label: Text(group.name),
                            selected: selectedGroups.contains(group.id),
                            onSelected: (selected) => setDialogState(() {
                              selected
                                  ? selectedGroups.add(group.id)
                                  : selectedGroups.remove(group.id);
                            }),
                          ),
                      ],
                    ),
                  const Divider(height: 28),
                  CheckboxListTile(
                    value: changeMargin,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Change target margin'),
                    onChanged: (value) =>
                        setDialogState(() => changeMargin = value ?? false),
                  ),
                  if (changeMargin)
                    TextField(
                      controller: margin,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Target margin',
                        suffixText: '%',
                      ),
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
              onPressed: () {
                final marginPercent = changeMargin
                    ? double.tryParse(margin.text.trim().replaceAll(',', '.'))
                    : null;
                if (replaceSections && selectedSections.isEmpty) {
                  showAppNotification(
                    context,
                    ref: ref,
                    title: 'Choose a menu section',
                    message: 'Products must remain in at least one section.',
                    level: AppNotificationLevel.warning,
                  );
                  return;
                }
                if (changeMargin &&
                    (marginPercent == null ||
                        marginPercent < 0 ||
                        marginPercent > 100)) {
                  showAppNotification(
                    context,
                    ref: ref,
                    title: 'Enter a valid margin',
                    message: 'Target margin must be between 0 and 100%.',
                    level: AppNotificationLevel.warning,
                  );
                  return;
                }
                if (!replaceSections &&
                    !replaceOptions &&
                    !replaceVariants &&
                    !changeTaxRate &&
                    !changeDefaultCourse &&
                    !changeProductionArea &&
                    !changeMargin &&
                    collectionChoice == 'unchanged' &&
                    deliveryChoice == 'unchanged' &&
                    !removeCollectionPrice &&
                    !removeDeliveryPrice &&
                    orderFlowChoice == 'unchanged') {
                  showAppNotification(
                    context,
                    ref: ref,
                    title: 'Choose something to change',
                    message: 'No product fields have been selected.',
                    level: AppNotificationLevel.warning,
                  );
                  return;
                }
                if (replaceVariants && selectedVariantSetId == null) {
                  showAppNotification(
                    context,
                    ref: ref,
                    title: 'Choose a variant set',
                    message: 'Select the reusable variants to apply.',
                    level: AppNotificationLevel.warning,
                  );
                  return;
                }
                if (changeTaxRate && selectedTaxRateId == null) {
                  showAppNotification(
                    context,
                    ref: ref,
                    title: 'Choose a tax rate',
                    message: 'Select the tax rate to apply.',
                    level: AppNotificationLevel.warning,
                  );
                  return;
                }
                final selectedTaxRate = changeTaxRate
                    ? taxRates.firstWhere(
                        (rate) => rate.id == selectedTaxRateId,
                      )
                    : null;
                Navigator.pop(
                  dialogContext,
                  _BulkProductChanges(
                    sectionIds: replaceSections
                        ? selectedSections.toList(growable: false)
                        : null,
                    productionArea: changeProductionArea
                        ? productionArea
                        : null,
                    showOnOrderFlow: orderFlowChoice == 'unchanged'
                        ? null
                        : orderFlowChoice == 'show',
                    modifierGroupIds: replaceOptions
                        ? selectedGroups.toList(growable: false)
                        : null,
                    targetMarginBasisPoints: marginPercent == null
                        ? null
                        : (marginPercent * 100).round(),
                    variantSetId: replaceVariants ? selectedVariantSetId : null,
                    changeTaxRate: changeTaxRate,
                    taxRateId: selectedTaxRate?.id == TaxRate.zero.id
                        ? null
                        : selectedTaxRate?.id,
                    changeDefaultCourse: changeDefaultCourse,
                    defaultCourseId: selectedDefaultCourseChoice == 'standard'
                        ? null
                        : selectedDefaultCourseChoice,
                    availableForCollection: collectionChoice == 'unchanged'
                        ? null
                        : collectionChoice == 'yes',
                    availableForDelivery: deliveryChoice == 'unchanged'
                        ? null
                        : deliveryChoice == 'yes',
                    removeCollectionPriceOverride: removeCollectionPrice,
                    removeDeliveryPriceOverride: removeDeliveryPrice,
                  ),
                );
              },
              child: const Text('Review and apply'),
            ),
          ],
        ),
      ),
    );
    margin.dispose();
    if (changes == null || !mounted) return;
    final confirmed = await _showMenuDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm bulk product change'),
        content: Text(
          'Apply the selected changes to ${_selectedProductIds.length} products? This will be recorded in the audit trail.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Go back'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Apply changes'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _savingBulkProducts = true);
    try {
      final count = _selectedProductIds.length;
      await ref
          .read(firestorePosRepositoryProvider)
          .bulkUpdateProducts(
            scope: scope,
            productIds: _selectedProductIds.toList(growable: false),
            sectionIds: changes.sectionIds,
            productionArea: changes.productionArea,
            showOnOrderFlow: changes.showOnOrderFlow,
            modifierGroupIds: changes.modifierGroupIds,
            targetMarginBasisPoints: changes.targetMarginBasisPoints,
            variantSetId: changes.variantSetId,
            changeTaxRate: changes.changeTaxRate,
            taxRateId: changes.taxRateId,
            changeDefaultCourse: changes.changeDefaultCourse,
            defaultCourseId: changes.defaultCourseId,
            availableForCollection: changes.availableForCollection,
            availableForDelivery: changes.availableForDelivery,
            removeCollectionPriceOverride:
                changes.removeCollectionPriceOverride,
            removeDeliveryPriceOverride: changes.removeDeliveryPriceOverride,
          );
      if (!mounted) return;
      setState(_selectedProductIds.clear);
      showAppNotification(
        context,
        ref: ref,
        title: 'Products updated',
        message: '$count products were changed securely.',
        level: AppNotificationLevel.success,
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Bulk update menu products', error, stackTrace);
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Bulk change failed',
        message: '$error',
        level: AppNotificationLevel.error,
      );
    } finally {
      if (mounted) setState(() => _savingBulkProducts = false);
    }
  }

  Future<void> _setDefaultTaxRate(
    VenueScope scope,
    String selectedTaxRateId,
  ) async {
    setState(() => _savingDefaultTaxRate = true);
    try {
      await ref
          .read(firestorePosRepositoryProvider)
          .setDefaultTaxRate(
            scope: scope,
            taxRateId: selectedTaxRateId == TaxRate.zero.id
                ? null
                : selectedTaxRateId,
          );
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Default tax rate updated',
        message: 'New products will start with the selected tax rate.',
        level: AppNotificationLevel.success,
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Set default tax rate', error, stackTrace);
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Could not update default tax rate',
        message: 'The venue default was not changed: $error',
        level: AppNotificationLevel.error,
      );
    } finally {
      if (mounted) setState(() => _savingDefaultTaxRate = false);
    }
  }
}
