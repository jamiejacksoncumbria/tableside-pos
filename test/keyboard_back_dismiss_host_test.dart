import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/core/keyboard_back_dismiss_host.dart';

void main() {
  testWidgets('first system Back closes text input without popping the route', (
    tester,
  ) async {
    final focusNode = FocusNode(debugLabel: 'test text input');
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => KeyboardBackDismissHost(child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                TextField(focusNode: focusNode),
                FilledButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => const Scaffold(body: Text('Next page')),
                    ),
                  ),
                  child: const Text('Next'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);

    final handled = await tester.binding.handlePopRoute();
    await tester.pump();

    expect(handled, isTrue);
    expect(focusNode.hasFocus, isFalse);
    expect(find.byType(TextField), findsOneWidget);
  });
}
