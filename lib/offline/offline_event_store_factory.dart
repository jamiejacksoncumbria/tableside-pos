import 'offline_event_store_base.dart';
import 'offline_event_store_stub.dart'
    if (dart.library.io) 'offline_event_store_native.dart'
    as implementation;

OfflineEventStore createOfflineEventStore() =>
    implementation.createOfflineEventStore();
