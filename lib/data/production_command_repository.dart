import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:tableside_pos/core/tenant_scope.dart';

import '../core/app_logger.dart';
import '../core/firebase_bootstrap.dart';
import '../firebase_options.dart';
import '../features/pos/domain.dart';

class ProductionDispatchResult {
  const ProductionDispatchResult({
    this.queuedPrintJobIds = const <String>[],
    this.queuedProductionAreas = const <String>[],
    this.unroutedProductionAreas = const <String>[],
  });

  final List<String> queuedPrintJobIds;
  final List<String> queuedProductionAreas;
  final List<String> unroutedProductionAreas;
}

/// The server-calculated receipt result. The client never supplies the order
/// total: it only records the confirmed tender, which the Cloud Function
/// compares to its immutable order snapshot before closing the sale.
class BillCloseResult {
  const BillCloseResult({
    required this.billId,
    required this.totalMinor,
    required this.currencyCode,
    required this.receiptNumber,
    required this.alreadyClosed,
    required this.receiptPrintRequested,
    required this.receiptPrintQueued,
  });

  final String billId;
  final int totalMinor;
  final String currencyCode;
  final String receiptNumber;
  final bool alreadyClosed;
  final bool receiptPrintRequested;
  final bool receiptPrintQueued;
}

/// A tender allocation as entered at checkout. The server derives the
/// reporting-currency value from the amount, currency and rate; it does not
/// trust a client-provided converted total.
class BillPaymentInput {
  const BillPaymentInput({
    required this.method,
    required this.tenderedAmountMinor,
    required this.tenderedCurrencyCode,
    required this.exchangeRateToBase,
    required this.cardPaymentApproved,
    this.terminalLabel,
  });

  final PaymentMethod method;
  final int tenderedAmountMinor;
  final String tenderedCurrencyCode;
  final String exchangeRateToBase;
  final bool cardPaymentApproved;
  final String? terminalLabel;

  Map<String, Object?> toRequestData() => {
    'method': method.name,
    'amountMinor': tenderedAmountMinor,
    'currencyCode': tenderedCurrencyCode,
    'exchangeRateToBase': exchangeRateToBase,
    'cardPaymentApproved': cardPaymentApproved,
    'terminalLabel': terminalLabel,
  };
}

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

  /// Persists one not-yet-sent order line.  Draft lines are intentionally
  /// server-owned so another till can open the same table and see changes in
  /// real time, while printing and stock movements remain deferred until Send.
  Future<void> addDraftLine({
    required VenueScope scope,
    required PosOrder order,
    required OrderLine line,
  }) {
    return _call('addOrderDraftLine', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'orderId': order.id,
      'tableId': order.tableId,
      'tabName': order.tabName,
      'line': {
        'id': line.id,
        'productId': line.productId,
        'quantity': line.quantity,
      },
    });
  }

  /// Changes an unsent draft line. A quantity of zero removes it. The server
  /// refuses any attempt to alter a line which has already been printed.
  Future<void> updateDraftLineQuantity({
    required VenueScope scope,
    required PosOrder order,
    required String lineId,
    required int quantity,
  }) {
    return _call('updateOrderDraftLine', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'orderId': order.id,
      'tableId': order.tableId,
      'tabName': order.tabName,
      'lineId': lineId,
      'quantity': quantity,
    });
  }

  Future<ProductionDispatchResult> sendNewLinesToProduction({
    required VenueScope scope,
    required PosOrder order,
    required bool printRequired,
    bool stockOverride = false,
  }) async {
    final unsentLines = order.lines
        .where((line) => !line.isSentToProduction)
        .toList(growable: false);
    if (unsentLines.isEmpty) return const ProductionDispatchResult();

    final response = await _call('sendOrderToProduction', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'orderId': order.id,
      'tableId': order.tableId,
      'tabName': order.tabName,
      'stockOverride': stockOverride,
      'printRequired': printRequired,
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
    return ProductionDispatchResult(
      queuedPrintJobIds: _stringList(response['printJobIds']),
      queuedProductionAreas: _stringList(response['queuedProductionAreas']),
      unroutedProductionAreas: _stringList(response['unroutedProductionAreas']),
    );
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

  Future<BillCloseResult> closeOrder({
    required VenueScope scope,
    required PosOrder order,
    required List<BillPaymentInput> payments,
    required bool printReceipt,
  }) async {
    final response = await _call('closeOrder', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'orderId': order.id,
      'payments': payments.map((payment) => payment.toRequestData()).toList(),
      'printReceipt': printReceipt,
    });
    final billId = response['billId'];
    final totalMinor = response['totalMinor'];
    final resultCurrency = response['currencyCode'];
    final receiptNumber = response['receiptNumber'];
    if (billId is! String ||
        totalMinor is! int ||
        resultCurrency is! String ||
        receiptNumber is! String) {
      throw StateError('The server did not return a valid closed bill.');
    }
    return BillCloseResult(
      billId: billId,
      totalMinor: totalMinor,
      currencyCode: resultCurrency,
      receiptNumber: receiptNumber,
      alreadyClosed: response['alreadyClosed'] == true,
      receiptPrintRequested: response['receiptPrintRequested'] == true,
      receiptPrintQueued: response['receiptPrintQueued'] == true,
    );
  }

  /// Owner-only, venue-specific notification timing. This remains a trusted
  /// server mutation because venue records themselves are server-owned.
  Future<void> updateVenueNotificationRetention({
    required VenueScope scope,
    required int seconds,
  }) {
    return _call('updateVenueNotificationSettings', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'notificationRetentionSeconds': seconds,
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
    final appCheckToken = await currentFirebaseAppCheckToken();
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
        'X-Firebase-AppCheck': ?appCheckToken,
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

  List<String> _stringList(Object? value) => value is List
      ? value.whereType<String>().toList(growable: false)
      : const <String>[];
}
