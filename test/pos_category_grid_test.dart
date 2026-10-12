import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/features/pos/pos_page.dart';

void main() {
  test('category grid uses five compact columns on tablets', () {
    expect(posCategoryGridColumnCount(600), 5);
    expect(posCategoryGridColumnCount(768), 5);
    expect(posCategoryGridColumnCount(1024), 5);
  });

  test('category grid remains adaptive on phones and desktops', () {
    expect(posCategoryGridColumnCount(390), 3);
    expect(posCategoryGridColumnCount(500), 4);
    expect(posCategoryGridColumnCount(1440), 8);
  });
}
