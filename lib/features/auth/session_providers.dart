import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/firestore_pos_repository.dart';
import '../../data/platform_admin_repository.dart';
import '../pos/domain.dart';

final platformAdminProvider = FutureProvider<bool>((ref) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return false;
  final token = await user.getIdTokenResult();
  return token.claims?['platformAdmin'] == true;
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
