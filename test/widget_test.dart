import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/app/pos_app.dart';

void main() {
  testWidgets('POS home opens with the selected venue and order workflow', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: TableSideApp()));

    expect(find.text('TableSide Hospitality'), findsOneWidget);
    await tester.tap(find.byType(Tab).at(1));
    await tester.pumpAndSettle();
    expect(find.text('New order'), findsOneWidget);
  });
}
