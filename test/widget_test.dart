import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/app/pos_app.dart';

void main() {
  testWidgets('compact POS menu hides the shell until tables is selected', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ProviderScope(child: TableSideCYApp()));
    await tester.pumpAndSettle();

    expect(find.text('New order'), findsOneWidget);
    expect(find.text('TableSideCY Hospitality'), findsNothing);

    await tester.tap(find.byType(Tab).first);
    await tester.pumpAndSettle();
    expect(find.text('TableSideCY Hospitality'), findsOneWidget);
    expect(find.text('Tables & tabs'), findsOneWidget);
  });
}
