import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/offline/venue_hub_server.dart';

void main() {
  test('native venue hub starts stopped and exposes no endpoint', () {
    final server = createVenueHubServer();
    expect(server.isSupported, isTrue);
    expect(server.isRunning, isFalse);
    expect(server.endpoint, isNull);
  });
}
