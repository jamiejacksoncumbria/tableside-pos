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

enum PrintJobStatus { queued, claimed, printed, failed }

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
  });

  final String id;
  final String tenantId;
  final String name;
  final String timeZone;
  final int notificationRetentionSeconds;
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
  });

  final String id;
  final String name;
  final String icon;
  final String? parentSectionId;
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
    this.isAvailable = true,
    this.showOnOrderFlow = true,
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
  final bool isAvailable;

  /// Drinks can still print to the bar while being omitted from the live
  /// kitchen/manager flow board.
  final bool showOnOrderFlow;
}

class DiningTable {
  const DiningTable({
    required this.id,
    required this.label,
    required this.seats,
    this.hasOpenOrder = false,
  });

  final String id;
  final String label;
  final int seats;
  final bool hasOpenOrder;
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

  int get totalMinor => quantity * unitPriceMinor;

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

  int get totalMinor => lines.fold(0, (total, line) => total + line.totalMinor);

  /// Stock is reserved as soon as an item is added to this order, rather than
  /// waiting until the waiter presses Send.  This is deliberately limited to
  /// local, unsent lines: once an item is sent, the product's Firestore stock
  /// stream becomes the source of truth for every device.
  double unsentStockReservedFor(String productId) => lines
      .where(
        (line) =>
            line.productId == productId &&
            line.trackStock &&
            !line.isSentToProduction,
      )
      .fold<double>(
        0,
        (reserved, line) => reserved + (line.quantity * line.stockPerSale),
      );

  /// Returns whether one more unit of [product] may be added locally.
  ///
  /// The Cloud Function performs the same validation in its transaction. This
  /// UI guard prevents an obvious over-sale in a single basket; the server
  /// still protects against another device selling the final unit first.
  bool canAddProduct(MenuProduct product) {
    if (!product.isAvailable) return false;
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
    this.claimedByDeviceId,
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
  final String? claimedByDeviceId;
  final int attempts;
  final Map<String, Object?> payload;
}

enum PaymentMethod { cash, cardTerminal, online }

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
