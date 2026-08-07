import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/firestore_pos_repository.dart';
import '../pos/domain.dart';

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
