import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/features/notifications/notification_centre.dart';

void main() {
  test('waiting frame cannot replay historical notifications', () {
    final bootstrap = OperationalNotificationBootstrap();

    expect(
      bootstrap.acceptSnapshot(
        hasData: false,
        isFromCache: false,
        documentIds: const <String>[],
      ),
      isEmpty,
    );
    expect(
      bootstrap.acceptSnapshot(
        hasData: true,
        isFromCache: false,
        documentIds: const ['old-1', 'old-2'],
      ),
      isEmpty,
    );
    expect(
      bootstrap.acceptSnapshot(
        hasData: true,
        isFromCache: false,
        documentIds: const ['old-1', 'old-2', 'new-1'],
      ),
      ['new-1'],
    );
  });

  test('cached data waits for the authoritative server baseline', () {
    final bootstrap = OperationalNotificationBootstrap();

    expect(
      bootstrap.acceptSnapshot(
        hasData: true,
        isFromCache: true,
        documentIds: const ['cached-old'],
      ),
      isEmpty,
    );
    expect(
      bootstrap.acceptSnapshot(
        hasData: true,
        isFromCache: false,
        documentIds: const ['cached-old', 'server-old'],
      ),
      isEmpty,
    );
  });

  test('reset creates a fresh historical baseline for another staff session', () {
    final bootstrap = OperationalNotificationBootstrap();
    bootstrap.acceptSnapshot(
      hasData: true,
      isFromCache: false,
      documentIds: const ['old-1'],
    );
    expect(
      bootstrap.acceptSnapshot(
        hasData: true,
        isFromCache: false,
        documentIds: const ['old-1', 'new-1'],
      ),
      ['new-1'],
    );

    bootstrap.reset();
    expect(
      bootstrap.acceptSnapshot(
        hasData: true,
        isFromCache: false,
        documentIds: const ['old-1', 'new-1'],
      ),
      isEmpty,
    );
  });
}
