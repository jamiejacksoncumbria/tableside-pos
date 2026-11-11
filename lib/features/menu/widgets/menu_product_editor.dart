part of '../menu_management_page.dart';

Future<void> _showProductDialog({
  required BuildContext context,
  required WidgetRef ref,
  required VenueScope scope,
  required List<MenuSection> sections,
  required List<TaxRate> taxRates,
  required List<MenuModifierGroup> modifierGroups,
  required List<MenuVariantSet> variantSets,
  required List<MenuProduct> allProducts,
  required String currencyCode,
  required String defaultTaxRateId,
  MenuProduct? existing,
}) async {
  var dialogSections = List<MenuSection>.of(sections);
  var dialogModifierGroups = List<MenuModifierGroup>.of(modifierGroups);
  final remembered = existing == null
      ? await _ProductFormDefaults.load(scope)
      : null;
  if (!context.mounted) return;
  final name = TextEditingController(text: existing?.name ?? '');
  final price = TextEditingController(
    text: existing == null ? '' : _priceText(existing.priceMinor),
  );
  final collectionPrice = TextEditingController(
    text: existing?.collectionPriceMinor == null
        ? ''
        : _priceText(existing!.collectionPriceMinor!),
  );
  final deliveryPrice = TextEditingController(
    text: existing?.deliveryPriceMinor == null
        ? ''
        : _priceText(existing!.deliveryPriceMinor!),
  );
  final stock = TextEditingController(
    text: existing == null
        ? (remembered?.trackStock == true ? '0' : '')
        : (existing.stockOnHand == null ? '' : '${existing.stockOnHand}'),
  );
  final stockPerSale = TextEditingController(
    text: '${existing?.stockPerSale ?? remembered?.stockPerSale ?? 1}',
  );
  final lowStockThreshold = TextEditingController(
    text:
        '${existing?.lowStockThreshold ?? remembered?.lowStockThreshold ?? 0}',
  );
  final storageLocation = TextEditingController(
    text: existing?.storageLocation ?? remembered?.storageLocation ?? '',
  );
  final initialMarginBasisPoints =
      existing?.targetMarginBasisPoints ??
      remembered?.targetMarginBasisPoints ??
      0;
  final targetMargin = TextEditingController(
    text: initialMarginBasisPoints == 0
        ? ''
        : (initialMarginBasisPoints / 100).toStringAsFixed(2),
  );
  final formKey = GlobalKey<FormState>();
  final availableSectionIds = sections.map((item) => item.id).toSet();
  final availableModifierGroupIds = modifierGroups
      .map((item) => item.id)
      .toSet();
  final selectedSections = <String>{
    ...?existing?.sectionIds,
    if (existing == null)
      ...?remembered?.sectionIds.where(availableSectionIds.contains),
  };
  final selectedModifierGroupIds = <String>{
    ...?existing?.modifierGroupIds,
    if (existing == null)
      ...?remembered?.modifierGroupIds.where(
        availableModifierGroupIds.contains,
      ),
  };
  var variants = <MenuProductVariant>[
    ...?existing?.variants,
    if (existing == null) ...?remembered?.variants,
  ];
  String? selectedVariantSetId;
  String? appliedVariantSetName;
  var stockComponents = <ProductStockComponent>[...?existing?.stockComponents];
  var productionArea =
      existing?.productionArea ??
      remembered?.productionArea ??
      ProductionArea.kitchen;
  var trackStock = existing?.trackStock ?? remembered?.trackStock ?? false;
  var stockUnit = existing?.stockUnit ?? remembered?.stockUnit ?? 'each';
  var showOnOrderFlow =
      existing?.showOnOrderFlow ?? remembered?.showOnOrderFlow ?? true;
  var availableForCollection = existing?.availableForCollection ?? true;
  var availableForDelivery = existing?.availableForDelivery ?? true;
  final courses = await ref.read(venueCoursesProvider.future);
  if (!context.mounted) return;
  var defaultCourseId = existing?.defaultCourseId;
  Uint8List? selectedImageBytes;
  String? selectedImageFileName;
  String? selectedImageContentType;
  var removeExistingImage = false;
  final availableTaxRateIds = taxRates.map((rate) => rate.id);
  var selectedTaxRateId = existing == null
      ? (availableTaxRateIds.contains(remembered?.taxRateId)
            ? remembered!.taxRateId
            : (availableTaxRateIds.contains(defaultTaxRateId)
                  ? defaultTaxRateId
                  : TaxRate.zero.id))
      : (availableTaxRateIds.contains(existing.taxRateId)
            ? existing.taxRateId!
            : TaxRate.zero.id);

  try {
    await _showMenuDialog<void>(
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
                    const SizedBox(height: 18),
                    Text(
                      'Product image',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    if (selectedImageBytes != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.memory(
                          selectedImageBytes!,
                          width: 120,
                          height: 120,
                          fit: BoxFit.cover,
                        ),
                      )
                    else if (!removeExistingImage && existing?.imageUrl != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.network(
                          existing!.imageUrl!,
                          width: 120,
                          height: 120,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const SizedBox(
                            width: 120,
                            height: 120,
                            child: Icon(Icons.broken_image_outlined),
                          ),
                        ),
                      )
                    else
                      const Text('No image selected.'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () async {
                            final file = await FilePicker.pickFile(
                              type: FileType.image,
                            );
                            if (file == null) return;
                            final bytes = await file.readAsBytes();
                            if (bytes.length > 2 * 1024 * 1024) {
                              if (!dialogContext.mounted) return;
                              showAppNotification(
                                dialogContext,
                                ref: ref,
                                title: 'Image is too large',
                                message: 'Choose an image no larger than 2 MB.',
                                level: AppNotificationLevel.warning,
                              );
                              return;
                            }
                            final extension = file.extension?.toLowerCase();
                            final contentType = switch (extension) {
                              'png' => 'image/png',
                              'jpg' || 'jpeg' => 'image/jpeg',
                              'webp' => 'image/webp',
                              'gif' => 'image/gif',
                              _ => null,
                            };
                            if (contentType == null) {
                              if (!dialogContext.mounted) return;
                              showAppNotification(
                                dialogContext,
                                ref: ref,
                                title: 'Unsupported image',
                                message:
                                    'Choose a PNG, JPEG, WebP, or GIF image.',
                                level: AppNotificationLevel.warning,
                              );
                              return;
                            }
                            setDialogState(() {
                              selectedImageBytes = bytes;
                              selectedImageFileName = file.name;
                              selectedImageContentType = contentType;
                              removeExistingImage = false;
                            });
                          },
                          icon: const Icon(Icons.add_photo_alternate_outlined),
                          label: Text(
                            existing?.imageUrl == null
                                ? 'Choose image'
                                : 'Replace image',
                          ),
                        ),
                        if (selectedImageBytes != null ||
                            (!removeExistingImage &&
                                existing?.imageUrl != null))
                          TextButton.icon(
                            onPressed: () => setDialogState(() {
                              selectedImageBytes = null;
                              selectedImageFileName = null;
                              selectedImageContentType = null;
                              removeExistingImage = existing?.imageUrl != null;
                            }),
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Remove image'),
                          ),
                      ],
                    ),
                    const Text(
                      'Optional. Used by customer-facing menus and QR ordering later.',
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
                    if (variantSets.isNotEmpty) ...[
                      DropdownButtonFormField<String>(
                        initialValue: selectedVariantSetId,
                        decoration: const InputDecoration(
                          labelText: 'Use a saved variant set',
                          helperText:
                              'Choose a set, then apply it to this product.',
                        ),
                        items: [
                          for (final set in variantSets)
                            DropdownMenuItem(
                              value: set.id,
                              child: Text(
                                '${set.name} (${set.variants.length})',
                              ),
                            ),
                        ],
                        onChanged: (value) => setDialogState(() {
                          selectedVariantSetId = value;
                          appliedVariantSetName = null;
                        }),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FilledButton.tonalIcon(
                          onPressed: selectedVariantSetId == null
                              ? null
                              : () {
                                  final selected = variantSets.firstWhere(
                                    (set) => set.id == selectedVariantSetId,
                                  );
                                  setDialogState(() {
                                    variants = List<MenuProductVariant>.of(
                                      selected.variants,
                                    );
                                    appliedVariantSetName = selected.name;
                                  });
                                },
                          icon: const Icon(Icons.content_copy_rounded),
                          label: const Text('Apply variant set'),
                        ),
                      ),
                      if (appliedVariantSetName != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            '$appliedVariantSetName applied. Save the product to keep this change.',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      const SizedBox(height: 8),
                    ],
                    OutlinedButton.icon(
                      onPressed: () async {
                        final next = await _showVariantsDialog(
                          context: dialogContext,
                          currencyCode: currencyCode,
                          initialVariants: variants,
                          stockProducts: allProducts
                              .where((item) => item.id != existing?.id)
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
                    if (variants.isNotEmpty)
                      TextButton.icon(
                        onPressed: () async {
                          final controller = TextEditingController();
                          final setName = await _showMenuDialog<String>(
                            context: dialogContext,
                            builder: (nameContext) => AlertDialog(
                              title: const Text('Save reusable variant set'),
                              content: TextField(
                                controller: controller,
                                autofocus: true,
                                textCapitalization: TextCapitalization.words,
                                decoration: const InputDecoration(
                                  labelText: 'Set name',
                                  hintText: 'For example: Glass sizes',
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(nameContext),
                                  child: const Text('Cancel'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(
                                    nameContext,
                                    controller.text.trim(),
                                  ),
                                  child: const Text('Save set'),
                                ),
                              ],
                            ),
                          );
                          controller.dispose();
                          if (setName == null || setName.trim().isEmpty) return;
                          try {
                            await ref
                                .read(firestorePosRepositoryProvider)
                                .saveVariantSet(
                                  scope: scope,
                                  name: setName,
                                  variants: variants,
                                );
                            if (!dialogContext.mounted) return;
                            showAppNotification(
                              dialogContext,
                              ref: ref,
                              title: 'Variant set saved',
                              message:
                                  '$setName can now be reused on other products.',
                              level: AppNotificationLevel.success,
                            );
                          } on Object catch (error, stackTrace) {
                            AppLogger.error(
                              'Save reusable variant set',
                              error,
                              stackTrace,
                            );
                            if (!dialogContext.mounted) return;
                            showAppNotification(
                              dialogContext,
                              ref: ref,
                              title: 'Variant set was not saved',
                              message: '$error',
                              level: AppNotificationLevel.error,
                            );
                          }
                        },
                        icon: const Icon(Icons.bookmark_add_outlined),
                        label: const Text('Save current variants as a set'),
                      ),
                    const SizedBox(height: 18),
                    Text(
                      'Collection and delivery',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Available for collection'),
                      value: availableForCollection,
                      onChanged: (value) =>
                          setDialogState(() => availableForCollection = value),
                    ),
                    if (availableForCollection)
                      TextFormField(
                        controller: collectionPrice,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText:
                              'Collection price override ($currencyCode)',
                          helperText: 'Leave blank to use the normal price.',
                        ),
                        validator: (value) =>
                            value?.trim().isEmpty == true ||
                                _minorFromPriceText(value) != null
                            ? null
                            : 'Enter a valid price or leave blank.',
                      ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Available for delivery'),
                      value: availableForDelivery,
                      onChanged: (value) =>
                          setDialogState(() => availableForDelivery = value),
                    ),
                    if (availableForDelivery)
                      TextFormField(
                        controller: deliveryPrice,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Delivery price override ($currencyCode)',
                          helperText: 'Leave blank to use the normal price.',
                        ),
                        validator: (value) =>
                            value?.trim().isEmpty == true ||
                                _minorFromPriceText(value) != null
                            ? null
                            : 'Enter a valid price or leave blank.',
                      ),
                    if (courses.isNotEmpty)
                      DropdownButtonFormField<String?>(
                        initialValue: defaultCourseId,
                        decoration: const InputDecoration(
                          labelText: 'Default course',
                          helperText: 'Standard releases immediately.',
                        ),
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('Standard'),
                          ),
                          for (final course in courses.where(
                            (item) => item.active,
                          ))
                            DropdownMenuItem<String?>(
                              value: course.id,
                              child: Text(course.name),
                            ),
                        ],
                        onChanged: (value) =>
                            setDialogState(() => defaultCourseId = value),
                      ),
                    const SizedBox(height: 18),
                    Text(
                      'Product options',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 4),
                    if (dialogModifierGroups.isEmpty)
                      const Text(
                        'Create reusable cooking, spice or drink options first.',
                      )
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final group in dialogModifierGroups)
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
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          await Navigator.of(dialogContext).push<void>(
                            MaterialPageRoute(
                              builder: (_) => ModifierGroupsPage(
                                currencyCode: currencyCode,
                              ),
                            ),
                          );
                          ref.invalidate(menuModifierGroupsProvider);
                          final refreshed = await ref.read(
                            menuModifierGroupsProvider.future,
                          );
                          if (dialogContext.mounted) {
                            setDialogState(
                              () => dialogModifierGroups = refreshed,
                            );
                          }
                        },
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Add or edit product options'),
                      ),
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
                        for (final section in dialogSections)
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
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          await _showSectionDialog(
                            context: dialogContext,
                            ref: ref,
                            scope: scope,
                            sections: dialogSections,
                            nextSortOrder: dialogSections.length,
                          );
                          ref.invalidate(menuSectionsProvider);
                          final refreshed = await ref.read(
                            menuSectionsProvider.future,
                          );
                          if (dialogContext.mounted) {
                            setDialogState(() => dialogSections = refreshed);
                          }
                        },
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Add menu section'),
                      ),
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
                      imageBytes: selectedImageBytes,
                      imageFileName: selectedImageFileName,
                      imageContentType: selectedImageContentType,
                      availableForCollection: availableForCollection,
                      availableForDelivery: availableForDelivery,
                      collectionPriceMinor: collectionPrice.text.trim().isEmpty
                          ? null
                          : _minorFromPriceText(collectionPrice.text),
                      deliveryPriceMinor: deliveryPrice.text.trim().isEmpty
                          ? null
                          : _minorFromPriceText(deliveryPrice.text),
                      defaultCourseId: defaultCourseId,
                    );
                    await _ProductFormDefaults(
                      sectionIds: selectedSections.toList(growable: false),
                      modifierGroupIds: selectedModifierGroupIds.toList(
                        growable: false,
                      ),
                      productionArea: productionArea,
                      showOnOrderFlow: showOnOrderFlow,
                      trackStock: trackStock,
                      stockUnit: stockUnit,
                      stockPerSale: unitStock,
                      lowStockThreshold: lowStock,
                      storageLocation: storageLocation.text.trim(),
                      targetMarginBasisPoints: targetMarginBasisPoints,
                      taxRateId: selectedTaxRate.id,
                      variants: variants
                          .map(
                            (variant) => MenuProductVariant(
                              id: variant.id,
                              name: variant.name,
                              priceDeltaMinor: variant.priceDeltaMinor,
                              isAvailable: variant.isAvailable,
                            ),
                          )
                          .toList(growable: false),
                    ).save(scope);
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
                      imageBytes: selectedImageBytes,
                      imageFileName: selectedImageFileName,
                      imageContentType: selectedImageContentType,
                      removeImage: removeExistingImage,
                      availableForCollection: availableForCollection,
                      availableForDelivery: availableForDelivery,
                      collectionPriceMinor: collectionPrice.text.trim().isEmpty
                          ? null
                          : _minorFromPriceText(collectionPrice.text),
                      deliveryPriceMinor: deliveryPrice.text.trim().isEmpty
                          ? null
                          : _minorFromPriceText(deliveryPrice.text),
                      defaultCourseId: defaultCourseId,
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
    collectionPrice.dispose();
    deliveryPrice.dispose();
    stock.dispose();
    stockPerSale.dispose();
    lowStockThreshold.dispose();
    storageLocation.dispose();
    targetMargin.dispose();
  }
}

class _ProductFormDefaults {
  const _ProductFormDefaults({
    required this.sectionIds,
    required this.modifierGroupIds,
    required this.productionArea,
    required this.showOnOrderFlow,
    required this.trackStock,
    required this.stockUnit,
    required this.stockPerSale,
    required this.lowStockThreshold,
    required this.storageLocation,
    required this.targetMarginBasisPoints,
    required this.taxRateId,
    required this.variants,
  });

  final List<String> sectionIds;
  final List<String> modifierGroupIds;
  final ProductionArea productionArea;
  final bool showOnOrderFlow;
  final bool trackStock;
  final String stockUnit;
  final double stockPerSale;
  final double lowStockThreshold;
  final String storageLocation;
  final int targetMarginBasisPoints;
  final String taxRateId;
  final List<MenuProductVariant> variants;

  static String _key(VenueScope scope) =>
      'tableside.productFormDefaults.${scope.tenantId}.${scope.venueId}';

  static Future<_ProductFormDefaults?> load(VenueScope scope) async {
    try {
      final raw = await SharedPreferencesAsync().getString(_key(scope));
      if (raw == null || raw.isEmpty) return null;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final areaName = json['productionArea'] as String?;
      final productionArea = ProductionArea.values.firstWhere(
        (area) => area.name == areaName,
        orElse: () => ProductionArea.kitchen,
      );
      return _ProductFormDefaults(
        sectionIds: _stringList(json['sectionIds']),
        modifierGroupIds: _stringList(json['modifierGroupIds']),
        productionArea: productionArea,
        showOnOrderFlow: json['showOnOrderFlow'] as bool? ?? true,
        trackStock: json['trackStock'] as bool? ?? false,
        stockUnit: json['stockUnit'] as String? ?? 'each',
        stockPerSale: (json['stockPerSale'] as num?)?.toDouble() ?? 1,
        lowStockThreshold: (json['lowStockThreshold'] as num?)?.toDouble() ?? 0,
        storageLocation: json['storageLocation'] as String? ?? '',
        targetMarginBasisPoints:
            (json['targetMarginBasisPoints'] as num?)?.toInt() ?? 0,
        taxRateId: json['taxRateId'] as String? ?? TaxRate.zero.id,
        variants: (json['variants'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(
              (item) => MenuProductVariant(
                id: item['id'] as String? ?? '',
                name: item['name'] as String? ?? '',
                priceDeltaMinor:
                    (item['priceDeltaMinor'] as num?)?.toInt() ?? 0,
                isAvailable: item['isAvailable'] as bool? ?? true,
              ),
            )
            .where(
              (variant) => variant.id.isNotEmpty && variant.name.isNotEmpty,
            )
            .toList(growable: false),
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Load remembered product choices', error, stackTrace);
      return null;
    }
  }

  Future<void> save(VenueScope scope) async {
    try {
      await SharedPreferencesAsync().setString(
        _key(scope),
        jsonEncode({
          'sectionIds': sectionIds,
          'modifierGroupIds': modifierGroupIds,
          'productionArea': productionArea.name,
          'showOnOrderFlow': showOnOrderFlow,
          'trackStock': trackStock,
          'stockUnit': stockUnit,
          'stockPerSale': stockPerSale,
          'lowStockThreshold': lowStockThreshold,
          'storageLocation': storageLocation,
          'targetMarginBasisPoints': targetMarginBasisPoints,
          'taxRateId': taxRateId,
          'variants': [
            for (final variant in variants)
              {
                'id': variant.id,
                'name': variant.name,
                'priceDeltaMinor': variant.priceDeltaMinor,
                'isAvailable': variant.isAvailable,
              },
          ],
        }),
      );
      AppLogger.info('Remembered product choices for venue ${scope.venueId}.');
    } on Object catch (error, stackTrace) {
      // The product already exists on the server. A local cache failure must
      // not turn that successful save into a misleading error for the user.
      AppLogger.error('Remember product choices', error, stackTrace);
    }
  }

  static List<String> _stringList(Object? value) =>
      (value as List<dynamic>? ?? const []).whereType<String>().toList(
        growable: false,
      );
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
    return await _showMenuDialog<List<ProductStockComponent>>(
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
  String? validationMessage;

  try {
    return await _showMenuDialog<List<MenuProductVariant>>(
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
                  if (drafts.isEmpty) ...[
                    const Text(
                      'No variants configured. The product will be sold at its base price.',
                    ),
                    const SizedBox(height: 8),
                  ],
                  for (var index = 0; index < drafts.length; index++) ...[
                    _VariantDraftRow(
                      draft: drafts[index],
                      onRemove: () => setDialogState(() {
                        final removed = drafts.removeAt(index);
                        removed.dispose();
                        validationMessage = null;
                      }),
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
    required this.onRemove,
    required this.onChanged,
    required this.onEditRecipe,
  });

  final _VariantDraft draft;
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
                onPressed: onRemove,
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
