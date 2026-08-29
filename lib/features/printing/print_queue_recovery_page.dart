import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../data/print_job_repository.dart';
import '../../data/production_command_repository.dart';
import '../auth/session_providers.dart';
import '../notifications/notification_centre.dart';
import '../pos/domain.dart';

final venuePrintJobsProvider = StreamProvider.autoDispose
    .family<List<PrintJob>, VenueScope>(
      (ref, scope) => PrintJobRepository(
        FirebaseFirestore.instance,
      ).watchVenueJobs(tenantId: scope.tenantId, venueId: scope.venueId),
    );

/// The venue's live print-recovery desk. Jobs are never physically deleted:
/// managers can clear unprinted work with a reason, leaving an audit record
/// while safely stopping any linked fallback copy.
class PrintQueueRecoveryPage extends ConsumerStatefulWidget {
  const PrintQueueRecoveryPage({super.key});

  @override
  ConsumerState<PrintQueueRecoveryPage> createState() =>
      _PrintQueueRecoveryPageState();
}

class _PrintQueueRecoveryPageState
    extends ConsumerState<PrintQueueRecoveryPage> {
  static const _staleClaimAfter = Duration(minutes: 5);
  final ProductionCommandRepository _commands = ProductionCommandRepository();
  final Set<String> _retryingJobIds = <String>{};
  final Set<String> _cancellingJobIds = <String>{};
  bool _retryingAll = false;
  bool _clearingAll = false;

  Future<void> _retryJob(PrintJob job, {bool skipConfirmation = false}) async {
    final scope = ref.read(activeVenueScopeProvider);
    if (scope == null || _retryingJobIds.contains(job.id)) return;
    if (!skipConfirmation) {
      final accepted = await _confirmRetry(job);
      if (!accepted || !mounted) return;
    }
    setState(() => _retryingJobIds.add(job.id));
    try {
      await _commands.retryFailedPrintJob(scope: scope, jobId: job.id);
      AppLogger.info('Manual reprint queued: job=${job.id}.');
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Reprint queued',
        message:
            '${_ticketLabel(job)} has returned to its original printer route and will print as REPRINT.',
        level: AppNotificationLevel.success,
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Retry failed print job', error, stackTrace);
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Could not queue reprint',
        message: '$error',
        level: AppNotificationLevel.error,
      );
    } finally {
      if (mounted) setState(() => _retryingJobIds.remove(job.id));
    }
  }

  Future<bool> _confirmRetry(PrintJob job) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reprint failed ticket?'),
        content: Text(
          '${_ticketLabel(job)} will be sent to its original printer again. The printed ticket will clearly say REPRINT, because a previous attempt may have partly printed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.print_rounded),
            label: const Text('Queue reprint'),
          ),
        ],
      ),
    );
    return accepted == true;
  }

  Future<void> _retryAll(List<PrintJob> jobs) async {
    if (_retryingAll) return;
    final eligible = jobs.where(_canRetry).toList(growable: false);
    if (eligible.isEmpty) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Queue ${eligible.length} reprint(s)?'),
        content: const Text(
          'Each ticket will return to its original active printer and be marked REPRINT. Check the printer is ready before continuing.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Queue all'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;

    setState(() => _retryingAll = true);
    var queued = 0;
    var failed = 0;
    for (final job in eligible) {
      final scope = ref.read(activeVenueScopeProvider);
      if (scope == null) break;
      try {
        await _commands.retryFailedPrintJob(scope: scope, jobId: job.id);
        queued += 1;
        AppLogger.info('Manual batch reprint queued: job=${job.id}.');
      } on Object catch (error, stackTrace) {
        failed += 1;
        AppLogger.error('Retry failed print job in batch', error, stackTrace);
      }
    }
    if (!mounted) return;
    setState(() => _retryingAll = false);
    showAppNotification(
      context,
      ref: ref,
      title: queued == 0 ? 'No reprints queued' : 'Reprints queued',
      message: failed == 0
          ? '$queued ticket${queued == 1 ? '' : 's'} returned to the printer queue.'
          : '$queued ticket${queued == 1 ? '' : 's'} queued; $failed still need${failed == 1 ? 's' : ''} attention.',
      level: failed == 0
          ? AppNotificationLevel.success
          : AppNotificationLevel.warning,
    );
  }

  Future<String?> _confirmCancellation({
    required int count,
    PrintJob? job,
  }) async {
    final reasonController = TextEditingController(text: 'No longer required.');
    try {
      return await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            count == 1 ? 'Clear print job?' : 'Clear $count print jobs?',
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  job == null
                      ? 'Queued, failed, or abandoned printing jobs will be cleared. A job claimed within the last five minutes stays protected. Any safe linked fallback job will also be stopped.'
                      : '${_ticketLabel(job)} will be removed from the active queue. It will not be deleted: the ticket, reason and manager action remain in the audit history.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: reasonController,
                  maxLength: 300,
                  minLines: 2,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Reason',
                    hintText: 'Why should this ticket not print?',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Keep jobs'),
            ),
            FilledButton.icon(
              onPressed: () {
                final reason = reasonController.text.trim();
                if (reason.isEmpty) return;
                Navigator.of(context).pop(reason);
              },
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              icon: const Icon(Icons.remove_circle_outline_rounded),
              label: Text(count == 1 ? 'Clear job' : 'Clear jobs'),
            ),
          ],
        ),
      );
    } finally {
      reasonController.dispose();
    }
  }

  Future<void> _cancelJob(PrintJob job, {String? reason}) async {
    final scope = ref.read(activeVenueScopeProvider);
    if (scope == null ||
        _clearingAll ||
        _cancellingJobIds.contains(job.id) ||
        !_canCancel(job)) {
      return;
    }
    final cancellationReason =
        reason ?? await _confirmCancellation(count: 1, job: job);
    if (cancellationReason == null || !mounted) return;

    setState(() => _cancellingJobIds.add(job.id));
    try {
      final cancelledJobIds = await _commands.cancelPrintJob(
        scope: scope,
        jobId: job.id,
        reason: cancellationReason,
      );
      AppLogger.info(
        'Cleared print queue job ${job.id}; linked jobs: ${cancelledJobIds.join(', ')}.',
      );
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Print job cleared',
        message: cancelledJobIds.length > 1
            ? '${_ticketLabel(job)} and its linked fallback copy were removed from the active queue.'
            : '${_ticketLabel(job)} was removed from the active queue.',
        level: AppNotificationLevel.success,
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Clear print queue job', error, stackTrace);
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Could not clear print job',
        message: '$error',
        level: AppNotificationLevel.error,
      );
    } finally {
      if (mounted) setState(() => _cancellingJobIds.remove(job.id));
    }
  }

  Future<void> _clearAll(List<PrintJob> jobs) async {
    if (_clearingAll) return;
    final scope = ref.read(activeVenueScopeProvider);
    final eligible = jobs.where(_canCancel).toList(growable: false);
    if (scope == null || eligible.isEmpty) return;
    final reason = await _confirmCancellation(count: eligible.length);
    if (reason == null || !mounted) return;

    setState(() => _clearingAll = true);
    final clearedJobIds = <String>{};
    var cleared = 0;
    var failed = 0;
    try {
      for (final job in eligible) {
        if (clearedJobIds.contains(job.id)) continue;
        try {
          final cancelled = await _commands.cancelPrintJob(
            scope: scope,
            jobId: job.id,
            reason: reason,
          );
          clearedJobIds.addAll(cancelled);
          cleared += 1;
          AppLogger.info('Batch-cleared print job ${job.id}.');
        } on Object catch (error, stackTrace) {
          failed += 1;
          AppLogger.error('Clear print queue job in batch', error, stackTrace);
        }
      }
    } finally {
      if (mounted) setState(() => _clearingAll = false);
    }
    if (!mounted) return;
    showAppNotification(
      context,
      ref: ref,
      title: failed == 0 ? 'Print queue cleared' : 'Queue partly cleared',
      message: failed == 0
          ? '$cleared job${cleared == 1 ? '' : 's'} ${cleared == 1 ? 'was' : 'were'} removed from the active queue.'
          : '$cleared job${cleared == 1 ? '' : 's'} ${cleared == 1 ? 'was' : 'were'} cleared; $failed still need${failed == 1 ? 's' : ''} attention.',
      level: failed == 0
          ? AppNotificationLevel.success
          : AppNotificationLevel.warning,
    );
  }

  bool _canRetry(PrintJob job) =>
      job.status == PrintJobStatus.failed &&
      job.fallbackDeliveryStatus != 'printed' &&
      (job.fallbackFromJobId?.isNotEmpty == true ||
          job.fallbackDeviceId?.isNotEmpty != true);

  bool _canCancel(PrintJob job) {
    if (job.status == PrintJobStatus.queued ||
        job.status == PrintJobStatus.failed) {
      return true;
    }
    if (job.status != PrintJobStatus.claimed) return false;
    final claimedAt = job.claimedAt ?? job.createdAt;
    return DateTime.now().difference(claimedAt) >= _staleClaimAfter;
  }

  @override
  Widget build(BuildContext context) {
    final scope = ref.watch(activeVenueScopeProvider);
    if (scope == null) {
      return const Scaffold(
        body: Center(
          child: Text('Choose a venue before opening the print queue.'),
        ),
      );
    }
    final userId = FirebaseAuth.instance.currentUser?.uid;
    final memberships = userId == null
        ? const <TenantMembership>[]
        : ref
              .watch(membershipsProvider(userId))
              .when(
                data: (items) => items,
                loading: () => const <TenantMembership>[],
                error: (error, stackTrace) {
                  AppLogger.error(
                    'Load print recovery access',
                    error,
                    stackTrace,
                  );
                  return const <TenantMembership>[];
                },
              );
    final canManagePrintQueue = memberships.any(
      (membership) =>
          membership.tenantId == scope.tenantId &&
          (membership.roles.contains('owner') ||
              membership.roles.contains('manager')),
    );
    final jobs = ref.watch(venuePrintJobsProvider(scope));

    return Scaffold(
      appBar: AppBar(title: const Text('Print queue recovery')),
      body: jobs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) {
          AppLogger.error('Load venue print queue', error, stackTrace);
          return _QueueError(error: error);
        },
        data: (allJobs) {
          final failed =
              allJobs
                  .where((job) => job.status == PrintJobStatus.failed)
                  .toList(growable: false)
                ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
          final waiting =
              allJobs
                  .where(
                    (job) =>
                        job.status == PrintJobStatus.queued ||
                        job.status == PrintJobStatus.claimed,
                  )
                  .toList(growable: false)
                ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
          final eligible = failed.where(_canRetry).toList(growable: false);
          final cancellable = allJobs.where(_canCancel).toList(growable: false);
          final queuedCount = waiting
              .where((job) => job.status == PrintJobStatus.queued)
              .length;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                color: failed.isEmpty
                    ? Theme.of(context).colorScheme.secondaryContainer
                    : Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        failed.isNotEmpty
                            ? '${failed.length} failed print job${failed.length == 1 ? '' : 's'}'
                            : waiting.isEmpty
                            ? 'All print jobs are clear'
                            : '$queuedCount ticket${queuedCount == 1 ? '' : 's'} waiting to print',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        canManagePrintQueue
                            ? 'Reprints use the original route and say REPRINT. You can also clear only jobs that have not started printing.'
                            : 'Managers and owners can reprint or clear unprinted tickets. You can still see the live printer status here.',
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => _PrintedTicketHistoryPage(
                              canReprint: canManagePrintQueue,
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.history_rounded),
                        label: const Text('Printed ticket history'),
                      ),
                      if (canManagePrintQueue && eligible.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _retryingAll
                              ? null
                              : () => _retryAll(eligible),
                          icon: _retryingAll
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.restart_alt_rounded),
                          label: Text(
                            _retryingAll
                                ? 'Queueing reprints…'
                                : 'Reprint all failed tickets',
                          ),
                        ),
                      ],
                      if (canManagePrintQueue && cancellable.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _clearingAll
                              ? null
                              : () => _clearAll(cancellable),
                          icon: _clearingAll
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.remove_circle_outline_rounded),
                          label: Text(
                            _clearingAll
                                ? 'Clearing queue…'
                                : 'Clear ${cancellable.length} unprinted job${cancellable.length == 1 ? '' : 's'}',
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (failed.isNotEmpty) ...[
                Text(
                  'Failed jobs',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                for (final job in failed)
                  _FailedPrintJobCard(
                    job: job,
                    canManagePrintQueue: canManagePrintQueue,
                    retrying: _retryingJobIds.contains(job.id),
                    cancelling: _cancellingJobIds.contains(job.id),
                    canRetry: _canRetry(job),
                    canCancel: _canCancel(job),
                    onRetry: () => _retryJob(job),
                    onCancel: () => _cancelJob(job),
                  ),
              ],
              if (waiting.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  'Live queue',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                for (final job in waiting)
                  _PendingPrintJobCard(
                    job: job,
                    canManagePrintQueue: canManagePrintQueue,
                    cancelling: _cancellingJobIds.contains(job.id),
                    canCancel: _canCancel(job),
                    onCancel: () => _cancelJob(job),
                  ),
              ],
              if (failed.isEmpty && waiting.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 28),
                  child: Center(
                    child: Text(
                      'There are no pending or failed print jobs for this venue.',
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  String _ticketLabel(PrintJob job) {
    final reference = job.payload['reference'] as String?;
    final tableLabel = job.payload['tableLabel'] as String?;
    final tabName = job.payload['tabName'] as String?;
    final location = tabName?.trim().isNotEmpty == true
        ? 'tab ${tabName!.trim()}'
        : tableLabel?.trim().isNotEmpty == true
        ? 'table ${tableLabel!.trim()}'
        : 'order ${reference ?? job.orderId}';
    return reference?.trim().isNotEmpty == true
        ? 'Order ${reference!.trim()} for $location'
        : location;
  }
}

class _PrintedTicketHistoryPage extends ConsumerStatefulWidget {
  const _PrintedTicketHistoryPage({required this.canReprint});

  final bool canReprint;

  @override
  ConsumerState<_PrintedTicketHistoryPage> createState() =>
      _PrintedTicketHistoryPageState();
}

class _PrintedTicketHistoryPageState
    extends ConsumerState<_PrintedTicketHistoryPage> {
  final ProductionCommandRepository _commands = ProductionCommandRepository();
  final Set<String> _reprinting = <String>{};

  Future<void> _reprint(PrintJob job) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reprint this ticket?'),
        content: Text(
          '${_jobLocation(job)} will print again on its original printer and will clearly say REPRINT.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.print_rounded),
            label: const Text('Reprint'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    final scope = ref.read(activeVenueScopeProvider);
    if (scope == null) return;
    setState(() => _reprinting.add(job.id));
    try {
      await _commands.reprintPrintedJob(scope: scope, jobId: job.id);
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Reprint queued',
        message: '${_jobLocation(job)} was sent to its original printer.',
        level: AppNotificationLevel.success,
      );
    } on Object catch (error, stackTrace) {
      AppLogger.error('Reprint printed ticket', error, stackTrace);
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: 'Could not reprint ticket',
        message: '$error',
        level: AppNotificationLevel.error,
      );
    } finally {
      if (mounted) setState(() => _reprinting.remove(job.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = ref.watch(activeVenueScopeProvider);
    if (scope == null) {
      return const Scaffold(body: Center(child: Text('Choose a venue first.')));
    }
    final jobs = ref.watch(venuePrintJobsProvider(scope));
    final cutoff = DateTime.now().subtract(const Duration(days: 5));
    return Scaffold(
      appBar: AppBar(title: const Text('Printed ticket history')),
      body: jobs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) {
          AppLogger.error('Load printed ticket history', error, stackTrace);
          return _QueueError(error: error);
        },
        data: (allJobs) {
          final printed = allJobs.where((job) {
            final printedAt = job.completedAt;
            return job.status == PrintJobStatus.printed &&
                printedAt != null &&
                !printedAt.isBefore(cutoff);
          }).toList(growable: false)
            ..sort((a, b) => b.completedAt!.compareTo(a.completedAt!));
          if (printed.isEmpty) {
            return const Center(
              child: Text('No successfully printed tickets in the last five days.'),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: printed.length,
            itemBuilder: (context, index) {
              final job = printed[index];
              final busy = _reprinting.contains(job.id);
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.receipt_long_rounded),
                  title: Text(
                    '${_areaLabel(job)} ${job.payload['type'] == 'receipt' ? 'receipt' : 'ticket'}',
                  ),
                  subtitle: Text(
                    '${_jobLocation(job)}\nPrinted ${_dateTime(job.completedAt!)}',
                  ),
                  isThreeLine: true,
                  trailing: widget.canReprint
                      ? FilledButton.icon(
                          onPressed: busy ? null : () => _reprint(job),
                          icon: busy
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.print_rounded),
                          label: Text(busy ? 'Queueing…' : 'Reprint'),
                        )
                      : const Text('Manager only'),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _FailedPrintJobCard extends StatelessWidget {
  const _FailedPrintJobCard({
    required this.job,
    required this.canManagePrintQueue,
    required this.retrying,
    required this.cancelling,
    required this.canRetry,
    required this.canCancel,
    required this.onRetry,
    required this.onCancel,
  });

  final PrintJob job;
  final bool canManagePrintQueue;
  final bool retrying;
  final bool cancelling;
  final bool canRetry;
  final bool canCancel;
  final VoidCallback onRetry;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallbackDelivered = job.fallbackDeliveryStatus == 'printed';
    final delegatedToFallback =
        job.fallbackFromJobId?.isNotEmpty != true &&
        job.fallbackDeviceId?.isNotEmpty == true;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.print_disabled_rounded, color: scheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${_areaLabel(job)} ${job.payload['type'] == 'receipt' ? 'receipt' : 'ticket'}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text('${job.attempts} attempt${job.attempts == 1 ? '' : 's'}'),
              ],
            ),
            const SizedBox(height: 8),
            Text(_jobLocation(job)),
            const SizedBox(height: 4),
            Text('Printer device: ${job.targetDeviceId}'),
            const SizedBox(height: 4),
            Text('Failed: ${_dateTime(job.completedAt ?? job.createdAt)}'),
            const SizedBox(height: 10),
            Text(
              fallbackDelivered
                  ? 'Fallback printer completed this ticket. No reprint is needed.'
                  : delegatedToFallback
                  ? 'A fallback printer is handling this ticket. Reprint the failed fallback ticket instead, so food cannot print twice.'
                  : job.failureReason?.trim().isNotEmpty == true
                  ? 'Reason: ${job.failureReason!.trim()}'
                  : 'Reason: The printer did not confirm this job.',
            ),
            const SizedBox(height: 12),
            if (!canManagePrintQueue)
              const Text(
                'Ask a manager or owner to reprint or clear this ticket.',
              )
            else
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: [
                    if (!fallbackDelivered && !delegatedToFallback)
                      FilledButton.icon(
                        onPressed: retrying || cancelling || !canRetry
                            ? null
                            : onRetry,
                        icon: retrying
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.print_rounded),
                        label: Text(retrying ? 'Queueing…' : 'Reprint ticket'),
                      ),
                    OutlinedButton.icon(
                      onPressed: retrying || cancelling || !canCancel
                          ? null
                          : onCancel,
                      icon: cancelling
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.remove_circle_outline_rounded),
                      label: Text(cancelling ? 'Clearing…' : 'Clear job'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PendingPrintJobCard extends StatelessWidget {
  const _PendingPrintJobCard({
    required this.job,
    required this.canManagePrintQueue,
    required this.cancelling,
    required this.canCancel,
    required this.onCancel,
  });

  final PrintJob job;
  final bool canManagePrintQueue;
  final bool cancelling;
  final bool canCancel;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: Icon(
        job.status == PrintJobStatus.claimed
            ? Icons.print_rounded
            : Icons.schedule_rounded,
      ),
      title: Text(
        '${_areaLabel(job)} ${job.payload['type'] == 'receipt' ? 'receipt' : 'ticket'}',
      ),
      subtitle: Text(
        '${_jobLocation(job)}\nQueued ${_dateTime(job.createdAt)}',
      ),
      isThreeLine: true,
      trailing: canManagePrintQueue && canCancel
          ? TextButton.icon(
              onPressed: cancelling ? null : onCancel,
              icon: cancelling
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.remove_circle_outline_rounded),
              label: Text(cancelling ? 'Clearing…' : 'Clear'),
            )
          : Text(job.status == PrintJobStatus.claimed ? 'Printing' : 'Waiting'),
    ),
  );
}

class _QueueError extends StatelessWidget {
  const _QueueError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        'The live print queue could not be loaded. Check the connection and try again.\n\n$error',
        textAlign: TextAlign.center,
      ),
    ),
  );
}

String _areaLabel(PrintJob job) => switch (job.productionArea) {
  'bar' => 'Bar',
  'dessert' => 'Dessert',
  'receipt' => 'Receipt',
  _ => 'Kitchen',
};

String _jobLocation(PrintJob job) {
  final tabName = job.payload['tabName'] as String?;
  final tableLabel = job.payload['tableLabel'] as String?;
  if (tabName?.trim().isNotEmpty == true) return 'Tab: ${tabName!.trim()}';
  if (tableLabel?.trim().isNotEmpty == true) {
    return 'Table: ${tableLabel!.trim()}';
  }
  final reference = job.payload['reference'] as String?;
  return reference?.trim().isNotEmpty == true
      ? 'Order: ${reference!.trim()}'
      : 'Order: ${job.orderId}';
}

String _dateTime(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} '
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
