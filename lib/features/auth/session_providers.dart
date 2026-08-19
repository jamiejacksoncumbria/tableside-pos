import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../data/firestore_pos_repository.dart';
import '../../data/platform_admin_repository.dart';
import '../pos/domain.dart';

final platformAdminProvider = FutureProvider<bool>((ref) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) {
    AppLogger.info('Platform access check: no signed-in user.');
    return false;
  }
  final token = await user.getIdTokenResult();
  final hasCustomClaim = token.claims?['platformAdmin'] == true;
  AppLogger.info(
    'Platform access check: custom admin claim present=$hasCustomClaim.',
  );
  if (hasCustomClaim) return true;

  // The matching Firestore rule permits this person to read only their own
  // record. It is written exclusively by trusted server code and bridges the
  // short period before Firebase Auth exposes a new custom claim on native
  // clients.
  try {
    final record = await FirebaseFirestore.instance
        .doc('platformAdmins/${user.uid}')
        .get();
    AppLogger.info(
      'Platform access check: server admin record found=${record.exists}.',
    );
    return record.exists;
  } on Object catch (error, stackTrace) {
    AppLogger.error('Platform admin record check', error, stackTrace);
    rethrow;
  }
});

final platformAuthUsersProvider =
    FutureProvider.autoDispose<List<PlatformAuthUser>>(
      (ref) => ref.watch(platformAdminRepositoryProvider).listAuthUsers(),
    );

final platformTenantsProvider =
    FutureProvider.autoDispose<List<PlatformTenantSummary>>(
      (ref) => ref.watch(platformAdminRepositoryProvider).listTenants(),
    );

final membershipsProvider =
    StreamProvider.family<List<TenantMembership>, String>(
      (ref, userId) =>
          ref.watch(firestorePosRepositoryProvider).watchMemberships(userId),
    );

final venuesProvider = StreamProvider.family<List<Venue>, String>(
  (ref, tenantId) =>
      ref.watch(firestorePosRepositoryProvider).watchVenues(tenantId),
);

final liveTenantProfileProvider = StreamProvider.family<TenantProfile, String>(
  (ref, tenantId) =>
      ref.watch(firestorePosRepositoryProvider).watchTenant(tenantId),
);
