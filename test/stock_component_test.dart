import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/features/pos/domain.dart';

void main() {
  const vodka = ProductStockComponent(
    productId: 'vodka',
    productName: 'Vodka',
    quantityPerSale: 50,
    stockUnit: 'ml',
    stockOnHand: 100,
  );
  const mixer = ProductStockComponent(
    productId: 'mixer',
    productName: 'Mixer',
    quantityPerSale: 333,
    stockUnit: 'ml',
    stockOnHand: 666,
  );
  const drink = MenuProduct(
    id: 'vodka-mixer',
    name: 'Vodka with mixer',
    priceMinor: 800,
    sectionIds: ['drinks'],
    productionArea: ProductionArea.bar,
    stockComponents: [vodka, mixer],
  );

  test('component stock controls sellable recipe availability', () {
    final order = PosOrder(
      id: 'order',
      tenantId: 'tenant',
      venueId: 'venue',
      businessDate: DateTime(2026, 8, 31),
      openedAt: DateTime(2026, 8, 31),
      status: OrderStatus.open,
      lines: const [],
    );
    expect(order.canAddProduct(drink), isTrue);
  });

  test('unsent recipe lines reserve every component', () {
    final order = PosOrder(
      id: 'order',
      tenantId: 'tenant',
      venueId: 'venue',
      businessDate: DateTime(2026, 8, 31),
      openedAt: DateTime(2026, 8, 31),
      status: OrderStatus.open,
      lines: const [
        OrderLine(
          id: 'line',
          productId: 'vodka-mixer',
          productName: 'Vodka with mixer',
          quantity: 2,
          unitPriceMinor: 800,
          productionArea: ProductionArea.bar,
          trackStock: false,
          stockComponents: [vodka, mixer],
        ),
      ],
    );
    expect(order.unsentStockReservedFor('vodka'), 100);
    expect(order.unsentStockReservedFor('mixer'), 666);
    expect(order.canAddProduct(drink), isFalse);
  });
}
