part of '../menu_management_page.dart';

Future<void> _showSectionOrderDialog({
  required BuildContext context,
  required WidgetRef ref,
  required VenueScope scope,
  required List<MenuSection> sections,
}) async {
  final ordered = List<MenuSection>.of(sections);
  final save = await _showMenuDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('Order menu sections'),
        content: SizedBox(
          width: 520,
          height: 520,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Drag categories into the order they should appear on the POS. Subcategories keep their current parent.',
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: ordered.length,
                  onReorderItem: (oldIndex, newIndex) {
                    setDialogState(() {
                      final item = ordered.removeAt(oldIndex);
                      ordered.insert(newIndex, item);
                    });
                  },
                  itemBuilder: (context, index) {
                    final section = ordered[index];
                    final parent = sections
                        .where((item) => item.id == section.parentSectionId)
                        .firstOrNull;
                    return Card(
                      key: ValueKey(section.id),
                      margin: const EdgeInsets.only(bottom: 6),
                      child: ListTile(
                        leading: CircleAvatar(child: Text('${index + 1}')),
                        title: Text('${section.icon} ${section.name}'),
                        subtitle: Text(
                          parent == null
                              ? 'Top-level category'
                              : 'Subcategory of ${parent.name}',
                        ),
                        trailing: ReorderableDragStartListener(
                          index: index,
                          child: const Padding(
                            padding: EdgeInsets.all(12),
                            child: Icon(Icons.drag_handle_rounded),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Save order'),
          ),
        ],
      ),
    ),
  );
  if (save != true || !context.mounted) return;
  try {
    await ref
        .read(firestorePosRepositoryProvider)
        .reorderMenuSections(
          scope: scope,
          sectionIds: ordered.map((item) => item.id).toList(growable: false),
        );
    if (!context.mounted) return;
    showAppNotification(
      context,
      ref: ref,
      title: 'Section order updated',
      message: 'The POS category order has been updated for this venue.',
      level: AppNotificationLevel.success,
    );
  } on Object catch (error, stackTrace) {
    AppLogger.error('Reorder menu sections', error, stackTrace);
    if (!context.mounted) return;
    showAppNotification(
      context,
      ref: ref,
      title: 'Could not reorder sections',
      message: '$error',
      level: AppNotificationLevel.error,
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
  final approved = await _showMenuDialog<bool>(
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

Future<void> _setProductArchived({
  required BuildContext context,
  required WidgetRef ref,
  required VenueScope scope,
  required MenuProduct product,
  required bool archived,
}) async {
  if (archived) {
    final approved = await _showMenuDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Archive product?'),
        content: Text(
          '“${product.name}” will be removed from the POS and active menu. Its historic sales, stock and supplier records will be preserved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Archive product'),
          ),
        ],
      ),
    );
    if (approved != true || !context.mounted) return;
  }
  try {
    await ref
        .read(firestorePosRepositoryProvider)
        .setProductArchived(
          scope: scope,
          productId: product.id,
          archived: archived,
        );
    if (!context.mounted) return;
    showAppNotification(
      context,
      ref: ref,
      title: archived ? 'Product archived' : 'Product restored',
      message: archived
          ? '${product.name} has been removed from the active menu.'
          : '${product.name} is restored but remains unavailable until you turn For sale on.',
      level: AppNotificationLevel.success,
    );
  } on Object catch (error, stackTrace) {
    AppLogger.error(
      archived ? 'Archive menu product' : 'Restore menu product',
      error,
      stackTrace,
    );
    if (!context.mounted) return;
    showAppNotification(
      context,
      ref: ref,
      title: archived
          ? 'Could not archive product'
          : 'Could not restore product',
      message: '$error',
      level: AppNotificationLevel.error,
    );
  }
}

class _BulkProductChanges {
  const _BulkProductChanges({
    this.sectionIds,
    this.productionArea,
    this.showOnOrderFlow,
    this.modifierGroupIds,
    this.targetMarginBasisPoints,
    this.variantSetId,
    this.changeTaxRate = false,
    this.taxRateId,
    this.changeDefaultCourse = false,
    this.defaultCourseId,
    this.availableForCollection,
    this.availableForDelivery,
    this.removeCollectionPriceOverride = false,
    this.removeDeliveryPriceOverride = false,
  });

  final List<String>? sectionIds;
  final ProductionArea? productionArea;
  final bool? showOnOrderFlow;
  final List<String>? modifierGroupIds;
  final int? targetMarginBasisPoints;
  final String? variantSetId;
  final bool changeTaxRate;
  final String? taxRateId;
  final bool changeDefaultCourse;
  final String? defaultCourseId;
  final bool? availableForCollection;
  final bool? availableForDelivery;
  final bool removeCollectionPriceOverride;
  final bool removeDeliveryPriceOverride;
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({
    required this.product,
    required this.sections,
    required this.currencyCode,
    required this.canEdit,
    required this.selected,
    required this.onSelected,
    required this.onEdit,
    required this.onAvailabilityChanged,
    required this.onArchive,
  });

  final MenuProduct product;
  final List<MenuSection> sections;
  final String currencyCode;
  final bool canEdit;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  final VoidCallback? onEdit;
  final ValueChanged<bool>? onAvailabilityChanged;
  final VoidCallback? onArchive;

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
    final details =
        '${product.productionArea.label} · ${product.taxRateLabel} · $stock';
    if (MediaQuery.sizeOf(context).width < 650) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Checkbox(
                  value: selected,
                  onChanged: onSelected == null
                      ? null
                      : (value) => onSelected!(value ?? false),
                ),
                CircleAvatar(
                  radius: 18,
                  child: Icon(switch (product.productionArea) {
                    ProductionArea.bar => Icons.local_bar_rounded,
                    ProductionArea.kitchen => Icons.restaurant_rounded,
                    ProductionArea.dessert => Icons.cake_outlined,
                  }, size: 19),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    product.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  formatMoney(product.priceMinor, currencyCode: currencyCode),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ],
            ),
            if (sectionNames.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                sectionNames,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 3),
            Text(
              details,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  product.isAvailable ? 'For sale' : 'Unavailable',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                Transform.scale(
                  scale: 0.82,
                  child: Switch(
                    value: product.isAvailable,
                    onChanged: onAvailabilityChanged,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Edit product',
                  visualDensity: VisualDensity.compact,
                  onPressed: canEdit ? onEdit : null,
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  tooltip: 'Archive product',
                  visualDensity: VisualDensity.compact,
                  onPressed: canEdit ? onArchive : null,
                  icon: const Icon(Icons.archive_outlined),
                ),
              ],
            ),
          ],
        ),
      );
    }
    return ListTile(
      isThreeLine: true,
      leading: Checkbox(
        value: selected,
        onChanged: onSelected == null
            ? null
            : (value) => onSelected!(value ?? false),
      ),
      title: Text(product.name),
      subtitle: Text('$sectionNames\n$details'),
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
          IconButton(
            tooltip: 'Archive product',
            onPressed: canEdit ? onArchive : null,
            icon: const Icon(Icons.archive_outlined),
          ),
        ],
      ),
    );
  }
}
