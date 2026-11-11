part of '../pos_page.dart';

class _MenuPanel extends ConsumerStatefulWidget {
  const _MenuPanel({required this.currencyCode});

  final String currencyCode;

  @override
  ConsumerState<_MenuPanel> createState() => _MenuPanelState();
}

class _MenuPanelState extends ConsumerState<_MenuPanel> {
  final ScrollController _productScrollController = ScrollController();
  final ScrollController _sectionScrollController = ScrollController();
  final ScrollController _subsectionScrollController = ScrollController();
  bool _menuControlsCollapsed = false;
  bool _compactLayout = false;
  bool _tileCategoryOpen = false;
  String _lastSearchQuery = '';

  String get currencyCode => widget.currencyCode;

  @override
  void initState() {
    super.initState();
    _productScrollController.addListener(_productScrollChanged);
  }

  @override
  void dispose() {
    _productScrollController.dispose();
    _sectionScrollController.dispose();
    _subsectionScrollController.dispose();
    super.dispose();
  }

  void _productScrollChanged() {
    if (!_compactLayout || !_productScrollController.hasClients) return;
    final position = _productScrollController.position;
    final shouldCollapse =
        position.pixels > 28 &&
        position.userScrollDirection == ScrollDirection.reverse;
    final shouldExpand =
        position.pixels <= 8 ||
        position.userScrollDirection == ScrollDirection.forward;
    if (shouldCollapse && !_menuControlsCollapsed) {
      setState(() => _menuControlsCollapsed = true);
    } else if (shouldExpand && _menuControlsCollapsed) {
      setState(() => _menuControlsCollapsed = false);
    }
  }

  Future<void> _changeCategoryView(VenueScope? scope, String preference) async {
    final previous = ref.read(posCategoryViewPreferenceProvider);
    _tileCategoryOpen = false;
    ref.read(posCategoryViewPreferenceProvider.notifier).apply(preference);
    if (scope == null) return;
    try {
      await ref
          .read(productionCommandRepositoryProvider)
          .updateOwnPosCategoryViewPreference(
            scope: scope,
            categoryView: preference,
          );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Save POS category view', error, stackTrace);
      ref.read(posCategoryViewPreferenceProvider.notifier).apply(previous);
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Category view was not saved',
        message: '$error',
        level: AppNotificationLevel.error,
      );
    }
  }

  Future<void> _changeProductSort(VenueScope? scope, String preference) async {
    final previous = ref.read(posProductSortPreferenceProvider);
    if (previous == preference) return;
    ref.read(posProductSortPreferenceProvider.notifier).apply(preference);
    if (scope == null) return;
    try {
      await ref
          .read(productionCommandRepositoryProvider)
          .updateOwnPosProductSortPreference(
            scope: scope,
            productSort: preference,
          );
    } on Object catch (error, stackTrace) {
      ref.read(posProductSortPreferenceProvider.notifier).apply(previous);
      AppLogger.error('Save POS product sort preference', error, stackTrace);
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Product sorting was not saved',
        message: '$error',
        level: AppNotificationLevel.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    _compactLayout = MediaQuery.sizeOf(context).width < 700;
    final selectedSection = ref.watch(activeSectionProvider);
    final selectedSubsection = ref.watch(activeSubsectionProvider);
    final activeOrder = ref.watch(activeOrderProvider);
    final selectedTableId = ref.watch(selectedTableProvider);
    final menuTables =
        ref.watch(diningTablesProvider).value ?? const <DiningTable>[];
    final activeOrderLocation = posMenuOrderLocationLabel(
      activeOrder,
      menuTables,
      selectedTableId: selectedTableId,
    );
    final categoryView = ref.watch(posCategoryViewPreferenceProvider);
    final useCategoryTiles = categoryView == 'tiles';
    final productSort = ref.watch(posProductSortPreferenceProvider);
    final scope = ref.watch(activeVenueScopeProvider);
    final sectionsState = ref.watch(menuSectionsProvider);
    final catalogState = ref.watch(menuProductsProvider);
    final modifierGroupsState = ref.watch(menuModifierGroupsProvider);
    final List<MenuSection> sections = sectionsState.when(
      data: (items) => items,
      loading: () => scope == null ? demoSections : const <MenuSection>[],
      error: (error, stackTrace) {
        AppLogger.error('Display menu sections', error, stackTrace);
        return scope == null ? demoSections : const <MenuSection>[];
      },
    );
    final List<MenuProduct> catalog = catalogState.when(
      data: (items) => items,
      loading: () => scope == null ? demoProducts : const <MenuProduct>[],
      error: (error, stackTrace) {
        AppLogger.error('Display menu products', error, stackTrace);
        return scope == null ? demoProducts : const <MenuProduct>[];
      },
    );
    final modifierGroups = modifierGroupsState.when(
      data: (items) => items,
      loading: () => const <MenuModifierGroup>[],
      error: (error, stackTrace) {
        AppLogger.error('Display menu modifier groups', error, stackTrace);
        return const <MenuModifierGroup>[];
      },
    );
    final loading = sectionsState.isLoading || catalogState.isLoading;
    final menuError = sectionsState.when<Object?>(
      data: (_) => catalogState.when<Object?>(
        data: (_) => null,
        loading: () => null,
        error: (error, _) => error,
      ),
      loading: () => null,
      error: (error, _) => error,
    );
    final topLevelSections = sections
        .where((section) => section.parentSectionId == null)
        .toList(growable: false);
    final showPopular = selectedSection == popularMenuSectionId;
    final effectiveSection =
        topLevelSections.any((section) => section.id == selectedSection)
        ? selectedSection
        : null;
    final subsections = effectiveSection == null
        ? const <MenuSection>[]
        : sections
              .where((section) => section.parentSectionId == effectiveSection)
              .toList(growable: false);
    final effectiveSubsection =
        subsections.any((section) => section.id == selectedSubsection)
        ? selectedSubsection
        : null;
    final includedSectionIds = effectiveSection == null
        ? const <String>{}
        : <String>{
            effectiveSection,
            ...subsections.map((section) => section.id),
          };
    final rawSearchQuery = ref.watch(posMenuSearchQueryProvider);
    final searchQuery = rawSearchQuery.trim().toLowerCase();
    if (_lastSearchQuery != rawSearchQuery) {
      _lastSearchQuery = rawSearchQuery;
      _menuControlsCollapsed = false;
      if (searchQuery.isEmpty) _tileCategoryOpen = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _productScrollController.hasClients) {
          _productScrollController.jumpTo(0);
        }
      });
    }
    final showTileCategoryBrowser =
        useCategoryTiles && searchQuery.isEmpty && !_tileCategoryOpen;
    // Compact tile navigation is deliberately staged. Once a category is
    // opened, the search row gives its space to the products while the Back
    // control remains pinned at the top. This prevents the product grid from
    // appearing to slide behind a search field that belongs to the preceding
    // category-browser stage.
    final compactTileProductStage =
        _compactLayout &&
        useCategoryTiles &&
        _tileCategoryOpen &&
        searchQuery.isEmpty;
    final products = catalog.where((product) {
      if (searchQuery.isNotEmpty) {
        return productMatchesMenuSearch(product, sections, searchQuery);
      }
      if (effectiveSubsection != null) {
        return product.sectionIds.contains(effectiveSubsection);
      }
      if (showPopular || effectiveSection == null) return true;
      return product.sectionIds.any(includedSectionIds.contains);
    }).toList();
    if (showPopular && searchQuery.isEmpty) {
      products.sort((first, second) {
        final popularity = second.soldQuantity.compareTo(first.soldQuantity);
        return popularity != 0
            ? popularity
            : first.name.toLowerCase().compareTo(second.name.toLowerCase());
      });
    } else {
      products.sort((first, second) {
        final byName = first.name.toLowerCase().compareTo(
          second.name.toLowerCase(),
        );
        return switch (productSort) {
          'priceAsc' =>
            first.priceMinor.compareTo(second.priceMinor) == 0
                ? byName
                : first.priceMinor.compareTo(second.priceMinor),
          'priceDesc' =>
            second.priceMinor.compareTo(first.priceMinor) == 0
                ? byName
                : second.priceMinor.compareTo(first.priceMinor),
          _ => byName,
        };
      });
    }
    final section = effectiveSection == null
        ? null
        : topLevelSections.firstWhere((item) => item.id == effectiveSection);

    Future<bool> addSelectedProduct(
      MenuProduct product, {
      required bool forceConfiguration,
    }) async {
      try {
        if (!await _ensureOrderLocation(context, ref)) return false;
        if (!context.mounted) return false;
        final activeChannel = ref.read(activeOrderProvider).channel;
        final channelUnavailable =
            activeChannel != OrderChannel.dineIn &&
            !product.isAvailableFor(activeChannel);
        var channelAvailabilityOverride = false;
        if (channelUnavailable) {
          final confirmed = await showAppDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: Text('Not normally available for ${activeChannel.label}'),
              content: Text(
                '${product.name} is marked as unavailable for '
                '${activeChannel.label.toLowerCase()}. Add it anyway at staff discretion?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Add anyway'),
                ),
              ],
            ),
          );
          if (confirmed != true || !context.mounted) return false;
          channelAvailabilityOverride = true;
        }
        final requiresConfiguration =
            forceConfiguration || product.requiresConfiguration;
        final selection = requiresConfiguration
            ? await showProductConfigurationSheet(
                context: context,
                product: product,
                availableGroups: modifierGroups,
                availableProducts: catalog,
                currencyCode: currencyCode,
                onAdd: (selection) async {
                  try {
                    await ref
                        .read(activeOrderProvider.notifier)
                        .addProduct(
                          product,
                          selection: selection,
                          channelAvailabilityOverride:
                              channelAvailabilityOverride,
                        );
                  } on Object catch (error, stackTrace) {
                    AppLogger.error(
                      'Add configured item to shared draft order',
                      error,
                      stackTrace,
                    );
                    rethrow;
                  }
                },
              )
            : const ProductConfigurationSelection();
        if (selection == null) return false;
        if (!requiresConfiguration) {
          await ref
              .read(activeOrderProvider.notifier)
              .addProduct(
                product,
                selection: selection,
                channelAvailabilityOverride: channelAvailabilityOverride,
              );
        }
        if (!context.mounted) return true;
        showAppNotification(
          context,
          ref: ref,
          title: 'Added to order',
          message: product.name,
          level: AppNotificationLevel.success,
        );
        return true;
      } on Object catch (error, stackTrace) {
        AppLogger.error('Add item to shared draft order', error, stackTrace);
        if (!context.mounted) return false;
        showAppNotification(
          context,
          ref: ref,
          title: 'Item was not added',
          message: '$error',
          level: AppNotificationLevel.error,
        );
        return false;
      }
    }

    return PopScope<Object?>(
      canPop: !useCategoryTiles || (searchQuery.isEmpty && !_tileCategoryOpen),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (searchQuery.isNotEmpty) {
          ref.read(posMenuSearchQueryProvider.notifier).clear();
          return;
        }
        setState(() {
          if (effectiveSubsection != null) {
            ref.read(activeSubsectionProvider.notifier).select(null);
          } else {
            _tileCategoryOpen = false;
          }
        });
      },
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: LayoutBuilder(
            builder: (context, panelConstraints) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // This header used to be a loose Flexible next to the product
                // Expanded. Flex divided the height before measuring it, so a
                // short header could reserve half a medium tablet and leave a
                // large blank area below the product grid. A non-flexible,
                // height-capped scroller uses only what it needs and gives all
                // remaining height to the products.
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: panelConstraints.maxHeight < 230
                        ? (panelConstraints.maxHeight * .48)
                              .clamp(0.0, 300.0)
                              .toDouble()
                        : (panelConstraints.maxHeight * .48)
                              .clamp(110.0, 300.0)
                              .toDouble(),
                  ),
                  child: SingleChildScrollView(
                    primary: false,
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Compact Android/iOS POS mode deliberately
                          // hides the app shell, including its centred
                          // search field. Keep the same shared search at
                          // the top of the menu so immersive mode never
                          // removes product search entirely.
                          if (MediaQuery.sizeOf(context).width < 840 &&
                              !(_compactLayout && _menuControlsCollapsed)) ...[
                            const SizedBox(
                              height: 40,
                              child: PosQuickSearchField(),
                            ),
                            const SizedBox(height: 4),
                          ],
                          if (!compactTileProductStage &&
                              !(_compactLayout && _menuControlsCollapsed))
                            Row(
                              children: [
                                Text(
                                  activeOrderLocation,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.labelMedium
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(width: 8),
                                if (panelConstraints.maxWidth >= 700 &&
                                    !useCategoryTiles) ...[
                                  Expanded(
                                    child: _CompactMenuDropdown(
                                      tooltip: 'Category',
                                      icon: Icons.category_outlined,
                                      value: showPopular
                                          ? popularMenuSectionId
                                          : effectiveSection ?? '__all__',
                                      items: [
                                        const DropdownMenuItem(
                                          value: popularMenuSectionId,
                                          child: Text('Popular'),
                                        ),
                                        const DropdownMenuItem(
                                          value: '__all__',
                                          child: Text('All categories'),
                                        ),
                                        for (final item in topLevelSections)
                                          DropdownMenuItem(
                                            value: item.id,
                                            child: Text(
                                              '${item.icon} ${item.name}',
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                      ],
                                      onChanged: (value) {
                                        ref
                                            .read(
                                              activeSectionProvider.notifier,
                                            )
                                            .select(
                                              value == '__all__' ? null : value,
                                            );
                                        ref
                                            .read(
                                              activeSubsectionProvider.notifier,
                                            )
                                            .select(null);
                                      },
                                    ),
                                  ),
                                  if (subsections.isNotEmpty) ...[
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: _CompactMenuDropdown(
                                        tooltip: 'Subcategory',
                                        icon: Icons.account_tree_outlined,
                                        value:
                                            effectiveSubsection ??
                                            '__all_subcategories__',
                                        items: [
                                          DropdownMenuItem(
                                            value: '__all_subcategories__',
                                            child: Text(
                                              'All ${section?.name ?? ''}',
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          for (final item in subsections)
                                            DropdownMenuItem(
                                              value: item.id,
                                              child: Text(
                                                '${item.icon} ${item.name}',
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                        ],
                                        onChanged: (value) => ref
                                            .read(
                                              activeSubsectionProvider.notifier,
                                            )
                                            .select(
                                              value == '__all_subcategories__'
                                                  ? null
                                                  : value,
                                            ),
                                      ),
                                    ),
                                  ],
                                ] else if (panelConstraints.maxWidth >= 700 &&
                                    useCategoryTiles &&
                                    _tileCategoryOpen &&
                                    searchQuery.isEmpty)
                                  Expanded(
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: TextButton.icon(
                                        onPressed: () => setState(() {
                                          if (effectiveSubsection != null) {
                                            ref
                                                .read(
                                                  activeSubsectionProvider
                                                      .notifier,
                                                )
                                                .select(null);
                                          } else {
                                            _tileCategoryOpen = false;
                                          }
                                        }),
                                        icon: const Icon(
                                          Icons.arrow_back_rounded,
                                          size: 18,
                                        ),
                                        label: Text(
                                          effectiveSubsection != null
                                              ? section?.name ?? 'Category'
                                              : section?.name ?? 'Categories',
                                        ),
                                      ),
                                    ),
                                  )
                                else
                                  const Spacer(),
                                IconButton(
                                  tooltip: useCategoryTiles
                                      ? 'Use scrolling category bars'
                                      : 'Use category tiles',
                                  onPressed: () => _changeCategoryView(
                                    scope,
                                    useCategoryTiles ? 'bars' : 'tiles',
                                  ),
                                  icon: Icon(
                                    useCategoryTiles
                                        ? Icons.view_stream_outlined
                                        : Icons.grid_view_rounded,
                                  ),
                                ),
                                PopupMenuButton<String>(
                                  tooltip: 'Sort products',
                                  initialValue: productSort,
                                  onSelected: (value) =>
                                      _changeProductSort(scope, value),
                                  icon: Icon(
                                    productSort == 'alphabetical'
                                        ? Icons.sort_by_alpha_rounded
                                        : productSort == 'priceDesc'
                                        ? Icons.south_rounded
                                        : Icons.north_rounded,
                                  ),
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(
                                      value: 'alphabetical',
                                      child: Text('Alphabetical (A–Z)'),
                                    ),
                                    PopupMenuItem(
                                      value: 'priceAsc',
                                      child: Text('Price: low to high'),
                                    ),
                                    PopupMenuItem(
                                      value: 'priceDesc',
                                      child: Text('Price: high to low'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          if (useCategoryTiles &&
                              panelConstraints.maxWidth < 700 &&
                              _tileCategoryOpen &&
                              searchQuery.isEmpty) ...[
                            const SizedBox(height: 4),
                            SizedBox(
                              height: 40,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton.icon(
                                  onPressed: () => setState(() {
                                    if (effectiveSubsection != null) {
                                      ref
                                          .read(
                                            activeSubsectionProvider.notifier,
                                          )
                                          .select(null);
                                    } else {
                                      _tileCategoryOpen = false;
                                    }
                                  }),
                                  icon: const Icon(Icons.arrow_back_rounded),
                                  label: Text(
                                    effectiveSubsection != null
                                        ? section?.name ?? 'Category'
                                        : 'Categories',
                                  ),
                                ),
                              ),
                            ),
                          ],
                          if (!compactTileProductStage &&
                              !(_compactLayout && _menuControlsCollapsed) &&
                              panelConstraints.maxWidth < 700)
                            const SizedBox(height: 14),
                          if (!useCategoryTiles &&
                              panelConstraints.maxWidth < 700 &&
                              !(_compactLayout && _menuControlsCollapsed))
                            _HorizontalMenuScroller(
                              controller: _sectionScrollController,
                              child: Row(
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: ChoiceChip(
                                      avatar: const Icon(
                                        Icons.local_fire_department_rounded,
                                      ),
                                      label: const Text('Popular'),
                                      selected: showPopular,
                                      onSelected: (_) {
                                        ref
                                            .read(
                                              activeSectionProvider.notifier,
                                            )
                                            .select(popularMenuSectionId);
                                        ref
                                            .read(
                                              activeSubsectionProvider.notifier,
                                            )
                                            .select(null);
                                      },
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: ChoiceChip(
                                      label: const Text('All'),
                                      selected:
                                          !showPopular &&
                                          effectiveSection == null,
                                      onSelected: (_) {
                                        ref
                                            .read(
                                              activeSectionProvider.notifier,
                                            )
                                            .select(null);
                                        ref
                                            .read(
                                              activeSubsectionProvider.notifier,
                                            )
                                            .select(null);
                                      },
                                    ),
                                  ),
                                  for (final item in topLevelSections)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: ChoiceChip(
                                        label: Text(
                                          '${item.icon} ${item.name}',
                                        ),
                                        selected: item.id == effectiveSection,
                                        onSelected: (_) {
                                          ref
                                              .read(
                                                activeSectionProvider.notifier,
                                              )
                                              .select(item.id);
                                          ref
                                              .read(
                                                activeSubsectionProvider
                                                    .notifier,
                                              )
                                              .select(null);
                                        },
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          if (!useCategoryTiles &&
                              panelConstraints.maxWidth < 700 &&
                              !(_compactLayout && _menuControlsCollapsed) &&
                              subsections.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            _HorizontalMenuScroller(
                              controller: _subsectionScrollController,
                              child: Row(
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: FilterChip(
                                      label: Text('All ${section?.name ?? ''}'),
                                      selected: effectiveSubsection == null,
                                      onSelected: (_) => ref
                                          .read(
                                            activeSubsectionProvider.notifier,
                                          )
                                          .select(null),
                                    ),
                                  ),
                                  for (final item in subsections)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: FilterChip(
                                        label: Text(
                                          '${item.icon} ${item.name}',
                                        ),
                                        selected:
                                            item.id == effectiveSubsection,
                                        onSelected: (_) => ref
                                            .read(
                                              activeSubsectionProvider.notifier,
                                            )
                                            .select(item.id),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                          if (!showTileCategoryBrowser &&
                              panelConstraints.maxWidth < 700 &&
                              !(_compactLayout && _menuControlsCollapsed)) ...[
                            const SizedBox(height: 14),
                            Text(
                              searchQuery.isNotEmpty
                                  ? 'Search results for “${rawSearchQuery.trim()}”'
                                  : effectiveSubsection == null
                                  ? section?.name ?? 'All menu items'
                                  : subsections
                                        .firstWhere(
                                          (item) =>
                                              item.id == effectiveSubsection,
                                        )
                                        .name,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 10),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: showTileCategoryBrowser
                      ? LayoutBuilder(
                          builder: (context, constraints) {
                            const spacing = 10.0;
                            final columns = posCategoryGridColumnCount(
                              constraints.maxWidth,
                            );
                            final tileWidth =
                                (constraints.maxWidth -
                                    (spacing * (columns - 1))) /
                                columns;
                            return SingleChildScrollView(
                              child: Wrap(
                                spacing: spacing,
                                runSpacing: spacing,
                                children: [
                                  _CategoryTile(
                                    width: tileWidth,
                                    icon: Icons.local_fire_department_rounded,
                                    label: 'Popular',
                                    selected: showPopular,
                                    onTap: () => setState(() {
                                      ref
                                          .read(activeSectionProvider.notifier)
                                          .select(popularMenuSectionId);
                                      ref
                                          .read(
                                            activeSubsectionProvider.notifier,
                                          )
                                          .select(null);
                                      _tileCategoryOpen = true;
                                    }),
                                  ),
                                  _CategoryTile(
                                    width: tileWidth,
                                    icon: Icons.apps_rounded,
                                    label: 'All',
                                    selected:
                                        !showPopular &&
                                        effectiveSection == null,
                                    onTap: () => setState(() {
                                      ref
                                          .read(activeSectionProvider.notifier)
                                          .select(null);
                                      ref
                                          .read(
                                            activeSubsectionProvider.notifier,
                                          )
                                          .select(null);
                                      _tileCategoryOpen = true;
                                    }),
                                  ),
                                  for (final item in topLevelSections)
                                    _CategoryTile(
                                      width: tileWidth,
                                      textIcon: item.icon,
                                      label: item.name,
                                      selected: item.id == effectiveSection,
                                      onTap: () => setState(() {
                                        ref
                                            .read(
                                              activeSectionProvider.notifier,
                                            )
                                            .select(item.id);
                                        ref
                                            .read(
                                              activeSubsectionProvider.notifier,
                                            )
                                            .select(null);
                                        _tileCategoryOpen = true;
                                      }),
                                    ),
                                ],
                              ),
                            );
                          },
                        )
                      : loading
                      ? const Center(child: CircularProgressIndicator())
                      : menuError != null
                      ? _MenuStateMessage(
                          icon: Icons.cloud_off_rounded,
                          title: 'Could not load this venue’s menu',
                          detail: '$menuError',
                        )
                      : products.isEmpty
                      ? const _MenuStateMessage(
                          icon: Icons.menu_book_outlined,
                          title: 'No menu items are available',
                          detail:
                              'Add a product in Menu management, or choose a different category.',
                        )
                      : LayoutBuilder(
                          builder: (context, _) {
                            return Scrollbar(
                              controller: _productScrollController,
                              thumbVisibility: true,
                              child: GridView.builder(
                                controller: _productScrollController,
                                primary: false,
                                itemCount: products.length,
                                gridDelegate:
                                    const SliverGridDelegateWithMaxCrossAxisExtent(
                                      // Compact cards fit an additional product
                                      // across a typical tablet while retaining
                                      // a generous touch target and two name
                                      // lines.
                                      maxCrossAxisExtent: 145,
                                      crossAxisSpacing: 8,
                                      mainAxisSpacing: 8,
                                      mainAxisExtent: 136,
                                    ),
                                itemBuilder: (context, index) => _ProductTile(
                                  product: products[index],
                                  categoryLabel: _primaryCategoryLabel(
                                    products[index],
                                    sections,
                                  ),
                                  currencyCode: currencyCode,
                                  canAdd: activeOrder.canAddProduct(
                                    products[index],
                                  ),
                                  onTap: () => addSelectedProduct(
                                    products[index],
                                    forceConfiguration: false,
                                  ),
                                  onLongPress: () async {
                                    await _showPosProductDetails(
                                      context: context,
                                      product: products[index],
                                      sections: sections,
                                      currencyCode: currencyCode,
                                      onAdd: () async {
                                        await addSelectedProduct(
                                          products[index],
                                          forceConfiguration: true,
                                        );
                                      },
                                    );
                                    return false;
                                  },
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.textIcon,
    this.width = 150,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final String? textIcon;
  final double width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      height: 58,
      child: Material(
        color: selected ? scheme.primaryContainer : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                if (textIcon != null)
                  Text(textIcon!, style: const TextStyle(fontSize: 20))
                else
                  Icon(icon, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Chooses a compact, predictable category grid for the available menu width.
///
/// Tablet layouts deliberately use five columns. Wider desktop layouts can
/// use more, while phone layouts retain a readable minimum tile width.
@visibleForTesting
int posCategoryGridColumnCount(double width) {
  if (width >= 1200) return (width / 160).floor().clamp(6, 8);
  if (width >= 600) return 5;
  if (width >= 440) return 4;
  if (width >= 300) return 3;
  return 2;
}

/// Produces the short order identity shown in the POS menu toolbar.
///
/// Staff need to see where every product will be added before touching it, so
/// fulfilment customer names and named tabs take precedence over the selected
/// dining table. Raw table IDs are used only while table metadata is loading.
@visibleForTesting
String posMenuOrderLocationLabel(
  PosOrder order,
  List<DiningTable> tables, {
  String? selectedTableId,
}) {
  final customerName = order.customerName?.trim();
  if (order.channel == OrderChannel.delivery) {
    return 'Delivery · ${customerName?.isNotEmpty == true ? customerName : 'Customer'}';
  }
  if (order.channel == OrderChannel.collection) {
    return 'Collection · ${customerName?.isNotEmpty == true ? customerName : 'Customer'}';
  }
  final tabName = order.tabName?.trim();
  if (tabName?.isNotEmpty == true) return 'Tab · $tabName';
  final tableId = order.tableId?.trim().isNotEmpty == true
      ? order.tableId!.trim()
      : selectedTableId?.trim() ?? '';
  if (tableId.isEmpty) return 'New order';
  for (final table in tables) {
    if (table.id == tableId) return table.label;
  }
  return tableId;
}

class _CategoryTilePanel extends StatelessWidget {
  const _CategoryTilePanel({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxHeight: 190),
    child: SingleChildScrollView(
      child: Wrap(spacing: 8, runSpacing: 8, children: children),
    ),
  );
}

/// Dense category selector used by landscape tablets and desktop POS layouts.
/// The full chip scrollers remain available on narrow screens, while this
/// single-line control returns substantially more height to the product grid.
class _CompactMenuDropdown extends StatelessWidget {
  const _CompactMenuDropdown({
    required this.tooltip,
    required this.icon,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String tooltip;
  final IconData icon;
  final String value;
  final List<DropdownMenuItem<String>> items;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Container(
        height: 36,
        padding: const EdgeInsets.only(left: 8),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(icon, size: 17, color: scheme.primary),
            const SizedBox(width: 6),
            Expanded(
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: value,
                  isExpanded: true,
                  isDense: true,
                  items: items,
                  onChanged: onChanged,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HorizontalMenuScroller extends StatelessWidget {
  const _HorizontalMenuScroller({
    required this.controller,
    required this.child,
  });

  final ScrollController controller;
  final Widget child;

  void _move(double delta) {
    if (!controller.hasClients) return;
    controller.animateTo(
      (controller.offset + delta).clamp(
        controller.position.minScrollExtent,
        controller.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      IconButton(
        tooltip: 'Earlier categories',
        visualDensity: VisualDensity.compact,
        onPressed: () => _move(-260),
        icon: const Icon(Icons.chevron_left_rounded),
      ),
      Expanded(
        child: Listener(
          onPointerSignal: (event) {
            if (event is! PointerScrollEvent || !controller.hasClients) return;
            final delta =
                event.scrollDelta.dx.abs() > event.scrollDelta.dy.abs()
                ? event.scrollDelta.dx
                : event.scrollDelta.dy;
            if (delta == 0) return;
            GestureBinding.instance.pointerSignalResolver.register(
              event,
              (_) => _move(delta),
            );
          },
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: const {
                PointerDeviceKind.touch,
                PointerDeviceKind.mouse,
                PointerDeviceKind.stylus,
                PointerDeviceKind.invertedStylus,
                PointerDeviceKind.trackpad,
              },
            ),
            child: Scrollbar(
              controller: controller,
              thumbVisibility: true,
              interactive: true,
              child: SingleChildScrollView(
                controller: controller,
                scrollDirection: Axis.horizontal,
                physics: const ClampingScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 8),
                child: child,
              ),
            ),
          ),
        ),
      ),
      IconButton(
        tooltip: 'More categories',
        visualDensity: VisualDensity.compact,
        onPressed: () => _move(260),
        icon: const Icon(Icons.chevron_right_rounded),
      ),
    ],
  );
}

class _MenuStateMessage extends StatelessWidget {
  const _MenuStateMessage({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: scheme.primary),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProductTile extends StatefulWidget {
  const _ProductTile({
    required this.product,
    required this.categoryLabel,
    required this.currencyCode,
    required this.canAdd,
    required this.onTap,
    required this.onLongPress,
  });

  final MenuProduct product;
  final String categoryLabel;
  final String currencyCode;
  final bool canAdd;
  final Future<bool> Function() onTap;
  final Future<bool> Function() onLongPress;

  @override
  State<_ProductTile> createState() => _ProductTileState();
}

class _ProductTileState extends State<_ProductTile> {
  bool _pressed = false;

  Future<void> _activate(
    Future<bool> Function() action, {
    bool animateToOrder = false,
  }) async {
    if (_pressed) return;
    HapticFeedback.selectionClick();
    setState(() => _pressed = true);
    await Future<void>.delayed(const Duration(milliseconds: 90));
    try {
      final added = await action();
      if (added && animateToOrder && mounted) _animateProductToOrder();
    } finally {
      if (mounted) setState(() => _pressed = false);
    }
  }

  /// Gives immediate, unmistakable feedback while the authoritative order
  /// update completes in the background. The visual copy spins, tilts and
  /// shrinks towards the Order area; it carries no order state and therefore
  /// cannot conceal a later server rejection or alter transaction safety.
  void _animateProductToOrder() {
    final tileBox = context.findRenderObject();
    final overlay = Overlay.of(context);
    final overlayBox = overlay.context.findRenderObject();
    if (tileBox is! RenderBox || overlayBox is! RenderBox) return;
    final start = overlayBox.globalToLocal(tileBox.localToGlobal(Offset.zero));
    final media = MediaQuery.sizeOf(context);
    final target = Offset(
      overlayBox.size.width - 68,
      (MediaQuery.paddingOf(context).top + (media.width >= 840 ? 112 : 44))
          .clamp(12.0, overlayBox.size.height - 70),
    );
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (overlayContext) => Positioned.fill(
        child: IgnorePointer(
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: 1),
            duration: const Duration(milliseconds: 720),
            curve: Curves.easeInOutCubicEmphasized,
            onEnd: () {
              if (entry.mounted) entry.remove();
            },
            builder: (context, progress, child) {
              final offset = Offset.lerp(start, target, progress)!;
              return Stack(
                children: [
                  Positioned(
                    left: offset.dx,
                    top: offset.dy,
                    child: Opacity(
                      opacity: (1 - (progress * .55)).clamp(0.0, 1.0),
                      child: Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.identity()
                          ..setEntry(3, 2, .0015)
                          ..rotateY(progress * 6.283185307)
                          ..rotateZ(progress * 6.283185307)
                          ..scaleByDouble(
                            1 - (progress * .58),
                            1 - (progress * .58),
                            1 - (progress * .58),
                            1,
                          ),
                        child: child,
                      ),
                    ),
                  ),
                ],
              );
            },
            child: Material(
              elevation: 14,
              color: Theme.of(overlayContext).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: 132,
                height: 68,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      Icon(
                        widget.product.productionArea == ProductionArea.bar
                            ? Icons.local_bar_rounded
                            : Icons.restaurant_rounded,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          widget.product.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final unavailable = !widget.canAdd;
    final unavailableLabel = widget.product.isAvailable
        ? 'Sold out'
        : 'Unavailable';
    return Semantics(
      button: true,
      enabled: !unavailable,
      label: unavailable
          ? '${widget.product.name}, $unavailableLabel'
          : 'Add ${widget.product.name}',
      child: AnimatedScale(
        scale: _pressed ? .92 : 1,
        duration: const Duration(milliseconds: 110),
        child: InkWell(
          onTap: unavailable
              ? null
              : () => _activate(
                  widget.onTap,
                  animateToOrder: !widget.product.requiresConfiguration,
                ),
          onLongPress: unavailable ? null : () => _activate(widget.onLongPress),
          borderRadius: BorderRadius.circular(16),
          child: Ink(
            decoration: BoxDecoration(
              color: unavailable
                  ? scheme.surfaceContainerHighest
                  : scheme.primaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              // Eight pixels keeps the complete two-line name, price and
              // category readable while allowing a denser waiter workspace.
              padding: const EdgeInsets.all(8),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Phone grids intentionally use a short tile. Keep its most
                  // useful information visible without causing a layout overflow.
                  final compact = constraints.maxHeight < 150;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        widget.product.productionArea == ProductionArea.bar
                            ? Icons.local_bar_rounded
                            : Icons.restaurant_rounded,
                        size: compact ? 18 : null,
                        color: unavailable ? scheme.outline : scheme.primary,
                      ),
                      if (!compact && widget.product.requiresConfiguration)
                        const Align(
                          alignment: Alignment.centerRight,
                          child: Icon(Icons.tune_rounded, size: 16),
                        ),
                      if (compact)
                        const SizedBox(height: 4)
                      else
                        const Spacer(),
                      Text(
                        widget.product.name,
                        maxLines: 2,
                        softWrap: true,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      SizedBox(height: compact ? 2 : 4),
                      Text(
                        formatMoney(
                          widget.product.priceMinor,
                          currencyCode: widget.currencyCode,
                        ),
                      ),
                      if (widget.categoryLabel.isNotEmpty)
                        Text(
                          widget.categoryLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      if (unavailable)
                        Text(
                          unavailableLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(
                            context,
                          ).textTheme.labelSmall?.copyWith(color: scheme.error),
                        ),
                      if (!compact && widget.product.trackStock)
                        Text(
                          '${_formatStock(widget.product.stockOnHand ?? 0)} ${widget.product.stockUnit} left',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _primaryCategoryLabel(MenuProduct product, List<MenuSection> sections) {
  final assigned = sections.where(
    (section) => product.sectionIds.contains(section.id),
  );
  final primary = assigned.where((section) => section.parentSectionId == null);
  if (primary.isNotEmpty) return primary.first.name;
  for (final section in assigned) {
    final parent = sections.where((item) => item.id == section.parentSectionId);
    if (parent.isNotEmpty) return parent.first.name;
  }
  return assigned.isEmpty ? '' : assigned.first.name;
}

Future<void> _showPosProductDetails({
  required BuildContext context,
  required MenuProduct product,
  required List<MenuSection> sections,
  required String currencyCode,
  required Future<void> Function() onAdd,
}) async {
  final sectionNames = sections
      .where((section) => product.sectionIds.contains(section.id))
      .map((section) => section.name)
      .join(' · ');
  final add = await showAppDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(product.name),
      content: SingleChildScrollView(
        child: ListBody(
          children: [
            Text(
              'Price: ${formatMoney(product.priceMinor, currencyCode: currencyCode)}',
            ),
            Text('Categories: ${sectionNames.isEmpty ? 'None' : sectionNames}'),
            Text('Production: ${product.productionArea.label}'),
            Text('Tax: ${product.taxRateLabel}'),
            Text(
              product.showOnOrderFlow
                  ? 'Shown on order flow'
                  : 'Excluded from order flow',
            ),
            if (product.variants.isNotEmpty)
              Text(
                'Variants: ${product.variants.map((item) => item.name).join(', ')}',
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.add_shopping_cart_rounded),
          label: const Text('Configure and add'),
        ),
      ],
    ),
  );
  if (add == true) await onAdd();
}

String _formatStock(double quantity) {
  if (quantity == quantity.roundToDouble()) return quantity.toStringAsFixed(0);
  return quantity
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}
