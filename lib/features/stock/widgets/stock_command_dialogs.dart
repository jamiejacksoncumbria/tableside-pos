part of '../stock_management_page.dart';

Future<void> _runCommand(
  BuildContext context,
  WidgetRef ref,
  VenueScope scope,
  String operation, {
  String? documentId,
  Map<String, Object?> values = const {},
  String success = 'Saved',
}) async {
  try {
    await ref
        .read(stockRepositoryProvider)
        .command(
          scope: scope,
          operation: operation,
          documentId: documentId,
          values: values,
        );
    if (!context.mounted) return;
    showAppNotification(
      context,
      ref: ref,
      title: success,
      message: '$success successfully.',
      level: AppNotificationLevel.success,
    );
  } on Object catch (error, stack) {
    AppLogger.error('Stock management $operation', error, stack);
    if (!context.mounted) return;
    showAppNotification(
      context,
      ref: ref,
      title: 'Stock action failed',
      message: '$error',
      level: AppNotificationLevel.error,
    );
  }
}

Future<void> _adjustStock(
  BuildContext context,
  WidgetRef ref,
  VenueScope scope,
  MenuProduct product,
) async {
  final quantity = TextEditingController();
  final reason = TextEditingController();
  var type = _StockAdjustmentType.correction;
  final confirmed = await showAppDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text('Update ${product.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<_StockAdjustmentType>(
              initialValue: type,
              decoration: const InputDecoration(labelText: 'Stock action'),
              items: const [
                DropdownMenuItem(
                  value: _StockAdjustmentType.correction,
                  child: Text('Correction / adjustment'),
                ),
                DropdownMenuItem(
                  value: _StockAdjustmentType.physicalCount,
                  child: Text('Record physical count'),
                ),
                DropdownMenuItem(
                  value: _StockAdjustmentType.wastage,
                  child: Text('Record wastage'),
                ),
                DropdownMenuItem(
                  value: _StockAdjustmentType.spillage,
                  child: Text('Record spillage'),
                ),
              ],
              onChanged: (value) => setDialogState(() {
                type = value ?? type;
                quantity.clear();
              }),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: quantity,
              keyboardType: TextInputType.numberWithOptions(
                decimal: true,
                signed: type == _StockAdjustmentType.correction,
              ),
              decoration: InputDecoration(
                labelText: type == _StockAdjustmentType.physicalCount
                    ? 'Counted quantity (${product.stockUnit})'
                    : type == _StockAdjustmentType.correction
                    ? 'Quantity change (${product.stockUnit})'
                    : 'Quantity removed (${product.stockUnit})',
                helperText: type == _StockAdjustmentType.physicalCount
                    ? 'Current system quantity: ${_quantity(product.stockOnHand ?? 0)}.'
                    : type == _StockAdjustmentType.correction
                    ? 'Use a negative number to remove stock.'
                    : 'Enter a positive discarded quantity.',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reason,
              decoration: const InputDecoration(labelText: 'Required reason'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Apply'),
          ),
        ],
      ),
    ),
  );
  final amount = double.tryParse(quantity.text.trim().replaceAll(',', '.'));
  if (confirmed == true &&
      amount != null &&
      amount.isFinite &&
      (type == _StockAdjustmentType.physicalCount
          ? amount >= 0
          : amount != 0) &&
      (type == _StockAdjustmentType.correction || amount > 0) &&
      reason.text.trim().isNotEmpty &&
      context.mounted) {
    await _runCommand(
      context,
      ref,
      scope,
      'adjustStock',
      values: {
        'productId': product.id,
        if (type == _StockAdjustmentType.physicalCount)
          'countedQuantity': amount
        else
          'quantity': type == _StockAdjustmentType.correction
              ? amount
              : -amount,
        'adjustmentType': type.name,
        'reason': reason.text.trim(),
      },
      success: 'Stock adjusted',
    );
  }
  quantity.dispose();
  reason.dispose();
}

enum _StockAdjustmentType { correction, physicalCount, wastage, spillage }

Future<void> _editSupplier(
  BuildContext context,
  WidgetRef ref,
  VenueScope scope, [
  StockSupplier? existing,
]) async {
  final name = TextEditingController(text: existing?.name);
  final contact = TextEditingController(text: existing?.contactName);
  final email = TextEditingController(text: existing?.email);
  final phone = TextEditingController(text: existing?.phone);
  final saved = await showAppDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(existing == null ? 'Add supplier' : 'Edit supplier'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Supplier name'),
            ),
            TextField(
              controller: contact,
              decoration: const InputDecoration(labelText: 'Contact name'),
            ),
            TextField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            TextField(
              controller: phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Phone'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (saved == true && name.text.trim().isNotEmpty && context.mounted) {
    await _runCommand(
      context,
      ref,
      scope,
      'saveSupplier',
      documentId: existing?.id,
      values: {
        'name': name.text.trim(),
        'contactName': contact.text.trim(),
        'email': email.text.trim(),
        'phone': phone.text.trim(),
        'active': true,
      },
      success: 'Supplier saved',
    );
  }
  name.dispose();
  contact.dispose();
  email.dispose();
  phone.dispose();
}

Future<void> _bulkLinkProducts(
  BuildContext context,
  WidgetRef ref,
  VenueScope scope,
  StockSupplier supplier,
  List<MenuProduct> products,
  String currencyCode,
) async {
  final selected = <String>{};
  final result = await showAppDialog<Set<String>>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('Add products to ${supplier.name}'),
        content: SizedBox(
          width: 480,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final product in products)
                CheckboxListTile(
                  value: selected.contains(product.id),
                  title: Text(product.name),
                  subtitle: Text(product.stockUnit),
                  onChanged: (value) => setState(
                    () => value == true
                        ? selected.add(product.id)
                        : selected.remove(product.id),
                  ),
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
            onPressed: selected.isEmpty
                ? null
                : () => Navigator.pop(context, {...selected}),
            child: const Text('Continue'),
          ),
        ],
      ),
    ),
  );
  if (result == null || !context.mounted) return;
  for (final product in products.where((item) => result.contains(item.id))) {
    if (!context.mounted) return;
    await _editSupplierProduct(
      context,
      ref,
      scope,
      supplier,
      product,
      currencyCode,
    );
  }
}

Future<void> _editSupplierProduct(
  BuildContext context,
  WidgetRef ref,
  VenueScope scope,
  StockSupplier supplier,
  MenuProduct product,
  String baseCurrencyCode, {
  SupplierProduct? existing,
}) async {
  final pack = TextEditingController(text: existing?.packName ?? 'Case');
  final units = TextEditingController(
    text: '${existing?.stockUnitsPerPack ?? 1}',
  );
  final cost = TextEditingController(
    text: existing == null
        ? ''
        : _costText(existing.packCostMinor, existing.currencyCode),
  );
  final currency = TextEditingController(
    text: existing?.currencyCode ?? baseCurrencyCode,
  );
  var preferred = existing?.preferred ?? false;
  final saved = await showAppDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('${supplier.name}: ${product.name}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: pack,
                decoration: const InputDecoration(
                  labelText: 'Pack name (case, bottle, bag)',
                ),
              ),
              TextField(
                controller: units,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: '${product.stockUnit} per pack',
                ),
              ),
              TextField(
                controller: cost,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Pack cost',
                  helperText: 'Example: 12.50.',
                ),
              ),
              TextField(
                controller: currency,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Currency code'),
              ),
              CheckboxListTile(
                value: preferred,
                title: const Text('Preferred supplier for this product'),
                onChanged: (value) =>
                    setState(() => preferred = value ?? false),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  final unitsValue = double.tryParse(units.text.trim());
  final costValue = _parseCostMinor(cost.text, currency.text);
  if (saved == true &&
      unitsValue != null &&
      unitsValue > 0 &&
      costValue != null &&
      costValue >= 0 &&
      context.mounted) {
    await _runCommand(
      context,
      ref,
      scope,
      'saveSupplierProduct',
      documentId: existing?.id,
      values: {
        'supplierId': supplier.id,
        'productId': product.id,
        'packName': pack.text.trim(),
        'stockUnitsPerPack': unitsValue,
        'packCostMinor': costValue,
        'currencyCode': currency.text.trim().toUpperCase(),
        'preferred': preferred,
        'active': true,
      },
      success: 'Supplier product saved',
    );
  }
  pack.dispose();
  units.dispose();
  cost.dispose();
  currency.dispose();
}

Future<void> _createRecommendedOrder(
  BuildContext context,
  WidgetRef ref,
  VenueScope scope,
  List<StockSupplier> suppliers,
) async {
  var supplierId = suppliers.first.id;
  final days = TextEditingController(text: '7');
  final confirmed = await showAppDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Create recommended order'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: supplierId,
              decoration: const InputDecoration(labelText: 'Supplier'),
              items: [
                for (final supplier in suppliers.where((item) => item.active))
                  DropdownMenuItem(
                    value: supplier.id,
                    child: Text(supplier.name),
                  ),
              ],
              onChanged: (value) =>
                  setState(() => supplierId = value ?? supplierId),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: days,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Days of stock to order',
                helperText:
                    'Uses the last 30 days and the same period last year when available.',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Calculate'),
          ),
        ],
      ),
    ),
  );
  final coverage = int.tryParse(days.text.trim());
  if (confirmed == true &&
      coverage != null &&
      coverage > 0 &&
      context.mounted) {
    await _runCommand(
      context,
      ref,
      scope,
      'createRecommendedOrder',
      values: {'supplierId': supplierId, 'coverageDays': coverage},
      success: 'Recommended draft created',
    );
  }
  days.dispose();
}

Future<void> _orderAction(
  BuildContext context,
  WidgetRef ref,
  VenueScope scope,
  StockPurchaseOrder order,
  String operation,
) => _runCommand(
  context,
  ref,
  scope,
  operation,
  documentId: order.id,
  success: 'Purchase order updated',
);

Future<void> _editDraftOrder(
  BuildContext context,
  WidgetRef ref,
  VenueScope scope,
  StockPurchaseOrder order,
) async {
  final controllers = {
    for (final line in order.lines)
      line.id: TextEditingController(text: _quantity(line.orderedPacks)),
  };
  final confirmed = await showAppDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Review recommended quantities'),
      content: SizedBox(
        width: 520,
        child: ListView(
          shrinkWrap: true,
          children: [
            const Text(
              'Recommendations are guidance. Confirm or change every pack quantity before marking the order as sent.',
            ),
            const SizedBox(height: 12),
            for (final line in order.lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: TextField(
                  controller: controllers[line.id],
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: '${line.productName} (${line.packName})',
                    helperText:
                        'Recommended ${_quantity(line.recommendedPacks)}',
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Save quantities'),
        ),
      ],
    ),
  );
  if (confirmed == true && context.mounted) {
    final lines = <Map<String, Object?>>[];
    var valid = true;
    for (final entry in controllers.entries) {
      final amount = double.tryParse(entry.value.text.trim());
      if (amount == null || amount < 0) {
        valid = false;
        showAppNotification(
          context,
          ref: ref,
          title: 'Invalid pack quantity',
          message: 'Use zero or a positive number for every order line.',
          level: AppNotificationLevel.warning,
        );
        break;
      }
      lines.add({'lineId': entry.key, 'orderedPacks': amount});
    }
    if (valid) {
      await _runCommand(
        context,
        ref,
        scope,
        'updateDraftOrder',
        documentId: order.id,
        values: {'lines': lines},
        success: 'Draft quantities saved',
      );
    }
  }
  for (final controller in controllers.values) {
    controller.dispose();
  }
}

Future<void> _receiveOrder(
  BuildContext context,
  WidgetRef ref,
  VenueScope scope,
  StockPurchaseOrder order,
) async {
  final controllers = {
    for (final line in order.lines.where((line) => line.remainingPacks > 0))
      line.id: TextEditingController(text: _quantity(line.remainingPacks)),
  };
  final confirmed = await showAppDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Receive delivered stock'),
      content: SizedBox(
        width: 520,
        child: ListView(
          shrinkWrap: true,
          children: [
            const Text(
              'Confirm actual packs received. Stock and cost history update only after this step.',
            ),
            const SizedBox(height: 12),
            for (final line in order.lines.where(
              (line) => line.remainingPacks > 0,
            ))
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: TextField(
                  controller: controllers[line.id],
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: '${line.productName} (${line.packName})',
                    helperText: '${_quantity(line.remainingPacks)} outstanding',
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Receive into stock'),
        ),
      ],
    ),
  );
  if (confirmed == true && context.mounted) {
    final lines = <Map<String, Object?>>[];
    for (final entry in controllers.entries) {
      final amount = double.tryParse(entry.value.text.trim());
      if (amount != null && amount > 0) {
        lines.add({'lineId': entry.key, 'receivedPacks': amount});
      }
    }
    if (lines.isNotEmpty) {
      await _runCommand(
        context,
        ref,
        scope,
        'receiveOrder',
        documentId: order.id,
        values: {'lines': lines},
        success: 'Stock received',
      );
    }
  }
  for (final controller in controllers.values) {
    controller.dispose();
  }
}
