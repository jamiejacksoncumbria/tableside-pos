import 'package:flutter/foundation.dart';

/// Process-wide count of foreground server operations.
///
/// Repository boundaries own this state so every screen receives the same
/// duplicate-submit protection without each button implementing a different
/// loading convention. Background heartbeats, printer polling and live
/// streams must never enter this state.
class AppBusyState {
  AppBusyState._();

  static final ValueNotifier<int> pending = ValueNotifier<int>(0);

  static void begin() => pending.value++;

  static void end() => pending.value = (pending.value - 1).clamp(0, 1 << 20);

  static Future<T> guard<T>(Future<T> Function() operation) async {
    begin();
    try {
      return await operation();
    } finally {
      end();
    }
  }
}
