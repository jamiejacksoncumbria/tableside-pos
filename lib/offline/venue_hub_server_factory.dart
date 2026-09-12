import 'venue_hub_server.dart';
import 'venue_hub_server_stub.dart'
    if (dart.library.io) 'venue_hub_server_native.dart'
    as platform;

VenueHubServer createPlatformVenueHubServer() =>
    platform.createVenueHubServer();
