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

/// The venue's live print-recovery desk. It deliberately retains failed job
/// data rather than offering deletion: staff can diagnose the reason and an
/// owner/manager can issue an audited, clearly marked reprint.
class PrintQueueRecoveryPage extends ConsumerStatefulWidget {
  const PrintQueueRecoveryPage({super.key});

  @override
  ConsumerState<PrintQueueRecoveryPage> createState() =>
      _PrintQueueRecoveryPageState();
}

class _PrintQueueRecoveryPageState
    extends ConsumerState<PrintQueueRecoveryPage> {
  final ProductionCommandRepository _commands = ProductionCommandRepository();
  final Set<String> _retryingJobIds = <String>{};
  bool _retryingAll = false;

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

  bool _canRetry(PrintJob job) =>
      job.status == PrintJobStatus.failed &&
      job.fallbackDeliveryStatus != 'printed' &&
      (job.fallbackFromJobId?.isNotEmpty == true ||
          job.fallbackDeviceId?.isNotEmpty != true);

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
    final canManageReprints = memberships.any(
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
                        failed.isEmpty
                            ? 'All print jobs are clear'
                            : '${failed.length} failed print job${failed.length == 1 ? '' : 's'}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        canManageReprints
                            ? 'Reprints return only to the original active route and are clearly marked REPRINT.'
                            : 'Managers and owners can reprint failed tickets. You can still see the live printer status here.',
                      ),
                      if (canManageReprints && eligible.isNotEmpty) ...[
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
                    canManageReprints: canManageReprints,
                    retrying: _retryingJobIds.contains(job.id),
                    canRetry: _canRetry(job),
                    onRetry: () => _retryJob(job),
                  ),
              ],
              if (waiting.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  'Live queue',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                for (final job in waiting) _PendingPrintJobCard(job: job),
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

class _FailedPrintJobCard extends StatelessWidget {
  const _FailedPrintJobCard({
    required this.job,
    required this.canManageReprints,
    required this.retrying,
    required this.canRetry,
    required this.onRetry,
  });

  final PrintJob job;
  final bool canManageReprints;
  final bool retrying;
  final bool canRetry;
  final VoidCallback onRetry;

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
            if (!canManageReprints)
              const Text('Ask a manager or owner to reprint this ticket.')
            else if (fallbackDelivered)
              const Text('Delivered by fallback printer.')
            else if (delegatedToFallback)
              const Text('Waiting for or using the fallback printer.')
            else
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: retrying || !canRetry ? null : onRetry,
                  icon: retrying
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.print_rounded),
                  label: Text(retrying ? 'Queueing…' : 'Reprint ticket'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PendingPrintJobCard extends StatelessWidget {
  const _PendingPrintJobCard({required this.job});

  final PrintJob job;

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
      trailing: Text(
        job.status == PrintJobStatus.claimed ? 'Printing' : 'Waiting',
      ),
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
