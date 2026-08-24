import 'package:cloud_firestore/cloud_firestore.dart';

class PrinterDevice {
  const PrinterDevice({
    required this.id,
    required this.venueId,
    required this.name,
    required this.platform,
    required this.productionAreas,
    required this.transports,
    required this.assignedUserId,
    required this.active,
    this.lastHeartbeatAt,
  });

  final String id;
  final String venueId;
  final String name;
  final String platform;
  final List<String> productionAreas;
  final List<String> transports;
  final String assignedUserId;
  final bool active;
  final DateTime? lastHeartbeatAt;
}

/// Devices are registered to a venue and explicitly assigned to the account
/// currently configuring them. This prevents an arbitrary signed-in device
/// from claiming a printer's queued jobs.
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
      'assignedUserId': device.assignedUserId,
      'active': device.active,
      'registeredAt': FieldValue.serverTimestamp(),
      'lastHeartbeatAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> heartbeat({required String tenantId, required String deviceId}) {
    return _firestore.doc('tenants/$tenantId/devices/$deviceId').update({
      'lastHeartbeatAt': FieldValue.serverTimestamp(),
    });
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
      assignedUserId: data['assignedUserId'] as String? ?? '',
      active: data['active'] as bool? ?? true,
      lastHeartbeatAt: (data['lastHeartbeatAt'] as Timestamp?)?.toDate(),
    );
  }
}
