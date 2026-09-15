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

List<int>? _pinnedCertificateDer(String? trustedCertificatePem) {
  final pem = trustedCertificatePem?.trim();
  if (pem == null || pem.isEmpty) return null;
  const begin = '-----BEGIN CERTIFICATE-----';
  const end = '-----END CERTIFICATE-----';
  final start = pem.indexOf(begin);
  final finish = pem.indexOf(end, start + begin.length);
  if (start < 0 || finish < 0) {
    throw const FormatException(
      'The trusted venue certificate PEM is invalid.',
    );
  }
  final encoded = pem
      .substring(start + begin.length, finish)
      .replaceAll(RegExp(r'\s'), '');
  try {
    final der = base64.decode(encoded);
    if (der.isEmpty) throw const FormatException();
    return der;
  } on FormatException {
    throw const FormatException(
      'The trusted venue certificate PEM is invalid.',
    );
  }
}

bool _sameCertificate(List<int> expected, List<int> actual) {
  if (expected.length != actual.length) return false;
  var difference = 0;
  for (var index = 0; index < expected.length; index++) {
    difference |= expected[index] ^ actual[index];
  }
  return difference == 0;
}

HttpClient _venueHubClient(String? trustedCertificatePem, String expectedHost) {
  final pinnedDer = _pinnedCertificateDer(trustedCertificatePem);
  final client = HttpClient(
    context: _venueHubSecurityContext(trustedCertificatePem),
  );
  if (pinnedDer != null) {
    // Some Android/BoringSSL versions reject a self-signed private trust
    // anchor even after SecurityContext imports it. Permit that one failure
    // only when the peer presents the byte-for-byte pinned certificate for
    // the configured host. This is not a general bad-certificate bypass.
    client.badCertificateCallback = (certificate, host, _) =>
        host == expectedHost && _sameCertificate(pinnedDer, certificate.der);
  }
  return client;
}

http.Client createVenueHubHttpClient(
  String? trustedCertificatePem, [
  String expectedHost = '',
]) => IOClient(_venueHubClient(trustedCertificatePem, expectedHost));

WebSocketChannel connectVenueHubWebSocket(
  Uri endpoint,
  String? trustedCertificatePem,
  Duration timeout,
) {
  final client = _venueHubClient(trustedCertificatePem, endpoint.host);
  return IOWebSocketChannel.connect(
    endpoint,
    customClient: client,
    connectTimeout: timeout,
  );
}
