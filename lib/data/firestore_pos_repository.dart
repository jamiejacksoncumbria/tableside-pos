import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/tenant_scope.dart';
import '../features/pos/domain.dart';

final firestorePosRepositoryProvider = Provider<FirestorePosRepository>(
  (ref) => FirestorePosRepository(FirebaseFirestore.instance),
);

class FirestorePosRepository {
  FirestorePosRepository(this._firestore);

  final FirebaseFirestore _firestore;

  Stream<List<TenantMembership>> watchMemberships(String userId) {
    return _firestore
        .collectionGroup('members')
        .where('userId', isEqualTo: userId)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map((document) {
                final data = document.data();
                return TenantMembership(
                  tenantId: document.reference.parent.parent!.id,
                  userId: data['userId'] as String,
                  roles: List<String>.from(data['roles'] as List? ?? const []),
                  defaultVenueId: data['defaultVenueId'] as String?,
                );
              })
              .toList(growable: false),
        );
  }

  Stream<TenantProfile> watchTenant(String tenantId) {
    return _firestore.doc('tenants/$tenantId').snapshots().map((document) {
      final data = document.data() ?? const <String, dynamic>{};
      return TenantProfile(
        id: document.id,
        displayName: data['displayName'] as String? ?? 'Unnamed restaurant',
        legalName: data['legalName'] as String? ?? '',
        currencyCode: data['currencyCode'] as String? ?? 'GBP',
        logoUrl: data['logoUrl'] as String?,
        address: data['address'] as String? ?? '',
        phone: data['phone'] as String? ?? '',
        receiptFooter: data['receiptFooter'] as String? ?? '',
      );
    });
  }

  Stream<List<Venue>> watchVenues(String tenantId) {
    return _firestore
        .collection('tenants/$tenantId/venues')
        .orderBy('name')
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map((document) {
                final data = document.data();
                return Venue(
                  id: document.id,
                  tenantId: tenantId,
                  name: data['name'] as String? ?? 'Unnamed venue',
                  timeZone: data['timeZone'] as String? ?? 'UTC',
                );
              })
              .toList(growable: false),
        );
  }

  Stream<List<MenuSection>> watchMenuSections(String tenantId) {
    return _firestore
        .collection('tenants/$tenantId/menuSections')
        .orderBy('sortOrder')
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map((document) {
                final data = document.data();
                return MenuSection(
                  id: document.id,
                  name: data['name'] as String? ?? 'Unnamed section',
                  icon: data['icon'] as String? ?? '🍽️',
                );
              })
              .toList(growable: false),
        );
  }

  Stream<List<MenuProduct>> watchProducts(String tenantId) {
    return _firestore
        .collection('tenants/$tenantId/products')
        .orderBy('name')
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map((document) {
                final data = document.data();
                return MenuProduct(
                  id: document.id,
                  name: data['name'] as String? ?? 'Unnamed product',
                  priceMinor: data['priceMinor'] as int? ?? 0,
                  sectionIds: List<String>.from(
                    data['sectionIds'] as List? ?? const [],
                  ),
                  productionArea: _productionArea(
                    data['productionArea'] as String?,
                  ),
                  trackStock: data['trackStock'] as bool? ?? false,
                  stockOnHand: data['stockOnHand'] as int?,
                  isAvailable: data['isAvailable'] as bool? ?? true,
                );
              })
              .toList(growable: false),
        );
  }

  Stream<List<DiningTable>> watchTables(VenueScope scope) {
    return _firestore
        .collection('tenants/${scope.tenantId}/tables')
        .where('venueId', isEqualTo: scope.venueId)
        .orderBy('label')
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map((document) {
                final data = document.data();
                return DiningTable(
                  id: document.id,
                  label: data['label'] as String? ?? 'Table',
                  seats: data['seats'] as int? ?? 0,
                  hasOpenOrder: data['currentOrderId'] != null,
                );
              })
              .toList(growable: false),
        );
  }

  ProductionArea _productionArea(String? value) => switch (value) {
    'bar' => ProductionArea.bar,
    _ => ProductionArea.kitchen,
  };
}
