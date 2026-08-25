import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/features/pos/domain.dart';

void main() {
  const product = MenuProduct(
    id: 'stocked-product',
    name: 'Stocked product',
    priceMinor: 500,
    sectionIds: ['mains'],
    productionArea: ProductionArea.kitchen,
    trackStock: true,
    stockOnHand: 2,
    stockPerSale: 1,
  );

  PosOrder orderWithLines(List<OrderLine> lines) => PosOrder(
    id: 'order-1',
    tenantId: 'tenant-1',
    venueId: 'venue-1',
    businessDate: DateTime(2026, 8, 25),
    openedAt: DateTime(2026, 8, 25),
    status: OrderStatus.open,
    lines: lines,
  );

  test('stock is reserved by unsent basket lines', () {
    final order = orderWithLines(const [
      OrderLine(
        id: 'line-1',
        productId: 'stocked-product',
        productName: 'Stocked product',
        quantity: 2,
        unitPriceMinor: 500,
        productionArea: ProductionArea.kitchen,
        trackStock: true,
      ),
    ]);

    expect(order.unsentStockReservedFor(product.id), 2);
    expect(order.canAddProduct(product), isFalse);
  });

  test('sent lines use the live product stock instead of reserving twice', () {
    final order = orderWithLines(const [
      OrderLine(
        id: 'line-1',
        productId: 'stocked-product',
        productName: 'Stocked product',
        quantity: 2,
        unitPriceMinor: 500,
        productionArea: ProductionArea.kitchen,
        trackStock: true,
        isSentToProduction: true,
      ),
    ]);

    expect(order.unsentStockReservedFor(product.id), 0);
    expect(order.canAddProduct(product), isTrue);
  });
}
