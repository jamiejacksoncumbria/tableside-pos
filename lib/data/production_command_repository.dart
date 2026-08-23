import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:tableside_pos/core/tenant_scope.dart';

import '../core/app_logger.dart';
import '../firebase_options.dart';
import '../features/pos/domain.dart';

final productionCommandRepositoryProvider =
    Provider<ProductionCommandRepository>(
      (ref) => ProductionCommandRepository(),
    );

/// Server-owned writes for an order leaving the till.
///
/// The app submits only a line reference and its displayed quantity/price. The
/// Cloud Function verifies the signed-in membership, loads the canonical menu
/// product, creates production tickets, and records stock movement atomically.
class ProductionCommandRepository {
  Future<void> createTable({
    required VenueScope scope,
    required String label,
    required int seats,
  }) {
    return _call('createTable', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'label': label,
      'seats': seats,
    });
  }

  Future<void> updateTable({
    required VenueScope scope,
    required String tableId,
    required String label,
    required int seats,
  }) {
    return _call('updateTable', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'tableId': tableId,
      'label': label,
      'seats': seats,
    });
  }

  Future<void> deleteTable({
    required VenueScope scope,
    required String tableId,
  }) {
    return _call('deleteTable', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'tableId': tableId,
    });
  }

  Future<String> openNamedTab({
    required VenueScope scope,
    required String tabName,
  }) async {
    final result = await _call('openNamedTab', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'tabName': tabName,
    });
    final orderId = result['orderId'];
    if (orderId is! String || orderId.isEmpty) {
      throw StateError('The server did not return the named tab order.');
    }
    return orderId;
  }

  Future<void> sendNewLinesToProduction({
    required VenueScope scope,
    required PosOrder order,
    bool stockOverride = false,
  }) async {
    final unsentLines = order.lines
        .where((line) => !line.isSentToProduction)
        .toList(growable: false);
    if (unsentLines.isEmpty) return;

    await _call('sendOrderToProduction', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'orderId': order.id,
      'tableId': order.tableId,
      'tabName': order.tabName,
      'stockOverride': stockOverride,
      'lines': unsentLines
          .map(
            (line) => {
              'id': line.id,
              'productId': line.productId,
              'quantity': line.quantity,
            },
          )
          .toList(growable: false),
    });
  }

  Future<void> updateProductionTicket({
    required VenueScope scope,
    required String ticketId,
    required String flowStatus,
    required bool isDelayed,
  }) {
    return _call('updateProductionTicket', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'ticketId': ticketId,
      'flowStatus': flowStatus,
      'isDelayed': isDelayed,
    });
  }

  Future<Map<String, Object?>> _call(
    String action,
    Map<String, Object?> data,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('Sign in before sending an order to production.');
    }
    final token = await user.getIdToken();
    if (token == null || token.isEmpty) {
      throw StateError('Could not obtain a Firebase sign-in token.');
    }
    final projectId = DefaultFirebaseOptions.currentPlatform.projectId;
    final endpoint = Uri.https(
      'europe-west2-$projectId.cloudfunctions.net',
      'posApi',
    );
    AppLogger.info('POS API $action: sending request.');
    final response = await http.post(
      endpoint,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'action': action, 'data': data}),
    );
    AppLogger.info('POS API $action: HTTP ${response.statusCode}.');

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw StateError('The POS server returned an invalid response.');
    }
    final body = Map<String, Object?>.from(decoded);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = body['error'];
      if (error is Map) {
        final message = Map<String, Object?>.from(error)['message'];
        throw StateError(
          message is String ? message : 'The POS action failed.',
        );
      }
      throw StateError('The POS action failed (${response.statusCode}).');
    }
    final result = body['data'];
    return result is Map<String, Object?>
        ? result
        : result is Map
        ? Map<String, Object?>.from(result)
        : const {};
  }
}
