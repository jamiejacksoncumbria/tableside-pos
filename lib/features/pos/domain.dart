enum OrderStatus { open, pendingApproval, sent, closed, rolledOver }

enum ProductionArea { bar, kitchen }

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
    this.receiptFooter = '',
  });

  final String id;
  final String displayName;
  final String legalName;
  final String currencyCode;
  final String? logoUrl;
  final String address;
  final String phone;
  final String receiptFooter;

  TenantProfile copyWith({
    String? displayName,
    String? legalName,
    String? currencyCode,
    String? logoUrl,
    String? address,
    String? phone,
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
      receiptFooter: receiptFooter ?? this.receiptFooter,
    );
  }

  Map<String, Object?> toMap() => {
    'displayName': displayName,
    'legalName': legalName,
    'currencyCode': currencyCode,
    'logoUrl': logoUrl,
    'address': address,
    'phone': phone,
    'receiptFooter': receiptFooter,
  };
}

class Venue {
  const Venue({
    required this.id,
    required this.tenantId,
    required this.name,
    required this.timeZone,
  });

  final String id;
  final String tenantId;
  final String name;
  final String timeZone;
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
  const MenuSection({required this.id, required this.name, required this.icon});

  final String id;
  final String name;
  final String icon;
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
    this.isAvailable = true,
  });

  final String id;
  final String name;
  final int priceMinor;
  final List<String> sectionIds;
  final ProductionArea productionArea;
  final bool trackStock;
  final int? stockOnHand;
  final bool isAvailable;
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

class OrderLine {
  const OrderLine({
    required this.id,
    required this.productId,
    required this.productName,
    required this.quantity,
    required this.unitPriceMinor,
    required this.productionArea,
    required this.trackStock,
  });

  final String id;
  final String productId;
  final String productName;
  final int quantity;
  final int unitPriceMinor;
  final ProductionArea productionArea;
  final bool trackStock;

  int get totalMinor => quantity * unitPriceMinor;

  OrderLine copyWith({int? quantity}) => OrderLine(
    id: id,
    productId: productId,
    productName: productName,
    quantity: quantity ?? this.quantity,
    unitPriceMinor: unitPriceMinor,
    productionArea: productionArea,
    trackStock: trackStock,
  );
}

class PosOrder {
  const PosOrder({
    required this.id,
    required this.tenantId,
    required this.venueId,
    required this.tableId,
    required this.businessDate,
    required this.openedAt,
    required this.status,
    required this.lines,
    this.isCustomerOriginated = false,
  });

  final String id;
  final String tenantId;
  final String venueId;
  final String tableId;
  final DateTime businessDate;
  final DateTime openedAt;
  final OrderStatus status;
  final List<OrderLine> lines;
  final bool isCustomerOriginated;

  int get totalMinor => lines.fold(0, (total, line) => total + line.totalMinor);

  PosOrder copyWith({
    OrderStatus? status,
    List<OrderLine>? lines,
    bool? isCustomerOriginated,
  }) {
    return PosOrder(
      id: id,
      tenantId: tenantId,
      venueId: venueId,
      tableId: tableId,
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
