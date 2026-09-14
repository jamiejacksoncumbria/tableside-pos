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
  // The signed Firebase custom claim is the client-side authority for showing
  // platform tools. Never probe the protected platformAdmins collection from
  // an ordinary client: the intentional rule denial both leaks into logs and,
  // more importantly, can prevent a native till reaching its cached venue and
  // offline PIN screen when it cold-starts without internet.
  //
  // Platform bootstrap already forces an ID-token refresh before invalidating
  // this provider, so a second Firestore fallback is neither necessary nor a
  // safe dependency of normal sign-in.
  return hasCustomClaim;
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
