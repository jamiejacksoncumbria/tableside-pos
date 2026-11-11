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
          'https://example.test/path?token=private-value&auth=id-token-value',
    );

    expect(store.lines, hasLength(DiagnosticLogStore.maximumLines));
    expect(store.copyText, isNot(contains('test@example.com')));
    expect(store.copyText, isNot(contains('hunter2')));
    expect(store.copyText, isNot(contains('private-value')));
    expect(store.copyText, isNot(contains('id-token-value')));
    expect(store.copyText, contains('<redacted-email>'));
    expect(store.copyText, contains('<redacted>'));
  });

  test(
    'cloud diagnostics exclude raw messages and external stack frames',
    () async {
      final store = DiagnosticLogStore.instance;
      await store.clear();
      store.append(
        'ERROR',
        '[Close bill] StateError: customer Jamie paid 10.00',
      );
      store.append(
        'STACK',
        '#0 ProductionCommandRepository.closeOrder '
            '(package:tableside_pos/data/production_command_repository.dart:1513:7)',
      );
      store.append(
        'STACK',
        '#1 External.call (package:third_party/client.dart:10:2)',
      );

      final entries = store.cloudDiagnosticEntries;
      expect(entries, hasLength(2));
      expect(entries.first, containsPair('action', 'Close bill'));
      expect(entries.first, containsPair('errorType', 'StateError'));
      expect(entries.toString(), isNot(contains('Jamie')));
      expect(entries.toString(), isNot(contains('10.00')));
      expect(entries.toString(), isNot(contains('third_party')));
    },
  );
}
