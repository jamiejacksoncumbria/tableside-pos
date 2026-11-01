import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tableside_pos/offline/windows_realtime_rest_session.dart';

void main() {
  test(
    'projects Firebase SSE put and patch events without native channels',
    () async {
      final requestedUris = <Uri>[];
      final client = MockClient((request) async {
        requestedUris.add(request.url);
        if (request.url.host == 'identitytoolkit.googleapis.com') {
          expect(jsonDecode(request.body), {
            'token': 'scoped-custom-token',
            'returnSecureToken': true,
          });
          return http.Response(
            jsonEncode({
              'idToken': 'scoped-id-token',
              'refreshToken': 'scoped-refresh-token',
              'expiresIn': '3600',
            }),
            200,
          );
        }
        expect(request.method, 'GET');
        expect(request.url.queryParameters['auth'], 'scoped-id-token');
        return http.Response(
          'event: put\n'
          'data: {"path":"/","data":{"online":true,"hubEpoch":7}}\n\n'
          'event: patch\n'
          'data: {"path":"/","data":{"lastReadyAt":1234}}\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final session = WindowsRealtimeRestSession(
        databaseUrl: 'https://example-default-rtdb.firebaseio.com',
        apiKey: 'public-api-key',
        customToken: 'scoped-custom-token',
        client: client,
      );

      await session.authenticate();
      final values = await session
          .watch('hubPresence/tenant/venue/device')
          .take(2)
          .toList();

      expect(values, [
        {'online': true, 'hubEpoch': 7},
        {'online': true, 'hubEpoch': 7, 'lastReadyAt': 1234},
      ]);
      expect(requestedUris.last.path, '/hubPresence/tenant/venue/device.json');
      await session.close();
    },
  );

  test(
    'writes use the scoped ID token and Firebase server timestamp',
    () async {
      http.Request? write;
      final client = MockClient((request) async {
        if (request.url.host == 'identitytoolkit.googleapis.com') {
          return http.Response(
            jsonEncode({
              'idToken': 'id-token',
              'refreshToken': 'refresh-token',
              'expiresIn': '3600',
            }),
            200,
          );
        }
        write = request;
        return http.Response('null', 200);
      });
      final session = WindowsRealtimeRestSession(
        databaseUrl: 'https://example-default-rtdb.firebaseio.com/',
        apiKey: 'public-api-key',
        customToken: 'custom-token',
        client: client,
      );

      await session.authenticate();
      await session.update('hubPresence/tenant/venue/device', {
        'online': true,
        'lastReadyAt': WindowsRealtimeRestSession.serverTimestamp,
      });

      expect(write?.method, 'PATCH');
      expect(write?.url.queryParameters['auth'], 'id-token');
      expect(jsonDecode(write!.body), {
        'online': true,
        'lastReadyAt': {'.sv': 'timestamp'},
      });
      await session.close();
    },
  );

  test('renews a scoped session after Firebase revokes an SSE credential', () async {
    var identityRequests = 0;
    var listenerRequests = 0;
    var renewals = 0;
    final client = MockClient((request) async {
      if (request.url.host == 'identitytoolkit.googleapis.com') {
        identityRequests += 1;
        final customToken = jsonDecode(request.body)['token'];
        return http.Response(
          jsonEncode({
            'idToken': customToken == 'renewed-custom-token'
                ? 'renewed-id-token'
                : 'initial-id-token',
            'refreshToken': 'refresh-$identityRequests',
            'expiresIn': '3600',
          }),
          200,
        );
      }
      listenerRequests += 1;
      if (listenerRequests == 1) {
        expect(request.url.queryParameters['auth'], 'initial-id-token');
        return http.Response(
          'event: auth_revoked\n'
          'data: credential is no longer valid\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }
      expect(request.url.queryParameters['auth'], 'renewed-id-token');
      return http.Response(
        'event: put\n'
        'data: {"path":"/","data":{"online":true}}\n\n',
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final session = WindowsRealtimeRestSession(
      databaseUrl: 'https://example-default-rtdb.firebaseio.com',
      apiKey: 'public-api-key',
      customToken: 'initial-custom-token',
      renewCustomToken: () async {
        renewals += 1;
        return 'renewed-custom-token';
      },
      client: client,
    );

    await session.authenticate();
    final value = await session.watch('hubPresence/tenant/venue/device').first;

    expect(value, {'online': true});
    expect(renewals, 1);
    expect(identityRequests, 2);
    await session.close();
  });
}
