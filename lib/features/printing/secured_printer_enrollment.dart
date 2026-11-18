import '../../core/tenant_scope.dart';
import '../../data/production_command_repository.dart';
import '../../offline/venue_hub_bootstrap.dart';
import '../../offline/venue_hub_client_registry.dart';
import '../../offline/venue_hub_device_credential.dart';

/// Enrols and verifies the device-only credential used to claim EPOS 3 print
/// jobs from the certificate-pinned venue hub.
///
/// This is deliberately separate from the Firebase shared-printer credential:
/// the latter publishes presence and protects cloud configuration, but it
/// cannot authorise unattended access to the hub's encrypted local queue.
/// Every printer setup screen must call this before reporting live printing
/// as ready so test-print success cannot mask a broken production path.
Future<void> ensureSecuredVenueHubPrinterChannel({
  required VenueScope scope,
  required String deviceId,
}) async {
  final commands = ProductionCommandRepository();
  var bootstrap = VenueHubBootstrap.fromJson(
    await commands.fetchOfflineHubBootstrap(scope: scope),
  );
  if (!bootstrap.enabled) return;

  final credential = await VenueHubDeviceCredentialStore().getOrCreate(
    tenantId: scope.tenantId,
    venueId: scope.venueId,
    deviceId: deviceId,
  );
  await commands.enrollOfflineHubDeviceCredential(
    scope: scope,
    deviceId: deviceId,
    credentialId: credential.credentialId,
    publicKeyBase64: credential.publicKeyBase64,
  );
  // Fetch again because the first bootstrap necessarily predates a new
  // credential. The hub will reject claims until its signed allow-list
  // contains the public key just enrolled by the manager.
  bootstrap = VenueHubBootstrap.fromJson(
    await commands.fetchOfflineHubBootstrap(scope: scope),
  );
  final registry = VenueHubPrinterClientRegistry.instance;
  await registry.configure(
    scope: scope,
    bootstrap: bootstrap,
    deviceId: deviceId,
    credential: credential,
  );
  if (!await registry.verifyConnection(scope)) {
    throw StateError(
      registry.configurationIssue(scope) ??
          'The secure venue-hub printer connection could not be verified.',
    );
  }
}
