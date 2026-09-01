import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/core/diagnostic_log_store.dart';

void main() {
  test('local diagnostics stay bounded and redact common secrets', () {
    final store = DiagnosticLogStore.instance;
    for (var index = 0; index < DiagnosticLogStore.maximumLines + 5; index++) {
      store.append('DEBUG', 'Safe diagnostic $index');
    }

    store.append(
      'ERROR',
      'email=test@example.com password=hunter2 token=abc123 '
          'https://example.test/path?token=private-value',
    );

    expect(store.lines, hasLength(DiagnosticLogStore.maximumLines));
    expect(store.copyText, isNot(contains('test@example.com')));
    expect(store.copyText, isNot(contains('hunter2')));
    expect(store.copyText, isNot(contains('private-value')));
    expect(store.copyText, contains('<redacted-email>'));
    expect(store.copyText, contains('<redacted>'));
  });
}
