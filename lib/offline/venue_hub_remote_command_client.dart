import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/app_logger.dart';
import '../core/tenant_scope.dart';
import '../core/app_busy_state.dart';
import 'venue_hub_client.dart';
import 'venue_hub_availability.dart';

typedef RemoteHubSubmitter =
    Future<Map<String, Object?>> Function(Map<String, Object?> request);
typedef RemoteHubStatusWaiter =
    Future<Map<String, Object?>> Function(Map<String, Object?> request);

/// Global, process-local indicator used by the shell to make the durability
/// wait explicit. A remote command is never reported as saved merely because
/// Firebase accepted it; this remains active until the venue hub confirms its
/// own durable commit.
class RemoteHubWaitState {
  RemoteHubWaitState._();

  static final ValueNotifier<int> pending = ValueNotifier<int>(0);

  static void begin() => pending.value++;
  static void end() => pending.value = (pending.value - 1).clamp(0, 1 << 20);
}

class VenueHubRemoteCommandClient {
  VenueHubRemoteCommandClient({this.timeout = const Duration(seconds: 90)});

  final Duration timeout;

  Future<VenueHubEventAcknowledgement> send({
    required VenueScope scope,
    required int hubEpoch,
    required String eventType,
    required Map<String, Object?> payload,
    required RemoteHubSubmitter submit,
    required RemoteHubStatusWaiter waitForStatus,
    DateTime? businessTimestampUtc,
  }) async {
    return AppBusyState.guard(
      () => _sendUnblocked(
        scope: scope,
        hubEpoch: hubEpoch,
        eventType: eventType,
        payload: payload,
        submit: submit,
        waitForStatus: waitForStatus,
        businessTimestampUtc: businessTimestampUtc,
      ),
    );
  }

  Future<VenueHubEventAcknowledgement> _sendUnblocked({
    required VenueScope scope,
    required int hubEpoch,
    required String eventType,
    required Map<String, Object?> payload,
    required RemoteHubSubmitter submit,
    required RemoteHubStatusWaiter waitForStatus,
    DateTime? businessTimestampUtc,
  }) async {
    final commandId =
        'remote-${DateTime.now().microsecondsSinceEpoch}-${UniqueKey().hashCode.abs()}';
    RemoteHubWaitState.begin();
    try {
      final request = <String, Object?>{
        'tenantId': scope.tenantId,
        'venueId': scope.venueId,
        'hubEpoch': hubEpoch,
        'commandId': commandId,
        'idempotencyKey': commandId,
        'eventType': eventType,
        'payload': payload,
        if (businessTimestampUtc != null)
          'businessTimestampUtc': businessTimestampUtc
              .toUtc()
              .toIso8601String(),
      };
      final deadline = DateTime.now().toUtc().add(timeout);
      Map<String, Object?>? submitted;
      Object? lastSubmitError;
      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          AppLogger.info(
            'Remote hub command $commandId: submitting (attempt $attempt).',
          );
          final remaining = deadline.difference(DateTime.now().toUtc());
          final attemptTimeout = remaining.inSeconds > 15
              ? const Duration(seconds: 15)
              : remaining;
          submitted = await submit(request).timeout(attemptTimeout);
          break;
        } catch (error) {
          lastSubmitError = error;
          if (!_looksLikeConnectivityFailure(error) ||
              attempt == 3 ||
              !DateTime.now().toUtc().isBefore(deadline)) {
            rethrow;
          }
          await Future<void>.delayed(Duration(milliseconds: attempt * 500));
        }
      }
      if (submitted == null) throw lastSubmitError!;
      final returnedId = submitted['commandId'];
      if (returnedId is! String || returnedId != commandId) {
        throw StateError(
          'The venue command server returned an invalid acknowledgement.',
        );
      }
      AppLogger.info('Remote hub command $commandId: queued in cloud.');
      Map<String, Object?>? value;
      Object? lastWaitError;
      while (DateTime.now().toUtc().isBefore(deadline)) {
        try {
          final remaining = deadline.difference(DateTime.now().toUtc());
          final pollTimeout = remaining.inSeconds > 15
              ? const Duration(seconds: 15)
              : remaining;
          value = await waitForStatus(<String, Object?>{
            'tenantId': scope.tenantId,
            'venueId': scope.venueId,
            'commandId': commandId,
          }).timeout(pollTimeout);
          final status = value['status'];
          final stage = value['stage'] ?? status;
          final hubPoll = value['lastHubClaimPollAt'] ?? 'never';
          final hubHeartbeat = value['lastHubHeartbeatAt'] ?? 'never';
          final claimedBy = value['claimedByDeviceId'] ?? 'none';
          AppLogger.info(
            'Remote hub command $commandId: status=$status, stage=$stage, '
            'claimedBy=$claimedBy, lastHubPoll=$hubPoll, '
            'lastHubHeartbeat=$hubHeartbeat.',
          );
          if (status == 'accepted') break;
          if (status == 'rejected' || status == 'expired') {
            final message = value['rejectionMessage'];
            throw StateError(
              message is String && message.trim().isNotEmpty
                  ? message
                  : status == 'expired'
                  ? 'The venue hub did not claim this command before it expired.'
                  : 'The venue hub rejected this command.',
            );
          }
          lastWaitError = null;
          // The production waiter normally holds the request for several
          // seconds. This small floor also prevents a misconfigured or mocked
          // server from creating a tight acknowledgement polling loop.
          await Future<void>.delayed(const Duration(milliseconds: 100));
        } catch (error) {
          // A terminal response is not a transport failure, even when its
          // business-rule message contains words such as "offline" (for
          // example an offline idempotency-key rejection). Surface the exact
          // hub decision immediately instead of polling the same rejected
          // command until the 90-second deadline.
          if (value?['status'] == 'rejected' || value?['status'] == 'expired') {
            rethrow;
          }
          if (!_looksLikeConnectivityFailure(error)) rethrow;
          lastWaitError = error;
          AppLogger.info(
            'Remote hub command $commandId: acknowledgement connection '
            'interrupted; resuming the same command.',
          );
          await Future<void>.delayed(const Duration(milliseconds: 750));
        }
      }
      if (value?['status'] != 'accepted') {
        final stage = value?['stage'] ?? value?['status'] ?? 'unknown';
        final lastPoll = value?['lastHubClaimPollAt'] ?? 'never';
        final lastHeartbeat = value?['lastHubHeartbeatAt'] ?? 'never';
        throw StateError(
          'The venue hub did not confirm command $commandId before the safe '
                  'deadline (last stage: $stage; last secure hub poll: '
                  '$lastPoll; last heartbeat: $lastHeartbeat). '
                  '${lastWaitError ?? ''}'
              .trim(),
        );
      }
      final acceptedValue = value!;
      final result = acceptedValue['result'];
      if (result is! Map) {
        throw StateError(
          'The venue hub returned an invalid durable acknowledgement.',
        );
      }
      final data = Map<String, Object?>.from(result);
      final eventId = data['eventId'];
      final sequence = data['sequence'];
      final eventHash = data['eventHash'];
      final committedAt = DateTime.tryParse(
        data['committedAtUtc'] as String? ?? '',
      );
      if (eventId is! String ||
          sequence is! int ||
          eventHash is! String ||
          committedAt == null) {
        throw StateError(
          'The venue hub returned an invalid durable acknowledgement.',
        );
      }
      VenueHubAvailability.markOnline();
      return VenueHubEventAcknowledgement(
        eventId: eventId,
        sequence: sequence,
        eventHash: eventHash,
        committedAtUtc: committedAt.toUtc(),
      );
    } on TimeoutException {
      VenueHubAvailability.markOffline();
      throw StateError(
        'The venue hub did not confirm this command. It was not shown as saved; check the connection before retrying.',
      );
    } on Object catch (error) {
      // Business-rule rejections (for example insufficient stock) prove that
      // the hub is online and responding. Only transport-shaped failures are
      // allowed to raise the global HUB OFFLINE warning.
      if (_looksLikeConnectivityFailure(error)) {
        VenueHubAvailability.markOffline(error.toString());
      }
      rethrow;
    } finally {
      RemoteHubWaitState.end();
    }
  }

  bool _looksLikeConnectivityFailure(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('offline') ||
        message.contains('unavailable') ||
        message.contains('connection') ||
        message.contains('network') ||
        message.contains('socket') ||
        message.contains('timed out') ||
        message.contains('timeout');
  }
}
