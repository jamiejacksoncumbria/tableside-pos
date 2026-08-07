import 'package:cloud_firestore/cloud_firestore.dart';

class PrinterDevice {
  const PrinterDevice({
    required this.id,
    required this.venueId,
    required this.name,
    required this.platform,
    required this.productionAreas,
    required this.transports,
  });

  final String id;
  final String venueId;
  final String name;
  final String platform;
  final List<String> productionAreas;
  final List<String> transports;
}

/// Devices are registered by a manager and then issued a device-specific
/// custom claim by a trusted server. The native worker only sends heartbeats
/// and claims jobs targeting its device ID.
class PrinterDeviceRepository {
  PrinterDeviceRepository(this._firestore);

  final FirebaseFirestore _firestore;

  Future<void> register(PrinterDevice device, {required String tenantId}) {
    return _firestore.doc('tenants/$tenantId/devices/${device.id}').set({
      'venueId': device.venueId,
      'name': device.name,
      'platform': device.platform,
      'productionAreas': device.productionAreas,
      'transports': device.transports,
      'active': true,
      'registeredAt': FieldValue.serverTimestamp(),
      'lastHeartbeatAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> heartbeat({required String tenantId, required String deviceId}) {
    return _firestore.doc('tenants/$tenantId/devices/$deviceId').update({
      'lastHeartbeatAt': FieldValue.serverTimestamp(),
    });
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
          (snapshot) => snapshot.docs
              .map((document) {
                final data = document.data();
                return PrinterDevice(
                  id: document.id,
                  venueId: data['venueId'] as String,
                  name: data['name'] as String? ?? 'Unnamed device',
                  platform: data['platform'] as String? ?? 'unknown',
                  productionAreas: List<String>.from(
                    data['productionAreas'] as List? ?? const [],
                  ),
                  transports: List<String>.from(
                    data['transports'] as List? ?? const [],
                  ),
                );
              })
              .toList(growable: false),
        );
  }
}
