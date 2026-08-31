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

  test('recipe cost and target margin use tax-exclusive sales value', () {
    const costedVodka = ProductStockComponent(
      productId: 'vodka',
      productName: 'Vodka',
      quantityPerSale: 50,
      stockUnit: 'ml',
      latestUnitCostMinor: 2,
    );
    const costedMixer = ProductStockComponent(
      productId: 'mixer',
      productName: 'Mixer',
      quantityPerSale: 1,
      stockUnit: 'each',
      latestUnitCostMinor: 100,
    );
    const product = MenuProduct(
      id: 'costed-drink',
      name: 'Vodka mixer',
      priceMinor: 600,
      sectionIds: ['drinks'],
      productionArea: ProductionArea.bar,
      taxRateBasisPoints: 2000,
      targetMarginBasisPoints: 6500,
      stockComponents: [costedVodka, costedMixer],
    );

    expect(product.estimatedCostMinor, 200);
    expect(product.estimatedMarginPercent, closeTo(60, 0.001));
    expect(product.isBelowTargetMargin, isTrue);
  });
}
