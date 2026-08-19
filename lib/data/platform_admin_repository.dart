import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../core/app_logger.dart';
import '../firebase_options.dart';

final platformAdminRepositoryProvider = Provider<PlatformAdminRepository>(
  (ref) => PlatformAdminRepository(),
);

class PlatformAdminRepository {
  /// Creates the first administrator, then waits for its custom claim to be
  /// present in the locally held Firebase ID token.
  ///
  /// Firebase Auth updates custom claims asynchronously.  A forced refresh is
  /// normally sufficient, but retrying for a few seconds prevents the UI from
  /// returning to the setup screen with a just-stale token.
  Future<bool> bootstrapPlatformAdmin() async {
    AppLogger.info('Initial platform admin setup: calling the server.');
    await _call('bootstrapPlatformAdmin');
    final claimAvailable = await _waitForPlatformAdminClaim();
    AppLogger.info(
      'Initial platform admin setup: token claim available=$claimAvailable.',
    );
    return claimAvailable;
  }

  Future<List<PlatformAuthUser>> listAuthUsers() async {
    final data = await _call('listAuthUsers');
    final values = List<Object?>.from(data['users'] as List? ?? const []);
    return values
        .map(
          (value) =>
              PlatformAuthUser.fromMap(Map<String, Object?>.from(value as Map)),
        )
        .toList(growable: false);
  }

  Future<List<PlatformTenantSummary>> listTenants() async {
    final data = await _call('listTenants');
    final values = List<Object?>.from(data['tenants'] as List? ?? const []);
    return values
        .map(
          (value) => PlatformTenantSummary.fromMap(
            Map<String, Object?>.from(value as Map),
          ),
        )
        .toList(growable: false);
  }

  Future<void> createTenant({
    required String displayName,
    required String legalName,
    required String venueName,
    required String timeZone,
    required String ownerUid,
    String currencyCode = 'GBP',
  }) async {
    await _call('createTenant', {
      'displayName': displayName,
      'legalName': legalName,
      'currencyCode': currencyCode,
      'venueName': venueName,
      'timeZone': timeZone,
      'ownerUid': ownerUid,
    });
  }

  Future<PlatformAuthUser> createStaffUser({
    required String email,
    required String displayName,
  }) async {
    final data = await _call('createStaffUser', {
      'email': email,
      'displayName': displayName,
    });
    return PlatformAuthUser(
      uid: data['uid'] as String,
      email: data['email'] as String,
      displayName: displayName,
      disabled: false,
      isPlatformAdmin: false,
    );
  }

  /// Requests Firebase Authentication's standard password-reset email.
  ///
  /// Firebase processes delivery asynchronously; this confirms only that
  /// Firebase accepted the request, never that an inbox received it.
  Future<void> sendPasswordResetEmail(String email) async {
    AppLogger.info('Password reset: requesting a Firebase email.');
    await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
    AppLogger.info('Password reset: Firebase accepted the request.');
  }

  Future<void> assignUserToTenant({
    required String tenantId,
    required String userUid,
    required String role,
  }) async {
    await _call('assignUserToTenant', {
      'tenantId': tenantId,
      'userUid': userUid,
      'roles': [role],
    });
  }

  Future<Map<String, Object?>> _call(
    String name, [
    Map<String, Object?> data = const {},
  ]) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('Sign in before using platform administration.');
    }
    final idToken = await user.getIdToken();
    if (idToken == null || idToken.isEmpty) {
      throw StateError('Could not obtain a Firebase sign-in token.');
    }
    final projectId = DefaultFirebaseOptions.currentPlatform.projectId;
    final endpoint = Uri.https(
      'europe-west2-$projectId.cloudfunctions.net',
      'platformAdminApi',
    );
    AppLogger.info('Platform API $name: sending request.');
    final response = await http.post(
      endpoint,
      headers: {
        'Authorization': 'Bearer $idToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'action': name, 'data': data}),
    );
    AppLogger.info('Platform API $name: HTTP ${response.statusCode}.');
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw StateError('The platform server returned an invalid response.');
    }
    final body = Map<String, Object?>.from(decoded);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = body['error'];
      if (error is Map) {
        final details = Map<String, Object?>.from(error);
        final message = details['message'];
        throw StateError(
          message is String ? message : 'Platform action failed.',
        );
      }
      throw StateError('Platform action failed (${response.statusCode}).');
    }
    final result = body['data'];
    if (result is! Map) return const {};
    return Map<String, Object?>.from(result);
  }

  Future<bool> _waitForPlatformAdminClaim() async {
    const attempts = 5;
    for (var attempt = 0; attempt < attempts; attempt++) {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return false;

      await user.reload();
      final token = await user.getIdTokenResult(true);
      final hasClaim = token.claims?['platformAdmin'] == true;
      AppLogger.info(
        'Platform admin token refresh ${attempt + 1}/$attempts: claim present=$hasClaim.',
      );
      if (hasClaim) return true;

      if (attempt < attempts - 1) {
        await Future<void>.delayed(
          Duration(milliseconds: 400 * (attempt + 1)),
        );
      }
    }
    return false;
  }
}

class PlatformAuthUser {
  const PlatformAuthUser({
    required this.uid,
    required this.email,
    required this.displayName,
    required this.disabled,
    required this.isPlatformAdmin,
  });

  factory PlatformAuthUser.fromMap(Map<String, Object?> data) {
    return PlatformAuthUser(
      uid: data['uid'] as String? ?? '',
      email: data['email'] as String? ?? '',
      displayName: data['displayName'] as String? ?? '',
      disabled: data['disabled'] as bool? ?? false,
      isPlatformAdmin: data['platformAdmin'] as bool? ?? false,
    );
  }

  final String uid;
  final String email;
  final String displayName;
  final bool disabled;
  final bool isPlatformAdmin;
}

class PlatformTenantSummary {
  const PlatformTenantSummary({required this.id, required this.displayName});

  factory PlatformTenantSummary.fromMap(Map<String, Object?> data) {
    return PlatformTenantSummary(
      id: data['id'] as String? ?? '',
      displayName: data['displayName'] as String? ?? 'Unnamed restaurant',
    );
  }

  final String id;
  final String displayName;
}
