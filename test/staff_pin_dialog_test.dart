import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/core/safe_dialog.dart';
import 'package:tableside_pos/features/auth/staff_pin_gate.dart';

void main() {
  testWidgets(
    'PIN pad remains laid out and submits on a compact touch screen',
    (tester) async {
      tester.view.physicalSize = const Size(600, 430);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(MaterialApp(home: _PinDialogHarness()));
      await tester.tap(find.text('Open PIN'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      for (final digit in const ['1', '2', '3', '4', '5', '6']) {
        await tester.tap(find.text(digit));
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
      await tester.pumpAndSettle();

      expect(find.text('PIN: 123456'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

class _PinDialogHarness extends StatefulWidget {
  @override
  State<_PinDialogHarness> createState() => _PinDialogHarnessState();
}

class _PinDialogHarnessState extends State<_PinDialogHarness> {
  String? _pin;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton(
            onPressed: () async {
              final pin = await showAppDialog<String>(
                context: context,
                builder: (_) => buildStaffPinDialogForTest(),
              );
              if (mounted) setState(() => _pin = pin);
            },
            child: const Text('Open PIN'),
          ),
          if (_pin != null) Text('PIN: $_pin'),
        ],
      ),
    ),
  );
}
