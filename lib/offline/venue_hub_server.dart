import 'venue_hub_command_processor.dart';
import 'venue_hub_server_factory.dart';

class VenueHubServerConfiguration {
  const VenueHubServerConfiguration({
    required this.bindAddress,
    required this.port,
    required this.certificateChainPem,
    required this.privateKeyPem,
    required this.processor,
    this.privateKeyPassword,
    this.allowedOrigins = const <String>{},
  });

  final String bindAddress;
  final int port;
  final String certificateChainPem;
  final String privateKeyPem;
  final String? privateKeyPassword;
  final Set<String> allowedOrigins;
  final VenueHubCommandProcessor processor;
}

abstract interface class VenueHubServer {
  bool get isSupported;
  bool get isRunning;
  Uri? get endpoint;

  Future<Uri> start(VenueHubServerConfiguration configuration);
  Future<void> stop();
}

VenueHubServer createVenueHubServer() => createPlatformVenueHubServer();
