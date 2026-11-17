import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/data/print_job_repository.dart';
import 'package:tableside_pos/features/printing/native_print_worker.dart';
import 'package:tableside_pos/features/pos/domain.dart';

void main() {
  test('LAN wake checks only the venue hub queue', () async {
    final queue = _RecordingQueue();
    final worker = NativePrintWorker(
      queue: queue,
      printer: _UnusedPrinter(),
      tenantId: 'tenant-a',
      venueId: 'venue-a',
      deviceId: 'printer-a',
      deviceCredential: 'credential-a',
      localHubOnly: true,
    );

    expect(await worker.processNext(), PrintWorkerResult.noWork);
    expect(queue.lastLocalHubOnly, isTrue);
  });

  test('physical printer failure is retained for the device alert', () async {
    final queue = _FailingPrintQueue();
    final worker = NativePrintWorker(
      queue: queue,
      printer: _FailingPrinter(),
      tenantId: 'tenant-a',
      venueId: 'venue-a',
      deviceId: 'printer-a',
      deviceCredential: 'credential-a',
    );

    expect(await worker.processNext(), PrintWorkerResult.failed);
    expect(worker.lastPrinterFailure, contains('printer is powered off'));
    expect(queue.completedAsPrinted, isFalse);
    expect(queue.failureReason, contains('printer is powered off'));
  });
}

class _RecordingQueue extends PrintJobRepository {
  _RecordingQueue() : super.localOnly();

  bool? lastLocalHubOnly;

  @override
  Future<PrintJob?> claimNext({
    required String tenantId,
    required String venueId,
    required String deviceId,
    required String deviceCredential,
    bool localHubOnly = false,
  }) async {
    lastLocalHubOnly = localHubOnly;
    return null;
  }
}

class _UnusedPrinter implements NativeReceiptPrinter {
  @override
  Future<void> printTicket({
    required Map<String, Object?> payload,
    required String idempotencyKey,
  }) => throw StateError('No job should reach the printer in this test.');
}

class _FailingPrintQueue extends PrintJobRepository {
  _FailingPrintQueue() : super.localOnly();

  bool? completedAsPrinted;
  String? failureReason;

  @override
  Future<PrintJob?> claimNext({
    required String tenantId,
    required String venueId,
    required String deviceId,
    required String deviceCredential,
    bool localHubOnly = false,
  }) async => PrintJob(
    id: 'job-a',
    tenantId: tenantId,
    venueId: venueId,
    targetDeviceId: deviceId,
    orderId: 'order-a',
    status: PrintJobStatus.claimed,
    idempotencyKey: 'print-a',
    createdAt: DateTime.utc(2026),
    payload: const <String, Object?>{'type': 'production'},
  );

  @override
  Future<void> complete({
    required PrintJob job,
    required String deviceCredential,
    required bool printed,
    String? failureReason,
  }) async {
    completedAsPrinted = printed;
    this.failureReason = failureReason;
  }
}

class _FailingPrinter implements NativeReceiptPrinter {
  @override
  Future<void> printTicket({
    required Map<String, Object?> payload,
    required String idempotencyKey,
  }) => throw StateError('The printer is powered off.');
}
