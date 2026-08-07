import '../../data/print_job_repository.dart';

/// Implement this in the Android and Windows apps using the printer protocol
/// selected for the venue (for example, vendor SDK, USB, Bluetooth, or ESC/POS
/// over TCP). Web builds intentionally never create this object.
abstract interface class NativeReceiptPrinter {
  Future<void> printTicket({
    required Map<String, Object?> payload,
    required String idempotencyKey,
  });
}

enum PrintWorkerResult { noWork, printed, failed }

class NativePrintWorker {
  NativePrintWorker({
    required this.queue,
    required this.printer,
    required this.tenantId,
    required this.venueId,
    required this.deviceId,
  });

  final PrintJobRepository queue;
  final NativeReceiptPrinter printer;
  final String tenantId;
  final String venueId;
  final String deviceId;

  /// Call this from a native foreground/background service on a short timer,
  /// and also when the Firestore queue stream reports new work.
  Future<PrintWorkerResult> processNext() async {
    final job = await queue.claimNext(
      tenantId: tenantId,
      venueId: venueId,
      deviceId: deviceId,
    );
    if (job == null) return PrintWorkerResult.noWork;

    try {
      await printer.printTicket(
        payload: job.payload,
        idempotencyKey: job.idempotencyKey,
      );
      await queue.complete(job: job, printed: true);
      return PrintWorkerResult.printed;
    } on Object catch (error) {
      await queue.complete(
        job: job,
        printed: false,
        failureReason: error.toString(),
      );
      return PrintWorkerResult.failed;
    }
  }
}
