enum OrderStatus { open, pendingApproval, sent, closed, rolledOver }

enum ProductionArea { bar, kitchen, dessert }

enum OrderFlowStatus {
  newOrder,
  preparing,
  ready,
  collected,
  served,
  cancelled,
  voided,
}

extension OrderFlowStatusLabel on OrderFlowStatus {
  String get label => switch (this) {
    OrderFlowStatus.newOrder => 'New',
    OrderFlowStatus.preparing => 'Preparing',
    OrderFlowStatus.ready => 'Ready',
    OrderFlowStatus.collected => 'Collected',
    OrderFlowStatus.served => 'Served',
    OrderFlowStatus.cancelled => 'Cancelled',
    OrderFlowStatus.voided => 'Voided',
  };

  bool get isTerminal => switch (this) {
    OrderFlowStatus.served ||
    OrderFlowStatus.cancelled ||
    OrderFlowStatus.voided => true,
    _ => false,
  };
}

extension ProductionAreaLabel on ProductionArea {
  String get label => switch (this) {
    ProductionArea.bar => 'Bar',
    ProductionArea.kitchen => 'Kitchen',
    ProductionArea.dessert => 'Dessert',
  };
}

/// A production-safe summary of a live order. It intentionally omits money
/// and contact data so it can be shown on a kitchen/bar display.
class OrderFlowOrder {
  const OrderFlowOrder({
    required this.id,
    required this.tenantId,
    required this.venueId,
    required this.reference,
    required this.productionArea,
    required this.status,
    required this.ticketReleasedAt,
    required this.itemSummary,
    this.tableLabel,
    this.tabName,
    this.createdByName = '',
    this.hasAllergyAlert = false,
    this.isDelayed = false,
    this.note = '',
  });

  final String id;
  final String tenantId;
  final String venueId;
  final String reference;
  final ProductionArea productionArea;
  final OrderFlowStatus status;
  final DateTime ticketReleasedAt;
  final List<String> itemSummary;
  final String? tableLabel;
  final String? tabName;
  final String createdByName;
  final bool hasAllergyAlert;
  final bool isDelayed;
  final String note;

  OrderFlowOrder copyWith({OrderFlowStatus? status, bool? isDelayed}) =>
      OrderFlowOrder(
        id: id,
        tenantId: tenantId,
        venueId: venueId,
        reference: reference,
        productionArea: productionArea,
        status: status ?? this.status,
        ticketReleasedAt: ticketReleasedAt,
        itemSummary: itemSummary,
        tableLabel: tableLabel,
        tabName: tabName,
        createdByName: createdByName,
        hasAllergyAlert: hasAllergyAlert,
        isDelayed: isDelayed ?? this.isDelayed,
        note: note,
      );
}

enum PrintJobStatus { queued, claimed, printed, failed, cancelled }

class TenantProfile {
  const TenantProfile({
    required this.id,
    required this.displayName,
    required this.legalName,
    required this.currencyCode,
    this.logoUrl,
    this.address = '',
    this.phone = '',
    this.phoneNumbers = const [],
    this.receiptFooter = '',
  });

  final String id;
  final String displayName;
  final String legalName;
  final String currencyCode;
  final String? logoUrl;
  final String address;

  /// Legacy primary telephone field retained for older tenant records.
  final String phone;
  final List<String> phoneNumbers;
  final String receiptFooter;

  String get primaryPhone =>
      phoneNumbers.isNotEmpty ? phoneNumbers.first : phone;

  TenantProfile copyWith({
    String? displayName,
    String? legalName,
    String? currencyCode,
    String? logoUrl,
    String? address,
    String? phone,
    List<String>? phoneNumbers,
    String? receiptFooter,
  }) {
    return TenantProfile(
      id: id,
      displayName: displayName ?? this.displayName,
      legalName: legalName ?? this.legalName,
      currencyCode: currencyCode ?? this.currencyCode,
      logoUrl: logoUrl ?? this.logoUrl,
      address: address ?? this.address,
      phone: phone ?? this.phone,
      phoneNumbers: phoneNumbers ?? this.phoneNumbers,
      receiptFooter: receiptFooter ?? this.receiptFooter,
    );
  }

  Map<String, Object?> toMap() => {
    'displayName': displayName,
    'legalName': legalName,
    'currencyCode': currencyCode,
    'logoUrl': logoUrl,
    'address': address,
    'phone': primaryPhone,
    'phoneNumbers': phoneNumbers.take(3).toList(growable: false),
    'receiptFooter': receiptFooter,
  };
}

class Venue {
  const Venue({
    required this.id,
    required this.tenantId,
    required this.name,
    required this.timeZone,
    this.notificationRetentionSeconds = 5,
    this.backgroundLockSeconds = 120,
    int orderFlowAmberMinutes = 15,
    int orderFlowRedMinutes = 25,
    int defaultBookingDurationMinutes = 120,
    int businessDayCutoffMinutes = 240,
    this.defaultThemeMode = 'light',
    this.pendingBusinessDayCutoffMinutes,
    this.pendingBusinessDayCutoffEffectiveDate,
    this.receiptName = '',
    this.address = '',
    this.phoneNumbers = const [],
    this.receiptFooter = '',
  }) : _orderFlowAmberMinutes = orderFlowAmberMinutes,
       _orderFlowRedMinutes = orderFlowRedMinutes,
       _defaultBookingDurationMinutes = defaultBookingDurationMinutes,
       _businessDayCutoffMinutes = businessDayCutoffMinutes;

  final String id;
  final String tenantId;
  final String name;
  final String timeZone;
  final int notificationRetentionSeconds;
  final int backgroundLockSeconds;
  final String defaultThemeMode;

  /// Optional venue-specific receipt details. Empty values inherit the company.
  final String receiptName;
  final String address;
  final List<String> phoneNumbers;
  final String receiptFooter;

  // Nullable backing fields deliberately protect a running debug session
  // whose Venue instances pre-date these fields after a hot reload. Existing
  // Firestore venue documents are also mapped to the same safe defaults.
  final int? _orderFlowAmberMinutes;
  final int? _orderFlowRedMinutes;
  final int? _defaultBookingDurationMinutes;
  final int? _businessDayCutoffMinutes;
  final int? pendingBusinessDayCutoffMinutes;
  final String? pendingBusinessDayCutoffEffectiveDate;

  int get orderFlowAmberMinutes => _orderFlowAmberMinutes ?? 15;
  int get orderFlowRedMinutes => _orderFlowRedMinutes ?? 25;
  int get defaultBookingDurationMinutes =>
      _defaultBookingDurationMinutes ?? 120;
  int get businessDayCutoffMinutes => _businessDayCutoffMinutes ?? 240;
}

class SalesReportPayment {
  const SalesReportPayment({
    required this.method,
    required this.currencyCode,
    required this.tenderedAmountMinor,
    required this.baseAmountMinor,
    this.terminalLabel,
  });

  final String method;
  final String currencyCode;
  final int tenderedAmountMinor;
  final int baseAmountMinor;
  final String? terminalLabel;
}

class SalesReportLine {
  const SalesReportLine({
    required this.productId,
    required this.productName,
    required this.quantity,
    required this.grossMinor,
  });

  final String productId;
  final String productName;
  final int quantity;
  final int grossMinor;
}

class SalesReportTaxEntry {
  const SalesReportTaxEntry({
    required this.name,
    required this.basisPoints,
    required this.grossMinor,
    required this.netMinor,
    required this.taxMinor,
  });

  final String name;
  final int basisPoints;
  final int grossMinor;
  final int netMinor;
  final int taxMinor;
}

/// Immutable financial snapshot produced only when the trusted close-order
/// command succeeds. Reports aggregate these snapshots and never recalculate
/// historic tax or prices from the current menu.
class SalesReportBill {
  const SalesReportBill({
    required this.id,
    required this.receiptNumber,
    required this.venueId,
    required this.businessDate,
    required this.currencyCode,
    required this.grossMinor,
    required this.netMinor,
    required this.taxMinor,
    required this.payments,
    required this.lines,
    required this.taxBreakdown,
    this.closedByName = '',
  });

  final String id;
  final String receiptNumber;
  final String venueId;
  final DateTime businessDate;
  final String currencyCode;
  final int grossMinor;
  final int netMinor;
  final int taxMinor;
  final List<SalesReportPayment> payments;
  final List<SalesReportLine> lines;
  final List<SalesReportTaxEntry> taxBreakdown;
  final String closedByName;
}

class TenantMembership {
  const TenantMembership({
    required this.tenantId,
    required this.userId,
    required this.roles,
    this.defaultVenueId,
  });

  final String tenantId;
  final String userId;
  final List<String> roles;
  final String? defaultVenueId;

  bool get canManageMenu =>
      roles.contains('owner') || roles.contains('manager');
}

class MenuSection {
  const MenuSection({
    required this.id,
    required this.name,
    required this.icon,
    this.parentSectionId,
    this.sortOrder = 0,
  });

  final String id;
  final String name;
  final String icon;
  final String? parentSectionId;
  final int sortOrder;
}

/// A venue-owned reusable, tax-inclusive sales rate. The product also stores
/// a snapshot of its selected rate so historic orders cannot change when a
/// manager later edits the tax setup.
class TaxRate {
  const TaxRate({
    required this.id,
    required this.name,
    required this.basisPoints,
    this.active = true,
  });

  static const zero = TaxRate(
    id: 'zero-rate',
    name: 'Zero Rate',
    basisPoints: 0,
  );

  final String id;
  final String name;
  final int basisPoints;
  final bool active;

  String get percentageLabel {
    final percent = basisPoints / 100;
    return percent == percent.roundToDouble()
        ? '${percent.toStringAsFixed(0)}%'
        : '${percent.toStringAsFixed(2)}%';
  }
}

/// A named sellable form of a product, such as Small/Large or Glass/Bottle.
/// The base product price is adjusted by [priceDeltaMinor]; this keeps every
/// variant tax-inclusive and makes the server the final price authority.
class MenuProductVariant {
  const MenuProductVariant({
    required this.id,
    required this.name,
    this.priceDeltaMinor = 0,
    this.isAvailable = true,
    this.stockComponents = const <ProductStockComponent>[],
  });

  final String id;
  final String name;
  final int priceDeltaMinor;
  final bool isAvailable;
  final List<ProductStockComponent> stockComponents;
}

/// A stock-tracked ingredient consumed when one sellable product is sent to
/// production. Quantities use the component product's base unit (for example
/// 50 ml vodka and 333 ml mixer).
class ProductStockComponent {
  const ProductStockComponent({
    required this.productId,
    required this.productName,
    required this.quantityPerSale,
    required this.stockUnit,
    this.stockOnHand,
    this.latestUnitCostMinor,
  });

  final String productId;
  final String productName;
  final double quantityPerSale;
  final String stockUnit;
  final double? stockOnHand;
  final double? latestUnitCostMinor;
}

/// One selectable option inside a venue's reusable modifier group.
class MenuModifierOption {
  const MenuModifierOption({
    required this.id,
    required this.name,
    this.priceDeltaMinor = 0,
    this.isAvailable = true,
    this.stockComponents = const <ProductStockComponent>[],
  });

  final String id;
  final String name;
  final int priceDeltaMinor;
  final bool isAvailable;
  final List<ProductStockComponent> stockComponents;
}

/// Reusable choices such as "Cooking preference", "Spice level" or "Ice".
/// A product stores only the group IDs, so one venue-wide change is reflected
/// on every attached product while historic order lines keep their snapshot.
class MenuModifierGroup {
  const MenuModifierGroup({
    required this.id,
    required this.name,
    required this.minimumSelections,
    required this.maximumSelections,
    required this.options,
    this.isAvailable = true,
  });

  final String id;
  final String name;
  final int minimumSelections;
  final int maximumSelections;
  final List<MenuModifierOption> options;
  final bool isAvailable;

  bool get isRequired => minimumSelections > 0;
}

/// An immutable, priced option snapshot recorded on a draft/order line.
class OrderModifierSelection {
  const OrderModifierSelection({
    required this.groupId,
    required this.groupName,
    required this.optionId,
    required this.optionName,
    this.priceDeltaMinor = 0,
    this.stockComponents = const <ProductStockComponent>[],
  });

  final String groupId;
  final String groupName;
  final String optionId;
  final String optionName;
  final int priceDeltaMinor;
  final List<ProductStockComponent> stockComponents;

  String get displayLabel => '$groupName: $optionName';
}

/// The product chooser returns this typed selection before the order line is
/// sent to Firebase for independent canonical validation and pricing.
class ProductConfigurationSelection {
  const ProductConfigurationSelection({
    this.variant,
    this.modifiers = const <OrderModifierSelection>[],
    this.itemNote = '',
  });

  final MenuProductVariant? variant;
  final List<OrderModifierSelection> modifiers;
  final String itemNote;

  int get priceDeltaMinor =>
      (variant?.priceDeltaMinor ?? 0) +
      modifiers.fold(0, (total, modifier) => total + modifier.priceDeltaMinor);
}

class MenuProduct {
  const MenuProduct({
    required this.id,
    required this.name,
    required this.priceMinor,
    required this.sectionIds,
    required this.productionArea,
    this.trackStock = false,
    this.stockOnHand,
    this.stockUnit = 'each',
    this.stockPerSale = 1,
    this.lowStockThreshold = 0,
    this.storageLocation = '',
    this.targetMarginBasisPoints = 0,
    this.latestUnitCostMinor,
    this.isAvailable = true,
    this.isArchived = false,
    this.showOnOrderFlow = true,
    this.taxRateBasisPoints = 0,
    this.taxRateId,
    this.taxRateName = 'Zero rate',
    this.variants = const <MenuProductVariant>[],
    this.modifierGroupIds = const <String>[],
    this.stockComponents = const <ProductStockComponent>[],
    this.imageUrl,
    this.imageStoragePath,
  });

  final String id;
  final String name;
  final int priceMinor;
  final List<String> sectionIds;
  final ProductionArea productionArea;
  final bool trackStock;
  final double? stockOnHand;
  final String stockUnit;
  final double stockPerSale;
  final double lowStockThreshold;
  final String storageLocation;
  final int targetMarginBasisPoints;
  final double? latestUnitCostMinor;
  final bool isAvailable;
  final bool isArchived;

  /// Drinks can still print to the bar while being omitted from the live
  /// kitchen/manager flow board.
  final bool showOnOrderFlow;

  /// Tax percentage in basis points: 2,000 represents 20.00%. Menu prices
  /// are tax-inclusive, so this rate derives the net and tax portions only
  /// when the server creates an immutable bill.
  final int taxRateBasisPoints;
  final String? taxRateId;
  final String taxRateName;
  final List<MenuProductVariant> variants;
  final List<String> modifierGroupIds;
  final List<ProductStockComponent> stockComponents;
  final String? imageUrl;
  final String? imageStoragePath;

  double? get estimatedCostMinor {
    if (stockComponents.isNotEmpty) {
      if (stockComponents.any((item) => item.latestUnitCostMinor == null)) {
        return null;
      }
      return stockComponents.fold<double>(
        0,
        (total, item) =>
            total + item.quantityPerSale * item.latestUnitCostMinor!,
      );
    }
    return latestUnitCostMinor == null
        ? null
        : latestUnitCostMinor! * stockPerSale;
  }

  double? get estimatedMarginPercent {
    final cost = estimatedCostMinor;
    if (cost == null || priceMinor <= 0) return null;
    // Menu prices are tax-inclusive. Gross margin must compare ingredient cost
    // with net sales, otherwise a higher tax rate falsely improves margin.
    final netSellingMinor = priceMinor * 10000 / (10000 + taxRateBasisPoints);
    if (netSellingMinor <= 0) return null;
    return ((netSellingMinor - cost) / netSellingMinor) * 100;
  }

  bool get isBelowTargetMargin {
    final margin = estimatedMarginPercent;
    return targetMarginBasisPoints > 0 &&
        margin != null &&
        margin < targetMarginBasisPoints / 100;
  }

  bool get requiresConfiguration =>
      variants.isNotEmpty || modifierGroupIds.isNotEmpty;

  bool get hasIngredientStockAvailable => stockComponents.every(
    (component) =>
        component.stockOnHand != null &&
        component.stockOnHand! >= component.quantityPerSale,
  );

  String get taxRateLabel {
    final percent = taxRateBasisPoints / 100;
    final percentage = percent == percent.roundToDouble()
        ? '${percent.toStringAsFixed(0)}%'
        : '${percent.toStringAsFixed(2)}%';
    return '$taxRateName ($percentage)';
  }
}

class DiningTable {
  const DiningTable({
    required this.id,
    required this.label,
    required this.seats,
    this.hasOpenOrder = false,
    this.currentOrderId,
  });

  final String id;
  final String label;
  final int seats;
  final bool hasOpenOrder;

  /// The server-owned open order for this table, if one exists.  The POS uses
  /// this identifier to stream the live total directly on the table tile.
  final String? currentOrderId;
}

/// A venue-local customer-name tab. Its server-created registry is what makes
/// a name unique while that tab remains open.
class OpenNamedTab {
  const OpenNamedTab({
    required this.id,
    required this.orderId,
    required this.name,
    this.openedAt,
  });

  final String id;
  final String orderId;
  final String name;
  final DateTime? openedAt;
}

class OrderLine {
  const OrderLine({
    required this.id,
    required this.productId,
    required this.productName,
    required this.quantity,
    required this.unitPriceMinor,
    required this.productionArea,
    required this.trackStock,
    this.stockPerSale = 1,
    this.isSentToProduction = false,
    this.taxRateBasisPoints = 0,
    this.taxRateId,
    this.taxRateName = 'Zero rate',
    this.variantId,
    this.variantName,
    this.variantPriceDeltaMinor = 0,
    this.modifiers = const <OrderModifierSelection>[],
    this.itemNote = '',
    this.stockComponents = const <ProductStockComponent>[],
  });

  final String id;
  final String productId;
  final String productName;
  final int quantity;
  final int unitPriceMinor;
  final ProductionArea productionArea;
  final bool trackStock;
  final double stockPerSale;
  final bool isSentToProduction;
  final int taxRateBasisPoints;
  final String? taxRateId;
  final String taxRateName;
  final String? variantId;
  final String? variantName;
  final int variantPriceDeltaMinor;
  final List<OrderModifierSelection> modifiers;
  final String itemNote;
  final List<ProductStockComponent> stockComponents;

  int get totalMinor => quantity * unitPriceMinor;

  /// Kitchen-safe detail lines, excluding any money. These are also used in
  /// the POS basket so a waiter can verify a guest's choices before sending.
  List<String> get productionDetails => [
    if (variantName?.trim().isNotEmpty == true) variantName!.trim(),
    ...modifiers.map((modifier) => modifier.displayLabel),
    if (itemNote.trim().isNotEmpty) 'NOTE: ${itemNote.trim()}',
  ];

  String get receiptDescription =>
      [productName, ...productionDetails].join('\n');

  OrderLine copyWith({int? quantity, bool? isSentToProduction}) => OrderLine(
    id: id,
    productId: productId,
    productName: productName,
    quantity: quantity ?? this.quantity,
    unitPriceMinor: unitPriceMinor,
    productionArea: productionArea,
    trackStock: trackStock,
    stockPerSale: stockPerSale,
    isSentToProduction: isSentToProduction ?? this.isSentToProduction,
    taxRateBasisPoints: taxRateBasisPoints,
    taxRateId: taxRateId,
    taxRateName: taxRateName,
    variantId: variantId,
    variantName: variantName,
    variantPriceDeltaMinor: variantPriceDeltaMinor,
    modifiers: modifiers,
    itemNote: itemNote,
    stockComponents: stockComponents,
  );
}

class PosOrder {
  const PosOrder({
    required this.id,
    required this.tenantId,
    required this.venueId,
    required this.businessDate,
    required this.openedAt,
    required this.status,
    required this.lines,
    this.tableId,
    this.tabName,
    this.isCustomerOriginated = false,
    this.splitFromOrderId,
    this.splitSequence,
    this.openSplitOrderIds = const <String>[],
  });

  final String id;
  final String tenantId;
  final String venueId;
  final String? tableId;
  final String? tabName;
  final DateTime businessDate;
  final DateTime openedAt;
  final OrderStatus status;
  final List<OrderLine> lines;
  final bool isCustomerOriginated;

  /// A payment-only child created from a table/name bill. It inherits the
  /// production-safe item snapshots but must never print those items again.
  final String? splitFromOrderId;
  final int? splitSequence;

  /// The parent order cannot close until these separately payable child bills
  /// have all been settled. This prevents a table being freed too early.
  final List<String> openSplitOrderIds;

  bool get isSplitOrder => splitFromOrderId?.trim().isNotEmpty == true;

  int get totalMinor => lines.fold(0, (total, line) => total + line.totalMinor);

  /// Stock is reserved as soon as an item is added to this order, rather than
  /// waiting until the waiter presses Send.  This is deliberately limited to
  /// local, unsent lines: once an item is sent, the product's Firestore stock
  /// stream becomes the source of truth for every device.
  double unsentStockReservedFor(String productId) => lines
      .where((line) => !line.isSentToProduction)
      .fold<double>(0, (reserved, line) {
        final componentUse = line.stockComponents
            .where((component) => component.productId == productId)
            .fold<double>(
              0,
              (total, component) =>
                  total + line.quantity * component.quantityPerSale,
            );
        final directUse =
            line.stockComponents.isEmpty &&
                line.productId == productId &&
                line.trackStock
            ? line.quantity * line.stockPerSale
            : 0;
        return reserved + componentUse + directUse;
      });

  /// Returns whether one more unit of [product] may be added locally.
  ///
  /// The Cloud Function performs the same validation in its transaction. This
  /// UI guard prevents an obvious over-sale in a single basket; the server
  /// still protects against another device selling the final unit first.
  bool canAddProduct(MenuProduct product) {
    if (!product.isAvailable) return false;
    if (product.stockComponents.isNotEmpty) {
      return product.stockComponents.every(
        (component) =>
            component.stockOnHand != null &&
            component.stockOnHand! -
                    unsentStockReservedFor(component.productId) >=
                component.quantityPerSale,
      );
    }
    if (!product.trackStock) return true;
    final stockOnHand = product.stockOnHand;
    if (stockOnHand == null || product.stockPerSale <= 0) return false;
    return stockOnHand - unsentStockReservedFor(product.id) >=
        product.stockPerSale;
  }

  PosOrder copyWith({
    String? id,
    String? tableId,
    String? tabName,
    OrderStatus? status,
    List<OrderLine>? lines,
    bool? isCustomerOriginated,
    String? splitFromOrderId,
    int? splitSequence,
    List<String>? openSplitOrderIds,
  }) {
    return PosOrder(
      id: id ?? this.id,
      tenantId: tenantId,
      venueId: venueId,
      tableId: tableId ?? this.tableId,
      tabName: tabName ?? this.tabName,
      businessDate: businessDate,
      openedAt: openedAt,
      status: status ?? this.status,
      lines: lines ?? this.lines,
      isCustomerOriginated: isCustomerOriginated ?? this.isCustomerOriginated,
      splitFromOrderId: splitFromOrderId ?? this.splitFromOrderId,
      splitSequence: splitSequence ?? this.splitSequence,
      openSplitOrderIds: openSplitOrderIds ?? this.openSplitOrderIds,
    );
  }
}

class PrintJob {
  const PrintJob({
    required this.id,
    required this.tenantId,
    required this.venueId,
    required this.targetDeviceId,
    required this.orderId,
    required this.status,
    required this.idempotencyKey,
    required this.createdAt,
    this.ticketId,
    this.productionArea,
    this.claimedByDeviceId,
    this.fallbackDeviceId,
    this.fallbackFromJobId,
    this.fallbackDeliveryStatus,
    this.failureReason,
    this.claimedAt,
    this.completedAt,
    this.attempts = 0,
    this.payload = const {},
  });

  final String id;
  final String tenantId;
  final String venueId;
  final String targetDeviceId;
  final String orderId;
  final PrintJobStatus status;
  final String idempotencyKey;
  final DateTime createdAt;
  final String? ticketId;
  final String? productionArea;
  final String? claimedByDeviceId;
  final String? fallbackDeviceId;
  final String? fallbackFromJobId;
  final String? fallbackDeliveryStatus;
  final String? failureReason;
  final DateTime? claimedAt;
  final DateTime? completedAt;
  final int attempts;
  final Map<String, Object?> payload;
}

enum PaymentMethod { cash, cardTerminal, voucher, online }

bool productNameStartsWith(MenuProduct product, String rawQuery) {
  final query = rawQuery.trim().toLowerCase();
  if (query.isEmpty) return true;
  return product.name
      .toLowerCase()
      .split(RegExp(r'[\s\-_/,().]+'))
      .any((word) => word.startsWith(query));
}

bool productMatchesMenuSearch(
  MenuProduct product,
  Iterable<MenuSection> sections,
  String rawQuery,
) {
  final terms = rawQuery
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty);
  if (terms.isEmpty) return true;
  final sectionNames = sections
      .where((section) => product.sectionIds.contains(section.id))
      .map((section) => section.name)
      .join(' ');
  final searchableValue = '${product.name} $sectionNames'.toLowerCase();
  return terms.every(searchableValue.contains);
}

/// Checkout policy kept outside the widget so a merge cannot silently remove
/// the supported foreign cash tenders without breaking a regression test.
List<String> checkoutTenderCurrencies(String baseCurrencyCode) => <String>{
  baseCurrencyCode.trim().toUpperCase(),
  'TRY',
  'EUR',
  'GBP',
  'USD',
}.toList(growable: false);

/// Restaurants normally issue a paid receipt. A user may opt out for an
/// individual payment, but every newly opened checkout starts selected.
const defaultPrintPaidReceipt = true;

enum PaymentRequestStatus {
  requested,
  awaitingTerminal,
  paid,
  failed,
  cancelled,
}

class PaymentRequest {
  const PaymentRequest({
    required this.id,
    required this.tenantId,
    required this.venueId,
    required this.billId,
    required this.amountMinor,
    required this.currencyCode,
    required this.method,
    required this.status,
    required this.idempotencyKey,
    this.terminalId,
  });

  final String id;
  final String tenantId;
  final String venueId;
  final String billId;
  final int amountMinor;

  /// The bill's functional currency, not a guest's foreign cash tender.
  final String currencyCode;
  final PaymentMethod method;
  final PaymentRequestStatus status;
  final String idempotencyKey;
  final String? terminalId;
}

const demoTenant = TenantProfile(
  id: 'tenant_demo',
  displayName: 'TableSide Hospitality',
  legalName: 'TableSide Hospitality Ltd',
  currencyCode: 'GBP',
  address: '12 Market Street, Manchester',
  phone: '+44 161 555 0100',
  receiptFooter: 'Thank you for dining with us.',
);

const demoVenue = Venue(
  id: 'venue_market_street',
  tenantId: 'tenant_demo',
  name: 'Market Street',
  timeZone: 'Europe/London',
);

const demoSections = [
  MenuSection(id: 'drinks', name: 'Drinks', icon: '🥤'),
  MenuSection(id: 'alcohol', name: 'Alcohol', icon: '🍷'),
  MenuSection(id: 'starters', name: 'Starters', icon: '🥗'),
  MenuSection(id: 'mains', name: 'Main courses', icon: '🍽️'),
  MenuSection(id: 'european', name: 'European', icon: '🇪🇺'),
  MenuSection(id: 'desserts', name: 'Desserts', icon: '🍰'),
];

const demoProducts = [
  MenuProduct(
    id: 'sparkling-water',
    name: 'Sparkling water',
    priceMinor: 275,
    sectionIds: ['drinks'],
    productionArea: ProductionArea.bar,
    trackStock: true,
    stockOnHand: 36,
  ),
  MenuProduct(
    id: 'house-red',
    name: 'House red, glass',
    priceMinor: 650,
    sectionIds: ['drinks', 'alcohol'],
    productionArea: ProductionArea.bar,
    trackStock: true,
    stockOnHand: 24,
  ),
  MenuProduct(
    id: 'burrata',
    name: 'Heritage tomato burrata',
    priceMinor: 895,
    sectionIds: ['starters', 'european'],
    productionArea: ProductionArea.kitchen,
    trackStock: true,
    stockOnHand: 8,
  ),
  MenuProduct(
    id: 'sea-bass',
    name: 'Pan-roasted sea bass',
    priceMinor: 1895,
    sectionIds: ['mains', 'european'],
    productionArea: ProductionArea.kitchen,
  ),
  MenuProduct(
    id: 'cheesecake',
    name: 'Basque cheesecake',
    priceMinor: 775,
    sectionIds: ['desserts'],
    productionArea: ProductionArea.kitchen,
    trackStock: true,
    stockOnHand: 5,
  ),
];

const demoTables = [
  DiningTable(id: 'table-1', label: 'T1', seats: 2),
  DiningTable(id: 'table-2', label: 'T2', seats: 2, hasOpenOrder: true),
  DiningTable(id: 'table-3', label: 'T3', seats: 4),
  DiningTable(id: 'table-4', label: 'T4', seats: 4, hasOpenOrder: true),
  DiningTable(id: 'table-5', label: 'T5', seats: 6),
  DiningTable(id: 'table-6', label: 'T6', seats: 2),
  DiningTable(id: 'bar-1', label: 'B1', seats: 2, hasOpenOrder: true),
  DiningTable(id: 'terrace-1', label: 'A1', seats: 4),
];

final demoOrderFlow = [
  OrderFlowOrder(
    id: 'flow-1024-kitchen',
    tenantId: demoTenant.id,
    venueId: demoVenue.id,
    reference: '1024',
    tableLabel: 'T2',
    productionArea: ProductionArea.kitchen,
    status: OrderFlowStatus.preparing,
    ticketReleasedAt: DateTime.now().subtract(const Duration(minutes: 11)),
    itemSummary: const ['2 × Sea bass', '1 × Burrata'],
    createdByName: 'Jamie',
    hasAllergyAlert: true,
    note: 'Allergy alert: no dairy on burrata.',
  ),
  OrderFlowOrder(
    id: 'flow-1024-bar',
    tenantId: demoTenant.id,
    venueId: demoVenue.id,
    reference: '1024',
    tableLabel: 'T2',
    productionArea: ProductionArea.bar,
    status: OrderFlowStatus.ready,
    ticketReleasedAt: DateTime.now().subtract(const Duration(minutes: 4)),
    itemSummary: const ['2 × House red, glass'],
    createdByName: 'Jamie',
  ),
  OrderFlowOrder(
    id: 'flow-1022-kitchen',
    tenantId: demoTenant.id,
    venueId: demoVenue.id,
    reference: '1022',
    tableLabel: 'T4',
    productionArea: ProductionArea.kitchen,
    status: OrderFlowStatus.newOrder,
    ticketReleasedAt: DateTime.now().subtract(const Duration(minutes: 27)),
    itemSummary: const ['2 × Basque cheesecake'],
    createdByName: 'Sam',
    isDelayed: true,
  ),
  OrderFlowOrder(
    id: 'flow-1021-bar',
    tenantId: demoTenant.id,
    venueId: demoVenue.id,
    reference: '1021',
    tabName: 'John N',
    productionArea: ProductionArea.bar,
    status: OrderFlowStatus.collected,
    ticketReleasedAt: DateTime.now().subtract(const Duration(minutes: 18)),
    itemSummary: const ['1 × Sparkling water'],
    createdByName: 'Alex',
  ),
];
