import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/features/pos/domain.dart';

void main() {
  const product = MenuProduct(
    id: 'efes-draught',
    name: 'Efes Draught',
    priceMinor: 15000,
    sectionIds: <String>['beer'],
    productionArea: ProductionArea.bar,
  );

  test('quick product search is a case-insensitive name prefix match', () {
    expect(productNameStartsWith(product, 'efe'), isTrue);
    expect(productNameStartsWith(product, '  EFES '), isTrue);
    expect(productNameStartsWith(product, 'draught'), isFalse);
  });
}
