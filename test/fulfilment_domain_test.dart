import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/features/pos/domain.dart';

void main() {
  const product = MenuProduct(
    id: 'product-a',
    name: 'Chicken Curry',
    priceMinor: 1200,
    sectionIds: <String>['mains'],
    productionArea: ProductionArea.kitchen,
    collectionPriceMinor: 1100,
    deliveryPriceMinor: 1350,
  );

  test('channel prices inherit or use their explicit override', () {
    expect(product.priceFor(OrderChannel.dineIn), 1200);
    expect(product.priceFor(OrderChannel.collection), 1100);
    expect(product.priceFor(OrderChannel.delivery), 1350);

    const inherited = MenuProduct(
      id: 'product-b',
      name: 'Rice',
      priceMinor: 300,
      sectionIds: <String>['sides'],
      productionArea: ProductionArea.kitchen,
    );
    expect(inherited.priceFor(OrderChannel.collection), 300);
    expect(inherited.priceFor(OrderChannel.delivery), 300);
  });

  test('channel availability is fail-closed without hiding dine-in', () {
    const collectionOnly = MenuProduct(
      id: 'product-c',
      name: 'Collection Special',
      priceMinor: 900,
      sectionIds: <String>['specials'],
      productionArea: ProductionArea.kitchen,
      availableForCollection: true,
      availableForDelivery: false,
    );
    expect(collectionOnly.isAvailableFor(OrderChannel.dineIn), isTrue);
    expect(collectionOnly.isAvailableFor(OrderChannel.collection), isTrue);
    expect(collectionOnly.isAvailableFor(OrderChannel.delivery), isFalse);
  });

  test('delivery fee is included once in the reporting-currency total', () {
    final order = PosOrder(
      id: 'delivery-1',
      tenantId: 'tenant',
      venueId: 'venue',
      businessDate: DateTime(2026, 9, 23),
      openedAt: DateTime(2026, 9, 23, 18),
      status: OrderStatus.open,
      channel: OrderChannel.delivery,
      serviceAreaId: 'girne',
      serviceAreaName: 'Girne',
      deliveryFeeMinor: 15000,
      lines: const <OrderLine>[
        OrderLine(
          id: 'line-1',
          productId: 'product-a',
          productName: 'Chicken Curry',
          quantity: 1,
          unitPriceMinor: 80000,
          productionArea: ProductionArea.kitchen,
          trackStock: false,
        ),
      ],
    );

    expect(order.totalMinor, 95000);
  });
}
