import 'dart:async';

import '../features/fulfilment/fulfilment_domain.dart';
import '../features/pos/domain.dart';

/// Last hub-approved catalogue used only when a Firestore stream fails.
/// Server mutations still independently canonicalise every line.
class VenueHubOfflineView {
  VenueHubOfflineView._();

  static final VenueHubOfflineView instance = VenueHubOfflineView._();
  Map<String, Object?>? _snapshot;
  final StreamController<void> _catalogueChanges =
      StreamController<void>.broadcast();
  final StreamController<List<PosOrder>> _orders =
      StreamController<List<PosOrder>>.broadcast();
  List<PosOrder> _currentOrders = const [];
  Map<String, Map<String, _OfflineTicketState>> _ticketStatesByOrder = const {};

  void install(Map<String, Object?> snapshot) {
    _snapshot = Map<String, Object?>.unmodifiable(snapshot);
    _catalogueChanges.add(null);
    // Tables depend on both catalogue and order state. Re-emit the current
    // orders so a screen opened before PIN/hub setup refreshes immediately.
    _orders.add(_currentOrders);
  }

  void clear() {
    _snapshot = null;
    _currentOrders = const [];
    _ticketStatesByOrder = const {};
    _catalogueChanges.add(null);
    _orders.add(_currentOrders);
  }

  Stream<List<MenuSection>> get sectionStream async* {
    yield sections;
    await for (final _ in _catalogueChanges.stream) {
      yield sections;
    }
  }

  Stream<List<MenuProduct>> productStream({
    bool includeArchived = false,
  }) async* {
    List<MenuProduct> current() => includeArchived
        ? products
        : products
              .where((product) => !product.isArchived)
              .toList(growable: false);
    yield current();
    await for (final _ in _catalogueChanges.stream) {
      yield current();
    }
  }

  Stream<List<MenuModifierGroup>> get modifierGroupStream async* {
    yield modifierGroups;
    await for (final _ in _catalogueChanges.stream) {
      yield modifierGroups;
    }
  }

  Stream<List<DiningTable>> get tableStream async* {
    yield tables;
    await for (final _ in _catalogueChanges.stream) {
      yield tables;
    }
  }

  Stream<List<VenueCustomer>> get customerStream async* {
    yield customers;
    await for (final _ in _catalogueChanges.stream) {
      yield customers;
    }
  }

  Stream<VenueFulfilmentSettings> get fulfilmentSettingsStream async* {
    yield fulfilmentSettings;
    await for (final _ in _catalogueChanges.stream) {
      yield fulfilmentSettings;
    }
  }

  Stream<List<MenuCourse>> get courseStream async* {
    yield courses;
    await for (final _ in _catalogueChanges.stream) {
      yield courses;
    }
  }

  Stream<List<FulfilmentStaffMember>> get staffStream async* {
    yield staff;
    await for (final _ in _catalogueChanges.stream) {
      yield staff;
    }
  }

  Stream<List<PosOrder>> get orderStream async* {
    yield _currentOrders;
    yield* _orders.stream;
  }

  /// Production tickets reconstructed from the hub's durable order ledger.
  /// Lines sent in the same operation share an exact `sentAt` timestamp and
  /// are grouped by production area/course, matching the cloud ticket model.
  Stream<List<OrderFlowOrder>> get orderFlowStream async* {
    yield orderFlowOrders;
    await for (final _ in _orders.stream) {
      yield orderFlowOrders;
    }
  }

  /// Forces time-sensitive held tickets to be recalculated without mutating
  /// any order data. Used by the KDS clock when running without Firebase.
  void refreshOrderFlow() => _orders.add(_currentOrders);

  List<PosOrder> get currentOrders => _currentOrders;

  List<OrderFlowOrder> get orderFlowOrders {
    final productVisibility = <String, bool>{
      for (final product in products) product.id: product.showOnOrderFlow,
    };
    final tableNames = <String, String>{
      for (final table in tables) table.id: table.label,
    };
    final staffNames = <String, String>{
      for (final member in staff) member.id: member.name,
    };
    final result = <OrderFlowOrder>[];
    for (final order in _currentOrders) {
      final grouped = <String, List<OrderLine>>{};
      for (final line in order.lines) {
        if (!line.isSentToProduction ||
            productVisibility[line.productId] == false) {
          continue;
        }
        final sentAt = line.sentAt ?? order.openedAt;
        final batchId =
            line.productionBatchId ??
            'legacy_${sentAt.toUtc().microsecondsSinceEpoch}';
        final key = '$batchId:${line.productionArea.name}';
        grouped.putIfAbsent(key, () => <OrderLine>[]).add(line);
      }
      for (final entry in grouped.entries) {
        final lines = entry.value;
        final first = lines.first;
        final batchId =
            first.productionBatchId ??
            'legacy_${(first.sentAt ?? order.openedAt).toUtc().microsecondsSinceEpoch}';
        final ticketId = 'offline_${batchId}_${first.productionArea.name}';
        final savedState = _ticketStatesByOrder[order.id]?[ticketId];
        final sentAt = first.sentAt ?? order.openedAt;
        final leadMinutes = order.channel == OrderChannel.delivery
            ? fulfilmentSettings.deliveryLeadMinutes
            : fulfilmentSettings.collectionLeadMinutes;
        final releaseAt =
            order.channel == OrderChannel.dineIn || order.scheduledFor == null
            ? sentAt
            : order.scheduledFor!.subtract(Duration(minutes: leadMinutes));
        final initiallyHeld =
            order.channel != OrderChannel.dineIn &&
            DateTime.now().isBefore(releaseAt);
        final status =
            savedState?.status ??
            (initiallyHeld ? OrderFlowStatus.held : OrderFlowStatus.newOrder);
        if (order.status == OrderStatus.closed && savedState == null) continue;
        if (status.isTerminal) continue;
        result.add(
          OrderFlowOrder(
            id: ticketId,
            tenantId: order.tenantId,
            venueId: order.venueId,
            reference:
                order.tabName ??
                order.customerName ??
                tableNames[order.tableId] ??
                'Order',
            productionArea: first.productionArea,
            status: status,
            ticketReleasedAt: releaseAt,
            itemSummary: <String>[
              for (final line in lines) ...<String>[
                '${line.quantity} x ${line.productName}',
                ...line.productionDetails.map((detail) => '  $detail'),
              ],
            ],
            tableLabel: order.tableId == null
                ? null
                : tableNames[order.tableId] ?? order.tableId,
            tabName: order.tabName,
            createdByName: order.primaryWaiterName ?? 'Staff member',
            hasAllergyAlert: lines.any(
              (line) => line.productionDetails.any(
                (detail) => detail.toLowerCase().contains('allerg'),
              ),
            ),
            channel: order.channel,
            customerName: order.customerName,
            scheduledFor: order.scheduledFor,
            courseName: first.courseName,
            orderId: order.id,
            assignedDriverName:
                order.assignedDriverName ??
                (order.assignedDriverId == null
                    ? null
                    : staffNames[order.assignedDriverId]),
            driverDeclined:
                order.fulfilmentStatus == FulfilmentStatus.driverDeclined,
            isDelayed: savedState?.isDelayed ?? false,
          ),
        );
      }
    }
    result.sort(
      (left, right) => left.ticketReleasedAt.compareTo(right.ticketReleasedAt),
    );
    return result;
  }

  String get venueCountry =>
      _snapshot?['venueCountry'] as String? ?? 'Kuzey Kıbrıs Türk Cumhuriyeti';

  Map<String, List<String>> get deliveryLocations {
    final raw = _snapshot?['deliveryLocations'];
    if (raw is! Map) return const <String, List<String>>{};
    return <String, List<String>>{
      for (final entry in raw.entries)
        if (entry.key is String && entry.value is List)
          entry.key as String: (entry.value as List).whereType<String>().toList(
            growable: false,
          ),
    };
  }

  void installOrders(List<Map<String, Object?>> values) {
    _ticketStatesByOrder = <String, Map<String, _OfflineTicketState>>{
      for (final value in values)
        if (value['orderId'] is String)
          value['orderId']! as String: _ticketStates(
            value['productionTicketStates'],
          ),
    };
    _currentOrders = values
        .map(_order)
        .whereType<PosOrder>()
        .toList(growable: false);
    _orders.add(_currentOrders);
  }

  PosOrder? _order(Map<String, Object?> value) {
    final orderId = value['orderId'];
    final openedAt = DateTime.tryParse(value['openedAtUtc'] as String? ?? '');
    final rawLines = value['lines'];
    if (orderId is! String || openedAt == null || rawLines is! List) {
      return null;
    }
    final lines = rawLines
        .whereType<Map>()
        .map((line) {
          final area = switch (line['productionArea']) {
            'bar' => ProductionArea.bar,
            'dessert' => ProductionArea.dessert,
            _ => ProductionArea.kitchen,
          };
          return OrderLine(
            id: line['id'] as String,
            productId: line['productId'] as String,
            productName: line['name'] as String,
            quantity: (line['quantity'] as num).toInt(),
            unitPriceMinor: (line['unitPriceMinor'] as num).toInt(),
            productionArea: area,
            trackStock: false,
            isSentToProduction: line['sent'] == true,
            taxRateBasisPoints:
                (line['taxRateBasisPoints'] as num?)?.toInt() ?? 0,
            taxRateName: line['taxRateName'] as String? ?? 'Zero Rate',
            addedAt: DateTime.tryParse(
              line['addedAtUtc'] as String? ?? '',
            )?.toLocal(),
            sentAt: DateTime.tryParse(
              line['sentAtUtc'] as String? ?? '',
            )?.toLocal(),
            productionBatchId: line['sentEventId'] as String?,
            persistedProductionDetails: (line['details'] as List? ?? const [])
                .whereType<String>()
                .toList(growable: false),
          );
        })
        .toList(growable: false);
    final rawPayments = value['payments'];
    final payments = rawPayments is List
        ? rawPayments
              .whereType<Map>()
              .map(
                (payment) => OrderPayment(
                  id: payment['id'] as String,
                  method: payment['method'] as String,
                  tenderedAmountMinor:
                      (payment['tenderedAmountMinor'] as num?)?.toInt() ??
                      (payment['baseAmountMinor'] as num).toInt(),
                  tenderedCurrencyCode: payment['currencyCode'] as String,
                  baseAmountMinor: (payment['baseAmountMinor'] as num).toInt(),
                  exchangeRateToBase:
                      payment['exchangeRateToBase'] as String? ?? '1',
                  recordedAt:
                      DateTime.tryParse(
                        payment['recordedAtUtc'] as String? ?? '',
                      )?.toLocal() ??
                      openedAt.toLocal(),
                  terminalLabel: payment['terminalLabel'] as String?,
                  cashChangeBaseMinor:
                      (payment['cashChangeBaseMinor'] as num?)?.toInt() ?? 0,
                ),
              )
              .toList(growable: false)
        : const <OrderPayment>[];
    return PosOrder(
      id: orderId,
      tenantId: value['tenantId'] as String,
      venueId: value['venueId'] as String,
      tableId: value['tableId'] as String?,
      tabName: value['tabName'] as String?,
      businessDate: _businessDate(openedAt),
      openedAt: openedAt.toLocal(),
      status: value['isClosed'] == true
          ? OrderStatus.closed
          : lines.any((line) => line.isSentToProduction)
          ? OrderStatus.sent
          : OrderStatus.open,
      lines: lines,
      splitFromOrderId: value['splitFromOrderId'] as String?,
      splitSequence: (value['splitSequence'] as num?)?.toInt(),
      openSplitOrderIds:
          (value['openSplitOrderIds'] as List?)?.whereType<String>().toList(
            growable: false,
          ) ??
          const <String>[],
      payments: payments,
      channel: switch (value['channel']) {
        'collection' => OrderChannel.collection,
        'delivery' => OrderChannel.delivery,
        _ => OrderChannel.dineIn,
      },
      fulfilmentStatus: switch (value['fulfilmentStatus']) {
        'readyForCollection' => FulfilmentStatus.readyForCollection,
        'awaitingDriver' => FulfilmentStatus.awaitingDriver,
        'assigned' => FulfilmentStatus.assigned,
        'driverDeclined' => FulfilmentStatus.driverDeclined,
        'outForDelivery' => FulfilmentStatus.outForDelivery,
        'collected' => FulfilmentStatus.collected,
        'delivered' => FulfilmentStatus.delivered,
        'cancelled' => FulfilmentStatus.cancelled,
        _ => FulfilmentStatus.awaitingPreparation,
      },
      assignedDriverId: value['assignedDriverId'] as String?,
      customerId: value['customerId'] as String?,
      customerName: value['customerName'] as String?,
      customerPhone: value['customerPhone'] as String?,
      deliveryAddress: value['deliveryAddress'] as String?,
      deliveryAddressLabel: value['deliveryAddressLabel'] as String?,
      deliveryLatitude: (value['deliveryLatitude'] as num?)?.toDouble(),
      deliveryLongitude: (value['deliveryLongitude'] as num?)?.toDouble(),
      serviceAreaId: value['serviceAreaId'] as String?,
      serviceAreaName: value['serviceAreaName'] as String?,
      deliveryFeeMinor: (value['deliveryFeeMinor'] as num?)?.toInt() ?? 0,
      scheduledFor: DateTime.tryParse(
        value['scheduledForUtc'] as String? ?? '',
      )?.toLocal(),
    );
  }

  Map<String, _OfflineTicketState> _ticketStates(Object? raw) {
    if (raw is! Map) return const <String, _OfflineTicketState>{};
    return <String, _OfflineTicketState>{
      for (final entry in raw.entries)
        if (entry.key is String && entry.value is Map)
          entry.key as String: _OfflineTicketState.fromJson(
            Map<String, Object?>.from(entry.value as Map),
          ),
    };
  }

  DateTime _businessDate(DateTime utc) {
    final offset = (_snapshot?['venueUtcOffsetMinutes'] as num?)?.toInt() ?? 0;
    final cutoff =
        (_snapshot?['businessDayCutoffMinutes'] as num?)?.toInt() ?? 240;
    var venueTime = utc.toUtc().add(Duration(minutes: offset));
    if ((venueTime.hour * 60) + venueTime.minute < cutoff) {
      venueTime = venueTime.subtract(const Duration(days: 1));
    }
    return DateTime(venueTime.year, venueTime.month, venueTime.day);
  }

  List<MenuSection> get sections {
    final raw = _snapshot?['sections'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) {
          final value = Map<String, Object?>.from(item);
          return MenuSection(
            id: value['id'] as String,
            name: value['name'] as String,
            icon: value['icon'] as String? ?? '🍽️',
            parentSectionId: value['parentSectionId'] as String?,
            sortOrder: (value['sortOrder'] as num?)?.toInt() ?? 0,
          );
        })
        .toList(growable: false);
  }

  List<DiningTable> get tables {
    final raw = _snapshot?['tables'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .where((item) => item['active'] != false)
        .map((item) {
          return DiningTable(
            id: item['id'] as String,
            label: item['label'] as String,
            seats: (item['seats'] as num?)?.toInt() ?? 0,
            sortOrder: (item['sortOrder'] as num?)?.toInt(),
          );
        })
        .toList(growable: false);
  }

  List<VenueCustomer> get customers {
    final raw = _snapshot?['venueCustomers'];
    if (raw is! List) return const [];
    final result = raw
        .whereType<Map>()
        .map((item) {
          final value = Map<String, Object?>.from(item);
          final id = value['id'] as String? ?? '';
          final displayName = value['displayName'] as String? ?? 'Customer';
          return VenueCustomer(
            id: id,
            displayName: displayName,
            phoneNumbers: (value['phoneNumbers'] as List? ?? const [])
                .whereType<String>()
                .toList(growable: false),
            email: value['email'] as String?,
            claimStatus: value['claimStatus'] as String? ?? 'unclaimed',
            globalCustomerId: value['globalCustomerId'] as String?,
            createdAt: DateTime.tryParse(
              value['createdAtUtc'] as String? ?? '',
            )?.toLocal(),
            addresses: (value['addresses'] as List? ?? const [])
                .whereType<Map>()
                .map((address) {
                  return CustomerAddress(
                    id: address['id'] as String? ?? '',
                    label: address['label'] as String? ?? 'Address',
                    country: address['country'] as String? ?? '',
                    town: address['town'] as String? ?? '',
                    area: address['area'] as String? ?? '',
                    addressLines: address['addressLines'] as String? ?? '',
                    notes: address['notes'] as String? ?? '',
                    isDefault: address['isDefault'] as bool? ?? false,
                    latitude: (address['latitude'] as num?)?.toDouble(),
                    longitude: (address['longitude'] as num?)?.toDouble(),
                  );
                })
                .toList(growable: false),
          );
        })
        .where((customer) => customer.id.isNotEmpty)
        .toList(growable: false);
    result.sort(
      (left, right) => left.displayName.toLowerCase().compareTo(
        right.displayName.toLowerCase(),
      ),
    );
    return result;
  }

  List<MenuCourse> get courses {
    final raw = _snapshot?['courses'];
    if (raw is! List) return const <MenuCourse>[];
    final result = raw.whereType<Map>().map((item) {
      return MenuCourse(
        id: item['id'] as String,
        name: item['name'] as String? ?? 'Course',
        sequence: (item['sequence'] as num?)?.toInt() ?? 0,
        releasePolicy: switch (item['releasePolicy']) {
          'manual' => CourseReleasePolicy.manual,
          'afterPreviousCollected' =>
            CourseReleasePolicy.afterPreviousCollected,
          'afterPreviousServed' => CourseReleasePolicy.afterPreviousServed,
          _ => CourseReleasePolicy.immediate,
        },
        amberMinutes: (item['amberMinutes'] as num?)?.toInt() ?? 15,
        redMinutes: (item['redMinutes'] as num?)?.toInt() ?? 25,
        productionAreas: (item['productionAreas'] as List? ?? const [])
            .whereType<String>()
            .map(
              (area) => switch (area) {
                'bar' => ProductionArea.bar,
                'dessert' => ProductionArea.dessert,
                _ => ProductionArea.kitchen,
              },
            )
            .toList(growable: false),
      );
    }).toList();
    result.sort((left, right) => left.sequence.compareTo(right.sequence));
    return result;
  }

  List<FulfilmentStaffMember> get staff {
    final raw = _snapshot?['staff'];
    if (raw is! List) return const <FulfilmentStaffMember>[];
    final result = raw
        .whereType<Map>()
        .map(
          (item) => FulfilmentStaffMember(
            id: item['staffId'] as String? ?? '',
            name: item['displayName'] as String? ?? 'Staff member',
            roles: (item['roles'] as List? ?? const [])
                .whereType<String>()
                .toList(growable: false),
          ),
        )
        .where((item) => item.id.isNotEmpty)
        .toList();
    result.sort(
      (left, right) =>
          left.name.toLowerCase().compareTo(right.name.toLowerCase()),
    );
    return result;
  }

  VenueFulfilmentSettings get fulfilmentSettings => VenueFulfilmentSettings(
    collectionEnabled: _snapshot?['collectionEnabled'] == true,
    deliveryEnabled: _snapshot?['deliveryEnabled'] == true,
    courseControlEnabled: _snapshot?['courseControlEnabled'] == true,
    collectionLeadMinutes:
        (_snapshot?['collectionLeadMinutes'] as num?)?.toInt() ?? 20,
    deliveryLeadMinutes:
        (_snapshot?['deliveryLeadMinutes'] as num?)?.toInt() ?? 20,
    collectionWindows: _serviceWindows(_snapshot?['collectionWindows']),
    deliveryWindows: _serviceWindows(_snapshot?['deliveryWindows']),
    serviceAreas: _serviceAreas(_snapshot?['serviceAreas']),
    dateOverrides: _serviceDateOverrides(_snapshot?['fulfilmentDateOverrides']),
  );

  List<ServiceWindow> _serviceWindows(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((window) {
          return ServiceWindow(
            weekday: (window['weekday'] as num?)?.toInt() ?? 1,
            opensMinute: (window['opensMinute'] as num?)?.toInt() ?? 0,
            closesMinute: (window['closesMinute'] as num?)?.toInt() ?? 1440,
            enabled: window['enabled'] != false,
          );
        })
        .toList(growable: false);
  }

  List<ServiceArea> _serviceAreas(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((area) {
          return ServiceArea(
            id: area['id'] as String? ?? '',
            name: area['name'] as String? ?? 'Area',
            country:
                area['country'] as String? ?? 'Kuzey Kıbrıs Türk Cumhuriyeti',
            district: area['district'] as String? ?? '',
            town: area['town'] as String? ?? area['name'] as String? ?? '',
            deliveryFeeMinor: (area['deliveryFeeMinor'] as num?)?.toInt() ?? 0,
            minimumOrderMinor:
                (area['minimumOrderMinor'] as num?)?.toInt() ?? 0,
            estimatedMinutes: (area['estimatedMinutes'] as num?)?.toInt() ?? 45,
            active: area['active'] != false,
          );
        })
        .where((area) => area.id.isNotEmpty)
        .toList(growable: false);
  }

  List<ServiceDateOverride> _serviceDateOverrides(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((override) {
          final parsedDate = DateTime.tryParse(
            override['date'] as String? ?? '',
          );
          return ServiceDateOverride(
            id: override['id'] as String? ?? '',
            date: parsedDate ?? DateTime(1970),
            channel: override['channel'] == 'delivery'
                ? OrderChannel.delivery
                : OrderChannel.collection,
            closed: override['closed'] != false,
            windows: _serviceWindows(override['windows']),
            note: override['note'] as String? ?? '',
          );
        })
        .where((override) => override.id.isNotEmpty)
        .toList(growable: false);
  }

  List<MenuModifierGroup> get modifierGroups {
    final raw = _snapshot?['modifierGroups'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) {
          return MenuModifierGroup(
            id: item['id'] as String,
            name: item['name'] as String,
            minimumSelections:
                (item['minimumSelections'] as num?)?.toInt() ?? 0,
            maximumSelections:
                (item['maximumSelections'] as num?)?.toInt() ?? 1,
            isAvailable: item['isAvailable'] != false,
            options: (item['options'] as List? ?? const [])
                .whereType<Map>()
                .map((option) {
                  return MenuModifierOption(
                    id: option['id'] as String,
                    name: option['name'] as String,
                    priceDeltaMinor:
                        (option['priceDeltaMinor'] as num?)?.toInt() ?? 0,
                    isAvailable: option['isAvailable'] != false,
                    stockComponents: _stockComponents(
                      option['stockComponents'],
                    ),
                  );
                })
                .toList(growable: false),
          );
        })
        .toList(growable: false);
  }

  List<MenuProduct> get products {
    final raw = _snapshot?['products'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) {
          final area = switch (item['productionArea']) {
            'bar' => ProductionArea.bar,
            'dessert' => ProductionArea.dessert,
            _ => ProductionArea.kitchen,
          };
          return MenuProduct(
            id: item['id'] as String,
            name: item['name'] as String,
            priceMinor: (item['priceMinor'] as num?)?.toInt() ?? 0,
            sectionIds: (item['sectionIds'] as List? ?? const [])
                .whereType<String>()
                .toList(),
            productionArea: area,
            trackStock: item['trackStock'] == true,
            stockOnHand: (item['stockOnHand'] as num?)?.toDouble(),
            stockPerSale: (item['stockPerSale'] as num?)?.toDouble() ?? 1,
            isAvailable: item['isAvailable'] == true,
            isArchived: item['isArchived'] == true,
            showOnOrderFlow: item['showOnOrderFlow'] != false,
            taxRateBasisPoints:
                (item['taxRateBasisPoints'] as num?)?.toInt() ?? 0,
            taxRateId: item['taxRateId'] as String?,
            taxRateName: item['taxRateName'] as String? ?? 'Zero Rate',
            modifierGroupIds: (item['modifierGroupIds'] as List? ?? const [])
                .whereType<String>()
                .toList(),
            variants: (item['variants'] as List? ?? const [])
                .whereType<Map>()
                .map((variant) {
                  return MenuProductVariant(
                    id: variant['id'] as String,
                    name: variant['name'] as String,
                    priceDeltaMinor:
                        (variant['priceDeltaMinor'] as num?)?.toInt() ?? 0,
                    isAvailable: variant['isAvailable'] != false,
                    stockComponents: _stockComponents(
                      variant['stockComponents'],
                    ),
                  );
                })
                .toList(growable: false),
            stockComponents: _stockComponents(item['stockComponents']),
            availableForCollection:
                item['availableForCollection'] as bool? ?? true,
            availableForDelivery: item['availableForDelivery'] as bool? ?? true,
            collectionPriceMinor: (item['collectionPriceMinor'] as num?)
                ?.toInt(),
            deliveryPriceMinor: (item['deliveryPriceMinor'] as num?)?.toInt(),
            defaultCourseId: item['defaultCourseId'] as String?,
            defaultCourseName:
                item['defaultCourseName'] as String? ?? 'Standard',
            defaultCourseSequence:
                (item['defaultCourseSequence'] as num?)?.toInt() ?? 0,
            courseReleasePolicy: switch (item['courseReleasePolicy']) {
              'manual' => CourseReleasePolicy.manual,
              'afterPreviousCollected' =>
                CourseReleasePolicy.afterPreviousCollected,
              'afterPreviousServed' => CourseReleasePolicy.afterPreviousServed,
              _ => CourseReleasePolicy.immediate,
            },
          );
        })
        .toList(growable: false);
  }

  List<ProductStockComponent> _stockComponents(Object? raw) {
    if (raw is! List) return const [];
    final rawProducts = _snapshot?['products'];
    final products = rawProducts is List
        ? rawProducts.whereType<Map>()
        : const Iterable<Map>.empty();
    return raw
        .whereType<Map>()
        .map((component) {
          final productId = component['productId'] as String;
          final stockProduct = products
              .where((product) => product['id'] == productId)
              .firstOrNull;
          return ProductStockComponent(
            productId: productId,
            productName:
                component['productName'] as String? ??
                stockProduct?['name'] as String? ??
                productId,
            quantityPerSale:
                (component['quantityPerSale'] as num?)?.toDouble() ?? 0,
            stockUnit:
                component['stockUnit'] as String? ??
                stockProduct?['stockUnit'] as String? ??
                'each',
            stockOnHand: (stockProduct?['stockOnHand'] as num?)?.toDouble(),
            latestUnitCostMinor: (stockProduct?['latestUnitCostMinor'] as num?)
                ?.toDouble(),
          );
        })
        .toList(growable: false);
  }
}

class _OfflineTicketState {
  const _OfflineTicketState({required this.status, required this.isDelayed});

  factory _OfflineTicketState.fromJson(Map<String, Object?> value) =>
      _OfflineTicketState(
        status: switch (value['status']) {
          'held' => OrderFlowStatus.held,
          'preparing' => OrderFlowStatus.preparing,
          'ready' => OrderFlowStatus.ready,
          'collected' => OrderFlowStatus.collected,
          'served' => OrderFlowStatus.served,
          'cancelled' => OrderFlowStatus.cancelled,
          'voided' => OrderFlowStatus.voided,
          'newOrder' => OrderFlowStatus.newOrder,
          _ => null,
        },
        isDelayed: value['isDelayed'] == true,
      );

  final OrderFlowStatus? status;
  final bool isDelayed;
}
