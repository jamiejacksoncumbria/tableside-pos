import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/tenant_scope.dart';
import 'production_command_repository.dart';

/// `receipt` is deliberately a separate route: a production printer never
/// receives prices or payment details, while the dedicated receipt printer
/// gets the full paid bill only when staff request it at checkout.
const productionRouteAreas = <String>['bar', 'kitchen', 'dessert', 'receipt'];

class PrinterRoute {
  const PrinterRoute({
    required this.id,
    required this.venueId,
    required this.productionArea,
    this.primaryDeviceId,
    this.fallbackDeviceId,
  });

  final String id;
  final String venueId;
  final String productionArea;
  final String? primaryDeviceId;
  final String? fallbackDeviceId;

  bool get isConfigured =>
      primaryDeviceId != null && primaryDeviceId!.isNotEmpty;
}

/// Venue-scoped primary/fallback assignments. The server validates the
/// configured target again before it creates a job, keeping a stale manager
/// configuration from routing orders to another venue.
class PrinterRouteRepository {
  PrinterRouteRepository(
    this._firestore, {
    ProductionCommandRepository? commands,
  }) : _commands = commands ?? ProductionCommandRepository();

  final FirebaseFirestore _firestore;
  final ProductionCommandRepository _commands;

  CollectionReference<Map<String, dynamic>> _routes(String tenantId) =>
      _firestore.collection('tenants/$tenantId/printerRoutes');

  String routeId(VenueScope scope, String productionArea) =>
      '${scope.venueId}_$productionArea';

  Stream<List<PrinterRoute>> watchVenueRoutes(VenueScope scope) =>
      _routes(scope.tenantId)
          .where('venueId', isEqualTo: scope.venueId)
          .snapshots()
          .map(
            (snapshot) => snapshot.docs
                .map((document) {
                  final data = document.data();
                  return PrinterRoute(
                    id: document.id,
                    venueId: data['venueId'] as String? ?? scope.venueId,
                    productionArea: data['productionArea'] as String? ?? '',
                    primaryDeviceId: data['primaryDeviceId'] as String?,
                    fallbackDeviceId: data['fallbackDeviceId'] as String?,
                  );
                })
                .where(
                  (route) =>
                      productionRouteAreas.contains(route.productionArea),
                )
                .toList(growable: false),
          );

  Future<void> saveRoute({
    required VenueScope scope,
    required String productionArea,
    String? primaryDeviceId,
    String? fallbackDeviceId,
  }) {
    if (!productionRouteAreas.contains(productionArea)) {
      throw ArgumentError.value(productionArea, 'productionArea');
    }
    final primary = _cleanId(primaryDeviceId);
    final fallback = _cleanId(fallbackDeviceId);
    if (primary == null && fallback != null) {
      throw ArgumentError(
        'Choose a primary printer before a fallback printer.',
      );
    }
    if (primary != null && primary == fallback) {
      throw ArgumentError(
        'The fallback printer must be different from the primary printer.',
      );
    }
    return _commands.manageVenueConfiguration(
      scope: scope,
      resource: 'printerRoute',
      values: {
        'productionArea': productionArea,
        'primaryDeviceId': primary,
        'fallbackDeviceId': fallback,
      },
    );
  }

  String? _cleanId(String? value) {
    final id = value?.trim();
    return id == null || id.isEmpty ? null : id;
  }
}
