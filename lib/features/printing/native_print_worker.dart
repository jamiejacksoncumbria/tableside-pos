import '../../core/app_logger.dart';
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
    required this.deviceCredential,
    Set<String>? printedAwaitingCompletion,
  }) : printedAwaitingCompletion =
           printedAwaitingCompletion ?? <String>{};

  final PrintJobRepository queue;
  final NativeReceiptPrinter printer;
  final String tenantId;
  final String venueId;
  final String deviceId;
  final String deviceCredential;
  final Set<String> printedAwaitingCompletion;

  /// Call this from a native foreground/background service on a short timer,
  /// and also when the Firestore queue stream reports new work.
  Future<PrintWorkerResult> processNext() async {
    final job = await queue.claimNext(
      tenantId: tenantId,
      venueId: venueId,
      deviceId: deviceId,
      deviceCredential: deviceCredential,
    );
    if (job == null) return PrintWorkerResult.noWork;

    AppLogger.info(
      'Printer job claimed: job=${job.id}, target=${job.targetDeviceId}, '
      'area=${job.productionArea ?? 'unknown'}, attempt=${job.attempts}.',
    );

    if (!printedAwaitingCompletion.contains(job.idempotencyKey)) {
      try {
        await printer.printTicket(
          payload: job.payload,
          idempotencyKey: job.idempotencyKey,
        );
        // Keep an in-process delivery checkpoint until the queue authority
        // confirms completion. If the HTTP response is interrupted after the
        // physical printer accepted the ticket, the resumed claim must only
        // retry its acknowledgement, never print a second kitchen ticket.
        printedAwaitingCompletion.add(job.idempotencyKey);
      } on Object catch (error, stackTrace) {
        AppLogger.error('Print ticket ${job.idempotencyKey}', error, stackTrace);
        await queue.complete(
          job: job,
          deviceCredential: deviceCredential,
          printed: false,
          failureReason: error.toString(),
        );
        return PrintWorkerResult.failed;
      }
    } else {
      AppLogger.info(
        'Printer job ${job.id} was already delivered; retrying completion acknowledgement only.',
      );
    }

    try {
      await queue.complete(
        job: job,
        deviceCredential: deviceCredential,
        printed: true,
      );
      printedAwaitingCompletion.remove(job.idempotencyKey);
      AppLogger.info('Printer job completed: job=${job.id}, printed=true.');
      return PrintWorkerResult.printed;
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'Confirm printed ticket ${job.idempotencyKey}',
        error,
        stackTrace,
      );
      // The paper has already left the printer. Never report it as a physical
      // failure or route a fallback copy merely because the completion
      // acknowledgement was interrupted. The owner worker retains the local
      // checkpoint and resumes this exact claim on its next pass.
      rethrow;
    }
  }
}
