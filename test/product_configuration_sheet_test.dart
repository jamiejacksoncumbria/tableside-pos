import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/features/pos/domain.dart';
import 'package:tableside_pos/features/pos/product_configuration_sheet.dart';

void main() {
  testWidgets('item note keyboard action focuses and saves the note', (
    tester,
  ) async {
    ProductConfigurationSelection? selection;
    const product = MenuProduct(
      id: 'product-a',
      name: 'Test Product',
      priceMinor: 1200,
      sectionIds: <String>['section-a'],
      productionArea: ProductionArea.kitchen,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                selection = await showProductConfigurationSheet(
                  context: context,
                  product: product,
                  availableGroups: const <MenuModifierGroup>[],
                  availableProducts: const <MenuProduct>[product],
                  currencyCode: 'GBP',
                );
              },
              child: const Text('Configure'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Configure'));
    await tester.pumpAndSettle();
    final keyboard = find.byTooltip('Open keyboard for item note');
    expect(keyboard, findsOneWidget);

    await tester.tap(keyboard);
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode?.hasFocus, isTrue);

    await tester.enterText(find.byType(TextField), 'No onions');
    await tester.tap(find.text('Add to order'));
    await tester.pumpAndSettle();

    expect(selection?.itemNote, 'No onions');
    expect(tester.takeException(), isNull);
  });
}
