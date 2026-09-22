import 'dart:async';

import '../core/app_logger.dart';
import '../core/tenant_scope.dart';
import '../core/trusted_clock.dart';
import '../data/production_command_repository.dart';
import 'offline_event.dart';
import 'offline_event_ledger.dart';
import 'venue_hub_bootstrap.dart';
import 'venue_hub_cloud_sync.dart';
import 'venue_hub_command_processor.dart';
import 'venue_hub_device_credential.dart';
import 'venue_hub_offline_pin.dart';
import 'venue_hub_server.dart';
import 'venue_hub_staff_sessions.dart';
import 'venue_hub_print_queue.dart';
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
  Future<void> Function(Map<String, Object?> snapshot)? _installFreshSnapshot;
  StreamSubscription? _pendingSubscription;
  Timer? _authorityTimer;
  Timer? _remoteCommandTimer;
  VenueHubRuntimeStatus _status = const VenueHubRuntimeStatus(
    state: VenueHubRuntimeState.stopped,
    pendingEvents: 0,
  );
  VenueScope? _activeScope;

  VenueHubRuntimeStatus get status => _status;
  Stream<VenueHubRuntimeStatus> get statuses => _statuses.stream;
  VenueScope? get activeScope => _activeScope;

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
        if (rawStaff is! List) return staffId;
        for (final raw in rawStaff.whereType<Map>()) {
          if (raw['staffId'] == staffId) {
            final name = raw['displayName'];
            if (name is String && name.trim().isNotEmpty) return name.trim();
          }
        }
        return staffId;
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
      await orderBook.rebuild();
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
            await printQueue.enqueueReceipt(
              order: await orderBook.order(orderId),
              printRequired: true,
              isPreReceipt: true,
              jobSuffix: event.id,
            );
          }
          return event;
        },
      );
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
          readClientSnapshot: () async =>
              Map<String, Object?>.from(snapshot)..remove('staff'),
          readOrders: () async => (await orderBook.rebuild()).values
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
      var remoteTickRunning = false;
      var remoteCloudAvailable = true;
      VenueHubStaffGrant? remoteGrant(Map<String, Object?> command) {
        final staffId = command['staffId'];
        final expectedPinVersion = command['pinVersion'];
        final expectedMembershipVersion = command['membershipVersion'];
        final expiresAt = DateTime.tryParse(command['expiresAt'] as String? ?? '');
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
        if (remoteTickRunning || _activeScope != scope) return;
        remoteTickRunning = true;
        try {
          await _repository.heartbeatRemoteHub(
            scope: scope,
            deviceId: deviceId,
            hubEpoch: bootstrap.hubEpoch,
            credential: credential,
            pendingLocalEvents: (await _ledger.pending()).length,
          );
          final commands = await _repository.claimRemoteHubCommands(
            scope: scope,
            deviceId: deviceId,
            hubEpoch: bootstrap.hubEpoch,
            credential: credential,
          );
          if (!remoteCloudAvailable) {
            AppLogger.info('Venue hub remote command connection restored.');
            remoteCloudAvailable = true;
          }
          for (final command in commands) {
            final commandId = command['commandId'];
            final claimToken = command['claimToken'];
            if (commandId is! String || claimToken is! String) continue;
            try {
              final grant = remoteGrant(command);
              final eventType = command['eventType'];
              final payload = command['payload'];
              if (grant == null || eventType is! String || payload is! Map) {
                throw const VenueHubCommandException(
                  'The staff permission snapshot changed before the command was accepted.',
                );
              }
              final acknowledgement = await processor.processRemote(
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
              await _repository.completeRemoteHubCommand(
                scope: scope,
                deviceId: deviceId,
                hubEpoch: bootstrap.hubEpoch,
                credential: credential,
                commandId: commandId,
                claimToken: claimToken,
                accepted: true,
                result: <String, Object?>{
                  'eventId': acknowledgement.eventId,
                  'sequence': acknowledgement.sequence,
                  'eventHash': acknowledgement.eventHash,
                  'committedAtUtc': acknowledgement.committedAtUtc.toUtc().toIso8601String(),
                },
              );
              unawaited(_sync!.flush());
            } catch (error, stackTrace) {
              AppLogger.error('Process remote venue command', error, stackTrace);
              try {
                await _repository.completeRemoteHubCommand(
                  scope: scope,
                  deviceId: deviceId,
                  hubEpoch: bootstrap.hubEpoch,
                  credential: credential,
                  commandId: commandId,
                  claimToken: claimToken,
                  accepted: false,
                  rejectionMessage: error.toString(),
                );
              } catch (_) {
                // The short claim lease makes an ambiguous completion retryable.
              }
            }
          }
        } catch (_) {
          if (remoteCloudAvailable) {
            AppLogger.info(
              'Venue hub remote command connection is offline; LAN orders remain available.',
            );
            remoteCloudAvailable = false;
          }
        } finally {
          remoteTickRunning = false;
        }
      }
      _remoteCommandTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => unawaited(remoteTick()),
      );
      unawaited(remoteTick());
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
      unawaited(_sync!.flush());
      var refreshingAuthority = false;
      Future<void> refreshAuthority() async {
        if (refreshingAuthority) return;
        refreshingAuthority = true;
        var cloudResponded = false;
        try {
          final raw = await _repository
              .fetchOfflineHubBootstrap(scope: scope)
              .timeout(const Duration(seconds: 8));
          cloudResponded = true;
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
          } catch (_) {
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
            return;
          }
          await installFreshSnapshot(refreshed);
        } catch (error, stackTrace) {
          // Cloud loss is expected; continue with the last authenticated
          // encrypted snapshot until connectivity returns.
          if (cloudResponded) {
            AppLogger.error('Refresh venue hub authority', error, stackTrace);
            await stop();
          }
        } finally {
          refreshingAuthority = false;
        }
      }

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
    _remoteCommandTimer?.cancel();
    _remoteCommandTimer = null;
    await _pendingSubscription?.cancel();
    _pendingSubscription = null;
    _sync?.dispose();
    _sync = null;
    _printQueue = null;
    _installFreshSnapshot = null;
    _activeScope = null;
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
