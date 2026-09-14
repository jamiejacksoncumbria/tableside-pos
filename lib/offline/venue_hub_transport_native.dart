import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

SecurityContext _venueHubSecurityContext(String? trustedCertificatePem) {
  final certificate = trustedCertificatePem?.trim();
  final hasPinnedCertificate = certificate?.isNotEmpty == true;
  final context = SecurityContext(withTrustedRoots: !hasPinnedCertificate);
  if (hasPinnedCertificate) {
    context.setTrustedCertificatesBytes(utf8.encode(certificate!));
  }
  return context;
}

http.Client createVenueHubHttpClient(String? trustedCertificatePem) => IOClient(
  HttpClient(context: _venueHubSecurityContext(trustedCertificatePem)),
);

WebSocketChannel connectVenueHubWebSocket(
  Uri endpoint,
  String? trustedCertificatePem,
  Duration timeout,
) {
  final client = HttpClient(
    context: _venueHubSecurityContext(trustedCertificatePem),
  );
  return IOWebSocketChannel.connect(
    endpoint,
    customClient: client,
    connectTimeout: timeout,
  );
}
