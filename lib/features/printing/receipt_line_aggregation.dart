/// A compact, immutable receipt line. Production tickets deliberately do not
/// use this: kitchen/bar staff need the original order additions, while a paid
/// customer receipt can safely combine matching sale lines to save paper.
class ReceiptLineSummary {
  const ReceiptLineSummary({
    required this.name,
    required this.quantity,
    required this.lineTotalMinor,
  });

  final String name;
  final int quantity;
  final int lineTotalMinor;
}

List<ReceiptLineSummary> aggregateReceiptPayloadLines(Object? rawLines) {
  if (rawLines is! List) return const [];
  final grouped = <String, _ReceiptLineTotal>{};
  for (final raw in rawLines.whereType<Map>()) {
    final quantity = (raw['quantity'] as num?)?.toInt() ?? 1;
    if (quantity <= 0) continue;
    final baseName =
        raw['productName'] as String? ?? raw['name'] as String? ?? 'Item';
    final details = <String>[
      if ((raw['variantName'] as String?)?.trim().isNotEmpty == true)
        (raw['variantName'] as String).trim(),
      if (raw['modifierSelections'] is List)
        for (final group
            in (raw['modifierSelections'] as List).whereType<Map>())
          '${group['groupName'] ?? 'Option'}: ${group['optionName'] ?? ''}'
              .trim(),
      if ((raw['itemNote'] as String?)?.trim().isNotEmpty == true)
        'Note: ${(raw['itemNote'] as String).trim()}',
    ].where((detail) => detail.isNotEmpty).toList(growable: false);
    final name = details.isEmpty
        ? baseName
        : '$baseName\n${details.join('\n')}';
    final lineTotalMinor = (raw['lineTotalMinor'] as num?)?.toInt() ?? 0;
    // Do not merge lines which have a different sale price or tax snapshot.
    // It keeps a historic receipt auditable even when a product is sold at a
    // manager-approved price override later in the same bill.
    final key = [
      raw['productId'] as String? ?? name,
      name,
      raw['unitPriceMinor']?.toString() ?? '',
      raw['taxRateId']?.toString() ?? '',
      raw['taxRateBasisPoints']?.toString() ?? '',
    ].join('|');
    final existing = grouped[key];
    if (existing == null) {
      grouped[key] = _ReceiptLineTotal(name, quantity, lineTotalMinor);
    } else {
      existing.quantity += quantity;
      existing.lineTotalMinor += lineTotalMinor;
    }
  }
  return grouped.values
      .map(
        (line) => ReceiptLineSummary(
          name: line.name,
          quantity: line.quantity,
          lineTotalMinor: line.lineTotalMinor,
        ),
      )
      .toList(growable: false);
}

class _ReceiptLineTotal {
  _ReceiptLineTotal(this.name, this.quantity, this.lineTotalMinor);

  final String name;
  int quantity;
  int lineTotalMinor;
}
