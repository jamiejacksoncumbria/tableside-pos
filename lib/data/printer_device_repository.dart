import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/tenant_scope.dart';
import 'production_command_repository.dart';

class PrinterDevice {
  const PrinterDevice({
    required this.id,
    required this.venueId,
    required this.name,
    required this.platform,
    required this.productionAreas,
    required this.transports,
    required this.active,
    this.lastHeartbeatAt,
  });

  final String id;
  final String venueId;
  final String name;
  final String platform;
  final List<String> productionAreas;
  final List<String> transports;
  final bool active;
  final DateTime? lastHeartbeatAt;
}

/// Devices are enrolled once to a venue. Queue mutations require the random
/// device credential issued during registration, independently of staff PINs.
class PrinterDeviceRepository {
  PrinterDeviceRepository(
    this._firestore, {
    ProductionCommandRepository? commands,
  }) : _commands = commands ?? ProductionCommandRepository();

  final FirebaseFirestore _firestore;
  final ProductionCommandRepository _commands;

  Future<String> register(PrinterDevice device, {required String tenantId}) {
    return _commands.registerPrinterDevice(
      scope: VenueScope(tenantId: tenantId, venueId: device.venueId),
      values: {
        'deviceId': device.id,
        'name': device.name,
        'platform': device.platform,
        'productionAreas': device.productionAreas,
        'transports': device.transports,
        'active': device.active,
      },
    );
  }

  Future<void> remove({required VenueScope scope, required String deviceId}) =>
      _commands.removePrinterDevice(scope: scope, deviceId: deviceId);

  Future<void> heartbeat({
    required VenueScope scope,
    required String deviceId,
    required String deviceCredential,
  }) {
    return _commands.heartbeatPrinterDevice(
      scope: scope,
      deviceId: deviceId,
      deviceCredential: deviceCredential,
    );
  }

  Future<PrinterDevice?> getDevice({
    required String tenantId,
    required String deviceId,
  }) async {
    final document = await _firestore
        .doc('tenants/$tenantId/devices/$deviceId')
        .get();
    return document.exists ? _fromDocument(document) : null;
  }

  Stream<List<PrinterDevice>> watchVenueDevices({
    required String tenantId,
    required String venueId,
  }) {
    return _firestore
        .collection('tenants/$tenantId/devices')
        .where('venueId', isEqualTo: venueId)
        .snapshots()
        .map(
          (snapshot) =>
              snapshot.docs.map(_fromDocument).toList(growable: false),
        );
  }

  PrinterDevice _fromDocument(DocumentSnapshot<Map<String, dynamic>> document) {
    final data = document.data() ?? const <String, dynamic>{};
    return PrinterDevice(
      id: document.id,
      venueId: data['venueId'] as String? ?? '',
      name: data['name'] as String? ?? 'Unnamed device',
      platform: data['platform'] as String? ?? 'unknown',
      productionAreas: List<String>.from(
        data['productionAreas'] as List? ?? const [],
      ),
      transports: List<String>.from(data['transports'] as List? ?? const []),
      active: data['active'] as bool? ?? true,
      lastHeartbeatAt: (data['lastHeartbeatAt'] as Timestamp?)?.toDate(),
    );
  }
}
