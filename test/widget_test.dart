import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/app/pos_app.dart';

void main() {
  testWidgets('compact POS menu hides the shell until tables is selected', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: TableSideApp()));
    await tester.pumpAndSettle();

    expect(find.text('New order'), findsOneWidget);
    expect(find.text('TableSide Hospitality'), findsNothing);

    await tester.tap(find.byType(Tab).first);
    await tester.pumpAndSettle();
    expect(find.text('TableSide Hospitality'), findsOneWidget);
    expect(find.text('Tables & tabs'), findsOneWidget);
  });
}
