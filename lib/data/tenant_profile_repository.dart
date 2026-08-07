import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

import '../features/pos/domain.dart';

/// Keeps tenant-owned branding separate from venue and receipt snapshots.
///
/// On a completed bill, copy the current tenant/venue branding into the receipt
/// document. That ensures old receipts remain historically accurate after a
/// company changes its logo or address.
class TenantProfileRepository {
  TenantProfileRepository(this._firestore, this._storage);

  final FirebaseFirestore _firestore;
  final FirebaseStorage _storage;

  Future<void> saveProfile(TenantProfile profile) {
    return _firestore
        .doc('tenants/${profile.id}')
        .set(profile.toMap(), SetOptions(merge: true));
  }

  Future<String> uploadLogo({
    required String tenantId,
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) async {
    final safeName = fileName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final reference = _storage.ref(
      'tenants/$tenantId/branding/${DateTime.now().millisecondsSinceEpoch}-$safeName',
    );
    await reference.putData(bytes, SettableMetadata(contentType: contentType));
    return reference.getDownloadURL();
  }
}
