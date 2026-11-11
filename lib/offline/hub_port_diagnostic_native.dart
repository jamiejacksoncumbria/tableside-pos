import 'dart:io';

/// Tests raw TCP reachability separately from TLS/certificate validation.
/// This makes a Windows firewall failure distinguishable from an invalid
/// certificate or an application-level hub health response.
Future<String> diagnoseVenueHubPort(String host, int port) async {
  Future<bool> connects(String target) async {
    try {
      final socket = await Socket.connect(
        target,
        port,
        timeout: const Duration(seconds: 3),
      );
      await socket.close();
      return true;
    } on Object {
      return false;
    }
  }

  final loopback = await connects('127.0.0.1');
  final advertised = host.trim().isNotEmpty && await connects(host.trim());
  if (loopback && advertised) {
    return 'TCP $port is listening and reachable through $host. Certificate and hub health checks are the next layer.';
  }
  if (loopback && !advertised) {
    return 'The hub listens locally on TCP $port but $host cannot reach it. On Windows, allow inbound TCP $port for TableSideCY (Private networks) and confirm the LAN IP is correct. Example administrator command: netsh advfirewall firewall add rule name="TableSideCY venue hub" dir=in action=allow protocol=TCP localport=$port profile=private';
  }
  return 'Nothing is listening on TCP $port. Start/refresh the venue hub first; if it then works on 127.0.0.1 only, add the Windows Private-network firewall rule.';
}
