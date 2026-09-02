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
    expect(productNameStartsWith(product, 'draught'), isTrue);
  });

  test('matches the start of any word in a product name', () {
    const product = MenuProduct(
      id: 'white-wine-large',
      name: 'Large Glass White Wine',
      priceMinor: 800,
      sectionIds: <String>['wine'],
      productionArea: ProductionArea.bar,
    );
    expect(productNameStartsWith(product, 'gla'), isTrue);
    expect(productNameStartsWith(product, 'wh'), isTrue);
    expect(productNameStartsWith(product, 'win'), isTrue);
    expect(productNameStartsWith(product, 'lass'), isFalse);
  });

  test('POS search matches product and assigned category names', () {
    const wine = MenuProduct(
      id: 'house-red',
      name: 'House Red',
      priceMinor: 900,
      sectionIds: <String>['wine', 'alcohol'],
      productionArea: ProductionArea.bar,
    );
    const sections = <MenuSection>[
      MenuSection(id: 'drinks', name: 'Drinks', icon: '🥤'),
      MenuSection(
        id: 'alcohol',
        name: 'Alcoholic Drinks',
        icon: '🍷',
        parentSectionId: 'drinks',
      ),
      MenuSection(
        id: 'wine',
        name: 'White Wine',
        icon: '🍾',
        parentSectionId: 'alcohol',
      ),
    ];

    expect(productMatchesMenuSearch(wine, sections, 'wine'), isTrue);
    expect(productMatchesMenuSearch(wine, sections, 'white'), isTrue);
    expect(productMatchesMenuSearch(wine, sections, 'house red'), isTrue);
    expect(productMatchesMenuSearch(wine, sections, 'beer'), isFalse);
  });
}
