import 'dart:async';

import '../core/app_logger.dart';
import '../core/tenant_scope.dart';
import '../core/trusted_clock.dart';
import '../data/production_command_repository.dart';
import 'offline_event.dart';
import 'offline_event_ledger.dart';
import 'offline_order_projection.dart';
import 'venue_hub_bootstrap.dart';
import 'venue_hub_cloud_sync.dart';
import 'venue_hub_command_processor.dart';
import 'venue_hub_device_credential.dart';
import 'venue_hub_offline_pin.dart';
import 'venue_hub_server.dart';
import 'venue_hub_staff_sessions.dart';
import 'venue_hub_print_queue.dart';
import 'venue_hub_realtime_presence.dart';
import 'venue_hub_platform.dart';
import 'venue_hub_offline_view.dart';
import 'venue_offline_catalogue.dart';
import 'venue_offline_order_book.dart';

enum VenueHubRuntimeState { stopped, starting, ready, degraded, failed }

class VenueHubRuntimeStatus {
  const VenueHubRuntimeStatus({
    required this.state,
    required this.pendingEvents,
    this.endpoint,
    this.message,
  });

  final VenueHubRuntimeState state;
  final int pendingEvents;
  final Uri? endpoint;
  final String? message;
}

/// Owns the authoritative native venue process. It refuses to start unless it
/// has a current cloud-signed bootstrap, encrypted catalogue/staff snapshot,
/// trusted TLS identity and recoverable event chain.
class VenueHubRuntime {
  VenueHubRuntime({
    OfflineEventLedger? ledger,
    ProductionCommandRepository? repository,
    VenueHubServer? server,
  }) : _ledger = ledger ?? OfflineEventLedger.instance,
       _repository = repository ?? ProductionCommandRepository(),
       _server = server ?? createVenueHubServer();

  static final VenueHubRuntime instance = VenueHubRuntime();

  static const bootstrapSnapshotKind = 'venueBootstrap.v1';
  final OfflineEventLedger _ledger;
  final ProductionCommandRepository _repository;
  final VenueHubServer _server;
  final StreamController<VenueHubRuntimeStatus> _statuses =
      StreamController<VenueHubRuntimeStatus>.broadcast();
  VenueHubCloudSync? _sync;
  VenueHubPrintQueue? _printQueue;
  VenueHubRealtimePresence? _realtimePresence;
  StreamSubscription<void>? _realtimeSignalSubscription;
  Future<void> Function(Map<String, Object?> snapshot)? _installFreshSnapshot;
  Future<void> Function()? _refreshAuthorityNow;
  StreamSubscription? _pendingSubscription;
  Timer? _authorityTimer;
  VenueHubRuntimeStatus _status = const VenueHubRuntimeStatus(
    state: VenueHubRuntimeState.stopped,
    pendingEvents: 0,
  );
  VenueScope? _activeScope;
  VenueHubBootstrap? _activeBootstrap;

  VenueHubRuntimeStatus get status => _status;
  Stream<VenueHubRuntimeStatus> get statuses => _statuses.stream;
  VenueScope? get activeScope => _activeScope;
  VenueHubBootstrap? get activeBootstrap => _activeBootstrap;

  /// Waits for this process's hub listener to become usable.
  ///
  /// The active scope is installed before the HTTPS listener has finished
  /// binding. PIN entry can therefore race hub startup. Hub hosts must use the
  /// loopback endpoint once it is ready instead of being mistaken for a remote
  /// POS and routing their own commands through Firebase.
  Future<Uri> waitForLocalEndpoint(
    VenueScope scope, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    Uri? readyEndpoint() {
      final current = _status;
      if (_activeScope == scope &&
          (current.state == VenueHubRuntimeState.ready ||
              current.state == VenueHubRuntimeState.degraded) &&
          current.endpoint != null) {
        return current.endpoint;
      }
      return null;
    }

    final current = readyEndpoint();
    if (current != null) return current;
    if (_status.state == VenueHubRuntimeState.failed) {
      throw StateError(
        _status.message ?? 'The venue hub local service failed to start.',
      );
    }
    try {
      final resolved = await statuses
          .firstWhere(
            (value) =>
                value.state == VenueHubRuntimeState.failed ||
                (_activeScope == scope &&
                    (value.state == VenueHubRuntimeState.ready ||
                        value.state == VenueHubRuntimeState.degraded) &&
                    value.endpoint != null),
          )
          .timeout(timeout);
      if (resolved.state == VenueHubRuntimeState.failed) {
        throw StateError(
          resolved.message ?? 'The venue hub local service failed to start.',
        );
      }
      return resolved.endpoint!;
    } on TimeoutException {
      throw StateError(
        'This device is the venue hub, but its local service did not become ready. '
        'Check Venue offline hub settings before processing orders.',
      );
    }
  }

  Future<void> start({
    required VenueScope scope,
    required String deviceId,
    required VenueHubDeviceCredential credential,
    required VenueHubBootstrap bootstrap,
    required String certificateChainPem,
    required String privateKeyPem,
    String bindAddress = '0.0.0.0',
    int port = 8443,
    Set<String> allowedOrigins = const {},
    Map<String, Object?>? freshSnapshot,
  }) async {
    if (_status.state != VenueHubRuntimeState.stopped &&
        _status.state != VenueHubRuntimeState.failed) {
      throw StateError('The venue hub is already starting or running.');
    }
    _emit(
      const VenueHubRuntimeStatus(
        state: VenueHubRuntimeState.starting,
        pendingEvents: 0,
      ),
    );
    try {
      if (!bootstrap.enabled ||
          bootstrap.hubEpoch < 1 ||
          bootstrap.hubDeviceId != deviceId ||
          bootstrap.hubCredentialId != credential.credentialId) {
        throw StateError(
          'This device is not the active cloud-authorised venue hub.',
        );
      }
      if (!TrustedClock.instance.snapshot.isSynchronised) {
        await TrustedClock.instance.synchroniseFirebase(
          () async => bootstrap.serverTimeMillis,
        );
      }
      await _ledger.initialize();
      if (freshSnapshot != null) {
        if (freshSnapshot['hubEpoch'] != bootstrap.hubEpoch ||
            freshSnapshot['version'] is! int) {
          throw StateError('The cloud venue snapshot is stale or invalid.');
        }
        await _ledger.saveSnapshot(
          tenantId: scope.tenantId,
          venueId: scope.venueId,
          kind: bootstrapSnapshotKind,
          version: freshSnapshot['version'] as int,
          value: freshSnapshot,
        );
      }
      final stored = await _ledger.readSnapshot(
        tenantId: scope.tenantId,
        venueId: scope.venueId,
        kind: bootstrapSnapshotKind,
      );
      final rawSnapshot = stored?['value'];
      if (rawSnapshot is! Map) {
        throw StateError(
          'Download the encrypted venue snapshot before starting offline mode.',
        );
      }
      var snapshot = Map<String, Object?>.from(rawSnapshot);
      if (snapshot['hubEpoch'] != bootstrap.hubEpoch) {
        throw StateError(
          'The encrypted venue snapshot is from an old hub generation.',
        );
      }
      var catalogue = VenueOfflineCatalogue.fromSnapshot(snapshot);
      String staffDisplayName(String staffId) {
        final rawStaff = snapshot['staff'];
        if (rawStaff is! List) return 'Staff member';
        for (final raw in rawStaff.whereType<Map>()) {
          if (raw['staffId'] == staffId) {
            final name = raw['displayName'];
            if (name is String && name.trim().isNotEmpty) return name.trim();
          }
        }
        // Never leak a Firebase UID onto a customer or production ticket.
        // A refreshed hub snapshot normally supplies the staff name; this
        // neutral fallback is safer and clearer if an old snapshot does not.
        return 'Staff member';
      }

      VenueHubOfflineView.instance.install(snapshot);
      final sessions = VenueHubStaffSessionAuthority(
        tenantId: scope.tenantId,
        venueId: scope.venueId,
        ledger: _ledger,
      );
      await sessions.initialize();
      final pins = VenueHubOfflinePinAuthority(
        sessions: sessions,
        tenantId: scope.tenantId,
        venueId: scope.venueId,
        ledger: _ledger,
      );
      await pins.initialize();
      await pins.installSnapshot(snapshot);
      final orderBook = VenueOfflineOrderBook(
        tenantId: scope.tenantId,
        venueId: scope.venueId,
        hubEpoch: bootstrap.hubEpoch,
        catalogueProvider: () => catalogue,
        ledger: _ledger,
      );
      await orderBook.installCloudBaselines(snapshot);
      Future<Map<String, OfflineOrderProjection>> publishOrders() async {
        final orders = await orderBook.rebuild();
        // The order book is the durable authority, while the offline view is
        // the live source consumed by the hub's POS widgets. Publishing every
        // rebuild keeps table balances, named tabs and closed-order state in
        // sync immediately without waiting for a cloud snapshot refresh.
        VenueHubOfflineView.instance.installOrders(
          orders.values
              .map((order) => order.toJson())
              .toList(growable: false),
        );
        return orders;
      }

      await publishOrders();
      final printQueue = VenueHubPrintQueue(
        tenantId: scope.tenantId,
        venueId: scope.venueId,
        hubEpoch: bootstrap.hubEpoch,
        snapshot: snapshot,
        ledger: _ledger,
      );
      await printQueue.initialize();
      _printQueue = printQueue;
      _activeScope = scope;
      _activeBootstrap = bootstrap;
      Future<void> installFreshSnapshot(Map<String, Object?> refreshed) async {
        if (refreshed['hubEpoch'] != bootstrap.hubEpoch ||
            refreshed['version'] is! int) {
          throw StateError('The refreshed cloud venue snapshot is invalid.');
        }
        final refreshedCatalogue = VenueOfflineCatalogue.fromSnapshot(
          refreshed,
        );
        await pins.installSnapshot(refreshed);
        catalogue = refreshedCatalogue;
        snapshot = Map<String, Object?>.from(refreshed);
        await orderBook.installCloudBaselines(snapshot);
        await publishOrders();
        printQueue.installSnapshot(snapshot);
        VenueHubOfflineView.instance.install(snapshot);
        await _ledger.saveSnapshot(
          tenantId: scope.tenantId,
          venueId: scope.venueId,
          kind: bootstrapSnapshotKind,
          version: refreshed['version'] as int,
          value: snapshot,
        );
      }

      _installFreshSnapshot = installFreshSnapshot;
      final processor = VenueHubCommandProcessor(
        tenantId: scope.tenantId,
        venueId: scope.venueId,
        hubEpoch: bootstrap.hubEpoch,
        credentials: bootstrap.credentials,
        authorizeStaff: sessions.authorize,
        validateEvent: catalogue.validateEvent,
        commitEvent: (draft, epoch) async {
          final event = await orderBook.commit(draft, epoch);
          if (event.type == 'order.sent') {
            final orderId = event.payload['orderId'] as String;
            final lineIds = (event.payload['lineIds'] as List)
                .whereType<String>()
                .toList();
            await printQueue.enqueueProduction(
              order: await orderBook.order(orderId),
              lineIds: lineIds,
              printRequired: event.payload['printRequired'] == true,
              createdByName: staffDisplayName(event.staffId),
            );
          } else if (event.type == 'order.closed') {
            final orderId = event.payload['orderId'] as String;
            await printQueue.enqueueReceipt(
              order: await orderBook.order(orderId),
              printRequired: event.payload['printReceipt'] == true,
            );
          } else if (event.type == 'receipt.requested') {
            final orderId = event.payload['orderId'] as String;
            final isDeliveryNote = event.payload['isDeliveryNote'] == true;
            await printQueue.enqueueReceipt(
              order: await orderBook.order(orderId),
              printRequired: true,
              isPreReceipt: !isDeliveryNote,
              isDeliveryNote: isDeliveryNote,
              jobSuffix: event.id,
            );
          }
          // Commit updates the encrypted ledger, but consumers are listening
          // to the in-memory projection. Emit the rebuilt projection before
          // acknowledging the command so every hub screen observes the same
          // accepted state as the submitting terminal.
          await publishOrders();
          return event;
        },
      );
      Future<void> Function()? refreshAuthorityCallback;
      final endpoint = await _server.start(
        VenueHubServerConfiguration(
          bindAddress: bindAddress,
          port: port,
          certificateChainPem: certificateChainPem,
          privateKeyPem: privateKeyPem,
          processor: processor,
          authenticatePin: (clientDeviceId, staffId, pin) async {
            try {
              final issued = await pins.verify(
                staffId: staffId,
                pin: pin,
                nowUtc: TrustedClock.instance.nowUtc(),
              );
              await _ledger.commit(
                OfflineEventDraft(
                  tenantId: scope.tenantId,
                  venueId: scope.venueId,
                  deviceId: clientDeviceId,
                  staffId: staffId,
                  type: 'security.pinAttempt',
                  payload: const <String, Object?>{'successful': true},
                ),
                hubEpoch: bootstrap.hubEpoch,
              );
              return issued;
            } catch (error) {
              await _ledger.commit(
                OfflineEventDraft(
                  tenantId: scope.tenantId,
                  venueId: scope.venueId,
                  deviceId: clientDeviceId,
                  staffId: staffId,
                  type: 'security.pinAttempt',
                  payload: <String, Object?>{
                    'successful': false,
                    'locked': error.toString().contains('locked'),
                  },
                ),
                hubEpoch: bootstrap.hubEpoch,
              );
              rethrow;
            }
          },
          claimPrintJob: printQueue.claim,
          completePrintJob: (deviceId, jobId, printed, failureReason) =>
              printQueue.complete(
                deviceId: deviceId,
                jobId: jobId,
                printed: printed,
                failureReason: failureReason,
              ),
          managePrintJob:
              (action, jobId, reason, clientDeviceId, staffId) async {
                await _ledger.commit(
                  OfflineEventDraft(
                    tenantId: scope.tenantId,
                    venueId: scope.venueId,
                    deviceId: clientDeviceId,
                    staffId: staffId,
                    type: 'security.printQueueManaged',
                    payload: <String, Object?>{
                      'action': action,
                      'jobId': jobId,
                      'reason': ?reason,
                    },
                  ),
                  hubEpoch: bootstrap.hubEpoch,
                );
                switch (action) {
                  case 'retry':
                    await printQueue.retry(jobId);
                    return const <String, Object?>{'updated': true};
                  case 'reprint':
                    await printQueue.reprint(jobId);
                    return const <String, Object?>{'updated': true};
                  case 'cancel':
                    return <String, Object?>{
                      'cancelledJobIds': await printQueue.cancel(
                        jobId,
                        reason ?? 'Cleared by manager.',
                      ),
                    };
                  default:
                    throw StateError(
                      'That local print action is not supported.',
                    );
                }
              },
          readClientSnapshot: () async =>
              Map<String, Object?>.from(snapshot)..remove('staff'),
          refreshSnapshot: () async {
            final refresh = refreshAuthorityCallback;
            if (refresh == null) {
              throw StateError('The venue catalogue refresh is not ready.');
            }
            await refresh();
          },
          readPrintJobs: () async => printQueue.visibleJobs,
          readOrders: () async => (await publishOrders()).values
              .map((order) => order.toJson())
              .toList(growable: false),
          allowedOrigins: allowedOrigins,
        ),
      );
      _sync = VenueHubCloudSync(
        ledger: _ledger,
        upload: (events) async {
          final acknowledged = await _repository.uploadOfflineHubEvents(
            scope: scope,
            deviceId: deviceId,
            hubEpoch: bootstrap.hubEpoch,
            credential: credential,
            events: events,
          );
          return VenueHubCloudUploadResult(acknowledgedEventIds: acknowledged);
        },
      );
      var reconcilingClosedOrders = false;
      final closedOrderRetryAfter = <String, DateTime>{};
      Future<void> reconcileClosedCloudOrders() async {
        if (reconcilingClosedOrders || _activeScope != scope) return;
        final rawCloudOrders = snapshot['openOrders'];
        if (rawCloudOrders is! List || rawCloudOrders.isEmpty) return;
        final cloudOpenIds = rawCloudOrders
            .whereType<Map>()
            .map((order) => order['orderId'])
            .whereType<String>()
            .toSet();
        if (cloudOpenIds.isEmpty) return;
        reconcilingClosedOrders = true;
        try {
          // Upload ordinary immutable events first. Reconciliation is a
          // narrow repair for a cloud document that still says open after the
          // same hub's durable projection has already closed it.
          await _sync!.flush();
          final localOrders = await publishOrders();
          final now = DateTime.now().toUtc();
          final ghosts = localOrders.values
              .where(
                (order) =>
                    order.isClosed &&
                    cloudOpenIds.contains(order.orderId) &&
                    !(closedOrderRetryAfter[order.orderId]?.isAfter(now) ??
                        false),
              )
              .toList(growable: false);
          for (final order in ghosts) {
            try {
              final repaired = await _repository
                  .reconcileOfflineHubClosedOrders(
                    scope: scope,
                    deviceId: deviceId,
                    hubEpoch: bootstrap.hubEpoch,
                    credential: credential,
                    orders: [order.toJson()],
                  );
              closedOrderRetryAfter.remove(order.orderId);
              if (!repaired.contains(order.orderId)) continue;
              AppLogger.info(
                'Reconciled locally closed order ${order.orderId} that '
                'was still advertised as open in cloud data.',
              );
            } catch (error, stackTrace) {
              // One malformed historical order must not prevent independent
              // valid orders from being repaired. Backoff also prevents a
              // permanent data conflict from calling the API every refresh.
              closedOrderRetryAfter[order.orderId] = now.add(
                const Duration(minutes: 5),
              );
              AppLogger.error(
                'Reconcile locally closed order ${order.orderId}',
                error,
                stackTrace,
              );
            }
          }
        } catch (error, stackTrace) {
          // Never stop the LAN hub for a cloud repair failure. The signed,
          // idempotent repair retries during the next authority refresh.
          AppLogger.error(
            'Reconcile locally closed orders with cloud terminals',
            error,
            stackTrace,
          );
        } finally {
          reconcilingClosedOrders = false;
        }
      }
      // RTDB is the sole internet-presence and wake channel. A failure here is
      // non-fatal for the local HTTPS hub: LAN terminals must remain usable
      // during a venue internet outage, while remote commands fail closed.
      // Keep the presence object attached even when its first cloud session
      // request fails. The local HTTPS hub must remain available on the LAN,
      // while the verified authority refresh below can retry only the RTDB
      // connection without restarting the hub or re-opening its local ledger.
      final activeRealtimePresence = _realtimePresence ??=
          VenueHubRealtimePresence(repository: _repository);
      try {
        await activeRealtimePresence.start(
          scope: scope,
          deviceId: deviceId,
          hubEpoch: bootstrap.hubEpoch,
          credential: credential,
        );
      } on Object catch (error, stackTrace) {
        AppLogger.error(
          'Start venue hub realtime presence; remote commands are unavailable but LAN remains active',
          error,
          stackTrace,
        );
      }
      var remoteTickRunning = false;
      var remoteTickRequested = false;
      var remoteClaimAvailable = true;
      VenueHubStaffGrant? remoteGrant(Map<String, Object?> command) {
        final staffId = command['staffId'];
        final expectedPinVersion = command['pinVersion'];
        final expectedMembershipVersion = command['membershipVersion'];
        final expiresAt = DateTime.tryParse(
          command['expiresAt'] as String? ?? '',
        );
        if (staffId is! String ||
            expectedPinVersion is! int ||
            expectedMembershipVersion is! int ||
            expiresAt == null ||
            !expiresAt.toUtc().isAfter(TrustedClock.instance.nowUtc())) {
          return null;
        }
        final rawStaff = snapshot['staff'];
        if (rawStaff is! List) return null;
        for (final raw in rawStaff.whereType<Map>()) {
          if (raw['staffId'] != staffId ||
              raw['pinVersion'] != expectedPinVersion ||
              raw['membershipVersion'] != expectedMembershipVersion) {
            continue;
          }
          return VenueHubStaffGrant(
            staffId: staffId,
            permissions: (raw['permissions'] as List? ?? const [])
                .whereType<String>()
                .toSet(),
            expiresAtUtc: expiresAt.toUtc(),
            pinVersion: expectedPinVersion,
            membershipVersion: expectedMembershipVersion,
          );
        }
        return null;
      }

      Future<void> remoteTick() async {
        if (_activeScope != scope) return;
        if (remoteTickRunning) {
          // Coalesce wake signals without losing one that arrives while a
          // previous claim batch is still validating or committing.
          remoteTickRequested = true;
          return;
        }
        remoteTickRunning = true;
        try {
          // Bound each signal-triggered claim so a half-open HTTP connection
          // cannot permanently block a later RTDB wake signal.
          final commands = await _repository
              .claimRemoteHubCommands(
                scope: scope,
                deviceId: deviceId,
                hubEpoch: bootstrap.hubEpoch,
                credential: credential,
              )
              .timeout(const Duration(seconds: 12));
          if (!remoteClaimAvailable) {
            AppLogger.info('Venue hub secure command claiming restored.');
            remoteClaimAvailable = true;
          }
          for (final command in commands) {
            final commandId = command['commandId'];
            final claimToken = command['claimToken'];
            if (commandId is! String || claimToken is! String) continue;
            VenueHubCommandAcknowledgement? acknowledgement;
            try {
              AppLogger.info(
                'Remote hub command $commandId: claimed; validating locally.',
              );
              final grant = remoteGrant(command);
              final eventType = command['eventType'];
              final payload = command['payload'];
              if (grant == null || eventType is! String || payload is! Map) {
                throw const VenueHubCommandException(
                  'The staff permission snapshot changed before the command was accepted.',
                );
              }
              acknowledgement = await processor.processRemote(
                commandId: commandId,
                eventType: eventType,
                payload: Map<String, Object?>.from(payload),
                deviceId: 'remote-${command['hostUid']}',
                grant: grant,
                businessTimestampUtc: DateTime.tryParse(
                  command['businessTimestampUtc'] as String? ?? '',
                ),
                trustedNowUtc: TrustedClock.instance.nowUtc(),
              );
              AppLogger.info(
                'Remote hub command $commandId: durably committed as '
                '${acknowledgement.eventId}.',
              );
            } catch (error, stackTrace) {
              // A failure before the durable event exists is a genuine
              // business rejection. It is safe to tell the originating POS
              // that nothing was committed.
              AppLogger.error(
                'Reject remote venue command $commandId before commit',
                error,
                stackTrace,
              );
              try {
                await _repository
                    .completeRemoteHubCommand(
                      scope: scope,
                      deviceId: deviceId,
                      hubEpoch: bootstrap.hubEpoch,
                      credential: credential,
                      commandId: commandId,
                      claimToken: claimToken,
                      accepted: false,
                      rejectionMessage: error.toString(),
                    )
                    .timeout(const Duration(seconds: 12));
              } catch (acknowledgementError, acknowledgementStack) {
                AppLogger.error(
                  'Report rejected remote command $commandId',
                  acknowledgementError,
                  acknowledgementStack,
                );
              }
              continue;
            }

            // From this point onward the operation is irrevocably committed
            // in the encrypted ledger. A network failure must never send it
            // down the rejection path. Start the durable event uploader first;
            // cloud ingestion can independently acknowledge this command if
            // the immediate completion request is lost.
            final committedAcknowledgement = acknowledgement;
            unawaited(_sync!.flush());
            try {
              await _repository
                  .completeRemoteHubCommand(
                    scope: scope,
                    deviceId: deviceId,
                    hubEpoch: bootstrap.hubEpoch,
                    credential: credential,
                    commandId: commandId,
                    claimToken: claimToken,
                    accepted: true,
                    result: <String, Object?>{
                      'eventId': committedAcknowledgement.eventId,
                      'sequence': committedAcknowledgement.sequence,
                      'eventHash': committedAcknowledgement.eventHash,
                      'committedAtUtc': committedAcknowledgement.committedAtUtc
                          .toUtc()
                          .toIso8601String(),
                    },
                  )
                  .timeout(const Duration(seconds: 12));
              AppLogger.info(
                'Remote hub command $commandId: cloud acknowledgement delivered.',
              );
            } catch (error, stackTrace) {
              // The local commit remains authoritative and retryable. The
              // encrypted outbox upload above will project the same immutable
              // event and mark its remote command accepted transactionally.
              AppLogger.error(
                'Deliver acknowledgement for committed remote command '
                '$commandId; durable outbox will retry',
                error,
                stackTrace,
              );
            }
          }
        } catch (error, stackTrace) {
          if (remoteClaimAvailable) {
            AppLogger.error(
              'Claim signalled remote venue commands; LAN orders remain available',
              error,
              stackTrace,
            );
            remoteClaimAvailable = false;
          }
        } finally {
          remoteTickRunning = false;
          if (remoteTickRequested && _activeScope == scope) {
            remoteTickRequested = false;
            unawaited(remoteTick());
          }
        }
      }

      await _realtimeSignalSubscription?.cancel();
      // The stream controller survives a failed initial connection. Attaching
      // now means a later authenticated retry can immediately wake the same
      // command processor without rebuilding the venue runtime.
      _realtimeSignalSubscription = activeRealtimePresence.commandSignals
          .listen(
            (_) => unawaited(remoteTick()),
            onError: (Object error, StackTrace stackTrace) {
              AppLogger.error(
                'Receive realtime hub wake signal',
                error,
                stackTrace,
              );
            },
          );
      if (activeRealtimePresence.connected.value) {
        // Recover commands queued just before the realtime listener connected.
        unawaited(remoteTick());
      }
      _pendingSubscription = _ledger.watchPending().listen(
        (events) {
          _emit(
            VenueHubRuntimeStatus(
              state: VenueHubRuntimeState.ready,
              pendingEvents: events.length,
              endpoint: endpoint,
            ),
          );
          if (events.isNotEmpty) unawaited(_sync!.flush());
        },
        onError: (Object error, StackTrace stackTrace) {
          AppLogger.error('Watch venue hub outbox', error, stackTrace);
          _emit(
            VenueHubRuntimeStatus(
              state: VenueHubRuntimeState.degraded,
              pendingEvents: _status.pendingEvents,
              endpoint: endpoint,
              message: 'Cloud synchronisation needs attention.',
            ),
          );
        },
      );
      _emit(
        VenueHubRuntimeStatus(
          state: VenueHubRuntimeState.ready,
          pendingEvents: (await _ledger.pending()).length,
          endpoint: endpoint,
        ),
      );
      unawaited(reconcileClosedCloudOrders());
      var refreshingAuthority = false;
      Future<void> refreshAuthority() async {
        if (refreshingAuthority) return;
        refreshingAuthority = true;
        try {
          final raw = await _repository
              .fetchOfflineHubBootstrap(scope: scope)
              .timeout(const Duration(seconds: 8));
          final current = VenueHubBootstrap.fromJson(raw);
          if (!current.enabled ||
              current.hubEpoch != bootstrap.hubEpoch ||
              current.hubDeviceId != deviceId ||
              current.hubCredentialId != credential.credentialId) {
            AppLogger.info(
              'Venue hub authority changed in cloud; stopping the old hub.',
            );
            await stop();
            return;
          }
          if (!activeRealtimePresence.connected.value) {
            try {
              // Retry only while disconnected. Healthy hubs remain on their
              // persistent RTDB socket, so this adds no steady-state Function
              // polling or heartbeat cost.
              await activeRealtimePresence.start(
                scope: scope,
                deviceId: deviceId,
                hubEpoch: bootstrap.hubEpoch,
                credential: credential,
              );
              AppLogger.info('Venue hub realtime presence session restored.');
              unawaited(remoteTick());
            } catch (error, stackTrace) {
              AppLogger.error(
                'Retry venue hub realtime presence; LAN remains available',
                error,
                stackTrace,
              );
            }
          }
          processor.installCredentials(current.credentials);
          late Map<String, Object?> refreshed;
          try {
            refreshed = await _repository.fetchOfflineHubSnapshot(
              scope: scope,
              deviceId: deviceId,
              hubEpoch: bootstrap.hubEpoch,
              credential: credential,
              knownSnapshotDigest: snapshot['snapshotDigest'] as String?,
              knownSnapshotGeneration: snapshot['snapshotGeneration'] as int?,
            );
          } catch (error, stackTrace) {
            AppLogger.error(
              'Download refreshed venue hub snapshot',
              error,
              stackTrace,
            );
            return;
          }
          if (refreshed['unchanged'] == true) {
            final returnedGeneration = refreshed['snapshotGeneration'] as int?;
            if (returnedGeneration != null &&
                returnedGeneration != snapshot['snapshotGeneration']) {
              snapshot = Map<String, Object?>.from(snapshot)
                ..['snapshotGeneration'] = returnedGeneration;
              await _ledger.saveSnapshot(
                tenantId: scope.tenantId,
                venueId: scope.venueId,
                kind: bootstrapSnapshotKind,
                version: snapshot['version'] as int,
                value: snapshot,
              );
            }
            AppLogger.info(
              'Venue hub snapshot is current; retained the encrypted local copy.',
            );
            unawaited(reconcileClosedCloudOrders());
            return;
          }
          await installFreshSnapshot(refreshed);
          unawaited(reconcileClosedCloudOrders());
        } catch (error, stackTrace) {
          // A timeout, malformed response, or snapshot refresh failure is not
          // evidence that cloud authority was revoked. Stopping here used to
          // kill command polling permanently because the auto-start host still
          // believed the runtime was running. Retain the last authenticated,
          // encrypted snapshot and retry. Explicit, successfully parsed
          // authority changes are handled above and still stop immediately.
          // Every cloud command remains protected by the server's current hub
          // credential and epoch checks, so this does not create a bypass.
          AppLogger.error(
            'Refresh venue hub authority; retaining last verified authority',
            error,
            stackTrace,
          );
        } finally {
          refreshingAuthority = false;
        }
      }

      // Configuration writes are cloud-owned rather than order events. Keep a
      // callable refresh hook so a successful menu/customer/settings edit can
      // update the hub catalogue immediately instead of leaving every native
      // screen on the old encrypted snapshot until the 30-second safety poll.
      _refreshAuthorityNow = refreshAuthority;
      refreshAuthorityCallback = refreshAuthority;

      _authorityTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => unawaited(refreshAuthority()),
      );
      await AndroidVenueHubService.start();
    } catch (error, stackTrace) {
      AppLogger.error('Start venue offline hub', error, stackTrace);
      await _server.stop();
      _emit(
        VenueHubRuntimeStatus(
          state: VenueHubRuntimeState.failed,
          pendingEvents: 0,
          message: error.toString(),
        ),
      );
      rethrow;
    }
  }

  Future<void> stop() async {
    _authorityTimer?.cancel();
    _authorityTimer = null;
    await _realtimeSignalSubscription?.cancel();
    _realtimeSignalSubscription = null;
    await _realtimePresence?.stop();
    await _pendingSubscription?.cancel();
    _pendingSubscription = null;
    _sync?.dispose();
    _sync = null;
    await _printQueue?.dispose();
    _printQueue = null;
    _installFreshSnapshot = null;
    _refreshAuthorityNow = null;
    _activeScope = null;
    _activeBootstrap = null;
    await _server.stop();
    await AndroidVenueHubService.stop();
    _emit(
      const VenueHubRuntimeStatus(
        state: VenueHubRuntimeState.stopped,
        pendingEvents: 0,
      ),
    );
  }

  Future<Map<String, Object?>?> claimLocalPrintJob(String deviceId) {
    final queue = _printQueue;
    if (queue == null) return Future.value(null);
    return queue.claim(deviceId);
  }

  Future<void> installFreshSnapshot(Map<String, Object?> snapshot) {
    final install = _installFreshSnapshot;
    if (install == null ||
        (_status.state != VenueHubRuntimeState.ready &&
            _status.state != VenueHubRuntimeState.degraded)) {
      throw StateError('The venue hub is not ready to refresh staff access.');
    }
    return install(snapshot);
  }

  Stream<List<Map<String, Object?>>>? localPrintJobs(VenueScope scope) {
    if (_activeScope != scope) return null;
    return _printQueue?.changes;
  }

  /// Requests an immediate cloud-authority refresh when this process is the
  /// active hub. Non-hub clients safely do nothing; they receive the refreshed
  /// catalogue from the hub on their next explicit catalogue fetch.
  Future<void> refreshAuthorityNow() async {
    final refresh = _refreshAuthorityNow;
    if (refresh != null) await refresh();
  }

  Future<void> completeLocalPrintJob({
    required String deviceId,
    required String jobId,
    required bool printed,
    String? failureReason,
  }) {
    final queue = _printQueue;
    if (queue == null) {
      throw StateError('The local venue print queue is unavailable.');
    }
    return queue.complete(
      deviceId: deviceId,
      jobId: jobId,
      printed: printed,
      failureReason: failureReason,
    );
  }

  void _emit(VenueHubRuntimeStatus value) {
    _status = value;
    if (!_statuses.isClosed) _statuses.add(value);
  }

  Future<void> dispose() async {
    await stop();
    await _statuses.close();
  }
}
