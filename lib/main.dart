import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/pos_app.dart';
import 'core/app_logger.dart';
import 'core/local_preferences_recovery.dart';
import 'core/push_notification_bootstrap.dart';
import 'offline/offline_event_ledger.dart';

void main() {
  runZonedGuarded(
    () async {
      // The binding, framework handlers, and runApp must share this guarded
      // zone. Initialising the binding before runZonedGuarded causes Flutter's
      // zone-mismatch assertion in debug builds.
      WidgetsFlutterBinding.ensureInitialized();
      registerFirebaseMessagingBackgroundHandler();
      var preferencesRecovery = const LocalPreferencesRecoveryResult(
        recovered: false,
      );
      try {
        preferencesRecovery = await recoverLocalPreferencesIfNeeded();
      } on Object catch (error) {
        // Local preference recovery must never prevent the first frame. The
        // cache users also fail independently so cloud operation can continue.
        debugPrint('Could not repair local preferences: $error');
      }
      await AppLogger.initialize();
      if (preferencesRecovery.recovered) {
        AppLogger.info(
          'Recovered ${preferencesRecovery.recoveredEntryCount} complete local '
          'preference entries after an interrupted Windows write.',
        );
      }
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
          child: TableSideCYApp(),
        ),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        AppLogger.info('First Flutter frame completed.');
      });
    },
    (error, stackTrace) =>
        AppLogger.error('Uncaught asynchronous error', error, stackTrace),
  );
}
