import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:tableside_pos/core/tenant_scope.dart';

import '../core/app_logger.dart';
import '../core/firebase_bootstrap.dart';
import '../core/staff_pin_session_store.dart';
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

class VenuePinStaff {
  const VenuePinStaff({
    required this.userId,
    required this.displayName,
    required this.roles,
    required this.hasPin,
    required this.pinLocked,
  });

  final String userId;
  final String displayName;
  final List<String> roles;
  final bool hasPin;
  final bool pinLocked;
}

class StaffPinVerification {
  const StaffPinVerification({
    required this.sessionId,
    required this.sessionToken,
    required this.expiresAt,
    required this.userId,
    required this.displayName,
    required this.isPlatformAdmin,
    required this.roles,
  });

  final String sessionId;
  final String sessionToken;
  final DateTime expiresAt;
  final String userId;
  final String displayName;
  final bool isPlatformAdmin;
  final List<String> roles;
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

/// The server-created child order resulting from an item/quantity bill split.
/// Its total is derived from the already-sent source-line snapshots, not from
/// a client-supplied price.
class OrderSplitResult {
  const OrderSplitResult({
    required this.splitOrderId,
    required this.splitTotalMinor,
    this.remainingTotalMinor,
    required this.alreadySplit,
  });

  final String splitOrderId;
  final int splitTotalMinor;
  final int? remainingTotalMinor;
  final bool alreadySplit;
}

/// An indicative exchange-rate quote fetched by the server from the official
/// CBRT daily bulletin. The manager still reviews it before adding cash
/// tender, and the exact chosen rate remains on the final bill.
class ExchangeRateQuote {
  const ExchangeRateQuote({
    required this.tenderCurrencyCode,
    required this.baseCurrencyCode,
    required this.exchangeRateToBase,
    required this.source,
    required this.publishedDate,
    required this.fetchedAt,
  });

  final String tenderCurrencyCode;
  final String baseCurrencyCode;
  final String exchangeRateToBase;
  final String source;
  final String? publishedDate;
  final String fetchedAt;
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
    this.cashChangeBaseMinor = 0,
    this.exchangeRateSource,
    this.exchangeRatePublishedDate,
    this.exchangeRateFetchedAt,
  });

  final PaymentMethod method;
  final int tenderedAmountMinor;
  final String tenderedCurrencyCode;
  final String exchangeRateToBase;
  final bool cardPaymentApproved;
  final String? terminalLabel;
  final int cashChangeBaseMinor;
  final String? exchangeRateSource;
  final String? exchangeRatePublishedDate;
  final String? exchangeRateFetchedAt;

  Map<String, Object?> toRequestData() => {
    'method': method.name,
    'amountMinor': tenderedAmountMinor,
    'currencyCode': tenderedCurrencyCode,
    'exchangeRateToBase': exchangeRateToBase,
    'cardPaymentApproved': cardPaymentApproved,
    'terminalLabel': terminalLabel,
    'cashChangeBaseMinor': cashChangeBaseMinor,
    'exchangeRateSource': exchangeRateSource,
    'exchangeRatePublishedDate': exchangeRatePublishedDate,
    'exchangeRateFetchedAt': exchangeRateFetchedAt,
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
  Future<String> manageMenuConfiguration({
    required VenueScope scope,
    required String resource,
    required String operation,
    String? documentId,
    Map<String, Object?> values = const {},
  }) async {
    final response = await _call('manageMenuConfiguration', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'resource': resource,
      'operation': operation,
      'documentId': documentId,
      'values': values,
    });
    final returnedId = response['documentId'];
    if (returnedId is! String || returnedId.isEmpty) {
      throw StateError('The menu server returned an invalid document ID.');
    }
    return returnedId;
  }

  Future<void> manageVenueConfiguration({
    required VenueScope scope,
    required String resource,
    required Map<String, Object?> values,
  }) {
    return _call('manageVenueConfiguration', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'resource': resource,
      'values': values,
    });
  }

  Future<String> registerPrinterDevice({
    required VenueScope scope,
    required Map<String, Object?> values,
  }) async {
    final response = await _call('manageVenueConfiguration', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'resource': 'printerDevice',
      'values': values,
    });
    final credential = response['deviceCredential'];
    if (credential is! String || credential.isEmpty) {
      throw StateError('The server did not return a printer enrollment credential.');
    }
    return credential;
  }

  Future<void> heartbeatPrinterDevice({
    required VenueScope scope,
    required String deviceId,
    required String deviceCredential,
  }) {
    return _call('heartbeatPrinterDevice', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'deviceId': deviceId,
      'deviceCredential': deviceCredential,
    });
  }

  Future<Map<String, Object?>?> claimDevicePrintJob({
    required VenueScope scope,
    required String deviceId,
    required String deviceCredential,
  }) async {
    final response = await _call('claimDevicePrintJob', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'deviceId': deviceId,
      'deviceCredential': deviceCredential,
    });
    final job = response['job'];
    return job is Map ? Map<String, Object?>.from(job) : null;
  }

  Future<void> completeDevicePrintJob({
    required VenueScope scope,
    required String deviceId,
    required String deviceCredential,
    required String jobId,
    required bool printed,
    String? failureReason,
  }) {
    return _call('completeDevicePrintJob', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'deviceId': deviceId,
      'deviceCredential': deviceCredential,
      'jobId': jobId,
      'printed': printed,
      if (failureReason != null) 'failureReason': failureReason,
    });
  }

  Future<String> uploadTenantLogo({
    required VenueScope scope,
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) async {
    final response = await _call('uploadTenantLogo', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'fileName': fileName,
      'contentType': contentType,
      'base64Data': base64Encode(bytes),
    });
    final logoUrl = response['logoUrl'];
    if (logoUrl is! String || logoUrl.isEmpty) {
      throw StateError('The branding server returned an invalid logo URL.');
    }
    return logoUrl;
  }

  Future<List<VenuePinStaff>> listVenuePinStaff(VenueScope scope) async {
    final response = await _call('listVenuePinStaff', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
    });
    final values = response['staff'];
    if (values is! List) {
      throw StateError('The server returned an invalid staff list.');
    }
    return values.map((value) {
      final data = Map<String, Object?>.from(value as Map);
      return VenuePinStaff(
        userId: data['userId'] as String,
        displayName: data['displayName'] as String,
        roles: List<String>.from(data['roles'] as List? ?? const []),
        hasPin: data['hasPin'] == true,
        pinLocked: data['pinLocked'] == true,
      );
    }).toList(growable: false);
  }

  Future<void> setOwnStaffPin({
    required VenueScope scope,
    required String pin,
  }) {
    return _call('setOwnStaffPin', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'pin': pin,
    });
  }

  Future<StaffPinVerification> verifyStaffPin({
    required VenueScope scope,
    required String userId,
    required String pin,
  }) async {
    final response = await _call('verifyStaffPin', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'userId': userId,
      'pin': pin,
    });
    return StaffPinVerification(
      sessionId: response['sessionId'] as String,
      sessionToken: response['sessionToken'] as String,
      expiresAt: DateTime.parse(response['expiresAt'] as String),
      userId: response['userId'] as String,
      displayName: response['displayName'] as String,
      isPlatformAdmin: response['isPlatformAdmin'] == true,
      roles: List<String>.from(response['roles'] as List? ?? const []),
    );
  }

  Future<void> unlockStaffPin({
    required VenueScope scope,
    required String userId,
  }) {
    return _call('unlockStaffPin', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'userId': userId,
    });
  }

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
        'variantId': line.variantId,
        'modifierSelections': _modifierSelections(line),
        'itemNote': line.itemNote,
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
              'variantId': line.variantId,
              'modifierSelections': _modifierSelections(line),
              'itemNote': line.itemNote,
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

  /// Requeues a job which exhausted its automatic retries. The server keeps
  /// the original job/audit trail, verifies the original route is still safe,
  /// and marks the payload as a visible REPRINT before any device can claim it.
  Future<void> retryFailedPrintJob({
    required VenueScope scope,
    required String jobId,
  }) {
    return _call('retryFailedPrintJob', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'jobId': jobId,
    });
  }

  /// Creates a new, audited REPRINT job from a successfully printed ticket.
  /// The original completed job is preserved unchanged.
  Future<void> reprintPrintedJob({
    required VenueScope scope,
    required String jobId,
  }) {
    return _call('reprintPrintedJob', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'jobId': jobId,
    });
  }

  /// Removes a queued/failed ticket from active printing without deleting its
  /// record. The server also clears any safe linked fallback copy and audits
  /// the manager-provided reason.
  Future<List<String>> cancelPrintJob({
    required VenueScope scope,
    required String jobId,
    required String reason,
  }) async {
    final response = await _call('cancelPrintJob', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'jobId': jobId,
      'reason': reason,
    });
    return _stringList(response['cancelledJobIds']);
  }

  Future<ExchangeRateQuote> lookupExchangeRate({
    required VenueScope scope,
    required String tenderCurrencyCode,
  }) async {
    final response = await _call('lookupExchangeRate', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'tenderCurrencyCode': tenderCurrencyCode,
    });
    final exchangeRateToBase = response['exchangeRateToBase'];
    final baseCurrencyCode = response['baseCurrencyCode'];
    final returnedTenderCurrencyCode = response['tenderCurrencyCode'];
    final source = response['source'];
    final fetchedAt = response['fetchedAt'];
    final publishedDate = response['publishedDate'];
    if (exchangeRateToBase is! String ||
        baseCurrencyCode is! String ||
        returnedTenderCurrencyCode is! String ||
        source is! String ||
        fetchedAt is! String ||
        (publishedDate != null && publishedDate is! String)) {
      throw StateError('The exchange-rate server returned an invalid quote.');
    }
    return ExchangeRateQuote(
      tenderCurrencyCode: returnedTenderCurrencyCode,
      baseCurrencyCode: baseCurrencyCode,
      exchangeRateToBase: exchangeRateToBase,
      source: source,
      publishedDate: publishedDate as String?,
      fetchedAt: fetchedAt,
    );
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

  Future<OrderSplitResult> splitOrder({
    required VenueScope scope,
    required PosOrder order,
    required String splitOrderId,
    required Map<String, int> lineQuantities,
  }) async {
    final response = await _call('splitOrder', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'orderId': order.id,
      'splitOrderId': splitOrderId,
      'splitLines': lineQuantities.entries
          .where((entry) => entry.value > 0)
          .map(
            (entry) => <String, Object?>{
              'lineId': entry.key,
              'quantity': entry.value,
            },
          )
          .toList(growable: false),
    });
    final returnedOrderId = response['splitOrderId'];
    final splitTotalMinor = response['splitTotalMinor'];
    final remainingTotalMinor = response['remainingTotalMinor'];
    if (returnedOrderId is! String ||
        returnedOrderId.isEmpty ||
        splitTotalMinor is! int ||
        (remainingTotalMinor != null && remainingTotalMinor is! int)) {
      throw StateError('The server did not return a valid split bill.');
    }
    return OrderSplitResult(
      splitOrderId: returnedOrderId,
      splitTotalMinor: splitTotalMinor,
      remainingTotalMinor: remainingTotalMinor as int?,
      alreadySplit: response['alreadySplit'] == true,
    );
  }

  /// Owner-only, venue-specific notification timing. This remains a trusted
  /// server mutation because venue records themselves are server-owned.
  Future<void> updateVenueOperationalSettings({
    required VenueScope scope,
    required int seconds,
    required int orderFlowAmberMinutes,
    required int orderFlowRedMinutes,
    required int businessDayCutoffMinutes,
  }) {
    return _call('updateVenueNotificationSettings', {
      'tenantId': scope.tenantId,
      'venueId': scope.venueId,
      'notificationRetentionSeconds': seconds,
      'orderFlowAmberMinutes': orderFlowAmberMinutes,
      'orderFlowRedMinutes': orderFlowRedMinutes,
      'businessDayCutoffMinutes': businessDayCutoffMinutes,
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
    final staffSession = StaffPinSessionStore.current;
    final requestData = <String, Object?>{
      ...data,
      if (staffSession != null) 'staffPinSessionId': staffSession.sessionId,
      if (staffSession != null) 'staffPinSessionToken': staffSession.sessionToken,
    };
    final response = await http.post(
      endpoint,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
        'X-Firebase-AppCheck': ?appCheckToken,
      },
      body: jsonEncode({'action': action, 'data': requestData}),
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

  List<Map<String, Object?>> _modifierSelections(OrderLine line) {
    final selectionsByGroup = <String, List<String>>{};
    for (final selection in line.modifiers) {
      selectionsByGroup
          .putIfAbsent(selection.groupId, () => <String>[])
          .add(selection.optionId);
    }
    return selectionsByGroup.entries
        .map(
          (entry) => <String, Object?>{
            'groupId': entry.key,
            'optionIds': entry.value.toSet().toList(growable: false),
          },
        )
        .toList(growable: false);
  }
}
