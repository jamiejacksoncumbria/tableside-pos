import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/pos_app.dart';
import 'core/app_logger.dart';
import 'offline/offline_event_ledger.dart';

void main() {
  runZonedGuarded(
    () async {
      // The binding, framework handlers, and runApp must share this guarded
      // zone. Initialising the binding before runZonedGuarded causes Flutter's
      // zone-mismatch assertion in debug builds.
      WidgetsFlutterBinding.ensureInitialized();
      await AppLogger.initialize();
      try {
        await OfflineEventLedger.instance.initialize();
      } catch (_) {
        // Online Firebase operation remains available. Offline mode will fail
        // closed until its encrypted durable store can be opened safely.
      }
      FlutterError.onError = (details) {
        AppLogger.flutterError(details);
        FlutterError.presentError(details);
      };
      PlatformDispatcher.instance.onError = (error, stackTrace) {
        AppLogger.error('Uncaught platform error', error, stackTrace);
        return true;
      };
      runApp(
        const ProviderScope(
          observers: [DebugProviderObserver()],
          child: TableSideApp(),
        ),
      );
    },
    (error, stackTrace) =>
        AppLogger.error('Uncaught asynchronous error', error, stackTrace),
  );
}
