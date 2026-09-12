import 'dart:collection';

import 'offline_event.dart';
import 'offline_order_projection.dart';
import 'venue_hub_command_processor.dart';

class VenueOfflineCatalogueException implements Exception {
  const VenueOfflineCatalogueException(this.message);

  final String message;

  @override
  String toString() => 'VenueOfflineCatalogueException: $message';
}

class VenueOfflineCatalogue {
  VenueOfflineCatalogue._({
    required this.version,
    required this.currencyCode,
    required this.cloudLastSequence,
    required this.products,
    required this.modifierGroups,
    required this.routedProductionAreas,
  });

  factory VenueOfflineCatalogue.fromSnapshot(Map<String, Object?> snapshot) {
    final version = snapshot['version'];
    final currencyCode = snapshot['currencyCode'];
    final rawProducts = snapshot['products'];
    final rawGroups = snapshot['modifierGroups'];
    final rawRoutes = snapshot['printerRoutes'] ?? const <Object?>[];
    final cloudLastSequence = snapshot['cloudLastSequence'] ?? 0;
    if (version is! int ||
        version < 1 ||
        currencyCode is! String ||
        !RegExp(r'^[A-Z]{3}$').hasMatch(currencyCode) ||
        rawProducts is! List ||
        rawGroups is! List ||
        rawRoutes is! List ||
        cloudLastSequence is! int ||
        cloudLastSequence < 0) {
      throw const VenueOfflineCatalogueException(
        'The encrypted venue catalogue snapshot is invalid.',
      );
    }
    final groups = <String, OfflineModifierGroup>{};
    for (final raw in rawGroups) {
      final group = OfflineModifierGroup.fromJson(_map(raw, 'modifier group'));
      if (groups.putIfAbsent(group.id, () => group) != group) {
        throw const VenueOfflineCatalogueException(
          'The catalogue contains duplicate modifier groups.',
        );
      }
    }
    final products = <String, OfflineCatalogueProduct>{};
    for (final raw in rawProducts) {
      final product = OfflineCatalogueProduct.fromJson(
        _map(raw, 'catalogue product'),
      );
      if (products.putIfAbsent(product.id, () => product) != product) {
        throw const VenueOfflineCatalogueException(
          'The catalogue contains duplicate products.',
        );
      }
      for (final groupId in product.modifierGroupIds) {
        if (!groups.containsKey(groupId)) {
          throw VenueOfflineCatalogueException(
            'Product ${product.id} refers to an unknown modifier group.',
          );
        }
      }
    }
    return VenueOfflineCatalogue._(
      version: version,
      currencyCode: currencyCode,
      cloudLastSequence: cloudLastSequence,
      products: UnmodifiableMapView(products),
      modifierGroups: UnmodifiableMapView(groups),
      routedProductionAreas: Set.unmodifiable(
        rawRoutes
            .whereType<Map>()
            .where(
              (route) =>
                  route['productionArea'] is String &&
                  route['primaryDeviceId'] is String &&
                  (route['primaryDeviceId'] as String).isNotEmpty,
            )
            .map((route) => route['productionArea'] as String),
      ),
    );
  }

  final int version;
  final String currencyCode;
  final int cloudLastSequence;
  final Map<String, OfflineCatalogueProduct> products;
  final Map<String, OfflineModifierGroup> modifierGroups;
  final Set<String> routedProductionAreas;

  void validatePrintRoutes(
    OfflineOrderProjection order,
    List<String> lineIds, {
    required bool printRequired,
  }) {
    if (!printRequired) return;
    final missing = lineIds
        .map((id) => order.lines[id]?.productionArea)
        .whereType<String>()
        .where((area) => !routedProductionAreas.contains(area))
        .toSet();
    if (missing.isNotEmpty) {
      throw VenueOfflineCatalogueException(
        'No active offline printer route is configured for ${missing.join(', ')}.',
      );
    }
  }

  void validateReceiptRoute({required bool printRequired}) {
    if (printRequired && !routedProductionAreas.contains('receipt')) {
      throw const VenueOfflineCatalogueException(
        'No active offline receipt printer route is configured.',
      );
    }
  }

  /// Validates stock against the activation snapshot plus every order already
  /// sent through this hub epoch. The append-only ledger is the authority, so
  /// a crash cannot forget locally reserved stock.
  void validateStockForSend(
    List<OfflineEvent> existing,
    OfflineOrderProjection order,
    List<String> lineIds, {
    required bool managerOverride,
  }) {
    if (managerOverride) return;
    final consumed = <String, double>{};
    final linePayloads = <String, Map<String, Object?>>{};
    for (final event in existing) {
      if (event.type == 'order.itemAdded') {
        final lineId = event.payload['lineId'];
        if (lineId is String) {
          linePayloads[lineId] = Map<String, Object?>.from(event.payload);
        }
      } else if (event.type == 'order.itemQuantityChanged') {
        final lineId = event.payload['lineId'];
        final quantity = event.payload['quantity'];
        if (lineId is String && quantity is int) {
          if (quantity == 0) {
            linePayloads.remove(lineId);
          } else {
            linePayloads[lineId]?['quantity'] = quantity;
          }
        }
      } else if (event.type == 'order.sent') {
        if (event.sequence <= cloudLastSequence) continue;
        for (final lineId in (event.payload['lineIds'] as List? ?? const [])) {
          if (lineId is String) {
            _addConsumption(consumed, linePayloads[lineId]);
          }
        }
      }
    }
    for (final lineId in lineIds) {
      final line = order.lines[lineId];
      if (line == null || line.sent) {
        throw const VenueOfflineCatalogueException(
          'Only unsent order items may be released.',
        );
      }
      final payload = linePayloads[lineId];
      if (payload != null) payload['quantity'] = line.quantity;
      _addConsumption(consumed, payload);
    }
    for (final entry in consumed.entries) {
      final product = products[entry.key];
      final onHand = product?.stockOnHand;
      if (product == null || !product.trackStock || onHand == null) {
        throw const VenueOfflineCatalogueException(
          'Tracked stock is unavailable in the offline catalogue.',
        );
      }
      if (entry.value > onHand + 0.0000001) {
        throw VenueOfflineCatalogueException(
          '${product.name} does not have enough stock. A manager override is required.',
        );
      }
    }
  }

  void _addConsumption(Map<String, double> totals, Map<String, Object?>? line) {
    if (line == null) {
      throw const VenueOfflineCatalogueException(
        'An offline stock line is missing from the ledger.',
      );
    }
    final quantity = (line['quantity'] as num?)?.toDouble();
    if (quantity == null || quantity <= 0) {
      throw const VenueOfflineCatalogueException(
        'An offline stock quantity is invalid.',
      );
    }
    final components = line['stockComponents'];
    if (components is List && components.isNotEmpty) {
      for (final raw in components) {
        final component = _map(raw, 'stock component');
        final productId = _requiredText(component, 'productId');
        final perSale = (component['quantityPerSale'] as num?)?.toDouble();
        if (perSale == null || !perSale.isFinite || perSale <= 0) {
          throw const VenueOfflineCatalogueException(
            'An offline stock recipe is invalid.',
          );
        }
        totals.update(
          productId,
          (value) => value + quantity * perSale,
          ifAbsent: () => quantity * perSale,
        );
      }
      return;
    }
    if (line['trackStock'] == true) {
      final productId = _requiredText(line, 'productId');
      final perSale = (line['stockPerSale'] as num?)?.toDouble() ?? 1;
      totals.update(
        productId,
        (value) => value + quantity * perSale,
        ifAbsent: () => quantity * perSale,
      );
    }
  }

  Future<Map<String, Object?>> validateEvent(
    String eventType,
    Map<String, Object?> payload,
    VenueHubStaffGrant grant,
  ) async {
    if (eventType == 'order.sent' &&
        payload['stockOverride'] == true &&
        !grant.permissions.contains('manager')) {
      throw const VenueOfflineCatalogueException(
        'Only a manager may override offline stock.',
      );
    }
    if (eventType != 'order.itemAdded') return payload;
    final productId = _requiredText(payload, 'productId');
    final product = products[productId];
    if (product == null || product.archived || !product.available) {
      throw const VenueOfflineCatalogueException(
        'This product is not currently available.',
      );
    }
    final quantity = _positiveInt(payload, 'quantity');
    final lineId = _requiredText(payload, 'lineId');
    final variantId = _optionalText(payload['variantId']);
    OfflineCatalogueVariant? variant;
    if (product.variants.isNotEmpty) {
      variant = product.variants[variantId];
      if (variant == null || !variant.available) {
        throw const VenueOfflineCatalogueException(
          'Select an available product variant.',
        );
      }
    } else if (variantId != null) {
      throw const VenueOfflineCatalogueException(
        'This product does not accept a variant.',
      );
    }

    final rawSelections = payload['modifierSelections'];
    final selections = rawSelections == null
        ? const <Object?>[]
        : rawSelections is List
        ? rawSelections
        : throw const VenueOfflineCatalogueException(
            'The selected modifiers are invalid.',
          );
    final selectedByGroup = <String, List<OfflineModifierOption>>{};
    for (final raw in selections) {
      final selection = _map(raw, 'modifier selection');
      final groupId = _requiredText(selection, 'groupId');
      final optionId = _requiredText(selection, 'optionId');
      if (!product.modifierGroupIds.contains(groupId)) {
        throw const VenueOfflineCatalogueException(
          'A selected modifier is not available for this product.',
        );
      }
      final group = modifierGroups[groupId]!;
      final option = group.options[optionId];
      if (!group.available || option == null || !option.available) {
        throw const VenueOfflineCatalogueException(
          'A selected modifier is not available.',
        );
      }
      final list = selectedByGroup.putIfAbsent(groupId, () => []);
      if (list.any((item) => item.id == optionId)) {
        throw const VenueOfflineCatalogueException(
          'A modifier option was selected more than once.',
        );
      }
      list.add(option);
    }
    final canonicalSelections = <Map<String, Object?>>[];
    for (final groupId in product.modifierGroupIds) {
      final group = modifierGroups[groupId]!;
      final chosen = selectedByGroup[groupId] ?? const [];
      if (chosen.length < group.minimumSelections ||
          chosen.length > group.maximumSelections) {
        throw VenueOfflineCatalogueException(
          '${group.name} requires ${group.minimumSelections}–${group.maximumSelections} selection(s).',
        );
      }
      for (final option in chosen) {
        canonicalSelections.add({
          'groupId': group.id,
          'groupName': group.name,
          'optionId': option.id,
          'optionName': option.name,
          'priceDeltaMinor': option.priceDeltaMinor,
          'stockComponents': option.stockComponents,
        });
      }
    }
    final unitPriceMinor =
        product.priceMinor +
        (variant?.priceDeltaMinor ?? 0) +
        canonicalSelections.fold<int>(
          0,
          (sum, item) => sum + (item['priceDeltaMinor'] as int),
        );
    if (unitPriceMinor < 0) {
      throw const VenueOfflineCatalogueException(
        'The configured product price is invalid.',
      );
    }
    return <String, Object?>{
      'orderId': _requiredText(payload, 'orderId'),
      'lineId': lineId,
      'productId': product.id,
      'productName': product.name,
      'quantity': quantity,
      'unitPriceMinor': unitPriceMinor,
      'currencyCode': currencyCode,
      'taxRateId': product.taxRateId,
      'taxRateName': product.taxRateName,
      'taxRateBasisPoints': product.taxRateBasisPoints,
      'productionArea': product.productionArea,
      'showOnOrderFlow': product.showOnOrderFlow,
      'trackStock': product.trackStock,
      'stockPerSale': product.stockPerSale,
      'stockComponents': <Object?>[
        ...product.stockComponents,
        ...?variant?.stockComponents,
        for (final item in canonicalSelections)
          ...(item['stockComponents'] as List<Object?>),
      ],
      if (variant != null) ...{
        'variantId': variant.id,
        'variantName': variant.name,
        'variantPriceDeltaMinor': variant.priceDeltaMinor,
      },
      'modifierSelections': canonicalSelections,
      'itemNote': _optionalText(payload['itemNote']) ?? '',
      'catalogueVersion': version,
    };
  }
}

class OfflineCatalogueProduct {
  OfflineCatalogueProduct.fromJson(Map<String, Object?> json)
    : id = _requiredText(json, 'id'),
      name = _requiredText(json, 'name'),
      priceMinor = _nonNegativeInt(json, 'priceMinor'),
      taxRateId = _requiredText(json, 'taxRateId'),
      taxRateName = _requiredText(json, 'taxRateName'),
      taxRateBasisPoints = _boundedInt(json, 'taxRateBasisPoints', 0, 100000),
      productionArea = _requiredText(json, 'productionArea'),
      available = json['isAvailable'] == true,
      archived = json['isArchived'] == true,
      showOnOrderFlow = json['showOnOrderFlow'] != false,
      trackStock = json['trackStock'] == true,
      stockPerSale = _positiveNumber(json['stockPerSale'], fallback: 1),
      stockOnHand = (json['stockOnHand'] as num?)?.toDouble(),
      stockComponents = _componentList(json['stockComponents']),
      modifierGroupIds = List.unmodifiable(
        (json['modifierGroupIds'] as List? ?? const [])
            .whereType<String>()
            .where((id) => id.isNotEmpty),
      ),
      variants = UnmodifiableMapView(
        _uniqueById(
          json['variants'],
          (value) => OfflineCatalogueVariant.fromJson(value),
        ),
      );

  final String id;
  final String name;
  final int priceMinor;
  final String taxRateId;
  final String taxRateName;
  final int taxRateBasisPoints;
  final String productionArea;
  final bool available;
  final bool archived;
  final bool showOnOrderFlow;
  final bool trackStock;
  final num stockPerSale;
  final double? stockOnHand;
  final List<Object?> stockComponents;
  final List<String> modifierGroupIds;
  final Map<String, OfflineCatalogueVariant> variants;
}

class OfflineCatalogueVariant {
  OfflineCatalogueVariant.fromJson(Map<String, Object?> json)
    : id = _requiredText(json, 'id'),
      name = _requiredText(json, 'name'),
      priceDeltaMinor = _signedInt(json, 'priceDeltaMinor'),
      available = json['isAvailable'] != false,
      stockComponents = _componentList(json['stockComponents']);

  final String id;
  final String name;
  final int priceDeltaMinor;
  final bool available;
  final List<Object?> stockComponents;
}

class OfflineModifierGroup {
  OfflineModifierGroup.fromJson(Map<String, Object?> json)
    : id = _requiredText(json, 'id'),
      name = _requiredText(json, 'name'),
      minimumSelections = _boundedInt(json, 'minimumSelections', 0, 100),
      maximumSelections = _boundedInt(json, 'maximumSelections', 1, 100),
      available = json['isAvailable'] != false,
      options = UnmodifiableMapView(
        _uniqueById(
          json['options'],
          (value) => OfflineModifierOption.fromJson(value),
        ),
      ) {
    if (minimumSelections > maximumSelections) {
      throw const VenueOfflineCatalogueException(
        'A modifier group selection range is invalid.',
      );
    }
  }

  final String id;
  final String name;
  final int minimumSelections;
  final int maximumSelections;
  final bool available;
  final Map<String, OfflineModifierOption> options;
}

class OfflineModifierOption {
  OfflineModifierOption.fromJson(Map<String, Object?> json)
    : id = _requiredText(json, 'id'),
      name = _requiredText(json, 'name'),
      priceDeltaMinor = _signedInt(json, 'priceDeltaMinor'),
      available = json['isAvailable'] != false,
      stockComponents = _componentList(json['stockComponents']);

  final String id;
  final String name;
  final int priceDeltaMinor;
  final bool available;
  final List<Object?> stockComponents;
}

Map<String, T> _uniqueById<T>(
  Object? raw,
  T Function(Map<String, Object?>) parse,
) {
  final values = <String, T>{};
  for (final item in raw is List ? raw : const <Object?>[]) {
    final value = parse(_map(item, 'catalogue entry'));
    final id = (value as dynamic).id as String;
    if (values.containsKey(id)) {
      throw const VenueOfflineCatalogueException(
        'The catalogue contains duplicate identifiers.',
      );
    }
    values[id] = value;
  }
  return values;
}

List<Object?> _componentList(Object? raw) {
  if (raw == null) return const [];
  if (raw is! List) {
    throw const VenueOfflineCatalogueException('Stock components are invalid.');
  }
  return List<Object?>.unmodifiable(
    raw.map(
      (item) => Map<String, Object?>.unmodifiable(_map(item, 'component')),
    ),
  );
}

Map<String, Object?> _map(Object? raw, String name) {
  if (raw is! Map) {
    throw VenueOfflineCatalogueException('The $name is invalid.');
  }
  return Map<String, Object?>.from(raw);
}

String _requiredText(Map<String, Object?> json, String key) {
  final value = _optionalText(json[key]);
  if (value == null || value.length > 160) {
    throw VenueOfflineCatalogueException('$key is invalid.');
  }
  return value;
}

String? _optionalText(Object? value) {
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty || value.length > 500) {
    throw const VenueOfflineCatalogueException('A text value is invalid.');
  }
  return value.trim();
}

int _positiveInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int || value < 1 || value > 10000) {
    throw VenueOfflineCatalogueException('$key is invalid.');
  }
  return value;
}

int _nonNegativeInt(Map<String, Object?> json, String key) =>
    _boundedInt(json, key, 0, 1000000000);

int _signedInt(Map<String, Object?> json, String key) {
  final value = json[key] ?? 0;
  if (value is! int || value < -1000000000 || value > 1000000000) {
    throw VenueOfflineCatalogueException('$key is invalid.');
  }
  return value;
}

int _boundedInt(Map<String, Object?> json, String key, int min, int max) {
  final value = json[key];
  if (value is! int || value < min || value > max) {
    throw VenueOfflineCatalogueException('$key is invalid.');
  }
  return value;
}

num _positiveNumber(Object? value, {required num fallback}) {
  final number = value is num ? value : fallback;
  if (!number.isFinite || number <= 0 || number > 1000000000) {
    throw const VenueOfflineCatalogueException('A stock quantity is invalid.');
  }
  return number;
}
