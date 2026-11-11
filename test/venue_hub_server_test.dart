import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/offline/venue_hub_server.dart';

void main() {
  test('venue hub server starts stopped and exposes no endpoint', () {
    final server = createVenueHubServer();
    expect(server.isRunning, isFalse);
    expect(server.endpoint, isNull);
  });
}
