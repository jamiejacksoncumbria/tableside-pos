import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

http.Client createVenueHubHttpClient(
  String? trustedCertificatePem, [
  String expectedHost = '',
]) => http.Client();

WebSocketChannel connectVenueHubWebSocket(
  Uri endpoint,
  String? trustedCertificatePem,
  Duration timeout,
) => WebSocketChannel.connect(endpoint);
