import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/core/safe_modal_bottom_sheet.dart';

void main() {
  testWidgets('barrier dismissal waits until the sheet overlay is detached', (
    tester,
  ) async {
    var fullyClosed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                await showAppModalBottomSheet<void>(
                  context: context,
                  builder: (_) => const SizedBox(
                    height: 160,
                    child: Center(child: Text('Payment sheet')),
                  ),
                );
                fullyClosed = true;
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Payment sheet'), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.text('Payment sheet'), findsNothing);
    expect(fullyClosed, isTrue);
    expect(tester.takeException(), isNull);
  });
}
