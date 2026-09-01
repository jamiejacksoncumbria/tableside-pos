import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'diagnostic_log_store.dart';

/// Console and device-local diagnostics. Do not add customer, payment, or
/// authentication values to log messages; the local redactor is a final safety
/// net, not a substitute for privacy-safe call sites.
abstract final class AppLogger {
  static DebugPrintCallback _consolePrint = debugPrint;
  static bool _initialized = false;

  static Future<void> initialize() async {
    if (_initialized) return;
    _consolePrint = debugPrint;
    try {
      await DiagnosticLogStore.instance.initialize();
    } on Object catch (error) {
      _consolePrint('TABLESIDE ERROR [Start local diagnostics] $error');
    }
    debugPrint = _captureDebugPrint;
    _initialized = true;
    DiagnosticLogStore.instance.append(
      'INFO',
      'Local diagnostic logging started; maximum '
          '${DiagnosticLogStore.maximumLines} lines.',
    );
  }

  static void info(String message) {
    DiagnosticLogStore.instance.append('DEBUG', message);
    if (kDebugMode) _consolePrint('TABLESIDE DEBUG $message');
  }

  static void error(String operation, Object error, [StackTrace? stackTrace]) {
    final summary = '[$operation] ${error.runtimeType}: $error';
    DiagnosticLogStore.instance.append('ERROR', summary);
    if (stackTrace != null) {
      DiagnosticLogStore.instance.appendAll(
        'STACK',
        stackTrace.toString().split(RegExp(r'\r?\n')).take(50),
      );
    }
    if (!kDebugMode) return;
    _consolePrint('TABLESIDE ERROR $summary');
    if (stackTrace != null) {
      _consolePrint('TABLESIDE STACK [$operation]');
      for (final line
          in stackTrace.toString().split(RegExp(r'\r?\n')).take(50)) {
        _consolePrint(line);
      }
    }
  }

  static void flutterError(FlutterErrorDetails details) {
    error('Flutter framework', details.exception, details.stack);
  }

  static void _captureDebugPrint(String? message, {int? wrapWidth}) {
    _consolePrint(message, wrapWidth: wrapWidth);
    if (message != null && message.isNotEmpty) {
      DiagnosticLogStore.instance.append('CONSOLE', message);
    }
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
