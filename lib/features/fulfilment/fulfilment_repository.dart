import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tenant_scope.dart';
import '../../data/production_command_repository.dart';
import '../../offline/venue_hub_client_registry.dart';
import '../../offline/venue_hub_offline_view.dart';
import '../pos/domain.dart';
import 'fulfilment_domain.dart';

final fulfilmentRepositoryProvider = Provider<FulfilmentRepository>(
  (ref) => FulfilmentRepository(
    FirebaseFirestore.instance,
    ref.watch(productionCommandRepositoryProvider),
  ),
);

final venueCoursesProvider = StreamProvider<List<MenuCourse>>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(const <MenuCourse>[]);
  return ref.watch(fulfilmentRepositoryProvider).watchCourses(scope);
});

final venueCustomersProvider = StreamProvider<List<VenueCustomer>>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(const <VenueCustomer>[]);
  if (!kIsWeb && VenueHubClientRegistry.instance.requiresHub(scope)) {
    return VenueHubOfflineView.instance.customerStream;
  }
  return ref.watch(fulfilmentRepositoryProvider).watchCustomers(scope);
});

final fulfilmentOrdersProvider = StreamProvider<List<PosOrder>>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(const <PosOrder>[]);
  if (!kIsWeb && VenueHubClientRegistry.instance.requiresHub(scope)) {
    return VenueHubOfflineView.instance.orderStream.map(
      (orders) => orders
          .where(
            (order) =>
                order.channel != OrderChannel.dineIn &&
                order.status != OrderStatus.closed,
          )
          .toList(growable: false),
    );
  }
  return ref.watch(fulfilmentRepositoryProvider).watchFulfilmentOrders(scope);
});

final fulfilmentStaffProvider = StreamProvider<List<FulfilmentStaffMember>>((
  ref,
) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(const <FulfilmentStaffMember>[]);
  return ref.watch(fulfilmentRepositoryProvider).watchStaff(scope);
});

final venueFulfilmentSettingsProvider = StreamProvider<VenueFulfilmentSettings>(
  (ref) {
    final scope = ref.watch(activeVenueScopeProvider);
    if (scope == null) return Stream.value(const VenueFulfilmentSettings());
    if (!kIsWeb && VenueHubClientRegistry.instance.requiresHub(scope)) {
      return VenueHubOfflineView.instance.fulfilmentSettingsStream;
    }
    return ref.watch(fulfilmentRepositoryProvider).watchSettings(scope);
  },
);

class FulfilmentRepository {
  FulfilmentRepository(this._firestore, this._commands);

  final FirebaseFirestore _firestore;
  final ProductionCommandRepository _commands;

  Stream<VenueFulfilmentSettings> watchSettings(VenueScope scope) => _firestore
      .doc('tenants/${scope.tenantId}/venues/${scope.venueId}')
      .snapshots()
      .map((document) {
        final data = document.data() ?? const <String, dynamic>{};
        return VenueFulfilmentSettings(
          collectionEnabled: data['collectionEnabled'] as bool? ?? false,
          deliveryEnabled: data['deliveryEnabled'] as bool? ?? false,
          courseControlEnabled: data['courseControlEnabled'] as bool? ?? false,
          collectionWindows: _windows(data['collectionWindows']),
          deliveryWindows: _windows(data['deliveryWindows']),
          serviceAreas: _areas(data['serviceAreas']),
          dateOverrides: _dateOverrides(data['fulfilmentDateOverrides']),
        );
      });

  Stream<List<MenuCourse>> watchCourses(VenueScope scope) => _firestore
      .collection('tenants/${scope.tenantId}/courses')
      .where('venueId', isEqualTo: scope.venueId)
      .snapshots()
      .map((snapshot) {
        final courses = snapshot.docs.map((document) {
          final data = document.data();
          return MenuCourse(
            id: document.id,
            name: data['name'] as String? ?? 'Course',
            sequence: (data['sequence'] as num?)?.toInt() ?? 0,
            active: data['active'] as bool? ?? true,
            releasePolicy: _releasePolicy(data['releasePolicy'] as String?),
            amberMinutes: (data['amberMinutes'] as num?)?.toInt() ?? 15,
            redMinutes: (data['redMinutes'] as num?)?.toInt() ?? 25,
            productionAreas: (data['productionAreas'] as List? ?? const [])
                .whereType<String>()
                .map(_productionArea)
                .toList(growable: false),
          );
        }).toList();
        courses.sort((a, b) => a.sequence.compareTo(b.sequence));
        return courses;
      });

  Stream<List<VenueCustomer>> watchCustomers(VenueScope scope) => _firestore
      .collection('tenants/${scope.tenantId}/venueCustomers')
      .where('venueId', isEqualTo: scope.venueId)
      .snapshots()
      .map((snapshot) {
        final customers = snapshot.docs.map((document) {
          final data = document.data();
          final createdAt = data['createdAt'];
          return VenueCustomer(
            id: document.id,
            displayName: data['displayName'] as String? ?? 'Customer',
            phoneNumbers: (data['phoneNumbers'] as List? ?? const [])
                .whereType<String>()
                .toList(growable: false),
            email: data['email'] as String?,
            claimStatus: data['claimStatus'] as String? ?? 'unclaimed',
            globalCustomerId: data['globalCustomerId'] as String?,
            createdAt: createdAt is Timestamp ? createdAt.toDate() : null,
            addresses: (data['addresses'] as List? ?? const [])
                .whereType<Map>()
                .map((raw) {
                  final item = Map<String, dynamic>.from(raw);
                  return CustomerAddress(
                    id: item['id'] as String? ?? '',
                    label: item['label'] as String? ?? 'Address',
                    country: item['country'] as String? ?? '',
                    town: item['town'] as String? ?? '',
                    area: item['area'] as String? ?? '',
                    addressLines: item['addressLines'] as String? ?? '',
                    notes: item['notes'] as String? ?? '',
                  );
                })
                .toList(growable: false),
          );
        }).toList();
        customers.sort(
          (a, b) => a.displayName.toLowerCase().compareTo(
            b.displayName.toLowerCase(),
          ),
        );
        return customers;
      });

  Stream<List<PosOrder>> watchFulfilmentOrders(VenueScope scope) => _firestore
      .collection('tenants/${scope.tenantId}/orders')
      .where('venueId', isEqualTo: scope.venueId)
      .snapshots()
      .map((snapshot) {
        final orders = snapshot.docs
            .map(_fulfilmentOrder)
            .whereType<PosOrder>()
            .where(
              (order) =>
                  order.channel != OrderChannel.dineIn &&
                  order.status != OrderStatus.closed,
            )
            .toList();
        orders.sort((left, right) {
          final leftTime = left.scheduledFor ?? left.openedAt;
          final rightTime = right.scheduledFor ?? right.openedAt;
          return leftTime.compareTo(rightTime);
        });
        return orders;
      });

  Stream<List<FulfilmentStaffMember>> watchStaff(VenueScope scope) => _firestore
      .collection('tenants/${scope.tenantId}/members')
      .snapshots()
      .map(
        (snapshot) => snapshot.docs
            .where((document) => document.data()['active'] != false)
            .map((document) {
              final data = document.data();
              return FulfilmentStaffMember(
                id: document.id,
                name:
                    data['displayName'] as String? ??
                    data['email'] as String? ??
                    'Staff member',
                roles: (data['roles'] as List? ?? const [])
                    .whereType<String>()
                    .toList(growable: false),
                venueIds: (data['venueIds'] as List? ?? const [])
                    .whereType<String>()
                    .toList(growable: false),
              );
            })
            .where((staff) => staff.availableAt(scope.venueId))
            .toList(growable: false),
      );

  PosOrder? _fulfilmentOrder(
    QueryDocumentSnapshot<Map<String, dynamic>> document,
  ) {
    final data = document.data();
    final channel = switch (data['channel']) {
      'collection' => OrderChannel.collection,
      'delivery' => OrderChannel.delivery,
      _ => OrderChannel.dineIn,
    };
    if (channel == OrderChannel.dineIn) return null;
    final rawStatus = data['status'] as String? ?? 'draft';
    final status = switch (rawStatus) {
      'sent' => OrderStatus.sent,
      'closed' => OrderStatus.closed,
      'pendingApproval' => OrderStatus.pendingApproval,
      'rolledOver' => OrderStatus.rolledOver,
      _ => OrderStatus.open,
    };
    final fulfilmentStatus = switch (data['fulfilmentStatus']) {
      'readyForCollection' => FulfilmentStatus.readyForCollection,
      'awaitingDriver' => FulfilmentStatus.awaitingDriver,
      'assigned' => FulfilmentStatus.assigned,
      'outForDelivery' => FulfilmentStatus.outForDelivery,
      'collected' => FulfilmentStatus.collected,
      'delivered' => FulfilmentStatus.delivered,
      'cancelled' => FulfilmentStatus.cancelled,
      _ => FulfilmentStatus.awaitingPreparation,
    };
    final openedAt = data['openedAt'];
    final scheduledFor = data['scheduledFor'];
    return PosOrder(
      id: document.id,
      tenantId: document.reference.parent.parent?.id ?? '',
      venueId: data['venueId'] as String? ?? '',
      businessDate: DateTime.now(),
      openedAt: openedAt is Timestamp ? openedAt.toDate() : DateTime.now(),
      status: status,
      lines: const [],
      channel: channel,
      fulfilmentStatus: fulfilmentStatus,
      customerId: data['customerId'] as String?,
      customerName: data['customerName'] as String?,
      customerPhone: data['customerPhone'] as String?,
      deliveryAddress: data['deliveryAddress'] as String?,
      scheduledFor: scheduledFor is Timestamp
          ? scheduledFor.toDate()
          : scheduledFor is String
          ? DateTime.tryParse(scheduledFor)
          : null,
      assignedDriverId: data['assignedDriverId'] as String?,
      assignedDriverName: data['assignedDriverName'] as String?,
      primaryWaiterId: data['primaryWaiterId'] as String?,
      primaryWaiterName: data['primaryWaiterName'] as String?,
    );
  }

  Future<void> updateFulfilmentOrder({
    required VenueScope scope,
    required String orderId,
    required FulfilmentStatus status,
    String? driverId,
  }) => _commands.manageFulfilment(
    scope: scope,
    operation: 'updateOrderFulfilment',
    documentId: orderId,
    values: {'status': status.name, if (driverId != null) 'driverId': driverId},
  );

  Future<void> saveSettings({
    required VenueScope scope,
    required VenueFulfilmentSettings settings,
  }) => _commands.manageVenueConfiguration(
    scope: scope,
    resource: 'fulfilmentSettings',
    values: {
      'collectionEnabled': settings.collectionEnabled,
      'deliveryEnabled': settings.deliveryEnabled,
      'courseControlEnabled': settings.courseControlEnabled,
      'collectionWindows': settings.collectionWindows.map(_windowMap).toList(),
      'deliveryWindows': settings.deliveryWindows.map(_windowMap).toList(),
      'serviceAreas': settings.serviceAreas.map(_areaMap).toList(),
      'dateOverrides': settings.dateOverrides.map(_dateOverrideMap).toList(),
    },
  );

  Future<void> saveCourse(VenueScope scope, MenuCourse course) async {
    await _commands.manageFulfilment(
      scope: scope,
      operation: 'saveCourse',
      documentId: course.id == 'new' ? null : course.id,
      values: {
        'name': course.name,
        'sequence': course.sequence,
        'active': course.active,
        'releasePolicy': course.releasePolicy.name,
        'amberMinutes': course.amberMinutes,
        'redMinutes': course.redMinutes,
        'productionAreas': course.productionAreas
            .map((area) => area.name)
            .toList(),
      },
    );
  }

  Future<void> archiveCourse(VenueScope scope, String courseId) async {
    await _commands.manageFulfilment(
      scope: scope,
      operation: 'archiveCourse',
      documentId: courseId,
    );
  }

  Future<String> saveCustomer({
    required VenueScope scope,
    String? customerId,
    required String displayName,
    required List<String> phoneNumbers,
    String? email,
    List<CustomerAddress> addresses = const [],
  }) async {
    final result = await _commands.manageFulfilment(
      scope: scope,
      operation: 'saveCustomer',
      documentId: customerId,
      values: {
        'displayName': displayName,
        'phoneNumbers': phoneNumbers,
        'email': email,
        'addresses': addresses.map(_addressMap).toList(),
      },
    );
    return result['documentId'] as String;
  }

  Map<String, Object?> _windowMap(ServiceWindow value) => {
    'weekday': value.weekday,
    'opensMinute': value.opensMinute,
    'closesMinute': value.closesMinute,
    'enabled': value.enabled,
  };

  Map<String, Object?> _areaMap(ServiceArea value) => {
    'id': value.id,
    'name': value.name,
    'deliveryFeeMinor': value.deliveryFeeMinor,
    'minimumOrderMinor': value.minimumOrderMinor,
    'estimatedMinutes': value.estimatedMinutes,
    'active': value.active,
  };

  Map<String, Object?> _addressMap(CustomerAddress value) => {
    'id': value.id,
    'label': value.label,
    'country': value.country,
    'town': value.town,
    'area': value.area,
    'addressLines': value.addressLines,
    'notes': value.notes,
  };

  List<ServiceWindow> _windows(Object? raw) => (raw as List? ?? const [])
      .whereType<Map>()
      .map((item) {
        final value = Map<String, dynamic>.from(item);
        return ServiceWindow(
          weekday: (value['weekday'] as num?)?.toInt() ?? 1,
          opensMinute: (value['opensMinute'] as num?)?.toInt() ?? 0,
          closesMinute: (value['closesMinute'] as num?)?.toInt() ?? 0,
          enabled: value['enabled'] as bool? ?? true,
        );
      })
      .toList(growable: false);

  List<ServiceArea> _areas(Object? raw) => (raw as List? ?? const [])
      .whereType<Map>()
      .map((item) {
        final value = Map<String, dynamic>.from(item);
        return ServiceArea(
          id: value['id'] as String? ?? '',
          name: value['name'] as String? ?? 'Area',
          deliveryFeeMinor: (value['deliveryFeeMinor'] as num?)?.toInt() ?? 0,
          minimumOrderMinor: (value['minimumOrderMinor'] as num?)?.toInt() ?? 0,
          estimatedMinutes: (value['estimatedMinutes'] as num?)?.toInt() ?? 45,
          active: value['active'] as bool? ?? true,
        );
      })
      .where((area) => area.id.isNotEmpty)
      .toList(growable: false);

  List<ServiceDateOverride> _dateOverrides(Object? raw) =>
      (raw as List? ?? const [])
          .whereType<Map>()
          .map((item) {
            final value = Map<String, dynamic>.from(item);
            final date = DateTime.tryParse(value['date'] as String? ?? '');
            if (date == null) return null;
            return ServiceDateOverride(
              id: value['id'] as String? ?? '',
              date: date,
              channel: value['channel'] == 'delivery'
                  ? OrderChannel.delivery
                  : OrderChannel.collection,
              closed: value['closed'] as bool? ?? true,
              windows: _windows(value['windows']),
              note: value['note'] as String? ?? '',
            );
          })
          .whereType<ServiceDateOverride>()
          .toList(growable: false);

  Map<String, Object?> _dateOverrideMap(ServiceDateOverride value) => {
    'id': value.id,
    'date': value.date.toIso8601String().split('T').first,
    'channel': value.channel.name,
    'closed': value.closed,
    'windows': value.windows.map(_windowMap).toList(),
    'note': value.note,
  };
}

CourseReleasePolicy _releasePolicy(String? value) => switch (value) {
  'manual' => CourseReleasePolicy.manual,
  'afterPreviousCollected' => CourseReleasePolicy.afterPreviousCollected,
  'afterPreviousServed' => CourseReleasePolicy.afterPreviousServed,
  _ => CourseReleasePolicy.immediate,
};

ProductionArea _productionArea(String value) => switch (value) {
  'bar' => ProductionArea.bar,
  'dessert' => ProductionArea.dessert,
  _ => ProductionArea.kitchen,
};
