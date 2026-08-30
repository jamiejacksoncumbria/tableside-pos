import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/pos_app.dart';
import 'core/app_logger.dart';

void main() {
  runZonedGuarded(
    () {
      // The binding, framework handlers, and runApp must share this guarded
      // zone. Initialising the binding before runZonedGuarded causes Flutter's
      // zone-mismatch assertion in debug builds.
      WidgetsFlutterBinding.ensureInitialized();
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
