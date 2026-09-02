import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tenant_scope.dart';

final auditTrailRepositoryProvider = Provider<AuditTrailRepository>(
  (ref) => AuditTrailRepository(FirebaseFirestore.instance),
);

final auditTrailProvider = StreamProvider.autoDispose<List<AuditTrailEvent>>((
  ref,
) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(const <AuditTrailEvent>[]);
  return ref.watch(auditTrailRepositoryProvider).watchLatest(scope.tenantId);
});

class AuditTrailRepository {
  const AuditTrailRepository(this._firestore);

  final FirebaseFirestore _firestore;

  Stream<List<AuditTrailEvent>> watchLatest(String tenantId) => _firestore
      .collection('tenants/$tenantId/auditEvents')
      .orderBy('createdAt', descending: true)
      .limit(250)
      .snapshots()
      .map(
        (snapshot) => snapshot.docs
            .map(AuditTrailEvent.fromDocument)
            .toList(growable: false),
      );
}

class AuditTrailEvent {
  const AuditTrailEvent({
    required this.id,
    required this.action,
    required this.actorUserId,
    required this.venueId,
    required this.target,
    required this.createdAt,
    required this.details,
  });

  factory AuditTrailEvent.fromDocument(
    QueryDocumentSnapshot<Map<String, dynamic>> document,
  ) {
    final data = document.data();
    final createdAt = data['createdAt'];
    final actor =
        data['actorUid'] ??
        data['actor'] ??
        data['callerUid'] ??
        data['createdByActor'] ??
        data['updatedByActor'];
    final rawDetails = data['details'];
    final details = rawDetails is Map
        ? Map<String, Object?>.from(rawDetails)
        : <String, Object?>{
            for (final entry in data.entries)
              if (!const {
                'action',
                'actorUid',
                'actor',
                'callerUid',
                'createdAt',
                'venueId',
                'target',
              }.contains(entry.key))
                entry.key: entry.value,
          };
    final directVenueId = data['venueId'];
    final detailedVenueId = details['venueId'];
    return AuditTrailEvent(
      id: document.id,
      action: data['action'] as String? ?? 'unknownAction',
      actorUserId: actor is String ? actor : null,
      venueId: directVenueId is String
          ? directVenueId
          : detailedVenueId is String
          ? detailedVenueId
          : null,
      target: _firstString(data, const [
        'target',
        'orderId',
        'billId',
        'productId',
        'tableId',
        'deviceId',
        'documentId',
      ]),
      createdAt: createdAt is Timestamp ? createdAt.toDate() : null,
      details: details,
    );
  }

  final String id;
  final String action;
  final String? actorUserId;
  final String? venueId;
  final String? target;
  final DateTime? createdAt;
  final Map<String, Object?> details;

  static String? _firstString(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final value = data[key];
      if (value is String && value.isNotEmpty) return value;
    }
    return null;
  }
}
