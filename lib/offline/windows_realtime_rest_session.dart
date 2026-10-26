import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Windows-only transport for TableSide's ephemeral Firebase Realtime Database
/// control plane.
///
/// FlutterFire's native Windows RTDB listeners currently invoke Flutter event
/// channels from a Firebase C++ worker thread. Flutter treats that as unsafe
/// and the process can eventually crash. This REST/SSE client uses the same
/// short-lived, least-privileged custom token but never loads the native Auth
/// or Database listener for the secondary control-plane app.
///
/// Durable orders, payments and print jobs do not pass through this class.
/// They remain in the signed hub ledger and protected APIs.
class WindowsRealtimeRestSession {
  WindowsRealtimeRestSession({
    required this.databaseUrl,
    required this.apiKey,
    required this.customToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String databaseUrl;
  final String apiKey;
  final String customToken;
  final http.Client _client;

  String? _idToken;
  String? _refreshToken;
  DateTime _expiresAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _closed = false;

  static const serverTimestamp = <String, String>{'.sv': 'timestamp'};

  Future<void> authenticate() async {
    if (_closed) throw StateError('The realtime session is closed.');
    final uri = Uri.https(
      'identitytoolkit.googleapis.com',
      '/v1/accounts:signInWithCustomToken',
      {'key': apiKey},
    );
    final response = await _client.post(
      uri,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'token': customToken, 'returnSecureToken': true}),
    );
    final body = _decodedObject(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        _firebaseError(body, 'Could not open realtime session.'),
      );
    }
    _acceptTokenResponse(body);
  }

  Future<void> set(String path, Object? value) => _write('PUT', path, value);

  Future<void> update(String path, Map<String, Object?> value) =>
      _write('PATCH', path, value);

  /// Emits the complete projected value after every Firebase SSE put/patch.
  /// It reconnects after transient socket closure and refreshes the scoped ID
  /// token before expiry. Cancelling the Dart subscription stops reconnects.
  Stream<Object?> watch(String path) {
    late StreamController<Object?> controller;
    var cancelled = false;
    var errorReported = false;
    Object? state = const _UnsetRealtimeValue();

    Future<void> run() async {
      var retry = const Duration(milliseconds: 250);
      while (!cancelled && !_closed) {
        try {
          final token = await _validIdToken();
          final request = http.Request('GET', _databaseUri(path, token));
          request.headers['Accept'] = 'text/event-stream';
          final response = await _client.send(request);
          if (response.statusCode < 200 || response.statusCode >= 300) {
            final body = await response.stream.bytesToString();
            throw StateError(
              'Realtime listener failed (${response.statusCode}): $body',
            );
          }
          errorReported = false;
          retry = const Duration(milliseconds: 250);
          String? eventName;
          final data = StringBuffer();
          await for (final line
              in response.stream
                  .transform(utf8.decoder)
                  .transform(const LineSplitter())) {
            if (cancelled || _closed) return;
            if (line.isEmpty) {
              if (data.isNotEmpty) {
                final envelope = jsonDecode(data.toString());
                if (envelope is Map &&
                    (eventName == 'put' || eventName == 'patch')) {
                  state = _applyEvent(
                    state,
                    Map<Object?, Object?>.from(envelope),
                    patch: eventName == 'patch',
                  );
                  if (!controller.isClosed) {
                    controller.add(state is _UnsetRealtimeValue ? null : state);
                  }
                } else if (eventName == 'cancel' ||
                    eventName == 'auth_revoked') {
                  throw StateError('Realtime session was revoked by Firebase.');
                }
              }
              eventName = null;
              data.clear();
              continue;
            }
            if (line.startsWith('event:')) {
              eventName = line.substring(6).trim();
            } else if (line.startsWith('data:')) {
              if (data.isNotEmpty) data.write('\n');
              data.write(line.substring(5).trimLeft());
            }
          }
        } on Object catch (error, stackTrace) {
          if (cancelled || _closed) return;
          // One notification per outage is enough for diagnostics. The SSE
          // loop continues reconnecting with backoff, but repeating the same
          // socket exception every few seconds hid useful operational logs.
          if (!errorReported && !controller.isClosed) {
            errorReported = true;
            controller.addError(error, stackTrace);
          }
        }
        if (cancelled || _closed) return;
        await Future<void>.delayed(retry);
        final nextMillis = (retry.inMilliseconds * 2).clamp(250, 5000);
        retry = Duration(milliseconds: nextMillis);
      }
    }

    controller = StreamController<Object?>(
      onListen: run,
      onCancel: () => cancelled = true,
    );
    return controller.stream;
  }

  Future<void> close() async {
    _closed = true;
    _client.close();
  }

  Future<void> _write(String method, String path, Object? value) async {
    final token = await _validIdToken();
    final request = http.Request(method, _databaseUri(path, token))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode(value);
    final response = await _client.send(request);
    final body = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Realtime write failed (${response.statusCode}): $body');
    }
  }

  Future<String> _validIdToken() async {
    if (_closed) throw StateError('The realtime session is closed.');
    final token = _idToken;
    if (token != null &&
        DateTime.now().isBefore(
          _expiresAt.subtract(const Duration(minutes: 5)),
        )) {
      return token;
    }
    final refreshToken = _refreshToken;
    if (refreshToken == null) {
      await authenticate();
      return _idToken!;
    }
    final response = await _client.post(
      Uri.https('securetoken.googleapis.com', '/v1/token', {'key': apiKey}),
      headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {'grant_type': 'refresh_token', 'refresh_token': refreshToken},
    );
    final body = _decodedObject(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        _firebaseError(body, 'Could not refresh realtime session.'),
      );
    }
    _acceptTokenResponse(body);
    return _idToken!;
  }

  void _acceptTokenResponse(Map<String, Object?> body) {
    final idToken = body['idToken'] ?? body['id_token'];
    final refreshToken = body['refreshToken'] ?? body['refresh_token'];
    final expiresIn = body['expiresIn'] ?? body['expires_in'];
    if (idToken is! String ||
        idToken.isEmpty ||
        refreshToken is! String ||
        refreshToken.isEmpty) {
      throw StateError('Firebase returned an invalid realtime credential.');
    }
    final seconds = int.tryParse('$expiresIn') ?? 3600;
    _idToken = idToken;
    _refreshToken = refreshToken;
    _expiresAt = DateTime.now().add(Duration(seconds: seconds));
  }

  Uri _databaseUri(String path, String token) {
    final base = databaseUrl.endsWith('/')
        ? databaseUrl.substring(0, databaseUrl.length - 1)
        : databaseUrl;
    final encodedPath = path
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    return Uri.parse(
      '$base/$encodedPath.json',
    ).replace(queryParameters: {'auth': token});
  }

  static Map<String, Object?> _decodedObject(String source) {
    final decoded = jsonDecode(source);
    return decoded is Map
        ? Map<String, Object?>.from(decoded)
        : <String, Object?>{};
  }

  static String _firebaseError(Map<String, Object?> body, String fallback) {
    final error = body['error'];
    if (error is Map) {
      final message = error['message'];
      if (message is String && message.isNotEmpty) return message;
    }
    return fallback;
  }
}

class _UnsetRealtimeValue {
  const _UnsetRealtimeValue();
}

Object? _applyEvent(
  Object? current,
  Map<Object?, Object?> envelope, {
  required bool patch,
}) {
  final path = envelope['path'];
  final data = envelope['data'];
  if (path is! String || !path.startsWith('/')) return current;
  final segments = path.split('/').where((value) => value.isNotEmpty).toList();
  if (segments.isEmpty) {
    if (data is Map && current is Map && patch) {
      return _mergeMap(current, data);
    }
    return data;
  }
  final root = current is Map
      ? Map<Object?, Object?>.from(current)
      : <Object?, Object?>{};
  _setNested(root, segments, data);
  return root;
}

Map<Object?, Object?> _mergeMap(Map current, Map patch) {
  final result = Map<Object?, Object?>.from(current);
  for (final entry in patch.entries) {
    if (entry.value == null) {
      result.remove(entry.key);
    } else {
      result[entry.key] = entry.value;
    }
  }
  return result;
}

void _setNested(
  Map<Object?, Object?> root,
  List<String> segments,
  Object? value,
) {
  var cursor = root;
  for (var index = 0; index < segments.length - 1; index++) {
    final key = segments[index];
    final child = cursor[key];
    final next = child is Map
        ? Map<Object?, Object?>.from(child)
        : <Object?, Object?>{};
    cursor[key] = next;
    cursor = next;
  }
  final key = segments.last;
  if (value == null) {
    cursor.remove(key);
  } else {
    cursor[key] = value;
  }
}
