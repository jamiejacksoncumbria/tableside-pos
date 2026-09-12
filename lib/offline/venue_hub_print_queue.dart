import 'dart:async';

import '../core/trusted_clock.dart';
import 'offline_event_ledger.dart';
import 'offline_order_projection.dart';

class VenueHubLocalPrintJob {
  const VenueHubLocalPrintJob({
    required this.id,
    required this.targetDeviceId,
    required this.orderId,
    required this.productionArea,
    required this.createdAtUtc,
    required this.attempts,
    required this.status,
    required this.payload,
    this.fallbackDeviceId,
    this.claimedAtUtc,
    this.failureReason,
  });

  final String id;
  final String targetDeviceId;
  final String orderId;
  final String productionArea;
  final DateTime createdAtUtc;
  final int attempts;
  final String status;
  final Map<String, Object?> payload;
  final String? fallbackDeviceId;
  final DateTime? claimedAtUtc;
  final String? failureReason;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'targetDeviceId': targetDeviceId,
    'orderId': orderId,
    'productionArea': productionArea,
    'createdAtUtc': createdAtUtc.toIso8601String(),
    'attempts': attempts,
    'status': status,
    'payload': payload,
    if (fallbackDeviceId != null) 'fallbackDeviceId': fallbackDeviceId,
    if (claimedAtUtc != null) 'claimedAtUtc': claimedAtUtc!.toIso8601String(),
    if (failureReason != null) 'failureReason': failureReason,
  };

  factory VenueHubLocalPrintJob.fromJson(Map<String, Object?> json) {
    final created = DateTime.tryParse(json['createdAtUtc'] as String? ?? '');
    final payload = json['payload'];
    if (json['id'] is! String ||
        json['targetDeviceId'] is! String ||
        json['orderId'] is! String ||
        json['productionArea'] is! String ||
        created == null ||
        json['attempts'] is! int ||
        json['status'] is! String ||
        payload is! Map) {
      throw const FormatException('A saved local print job is invalid.');
    }
    return VenueHubLocalPrintJob(
      id: json['id'] as String,
      targetDeviceId: json['targetDeviceId'] as String,
      orderId: json['orderId'] as String,
      productionArea: json['productionArea'] as String,
      createdAtUtc: created.toUtc(),
      attempts: json['attempts'] as int,
      status: json['status'] as String,
      payload: Map<String, Object?>.from(payload),
      fallbackDeviceId: json['fallbackDeviceId'] as String?,
      claimedAtUtc: DateTime.tryParse(
        json['claimedAtUtc'] as String? ?? '',
      )?.toUtc(),
      failureReason: json['failureReason'] as String?,
    );
  }

  VenueHubLocalPrintJob copyWith({
    int? attempts,
    String? status,
    DateTime? claimedAtUtc,
    bool clearClaim = false,
    String? failureReason,
    bool clearFailure = false,
    String? targetDeviceId,
  }) => VenueHubLocalPrintJob(
    id: id,
    targetDeviceId: targetDeviceId ?? this.targetDeviceId,
    orderId: orderId,
    productionArea: productionArea,
    createdAtUtc: createdAtUtc,
    attempts: attempts ?? this.attempts,
    status: status ?? this.status,
    payload: payload,
    fallbackDeviceId: fallbackDeviceId,
    claimedAtUtc: clearClaim ? null : claimedAtUtc ?? this.claimedAtUtc,
    failureReason: clearFailure ? null : failureReason ?? this.failureReason,
  );
}

/// Encrypted, crash-recoverable print queue owned by the venue hub.
class VenueHubPrintQueue {
  VenueHubPrintQueue({
    required this.tenantId,
    required this.venueId,
    required this.hubEpoch,
    required this.snapshot,
    OfflineEventLedger? ledger,
  }) : _ledger = ledger ?? OfflineEventLedger.instance;

  static const _kind = 'venuePrintQueue.v1';
  final String tenantId;
  final String venueId;
  final int hubEpoch;
  Map<String, Object?> snapshot;
  final OfflineEventLedger _ledger;
  final Map<String, VenueHubLocalPrintJob> _jobs = {};
  Future<void> _serial = Future.value();

  Future<void> initialize() async {
    final stored = await _ledger.readSnapshot(
      tenantId: tenantId,
      venueId: venueId,
      kind: _kind,
    );
    final value = stored?['value'];
    final rawJobs = value is Map ? value['jobs'] : null;
    if (rawJobs is List) {
      for (final raw in rawJobs) {
        if (raw is Map) {
          final job = VenueHubLocalPrintJob.fromJson(
            Map<String, Object?>.from(raw),
          );
          // A power failure after claiming is unknown, so retry visibly and
          // rely on the ticket idempotency key to avoid silent loss.
          _jobs[job.id] = job.status == 'claimed'
              ? job.copyWith(status: 'queued', clearClaim: true)
              : job;
        }
      }
      await _persist();
    }
  }

  void installSnapshot(Map<String, Object?> value) {
    if (value['hubEpoch'] != hubEpoch) {
      throw StateError('A stale print-routing snapshot was rejected.');
    }
    snapshot = Map<String, Object?>.from(value);
  }

  Future<void> enqueueProduction({
    required OfflineOrderProjection order,
    required List<String> lineIds,
    required bool printRequired,
    required String createdByName,
  }) => _run(() async {
    if (!printRequired) return;
    final routes = _routes();
    final grouped = <String, List<OfflineProjectedLine>>{};
    for (final id in lineIds) {
      final line = order.lines[id];
      if (line == null) continue;
      final area = line.productionArea;
      grouped.putIfAbsent(area, () => []).add(line);
    }
    for (final entry in grouped.entries) {
      final route = routes[entry.key];
      if (route == null || route.primaryDeviceId.isEmpty) continue;
      final id =
          'offline-${hubEpoch}-${order.orderId}-${entry.key}-${lineIds.join('-')}';
      _jobs.putIfAbsent(
        id,
        () => VenueHubLocalPrintJob(
          id: id,
          targetDeviceId: route.primaryDeviceId,
          fallbackDeviceId: route.fallbackDeviceId,
          orderId: order.orderId,
          productionArea: entry.key,
          createdAtUtc: TrustedClock.instance.nowUtc(),
          attempts: 0,
          status: 'queued',
          payload: <String, Object?>{
            'type': 'production',
            'ticketId': id,
            'restaurantName':
                snapshot['venueName'] ?? snapshot['tenantName'] ?? '',
            'reference': order.orderId.split('-').last,
            'productionArea': entry.key,
            'tableLabel': _tableLabel(order.tableId),
            'tabName': order.tabName,
            'createdByName': createdByName,
            'lines': entry.value
                .map(
                  (line) => <String, Object?>{
                    'name': line.name,
                    'quantity': line.quantity,
                    'details': line.details,
                  },
                )
                .toList(growable: false),
          },
        ),
      );
    }
    await _persist();
  });

  Future<void> enqueueReceipt({
    required OfflineOrderProjection order,
    required bool printRequired,
    bool isPreReceipt = false,
    String? jobSuffix,
  }) => _run(() async {
    if (!printRequired) return;
    final route = _routes()['receipt'];
    if (route == null || route.primaryDeviceId.isEmpty) return;
    final id =
        'offline-$hubEpoch-${order.orderId}-receipt-${jobSuffix ?? order.lastSequence}';
    final total = order.totalMinor;
    var net = 0;
    final taxByName = <String, Map<String, int>>{};
    for (final line in order.lines.values) {
      final gross = line.totalMinor;
      final lineNet = (gross * 10000 / (10000 + line.taxRateBasisPoints))
          .round();
      net += lineNet;
      final tax = gross - lineNet;
      final current = taxByName[line.taxRateName];
      taxByName[line.taxRateName] = <String, int>{
        'basisPoints': line.taxRateBasisPoints,
        'taxMinor': (current?['taxMinor'] ?? 0) + tax,
      };
    }
    _jobs.putIfAbsent(
      id,
      () => VenueHubLocalPrintJob(
        id: id,
        targetDeviceId: route.primaryDeviceId,
        fallbackDeviceId: route.fallbackDeviceId,
        orderId: order.orderId,
        productionArea: 'receipt',
        createdAtUtc: TrustedClock.instance.nowUtc(),
        attempts: 0,
        status: 'queued',
        payload: <String, Object?>{
          'type': 'receipt',
          'isPreReceipt': isPreReceipt,
          'receiptNumber':
              order.receiptNumber ?? 'OFF-$hubEpoch-${order.lastSequence}',
          'restaurantName':
              snapshot['venueName'] ?? snapshot['tenantName'] ?? '',
          'currencyCode': snapshot['currencyCode'] ?? 'GBP',
          'tableLabel': _tableLabel(order.tableId),
          'tabName': order.tabName,
          'businessDate': _businessDate(
            order.payments.lastOrNull?.recordedAtUtc ?? order.openedAtUtc,
          ),
          'totalMinor': total,
          'netTotalMinor': net,
          'taxTotalMinor': total - net,
          'lines': order.lines.values
              .map(
                (line) => <String, Object?>{
                  'name': line.name,
                  'quantity': line.quantity,
                  'lineTotalMinor': line.totalMinor,
                },
              )
              .toList(growable: false),
          'payments': order.payments
              .map(
                (payment) => <String, Object?>{
                  'method': payment.method,
                  'tenderedAmountMinor': payment.tenderedAmountMinor,
                  'tenderedCurrencyCode': payment.currencyCode,
                  'baseAmountMinor': payment.baseAmountMinor,
                  'exchangeRateToBase': payment.exchangeRateToBase,
                  'terminalLabel': payment.terminalLabel,
                  'cashChangeBaseMinor': payment.cashChangeBaseMinor,
                  'recordedAt': payment.recordedAtUtc.toIso8601String(),
                },
              )
              .toList(growable: false),
          'taxBreakdown': taxByName.entries
              .map(
                (entry) => <String, Object?>{
                  'taxRateName': entry.key,
                  'taxRateBasisPoints': entry.value['basisPoints'],
                  'taxMinor': entry.value['taxMinor'],
                },
              )
              .toList(growable: false),
          'business': <String, Object?>{
            'name': snapshot['venueName'] ?? snapshot['tenantName'] ?? '',
            'address':
                snapshot['venueAddress'] ?? snapshot['tenantAddress'] ?? '',
            'phoneNumbers':
                snapshot['venuePhoneNumbers'] ??
                snapshot['tenantPhoneNumbers'] ??
                const <String>[],
            'receiptFooter': snapshot['receiptFooter'] ?? '',
          },
          if (isPreReceipt) 'balanceDueMinor': order.balanceDueMinor,
        },
      ),
    );
    await _persist();
  });

  Future<Map<String, Object?>?> claim(String deviceId) => _run(() async {
    final now = TrustedClock.instance.nowUtc();
    var recoveredClaim = false;
    for (final job in _jobs.values.toList(growable: false)) {
      if (job.status == 'claimed' &&
          job.claimedAtUtc != null &&
          now.difference(job.claimedAtUtc!) >= const Duration(minutes: 2)) {
        _jobs[job.id] = job.copyWith(
          status: 'queued',
          clearClaim: true,
          failureReason:
              'Printer acknowledgement was lost; retrying the same ticket.',
        );
        recoveredClaim = true;
      }
    }
    final historyPruned = _pruneHistory(now);
    final candidates =
        _jobs.values
            .where(
              (job) => job.targetDeviceId == deviceId && job.status == 'queued',
            )
            .toList()
          ..sort((a, b) => a.createdAtUtc.compareTo(b.createdAtUtc));
    if (candidates.isEmpty) {
      if (recoveredClaim || historyPruned) await _persist();
      return null;
    }
    final selected = candidates.first.copyWith(
      status: 'claimed',
      attempts: candidates.first.attempts + 1,
      claimedAtUtc: now,
      clearFailure: true,
    );
    _jobs[selected.id] = selected;
    await _persist();
    return selected.toJson();
  });

  Future<void> complete({
    required String deviceId,
    required String jobId,
    required bool printed,
    String? failureReason,
  }) => _run(() async {
    final job = _jobs[jobId];
    if (job == null ||
        job.targetDeviceId != deviceId ||
        job.status != 'claimed') {
      throw StateError('This device does not own the local print job.');
    }
    _jobs[jobId] = printed
        ? job.copyWith(status: 'printed', clearClaim: true, clearFailure: true)
        : job.attempts < 3
        ? job.copyWith(
            status: 'queued',
            clearClaim: true,
            failureReason: failureReason ?? 'Printer did not accept ticket.',
          )
        : job.fallbackDeviceId != null &&
              job.fallbackDeviceId!.isNotEmpty &&
              job.targetDeviceId != job.fallbackDeviceId
        ? job.copyWith(
            targetDeviceId: job.fallbackDeviceId,
            attempts: 0,
            status: 'queued',
            clearClaim: true,
            failureReason: 'Primary printer failed; routed to fallback.',
          )
        : job.copyWith(
            status: 'failed',
            clearClaim: true,
            failureReason:
                failureReason ?? 'Printer failed after three attempts.',
          );
    await _persist();
  });

  bool _pruneHistory(DateTime nowUtc) {
    final oldestRetained = nowUtc.subtract(const Duration(days: 5));
    final before = _jobs.length;
    _jobs.removeWhere(
      (_, job) =>
          job.status == 'printed' && job.createdAtUtc.isBefore(oldestRetained),
    );
    return _jobs.length != before;
  }

  Map<String, _OfflinePrinterRoute> _routes() {
    final result = <String, _OfflinePrinterRoute>{};
    final routes = snapshot['printerRoutes'];
    if (routes is List) {
      for (final raw in routes) {
        if (raw is Map &&
            raw['productionArea'] is String &&
            raw['primaryDeviceId'] is String) {
          result[raw['productionArea'] as String] = _OfflinePrinterRoute(
            primaryDeviceId: raw['primaryDeviceId'] as String,
            fallbackDeviceId: raw['fallbackDeviceId'] as String?,
          );
        }
      }
    }
    return result;
  }

  String? _tableLabel(String? tableId) {
    if (tableId == null) return null;
    final tables = snapshot['tables'];
    if (tables is List) {
      for (final table in tables.whereType<Map>()) {
        if (table['id'] == tableId && table['label'] is String) {
          return table['label'] as String;
        }
      }
    }
    return tableId;
  }

  String _businessDate(DateTime utc) {
    final offset = (snapshot['venueUtcOffsetMinutes'] as num?)?.toInt() ?? 0;
    final cutoff =
        (snapshot['businessDayCutoffMinutes'] as num?)?.toInt() ?? 240;
    var venueTime = utc.toUtc().add(Duration(minutes: offset));
    if ((venueTime.hour * 60) + venueTime.minute < cutoff) {
      venueTime = venueTime.subtract(const Duration(days: 1));
    }
    return '${venueTime.year.toString().padLeft(4, '0')}-'
        '${venueTime.month.toString().padLeft(2, '0')}-'
        '${venueTime.day.toString().padLeft(2, '0')}';
  }

  Future<void> _persist() => _ledger.saveSnapshot(
    tenantId: tenantId,
    venueId: venueId,
    kind: _kind,
    version: DateTime.now().toUtc().microsecondsSinceEpoch,
    value: <String, Object?>{
      'hubEpoch': hubEpoch,
      'jobs': _jobs.values.map((job) => job.toJson()).toList(growable: false),
    },
  );

  Future<T> _run<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _serial = _serial.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}

class _OfflinePrinterRoute {
  const _OfflinePrinterRoute({
    required this.primaryDeviceId,
    this.fallbackDeviceId,
  });

  final String primaryDeviceId;
  final String? fallbackDeviceId;
}
