import 'venue_hub_server.dart';

VenueHubServer createVenueHubServer() => _UnsupportedVenueHubServer();

class _UnsupportedVenueHubServer implements VenueHubServer {
  @override
  Uri? get endpoint => null;

  @override
  bool get isRunning => false;

  @override
  bool get isSupported => false;

  @override
  Future<Uri> start(VenueHubServerConfiguration configuration) =>
      throw UnsupportedError('A web browser cannot host the venue hub.');

  @override
  Future<void> stop() async {}
}
