import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Debug-only diagnostics for errors that need to be visible in Android Studio
/// or the terminal while developing. Do not add customer, payment, or secret
/// values to log messages.
abstract final class AppLogger {
  static void info(String message) {
    if (!kDebugMode) return;
    debugPrint('TABLESIDE DEBUG $message');
  }

  static void error(String operation, Object error, [StackTrace? stackTrace]) {
    if (!kDebugMode) return;
    debugPrint('TABLESIDE ERROR [$operation] ${error.runtimeType}: $error');
    if (stackTrace != null) {
      debugPrintStack(
        label: 'TABLESIDE STACK [$operation]',
        stackTrace: stackTrace,
        maxFrames: 50,
      );
    }
  }

  static void flutterError(FlutterErrorDetails details) {
    error('Flutter framework', details.exception, details.stack);
  }
}

/// Reports provider and stream failures that would otherwise only appear as
/// an AsyncError in the user interface.
final class DebugProviderObserver extends ProviderObserver {
  const DebugProviderObserver();

  @override
  void providerDidFail(
    ProviderObserverContext context,
    Object error,
    StackTrace stackTrace,
  ) {
    AppLogger.error('Riverpod provider ${context.provider}', error, stackTrace);
  }
}
