import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/core/safe_dialog.dart';

void main() {
  testWidgets(
    'a replacement dialog opens only after the previous route is removed',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  final first = await showAppDialog<bool>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: const Text('Choose customer'),
                      actions: [
                        TextButton(
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(true),
                          child: const Text('Continue'),
                        ),
                      ],
                    ),
                  );
                  if (first != true || !context.mounted) return;
                  await showAppDialog<void>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: const Text('Delivery details'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          child: const Text('Done'),
                        ),
                      ],
                    ),
                  );
                },
                child: const Text('Start'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('Choose customer'), findsNothing);
      expect(find.text('Delivery details'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
