import 'venue_hub_command_processor.dart';
import 'venue_hub_server_factory.dart';
import 'venue_hub_staff_sessions.dart';

typedef VenueHubPinAuthenticator =
    Future<VenueHubIssuedStaffSession> Function(
      String deviceId,
      String staffId,
      String pin,
    );
typedef VenueHubPrintJobClaimer =
    Future<Map<String, Object?>?> Function(String deviceId);
typedef VenueHubPrintJobCompleter =
    Future<void> Function(
      String deviceId,
      String jobId,
      bool printed,
      String? failureReason,
    );
typedef VenueHubClientSnapshotReader = Future<Map<String, Object?>> Function();
typedef VenueHubOrderProjectionReader =
    Future<List<Map<String, Object?>>> Function();

class VenueHubServerConfiguration {
  const VenueHubServerConfiguration({
    required this.bindAddress,
    required this.port,
    required this.certificateChainPem,
    required this.privateKeyPem,
    required this.processor,
    required this.authenticatePin,
    required this.claimPrintJob,
    required this.completePrintJob,
    required this.readClientSnapshot,
    required this.readOrders,
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
  final VenueHubPinAuthenticator authenticatePin;
  final VenueHubPrintJobClaimer claimPrintJob;
  final VenueHubPrintJobCompleter completePrintJob;
  final VenueHubClientSnapshotReader readClientSnapshot;
  final VenueHubOrderProjectionReader readOrders;
}

abstract interface class VenueHubServer {
  bool get isSupported;
  bool get isRunning;
  Uri? get endpoint;

  Future<Uri> start(VenueHubServerConfiguration configuration);
  Future<void> stop();
}

VenueHubServer createVenueHubServer() => createPlatformVenueHubServer();
