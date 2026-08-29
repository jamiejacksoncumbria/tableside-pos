import 'dart:typed_data';

import '../features/pos/domain.dart';
import '../core/tenant_scope.dart';
import 'production_command_repository.dart';

/// Keeps tenant-owned branding separate from venue and receipt snapshots.
///
/// On a completed bill, copy the current tenant/venue branding into the receipt
/// document. That ensures old receipts remain historically accurate after a
/// company changes its logo or address.
class TenantProfileRepository {
  TenantProfileRepository({ProductionCommandRepository? commands})
    : _commands = commands ?? ProductionCommandRepository();

  final ProductionCommandRepository _commands;

  Future<void> saveProfile({
    required VenueScope scope,
    required TenantProfile profile,
  }) {
    if (profile.id != scope.tenantId) {
      throw ArgumentError('The profile does not belong to the active company.');
    }
    return _commands.manageVenueConfiguration(
      scope: scope,
      resource: 'tenantProfile',
      values: profile.toMap(),
    );
  }

  Future<String> uploadLogo({
    required VenueScope scope,
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) async {
    return _commands.uploadTenantLogo(
      scope: scope,
      bytes: bytes,
      fileName: fileName,
      contentType: contentType,
    );
  }
}
