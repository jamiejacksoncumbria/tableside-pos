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
  // Never probe the protected platformAdmins collection directly from the
  // client. Older administrator accounts may not yet carry the custom claim,
  // so the narrowly scoped server check below verifies the protected record.
  // Failure is deliberately treated as ordinary access so an offline till is
  // never prevented from reaching its venue and cached PIN screen.
  if (hasCustomClaim) return true;
  try {
    final hasServerRecord = await ref
        .read(platformAdminRepositoryProvider)
        .hasPlatformAdminAccess();
    AppLogger.info(
      'Platform access check: protected server admin record found=$hasServerRecord.',
    );
    return hasServerRecord;
  } on Object catch (error, stackTrace) {
    // Platform discovery must never prevent an ordinary till reaching its
    // cached venue and offline PIN screen. Fail closed for platform tools.
    AppLogger.error('Platform access server check', error, stackTrace);
    return false;
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
