import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/pos_app.dart';
import 'core/app_logger.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    AppLogger.flutterError(details);
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    AppLogger.error('Uncaught platform error', error, stackTrace);
    return true;
  };
  runZonedGuarded(
    () => runApp(
      const ProviderScope(
        observers: [DebugProviderObserver()],
        child: TableSideApp(),
      ),
    ),
    (error, stackTrace) =>
        AppLogger.error('Uncaught asynchronous error', error, stackTrace),
  );
}
