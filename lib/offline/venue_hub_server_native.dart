import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/app_logger.dart';
import '../core/trusted_clock.dart';
import 'venue_hub_command_processor.dart';
import 'venue_hub_protocol.dart';
import 'venue_hub_server.dart';

VenueHubServer createVenueHubServer() => NativeVenueHubServer();

class NativeVenueHubServer implements VenueHubServer {
  static const _maximumRequestBytes = 600 * 1024;

  HttpServer? _server;
  StreamSubscription<HttpRequest>? _requests;
  VenueHubServerConfiguration? _configuration;
  final Set<WebSocket> _sockets = <WebSocket>{};

  @override
  bool get isSupported => true;

  @override
  bool get isRunning => _server != null;

  @override
  Uri? get endpoint {
    final server = _server;
    if (server == null) return null;
    final host =
        server.address.address == '0.0.0.0' || server.address.address == '::'
        ? 'localhost'
        : server.address.address;
    return Uri(scheme: 'https', host: host, port: server.port);
  }

  @override
  Future<Uri> start(VenueHubServerConfiguration configuration) async {
    if (_server != null) throw StateError('The venue hub is already running.');
    if (configuration.port < 1024 || configuration.port > 65535) {
      throw ArgumentError.value(
        configuration.port,
        'port',
        'Invalid hub port.',
      );
    }
    if (configuration.certificateChainPem.trim().isEmpty ||
        configuration.privateKeyPem.trim().isEmpty) {
      throw StateError(
        'The venue TLS certificate and private key are required.',
      );
    }
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(configuration.certificateChainPem))
      ..usePrivateKeyBytes(
        utf8.encode(configuration.privateKeyPem),
        password: configuration.privateKeyPassword,
      );
    final server = await HttpServer.bindSecure(
      configuration.bindAddress,
      configuration.port,
      context,
      shared: false,
    );
    _configuration = configuration;
    _server = server;
    _requests = server.listen(
      _handle,
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.error('Venue hub HTTPS listener', error, stackTrace);
      },
      cancelOnError: false,
    );
    AppLogger.info('Venue hub HTTPS service listening on port ${server.port}.');
    return endpoint!;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      _applySecurityHeaders(request);
      if (request.method == 'OPTIONS') {
        _requireAllowedOrigin(request);
        response.statusCode = HttpStatus.noContent;
        await response.close();
        return;
      }
      if (request.uri.path == '/v1/health' && request.method == 'GET') {
        _requireAllowedOrigin(request, allowNoOrigin: true);
        _json(response, HttpStatus.ok, {
          'status': 'ready',
          'hubEpoch': _configuration!.processor.hubEpoch,
          'serverTimeMillis': TrustedClock.instance
              .nowUtc()
              .millisecondsSinceEpoch,
        });
        return;
      }
      if (request.uri.path == '/v1/stream' &&
          WebSocketTransformer.isUpgradeRequest(request)) {
        _requireAllowedOrigin(request);
        await _upgradeStream(request);
        return;
      }
      if (request.uri.path != '/v1/events' || request.method != 'POST') {
        _json(response, HttpStatus.notFound, {'error': 'not_found'});
        return;
      }
      _requireAllowedOrigin(request, allowNoOrigin: true);
      final payload = await _readJson(request);
      final envelope = _envelope(payload['envelope']);
      final body = _map(payload['body'], 'The request body is invalid.');
      final acknowledgement = await _configuration!.processor.process(
        envelope: envelope,
        body: body,
        trustedNowUtc: TrustedClock.instance.nowUtc(),
      );
      final result = <String, Object?>{
        'accepted': true,
        'eventId': acknowledgement.eventId,
        'sequence': acknowledgement.sequence,
        'eventHash': acknowledgement.eventHash,
        'committedAtUtc': acknowledgement.committedAtUtc.toIso8601String(),
      };
      _json(response, HttpStatus.created, result);
      _broadcast({'type': 'event.committed', ...result});
    } on VenueHubProtocolException catch (error, stackTrace) {
      AppLogger.error('Reject venue hub protocol request', error, stackTrace);
      _json(response, HttpStatus.unauthorized, {'error': 'unauthorized'});
    } on VenueHubCommandException catch (error, stackTrace) {
      AppLogger.error('Reject venue hub command', error, stackTrace);
      _json(response, HttpStatus.forbidden, {'error': 'forbidden'});
    } on FormatException catch (error, stackTrace) {
      AppLogger.error('Reject malformed venue hub request', error, stackTrace);
      _json(response, HttpStatus.badRequest, {'error': 'invalid_request'});
    } catch (error, stackTrace) {
      AppLogger.error('Process venue hub request', error, stackTrace);
      _json(response, HttpStatus.internalServerError, {'error': 'hub_error'});
    }
  }

  Future<void> _upgradeStream(HttpRequest request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    try {
      final messages = socket.asBroadcastStream();
      final first = await messages.first.timeout(const Duration(seconds: 10));
      if (first is! String || utf8.encode(first).length > 32 * 1024) {
        throw const FormatException('Invalid stream authentication.');
      }
      final decoded = jsonDecode(first);
      final root = _map(decoded, 'Invalid stream authentication.');
      final envelope = _envelope(root['envelope']);
      final body = _map(root['body'], 'Invalid stream authentication.');
      if (envelope.method != 'GET' || envelope.path != '/v1/stream') {
        throw const VenueHubProtocolException('Invalid stream endpoint.');
      }
      await _configuration!.processor.authenticate(
        envelope: envelope,
        body: body,
        trustedNowUtc: TrustedClock.instance.nowUtc(),
        requiredPermission: 'order',
      );
      _sockets.add(socket);
      socket.add(jsonEncode({'type': 'stream.ready'}));
      messages.listen(
        (_) {},
        onDone: () => _sockets.remove(socket),
        onError: (_) => _sockets.remove(socket),
        cancelOnError: true,
      );
    } catch (error, stackTrace) {
      AppLogger.error('Authenticate venue hub stream', error, stackTrace);
      await socket.close(
        WebSocketStatus.policyViolation,
        'Authentication failed',
      );
    }
  }

  Future<Map<String, Object?>> _readJson(HttpRequest request) async {
    final declared = request.contentLength;
    if (declared > _maximumRequestBytes) {
      throw const FormatException('The request is too large.');
    }
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
      if (bytes.length > _maximumRequestBytes) {
        throw const FormatException('The request is too large.');
      }
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    return _map(decoded, 'The request is invalid.');
  }

  VenueHubRequestEnvelope _envelope(Object? value) =>
      VenueHubRequestEnvelope.fromJson(
        _map(value, 'The request envelope is invalid.'),
      );

  Map<String, Object?> _map(Object? value, String message) {
    if (value is! Map) throw FormatException(message);
    return Map<String, Object?>.from(value);
  }

  void _requireAllowedOrigin(
    HttpRequest request, {
    bool allowNoOrigin = false,
  }) {
    final origin = request.headers.value('origin');
    if (origin == null && allowNoOrigin) return;
    if (origin == null || !_configuration!.allowedOrigins.contains(origin)) {
      throw const VenueHubProtocolException(
        'The request origin is not allowed.',
      );
    }
  }

  void _applySecurityHeaders(HttpRequest request) {
    final origin = request.headers.value('origin');
    if (origin != null && _configuration!.allowedOrigins.contains(origin)) {
      request.response.headers
        ..set('Access-Control-Allow-Origin', origin)
        ..set('Vary', 'Origin')
        ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        ..set('Access-Control-Allow-Headers', 'Content-Type')
        ..set('Access-Control-Allow-Private-Network', 'true');
    }
    request.response.headers
      ..set('Cache-Control', 'no-store')
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('Referrer-Policy', 'no-referrer');
  }

  void _json(HttpResponse response, int status, Map<String, Object?> value) {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(value))
      ..close();
  }

  void _broadcast(Map<String, Object?> message) {
    final encoded = jsonEncode(message);
    for (final socket in _sockets.toList(growable: false)) {
      try {
        socket.add(encoded);
      } catch (_) {
        _sockets.remove(socket);
      }
    }
  }

  @override
  Future<void> stop() async {
    final sockets = _sockets.toList(growable: false);
    _sockets.clear();
    for (final socket in sockets) {
      await socket.close(WebSocketStatus.goingAway, 'Hub stopping');
    }
    await _requests?.cancel();
    _requests = null;
    await _server?.close(force: true);
    _server = null;
    _configuration = null;
  }
}
