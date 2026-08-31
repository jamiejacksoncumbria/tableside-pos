enum PurchaseOrderStatus {
  draft,
  ordered,
  partiallyReceived,
  received,
  cancelled,
}

PurchaseOrderStatus purchaseOrderStatusFromWire(String? value) =>
    switch (value) {
      'ordered' => PurchaseOrderStatus.ordered,
      'partiallyReceived' => PurchaseOrderStatus.partiallyReceived,
      'received' => PurchaseOrderStatus.received,
      'cancelled' => PurchaseOrderStatus.cancelled,
      _ => PurchaseOrderStatus.draft,
    };

extension PurchaseOrderStatusLabel on PurchaseOrderStatus {
  String get label => switch (this) {
    PurchaseOrderStatus.draft => 'Draft',
    PurchaseOrderStatus.ordered => 'Ordered',
    PurchaseOrderStatus.partiallyReceived => 'Part received',
    PurchaseOrderStatus.received => 'Received',
    PurchaseOrderStatus.cancelled => 'Cancelled',
  };
}

class StockSupplier {
  const StockSupplier({
    required this.id,
    required this.name,
    this.contactName = '',
    this.email = '',
    this.phone = '',
    this.notes = '',
    this.active = true,
  });

  final String id;
  final String name;
  final String contactName;
  final String email;
  final String phone;
  final String notes;
  final bool active;
}

/// Maps one supplier pack to a venue product's base stock unit. A case of
/// 24 x 330 ml bottles can therefore add 7,920 ml when it is received.
class SupplierProduct {
  const SupplierProduct({
    required this.id,
    required this.supplierId,
    required this.productId,
    required this.productName,
    required this.packName,
    required this.stockUnitsPerPack,
    required this.packCostMinor,
    required this.currencyCode,
    this.supplierSku = '',
    this.preferred = false,
    this.active = true,
  });

  final String id;
  final String supplierId;
  final String productId;
  final String productName;
  final String packName;
  final double stockUnitsPerPack;
  final int packCostMinor;
  final String currencyCode;
  final String supplierSku;
  final bool preferred;
  final bool active;
}

class PurchaseOrderLine {
  const PurchaseOrderLine({
    required this.id,
    required this.supplierProductId,
    required this.productId,
    required this.productName,
    required this.packName,
    required this.orderedPacks,
    required this.receivedPacks,
    required this.stockUnitsPerPack,
    required this.packCostMinor,
    required this.currencyCode,
    required this.recommendedPacks,
    required this.recentDailyUsage,
    this.priorYearDailyUsage,
  });

  final String id;
  final String supplierProductId;
  final String productId;
  final String productName;
  final String packName;
  final double orderedPacks;
  final double receivedPacks;
  final double stockUnitsPerPack;
  final int packCostMinor;
  final String currencyCode;
  final double recommendedPacks;
  final double recentDailyUsage;
  final double? priorYearDailyUsage;

  double get remainingPacks =>
      (orderedPacks - receivedPacks).clamp(0, double.infinity);
}

class StockPurchaseOrder {
  const StockPurchaseOrder({
    required this.id,
    required this.supplierId,
    required this.supplierName,
    required this.status,
    required this.coverageDays,
    required this.lines,
    required this.createdAt,
    this.orderedAt,
    this.receivedAt,
  });

  final String id;
  final String supplierId;
  final String supplierName;
  final PurchaseOrderStatus status;
  final int coverageDays;
  final List<PurchaseOrderLine> lines;
  final DateTime createdAt;
  final DateTime? orderedAt;
  final DateTime? receivedAt;

  int get totalMinor => lines.fold(
    0,
    (total, line) => total + (line.orderedPacks * line.packCostMinor).round(),
  );
}

class StockMovement {
  const StockMovement({
    required this.id,
    required this.productId,
    required this.productName,
    required this.quantity,
    required this.stockUnit,
    required this.reason,
    required this.createdAt,
    this.actorName = '',
  });

  final String id;
  final String productId;
  final String productName;
  final double quantity;
  final String stockUnit;
  final String reason;
  final DateTime createdAt;
  final String actorName;
}
