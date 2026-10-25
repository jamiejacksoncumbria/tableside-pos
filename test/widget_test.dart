import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/app/pos_app.dart';
import 'package:tableside_pos/core/app_theme_controller.dart';

void main() {
  for (final size in const <Size>[
    Size(360, 640),
    Size(600, 800),
    Size(800, 500),
    Size(1280, 720),
  ]) {
    testWidgets(
      'POS shell has no layout exception at ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(_testApp());
        await tester.pumpAndSettle();

        expect(find.text('New order'), findsOneWidget);
      },
    );
  }

  testWidgets('wide workspace navigation remains bounded and visible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_testApp());
    await tester.pumpAndSettle();

    expect(find.text('TableSideCY Hospitality'), findsOneWidget);
    expect(find.text('POS'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact POS menu hides the shell until tables is selected', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_testApp());
    await tester.pumpAndSettle();

    expect(find.text('New order'), findsOneWidget);
    expect(find.text('TableSideCY Hospitality'), findsNothing);

    await tester.tap(find.byType(Tab).first);
    await tester.pumpAndSettle();
    expect(find.text('TableSideCY Hospitality'), findsOneWidget);
    expect(find.text('Tables & tabs'), findsOneWidget);
  });

  testWidgets('POS menu remains bounded in a short web-style viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_testApp());
    await tester.pumpAndSettle();

    expect(find.text('New order'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // The order footer contains totals, payment history and three action
    // rows. It must become internally scrollable rather than overflowing on a
    // shallow tablet/browser viewport.
    await tester.tap(find.byType(Tab).last);
    await tester.pumpAndSettle();
    expect(find.text('No table selected'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('web product search preserves keyboard text', (tester) async {
    tester.view.physicalSize = const Size(900, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_testApp());
    await tester.pumpAndSettle();

    final search = find.byType(TextField).first;
    await tester.enterText(search, 'draft');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(search).controller?.text, 'draft');
    expect(tester.takeException(), isNull);
  });
}

Widget _testApp() => ProviderScope(
  overrides: [
    appThemeControllerProvider.overrideWith(_TestThemeController.new),
  ],
  child: const TableSideCYApp(),
);

class _TestThemeController extends AppThemeController {
  @override
  AppThemeSelection build() => const AppThemeSelection();
}
