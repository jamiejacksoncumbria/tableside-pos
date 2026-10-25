import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tableside_pos/core/tenant_scope.dart';
import 'package:tableside_pos/offline/offline_event.dart';
import 'package:tableside_pos/offline/offline_event_crypto.dart';
import 'package:tableside_pos/offline/offline_event_ledger.dart';
import 'package:tableside_pos/offline/offline_event_store_native.dart';
import 'package:tableside_pos/offline/offline_order_projection.dart';
import 'package:tableside_pos/offline/venue_hub_command_processor.dart';
import 'package:tableside_pos/offline/venue_hub_print_queue.dart';
import 'package:tableside_pos/offline/venue_hub_remote_command_client.dart';
import 'package:tableside_pos/offline/venue_offline_catalogue.dart';
import 'package:tableside_pos/offline/venue_offline_order_book.dart';

void main() {
  group('EPOS 3 transaction integrity', () {
    test(
      'remote sale survives lost acknowledgement, prints once and closes once',
      () async {
        final harness = await _EposHarness.create();
        addTearDown(harness.dispose);

        await harness.send('order.opened', const <String, Object?>{
          'orderId': 'order-table-a',
          'channel': 'dineIn',
          'tableId': 'table-a',
        });
        await harness.send('order.itemsAdded', const <String, Object?>{
          'orderId': 'order-table-a',
          'items': <Object?>[
            <String, Object?>{
              'lineId': 'line-curry',
              'productId': 'curry',
              'quantity': 1,
              'channel': 'dineIn',
            },
            <String, Object?>{
              'lineId': 'line-rice',
              'productId': 'rice',
              'quantity': 1,
              'channel': 'dineIn',
            },
            <String, Object?>{
              'lineId': 'line-water',
              'productId': 'water',
              'quantity': 1,
              'channel': 'dineIn',
            },
          ],
        }, loseFirstAcknowledgement: true);
        await harness.send('order.itemQuantityChanged', const <String, Object?>{
          'orderId': 'order-table-a',
          'lineId': 'line-curry',
          'quantity': 2,
        });
        await harness.send('order.itemQuantityChanged', const <String, Object?>{
          'orderId': 'order-table-a',
          'lineId': 'line-water',
          'quantity': 0,
        });
        await harness.send('order.sent', const <String, Object?>{
          'orderId': 'order-table-a',
          'lineIds': <String>['line-curry', 'line-rice'],
          'printRequired': true,
        });

        var order = await harness.orderBook.order('order-table-a');
        expect(order.tableId, 'table-a');
        expect(
          order.lines.keys,
          containsAll(<String>['line-curry', 'line-rice']),
        );
        expect(order.lines, isNot(contains('line-water')));
        expect(order.totalMinor, 2800);
        expect(order.lines.values, everyElement(isA<OfflineProjectedLine>()));
        expect(order.lines.values.every((line) => line.sent), isTrue);

        final kitchenJob = await harness.printQueue.claim('printer-kitchen');
        expect(kitchenJob, isNotNull);
        expect(kitchenJob!['orderId'], 'order-table-a');
        expect((kitchenJob['payload']! as Map)['type'], 'production');
        await harness.printQueue.complete(
          deviceId: 'printer-kitchen',
          jobId: kitchenJob['id']! as String,
          printed: true,
        );

        await harness.send('payment.recorded', const <String, Object?>{
          'orderId': 'order-table-a',
          'paymentId': 'payment-partial',
          'baseAmountMinor': 1000,
          'tenderedAmountMinor': 1000,
          'method': 'cash',
          'currencyCode': 'GBP',
          'exchangeRateToBase': '1',
        });
        order = await harness.orderBook.order('order-table-a');
        expect(order.balanceDueMinor, 1800);
        expect(order.isClosed, isFalse);

        await harness.send('payment.recorded', const <String, Object?>{
          'orderId': 'order-table-a',
          'paymentId': 'payment-final',
          'baseAmountMinor': 1800,
          'tenderedAmountMinor': 2000,
          'cashChangeBaseMinor': 200,
          'method': 'cash',
          'currencyCode': 'GBP',
          'exchangeRateToBase': '1',
        });
        await harness.send('order.closed', const <String, Object?>{
          'orderId': 'order-table-a',
          'receiptNumber': 'R-1001',
          'printReceipt': true,
        });

        order = await harness.orderBook.order('order-table-a');
        expect(order.balanceDueMinor, 0);
        expect(order.isClosed, isTrue);
        expect(order.receiptNumber, 'R-1001');
        expect(order.payments, hasLength(2));

        final receiptJob = await harness.printQueue.claim('printer-receipt');
        expect(receiptJob, isNotNull);
        final receiptPayload = Map<String, Object?>.from(
          receiptJob!['payload']! as Map,
        );
        expect(receiptPayload['type'], 'receipt');
        expect(receiptPayload['totalMinor'], 2800);
        expect(receiptPayload['payments'], hasLength(2));
        await harness.printQueue.complete(
          deviceId: 'printer-receipt',
          jobId: receiptJob['id']! as String,
          printed: true,
        );

        final events = await harness.events();
        expect(
          events.where((event) => event.type == 'order.itemsAdded'),
          hasLength(1),
          reason: 'An ambiguous client retry must not duplicate basket lines.',
        );
        expect(
          events.where((event) => event.type == 'payment.recorded'),
          hasLength(2),
        );
        expect(
          events.where((event) => event.type == 'order.closed'),
          hasLength(1),
        );

        final restartedOrderBook = harness.restartedOrderBook();
        final restartedOrder = await restartedOrderBook.order('order-table-a');
        expect(restartedOrder.isClosed, isTrue);
        expect(restartedOrder.balanceDueMinor, 0);

        final restartedPrintQueue = harness.restartedPrintQueue();
        addTearDown(restartedPrintQueue.dispose);
        await restartedPrintQueue.initialize();
        expect(
          restartedPrintQueue.visibleJobs.where(
            (job) => job['status'] == 'printed',
          ),
          hasLength(2),
        );
        expect(await restartedPrintQueue.claim('printer-kitchen'), isNull);
        expect(await restartedPrintQueue.claim('printer-receipt'), isNull);
      },
    );

    test(
      'table, named tab, collection and delivery identities survive replay',
      () async {
        final harness = await _EposHarness.create();
        addTearDown(harness.dispose);
        final cases = <String, Map<String, Object?>>{
          'table': <String, Object?>{
            'orderId': 'order-table',
            'channel': 'dineIn',
            'tableId': 'table-a',
          },
          'named-tab': <String, Object?>{
            'orderId': 'order-tab',
            'channel': 'dineIn',
            'tabName': 'Garden Party',
          },
          'collection': <String, Object?>{
            'orderId': 'order-collection',
            'channel': 'collection',
            'customerId': 'customer-a',
            'customerName': 'Alex Customer',
          },
          'delivery': <String, Object?>{
            'orderId': 'order-delivery',
            'channel': 'delivery',
            'customerId': 'customer-b',
            'customerName': 'Dana Customer',
            'deliveryAddress': '12 Harbour Road',
            'deliveryAddressLabel': 'Home',
            'serviceAreaId': 'area-a',
            'serviceAreaName': 'Kyrenia',
            'deliveryFeeMinor': 300,
          },
        };

        for (final entry in cases.entries) {
          await harness.send('order.opened', entry.value);
          final order = await harness.orderBook.order(
            entry.value['orderId']! as String,
          );
          expect(order.channel, entry.value['channel'], reason: entry.key);
          expect(order.tableId, entry.value['tableId'], reason: entry.key);
          expect(order.tabName, entry.value['tabName'], reason: entry.key);
          expect(
            order.customerName,
            entry.value['customerName'],
            reason: entry.key,
          );
          expect(
            order.deliveryAddress,
            entry.value['deliveryAddress'],
            reason: entry.key,
          );
          expect(
            order.deliveryFeeMinor,
            entry.value['deliveryFeeMinor'] ?? 0,
            reason: entry.key,
          );
        }

        final restarted = harness.restartedOrderBook();
        final orders = await restarted.rebuild();
        expect(
          orders.keys,
          containsAll(cases.values.map((item) => item['orderId'])),
        );
        expect(orders['order-tab']!.tabName, 'Garden Party');
        expect(orders['order-delivery']!.serviceAreaName, 'Kyrenia');
      },
    );

    test(
      'manager adjustment, split bill and mixed currencies settle exactly once',
      () async {
        final harness = await _EposHarness.create();
        addTearDown(harness.dispose);

        await harness.send('order.opened', const <String, Object?>{
          'orderId': 'order-split-main',
          'channel': 'dineIn',
          'tableId': 'table-a',
        });
        await harness.send('order.itemsAdded', const <String, Object?>{
          'orderId': 'order-split-main',
          'items': <Object?>[
            <String, Object?>{
              'lineId': 'line-curry',
              'productId': 'curry',
              'quantity': 2,
              'channel': 'dineIn',
            },
            <String, Object?>{
              'lineId': 'line-rice',
              'productId': 'rice',
              'quantity': 1,
              'channel': 'dineIn',
            },
          ],
        });
        await harness.send('order.lineAdjusted', const <String, Object?>{
          'orderId': 'order-split-main',
          'lineId': 'line-rice',
          'operation': 'discountUnitAmount',
          'valueMinor': 100,
          'reason': 'Service recovery discount',
        });
        await harness.send('order.sent', const <String, Object?>{
          'orderId': 'order-split-main',
          'lineIds': <String>['line-curry', 'line-rice'],
          'printRequired': false,
        });
        await harness.send('order.splitCreated', const <String, Object?>{
          'orderId': 'order-split-main',
          'splitOrderId': 'order-split-child',
          'splitLines': <Object?>[
            <String, Object?>{'lineId': 'line-curry', 'quantity': 1},
          ],
        });

        var main = await harness.orderBook.order('order-split-main');
        var child = await harness.orderBook.order('order-split-child');
        expect(main.totalMinor, 1500);
        expect(child.totalMinor, 1200);
        expect(main.openSplitOrderIds, <String>['order-split-child']);

        await harness.send('payment.recorded', const <String, Object?>{
          'orderId': 'order-split-child',
          'paymentId': 'payment-child-eur',
          'baseAmountMinor': 1200,
          'tenderedAmountMinor': 1400,
          'cashChangeBaseMinor': 0,
          'method': 'cash',
          'currencyCode': 'EUR',
          'exchangeRateToBase': '0.85714286',
        });
        await harness.send('order.closed', const <String, Object?>{
          'orderId': 'order-split-child',
          'receiptNumber': 'R-SPLIT-1',
          'printReceipt': false,
        });
        await harness.send('payment.batchRecorded', const <String, Object?>{
          'orderId': 'order-split-main',
          'batchId': 'batch-main-mixed',
          'payments': <Object?>[
            <String, Object?>{
              'paymentId': 'payment-main-usd',
              'baseAmountMinor': 500,
              'tenderedAmountMinor': 625,
              'method': 'cash',
              'currencyCode': 'USD',
              'exchangeRateToBase': '0.8',
            },
            <String, Object?>{
              'paymentId': 'payment-main-gbp',
              'baseAmountMinor': 1000,
              'tenderedAmountMinor': 1000,
              'method': 'card',
              'currencyCode': 'GBP',
              'exchangeRateToBase': '1',
            },
          ],
        });
        await harness.send('order.closed', const <String, Object?>{
          'orderId': 'order-split-main',
          'receiptNumber': 'R-SPLIT-2',
          'printReceipt': true,
        });

        main = await harness.orderBook.order('order-split-main');
        child = await harness.orderBook.order('order-split-child');
        expect(main.isClosed, isTrue);
        expect(child.isClosed, isTrue);
        expect(main.balanceDueMinor, 0);
        expect(child.balanceDueMinor, 0);
        expect(main.openSplitOrderIds, isEmpty);
        expect(main.payments.map((payment) => payment.currencyCode), <String>[
          'USD',
          'GBP',
        ]);
        expect(child.payments.single.currencyCode, 'EUR');
        expect(child.payments.single.exchangeRateToBase, '0.85714286');

        final receipt = await harness.printQueue.claim('printer-receipt');
        expect(receipt, isNotNull);
        final payload = Map<String, Object?>.from(receipt!['payload']! as Map);
        expect(receipt['orderId'], 'order-split-main');
        expect(payload['payments'], hasLength(2));
        await harness.printQueue.complete(
          deviceId: 'printer-receipt',
          jobId: receipt['id']! as String,
          printed: true,
        );
        await harness.printQueue.reprint(receipt['id']! as String);
        final reprint = await harness.printQueue.claim('printer-receipt');
        expect(reprint, isNotNull);
        expect(reprint!['orderId'], 'order-split-main');
        expect((reprint['payload']! as Map)['isReprint'], isTrue);
        await harness.printQueue.complete(
          deviceId: 'printer-receipt',
          jobId: reprint['id']! as String,
          printed: true,
        );

        final replayed = harness.restartedOrderBook();
        expect((await replayed.order('order-split-main')).balanceDueMinor, 0);
        expect((await replayed.order('order-split-child')).balanceDueMinor, 0);
        expect(
          (await harness.events()).where(
            (event) => event.type == 'order.splitCreated',
          ),
          hasLength(1),
        );
      },
    );

    test(
      'delivery driver and collection production states survive closure and restart',
      () async {
        final harness = await _EposHarness.create();
        addTearDown(harness.dispose);

        await harness.send('order.opened', const <String, Object?>{
          'orderId': 'order-delivery-flow',
          'channel': 'delivery',
          'customerId': 'customer-delivery',
          'customerName': 'Delivery Customer',
          'customerPhone': '+905551112233',
          'deliveryAddress': '12 Harbour Road',
          'deliveryAddressLabel': 'Home',
          'serviceAreaId': 'area-a',
          'serviceAreaName': 'Kyrenia',
          'deliveryFeeMinor': 300,
          'scheduledForUtc': '2026-10-26T18:30:00.000Z',
        });
        await harness.send('order.itemAdded', const <String, Object?>{
          'orderId': 'order-delivery-flow',
          'lineId': 'line-delivery-curry',
          'productId': 'curry',
          'quantity': 1,
          'channel': 'delivery',
          'modifierSelections': <Object?>[
            <String, Object?>{
              'groupId': 'curry-heat',
              'optionId': 'extra-hot',
            },
          ],
        });
        await harness.send('order.sent', const <String, Object?>{
          'orderId': 'order-delivery-flow',
          'lineIds': <String>['line-delivery-curry'],
          'printRequired': false,
        });
        await harness.send('order.fulfilmentChanged', const <String, Object?>{
          'orderId': 'order-delivery-flow',
          'status': 'assigned',
          'driverId': 'staff-a',
          'managerAuthorized': true,
        });
        await harness.send('order.fulfilmentChanged', const <String, Object?>{
          'orderId': 'order-delivery-flow',
          'status': 'outForDelivery',
        });
        await harness.send('order.fulfilmentChanged', const <String, Object?>{
          'orderId': 'order-delivery-flow',
          'status': 'delivered',
        });
        await harness.send('payment.recorded', const <String, Object?>{
          'orderId': 'order-delivery-flow',
          'paymentId': 'payment-delivery',
          'baseAmountMinor': 1600,
          'tenderedAmountMinor': 1600,
          'method': 'cash',
          'currencyCode': 'GBP',
          'exchangeRateToBase': '1',
        });
        await harness.send('order.closed', const <String, Object?>{
          'orderId': 'order-delivery-flow',
          'receiptNumber': 'R-DELIVERY-1',
          'printReceipt': false,
        });

        await harness.send('order.opened', const <String, Object?>{
          'orderId': 'order-collection-flow',
          'channel': 'collection',
          'customerId': 'customer-collection',
          'customerName': 'Collection Customer',
        });
        await harness.send('order.itemAdded', const <String, Object?>{
          'orderId': 'order-collection-flow',
          'lineId': 'line-collection-rice',
          'productId': 'rice',
          'quantity': 1,
          'channel': 'collection',
        });
        await harness.send('order.sent', const <String, Object?>{
          'orderId': 'order-collection-flow',
          'lineIds': <String>['line-collection-rice'],
          'printRequired': false,
        });
        await harness.send('order.fulfilmentChanged', const <String, Object?>{
          'orderId': 'order-collection-flow',
          'status': 'readyForCollection',
          'managerAuthorized': true,
        });
        await harness.send('order.fulfilmentChanged', const <String, Object?>{
          'orderId': 'order-collection-flow',
          'status': 'collected',
          'managerAuthorized': true,
        });

        final replayed = harness.restartedOrderBook();
        final delivery = await replayed.order('order-delivery-flow');
        final collection = await replayed.order('order-collection-flow');
        expect(delivery.isClosed, isTrue);
        expect(delivery.fulfilmentStatus, 'delivered');
        expect(delivery.assignedDriverId, 'staff-a');
        expect(delivery.totalMinor, 1600);
        expect(delivery.lines.values.single.details, contains('Extra Hot'));
        expect(delivery.scheduledForUtc, DateTime.utc(2026, 10, 26, 18, 30));
        expect(collection.isClosed, isFalse);
        expect(collection.fulfilmentStatus, 'collected');
        expect(collection.balanceDueMinor, 400);
      },
    );

    test(
      'remote outage creates no phantom sale while local hub work remains durable',
      () async {
        final harness = await _EposHarness.create();
        addTearDown(harness.dispose);
        final before = await harness.events();
        final remote = VenueHubRemoteCommandClient(
          timeout: const Duration(milliseconds: 250),
        );

        await expectLater(
          remote.send(
            scope: _EposHarness.scope,
            hubEpoch: _EposHarness.hubEpoch,
            eventType: 'order.opened',
            payload: const <String, Object?>{
              'orderId': 'order-remote-offline',
              'channel': 'dineIn',
              'tableId': 'table-a',
            },
            showBusy: false,
            submit: (_) async => throw StateError(
              'The venue hub is offline. Join the venue network or wait for it to reconnect.',
            ),
            waitForStatus: (_) async => const <String, Object?>{},
          ),
          throwsA(isA<StateError>()),
        );
        expect(await harness.events(), hasLength(before.length));

        // The authoritative local ledger remains usable during the cloud
        // outage and survives a process restart.
        await harness.orderBook.commit(
          OfflineEventDraft(
            tenantId: 'tenant-a',
            venueId: 'venue-a',
            deviceId: 'lan-terminal-a',
            staffId: 'staff-a',
            type: 'order.opened',
            payload: <String, Object?>{
              'orderId': 'order-lan-offline',
              'channel': 'dineIn',
              'tableId': 'table-a',
            },
          ),
          _EposHarness.hubEpoch,
        );
        final replayed = harness.restartedOrderBook();
        expect((await replayed.order('order-lan-offline')).tableId, 'table-a');
        await expectLater(
          replayed.order('order-remote-offline'),
          throwsA(isA<OfflineProjectionException>()),
        );
      },
    );

    test(
      'print retry uses one ticket and safely switches to fallback',
      () async {
        final harness = await _EposHarness.create();
        addTearDown(harness.dispose);
        await harness.send('order.opened', const <String, Object?>{
          'orderId': 'order-print-retry',
          'channel': 'dineIn',
          'tableId': 'table-a',
        });
        await harness.send('order.itemAdded', const <String, Object?>{
          'orderId': 'order-print-retry',
          'lineId': 'line-curry',
          'productId': 'curry',
          'quantity': 1,
          'channel': 'dineIn',
        });
        await harness.send('order.sent', const <String, Object?>{
          'orderId': 'order-print-retry',
          'lineIds': <String>['line-curry'],
          'printRequired': true,
        });

        String? jobId;
        for (var attempt = 0; attempt < 3; attempt++) {
          final job = await harness.printQueue.claim('printer-kitchen');
          expect(job, isNotNull);
          jobId ??= job!['id']! as String;
          expect(job!['id'], jobId);
          await harness.printQueue.complete(
            deviceId: 'printer-kitchen',
            jobId: jobId,
            printed: false,
            failureReason: 'Test printer unavailable',
          );
        }

        expect(await harness.printQueue.claim('printer-kitchen'), isNull);
        final fallback = await harness.printQueue.claim('printer-fallback');
        expect(fallback, isNotNull);
        expect(fallback!['id'], jobId);
        expect(fallback['attempts'], 1);
        await harness.printQueue.complete(
          deviceId: 'printer-fallback',
          jobId: jobId!,
          printed: true,
        );
        expect(harness.printQueue.visibleJobs.single['status'], 'printed');
      },
    );

    test(
      'remote terminal retries a pre-commit outage without phantom state',
      () async {
        final harness = await _EposHarness.create();
        addTearDown(harness.dispose);

        await harness.send('order.opened', const <String, Object?>{
          'orderId': 'order-pre-commit-retry',
          'channel': 'dineIn',
          'tableId': 'table-a',
        }, failFirstBeforeCommit: true);

        final order = await harness.orderBook.order('order-pre-commit-retry');
        expect(order.isClosed, isFalse);
        expect(order.tableId, 'table-a');
        final events = await harness.events();
        expect(
          events.where(
            (event) => event.payload['orderId'] == 'order-pre-commit-retry',
          ),
          hasLength(1),
          reason: 'A failed submission must not create a phantom order.',
        );
      },
    );

    test(
      'hub restart safely recovers a claimed but unacknowledged print job',
      () async {
        final harness = await _EposHarness.create();
        addTearDown(harness.dispose);
        await harness.send('order.opened', const <String, Object?>{
          'orderId': 'order-printer-power-loss',
          'channel': 'dineIn',
          'tableId': 'table-a',
        });
        await harness.send('order.itemAdded', const <String, Object?>{
          'orderId': 'order-printer-power-loss',
          'lineId': 'line-curry',
          'productId': 'curry',
          'quantity': 1,
          'channel': 'dineIn',
        });
        await harness.send('order.sent', const <String, Object?>{
          'orderId': 'order-printer-power-loss',
          'lineIds': <String>['line-curry'],
          'printRequired': true,
        });

        final interrupted = await harness.printQueue.claim('printer-kitchen');
        expect(interrupted, isNotNull);
        expect(interrupted!['status'], 'claimed');

        // Simulate power loss after the operating system received the ticket
        // but before it acknowledged printing. Startup deliberately retries
        // the same durable job ID so it is visible and can never be lost.
        final restarted = harness.restartedPrintQueue();
        addTearDown(restarted.dispose);
        await restarted.initialize();
        final recovered = await restarted.claim('printer-kitchen');
        expect(recovered, isNotNull);
        expect(recovered!['id'], interrupted['id']);
        expect(recovered['attempts'], 2);
        await restarted.complete(
          deviceId: 'printer-kitchen',
          jobId: recovered['id']! as String,
          printed: true,
        );

        final verifiedRestart = harness.restartedPrintQueue();
        addTearDown(verifiedRestart.dispose);
        await verifiedRestart.initialize();
        expect(await verifiedRestart.claim('printer-kitchen'), isNull);
        expect(verifiedRestart.visibleJobs, hasLength(1));
        expect(verifiedRestart.visibleJobs.single['status'], 'printed');
      },
    );
  });
}

class _EposHarness {
  _EposHarness._({
    required this.database,
    required this.store,
    required this.ledger,
    required this.catalogue,
    required this.orderBook,
    required this.printQueue,
    required this.processor,
    required this.snapshot,
  });

  static const scope = VenueScope(tenantId: 'tenant-a', venueId: 'venue-a');
  static const hubEpoch = 9;

  final Database database;
  final NativeOfflineEventStore store;
  final OfflineEventLedger ledger;
  final VenueOfflineCatalogue catalogue;
  final VenueOfflineOrderBook orderBook;
  final VenueHubPrintQueue printQueue;
  final VenueHubCommandProcessor processor;
  final Map<String, Object?> snapshot;
  final Map<String, VenueHubCommandAcknowledgement> _acknowledgements = {};
  final Map<String, int> _submissionAttempts = {};

  static Future<_EposHarness> create() async {
    final database = sqlite3.openInMemory();
    final store = NativeOfflineEventStore(
      database: database,
      crypto: OfflineEventCrypto.forTesting(Uint8List(64)),
    );
    final ledger = OfflineEventLedger.forTesting(store);
    await ledger.initialize();
    final snapshot = _venueSnapshot();
    final catalogue = VenueOfflineCatalogue.fromSnapshot(snapshot);
    final orderBook = VenueOfflineOrderBook(
      tenantId: scope.tenantId,
      venueId: scope.venueId,
      hubEpoch: hubEpoch,
      ledger: ledger,
      catalogueProvider: () => catalogue,
    );
    final printQueue = VenueHubPrintQueue(
      tenantId: scope.tenantId,
      venueId: scope.venueId,
      hubEpoch: hubEpoch,
      snapshot: snapshot,
      ledger: ledger,
    );
    await printQueue.initialize();

    late VenueHubCommandProcessor processor;
    Future<OfflineEvent> commitEvent(OfflineEventDraft draft, int epoch) async {
      final event = await orderBook.commit(draft, epoch);
      if (event.type == 'order.sent') {
        await printQueue.enqueueProduction(
          order: await orderBook.order(event.payload['orderId']! as String),
          lineIds: (event.payload['lineIds']! as List)
              .whereType<String>()
              .toList(),
          printRequired: event.payload['printRequired'] == true,
          createdByName: 'Test Staff',
        );
      } else if (event.type == 'order.closed') {
        await printQueue.enqueueReceipt(
          order: await orderBook.order(event.payload['orderId']! as String),
          printRequired: event.payload['printReceipt'] == true,
        );
      }
      return event;
    }

    processor = VenueHubCommandProcessor(
      tenantId: scope.tenantId,
      venueId: scope.venueId,
      hubEpoch: hubEpoch,
      credentials: const {},
      authorizeStaff: (_, _, _) async => null,
      validateEvent: catalogue.validateEvent,
      commitEvent: commitEvent,
    );
    return _EposHarness._(
      database: database,
      store: store,
      ledger: ledger,
      catalogue: catalogue,
      orderBook: orderBook,
      printQueue: printQueue,
      processor: processor,
      snapshot: snapshot,
    );
  }

  Future<void> send(
    String eventType,
    Map<String, Object?> payload, {
    bool loseFirstAcknowledgement = false,
    bool failFirstBeforeCommit = false,
  }) async {
    final client = VenueHubRemoteCommandClient(
      timeout: const Duration(seconds: 5),
    );
    await client.send(
      scope: scope,
      hubEpoch: hubEpoch,
      eventType: eventType,
      payload: payload,
      showBusy: false,
      submit: (request) async {
        final commandId = request['commandId']! as String;
        final attempts = (_submissionAttempts[commandId] ?? 0) + 1;
        _submissionAttempts[commandId] = attempts;
        if (failFirstBeforeCommit && attempts == 1) {
          throw StateError('Network connection interrupted before hub commit.');
        }
        final acknowledgement = await processor.processRemote(
          commandId: commandId,
          eventType: request['eventType']! as String,
          payload: Map<String, Object?>.from(request['payload']! as Map),
          deviceId: 'remote-terminal-a',
          grant: _grant,
          trustedNowUtc: DateTime.now().toUtc(),
        );
        _acknowledgements[commandId] = acknowledgement;
        if (loseFirstAcknowledgement && attempts == 1) {
          throw StateError('Connection closed before response.');
        }
        return <String, Object?>{'commandId': commandId};
      },
      waitForStatus: (request) async {
        final commandId = request['commandId']! as String;
        final acknowledgement = _acknowledgements[commandId]!;
        return <String, Object?>{
          'commandId': commandId,
          'status': 'accepted',
          'stage': 'cloudProjected',
          'result': <String, Object?>{
            'eventId': acknowledgement.eventId,
            'sequence': acknowledgement.sequence,
            'eventHash': acknowledgement.eventHash,
            'committedAtUtc': acknowledgement.committedAtUtc.toIso8601String(),
          },
        };
      },
    );
  }

  VenueOfflineOrderBook restartedOrderBook() => VenueOfflineOrderBook(
    tenantId: scope.tenantId,
    venueId: scope.venueId,
    hubEpoch: hubEpoch,
    ledger: ledger,
    catalogueProvider: () => catalogue,
  );

  VenueHubPrintQueue restartedPrintQueue() => VenueHubPrintQueue(
    tenantId: scope.tenantId,
    venueId: scope.venueId,
    hubEpoch: hubEpoch,
    snapshot: snapshot,
    ledger: ledger,
  );

  Future<List<OfflineEvent>> events() => ledger.eventsForVenue(
    tenantId: scope.tenantId,
    venueId: scope.venueId,
    hubEpoch: hubEpoch,
  );

  Future<void> dispose() async {
    await printQueue.dispose();
    store.close();
  }

  static final _grant = VenueHubStaffGrant(
    staffId: 'staff-a',
    permissions: const <String>{'order', 'payment', 'manager', 'delivery'},
    expiresAtUtc: DateTime.utc(2099),
    pinVersion: 1,
    membershipVersion: 1,
  );
}

Map<String, Object?> _venueSnapshot() => <String, Object?>{
  'version': 1,
  'hubEpoch': _EposHarness.hubEpoch,
  'cloudLastSequence': 0,
  'currencyCode': 'GBP',
  'venueName': 'TableSide Test Venue',
  'venueAddress': '1 Test Street',
  'venuePhoneNumbers': <String>['+44 1234 567890'],
  'receiptFooter': 'Thank you',
  'tables': <Object?>[
    <String, Object?>{'id': 'table-a', 'label': 'Table 1'},
  ],
  'serviceAreas': <Object?>[
    <String, Object?>{
      'id': 'area-a',
      'name': 'Kyrenia',
      'active': true,
      'deliveryFeeMinor': 300,
      'minimumOrderMinor': 0,
    },
  ],
  'printerRoutes': <Object?>[
    <String, Object?>{
      'productionArea': 'kitchen',
      'primaryDeviceId': 'printer-kitchen',
      'fallbackDeviceId': 'printer-fallback',
    },
    <String, Object?>{
      'productionArea': 'receipt',
      'primaryDeviceId': 'printer-receipt',
    },
  ],
  'modifierGroups': <Object?>[
    <String, Object?>{
      'id': 'curry-heat',
      'name': 'Heat',
      'minimumSelections': 0,
      'maximumSelections': 1,
      'isAvailable': true,
      'options': <Object?>[
        <String, Object?>{
          'id': 'extra-hot',
          'name': 'Extra Hot',
          'priceDeltaMinor': 100,
          'isAvailable': true,
        },
      ],
    },
  ],
  'products': <Object?>[
    <String, Object?>{
      ..._product('curry', 'Chicken Curry', 1200, 'kitchen'),
      'modifierGroupIds': <String>['curry-heat'],
    },
    _product('rice', 'Pilau Rice', 400, 'kitchen'),
    _product('water', 'Mineral Water', 200, 'kitchen'),
  ],
};

Map<String, Object?> _product(
  String id,
  String name,
  int priceMinor,
  String productionArea,
) => <String, Object?>{
  'id': id,
  'name': name,
  'priceMinor': priceMinor,
  'taxRateId': 'tax-standard',
  'taxRateName': 'Standard',
  'taxRateBasisPoints': 2000,
  'productionArea': productionArea,
  'isAvailable': true,
  'isArchived': false,
  'showOnOrderFlow': true,
  'trackStock': false,
  'availableForCollection': true,
  'availableForDelivery': true,
  'modifierGroupIds': <String>[],
  'variants': <Object?>[],
};
