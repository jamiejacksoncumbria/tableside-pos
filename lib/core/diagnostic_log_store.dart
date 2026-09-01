import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A device-local, bounded diagnostic log. Entries are deliberately plain
/// text so a manager can inspect and copy them even when Firebase is offline.
/// Never pass customer, payment, authentication, or PIN values to this store.
class DiagnosticLogStore {
  DiagnosticLogStore._();

  static final DiagnosticLogStore instance = DiagnosticLogStore._();

  static const int maximumLines = 1000;
  static const int _maximumLineLength = 2000;
  static const String _storageKey = 'tableside.localDiagnosticLog.v1';

  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  final List<String> _lines = <String>[];
  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();
  Timer? _persistTimer;
  Future<void> _pendingWrite = Future<void>.value();
  bool _initialized = false;

  List<String> get lines => List<String>.unmodifiable(_lines);

  String get copyText => _lines.join('\n');

  Future<void> initialize() async {
    if (_initialized) return;
    try {
      final stored = await _preferences.getStringList(_storageKey);
      if (stored != null) {
        _lines
          ..clear()
          ..addAll(
            stored.length <= maximumLines
                ? stored
                : stored.sublist(stored.length - maximumLines),
          );
      }
    } finally {
      _initialized = true;
      revision.value++;
    }
  }

  void append(String level, String message) {
    appendAll(level, message.split(RegExp(r'\r?\n')));
  }

  void appendAll(String level, Iterable<String> messages) {
    final timestamp = DateTime.now().toIso8601String();
    var changed = false;
    for (final raw in messages) {
      final cleaned = _sanitise(raw.trimRight());
      if (cleaned.isEmpty) continue;
      final bounded = cleaned.length <= _maximumLineLength
          ? cleaned
          : '${cleaned.substring(0, _maximumLineLength)}…';
      _lines.add('$timestamp [$level] $bounded');
      changed = true;
    }
    if (!changed) return;
    if (_lines.length > maximumLines) {
      _lines.removeRange(0, _lines.length - maximumLines);
    }
    revision.value++;
    _schedulePersist();
  }

  Future<void> clear() async {
    _persistTimer?.cancel();
    _lines.clear();
    revision.value++;
    await _queueWrite(const <String>[]);
  }

  void _schedulePersist() {
    if (!_initialized) return;
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(_queueWrite(List<String>.of(_lines)));
    });
  }

  Future<void> _queueWrite(List<String> snapshot) {
    _pendingWrite = _pendingWrite
        .then(
          (_) => _preferences.setStringList(_storageKey, snapshot),
          onError: (_) => _preferences.setStringList(_storageKey, snapshot),
        )
        .catchError((Object _) {
          // Diagnostics must never create a recursive unhandled error when local
          // storage is unavailable or full.
        });
    return _pendingWrite;
  }

  String _sanitise(String input) {
    var value = input;
    value = value.replaceAll(
      RegExp(r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}', caseSensitive: false),
      '<redacted-email>',
    );
    value = value.replaceAll(
      RegExp(
        r'\b(password|pin|token|authorization|secret|apiKey)\s*[:=]\s*[^\s,;]+',
        caseSensitive: false,
      ),
      r'$1=<redacted>',
    );
    value = value.replaceAll(
      RegExp(r'([?&](?:token|key|signature)=)[^&\s]+', caseSensitive: false),
      r'$1<redacted>',
    );
    value = value.replaceAll(
      RegExp(r'Bearer\s+[A-Za-z0-9._~+/-]+=*', caseSensitive: false),
      'Bearer <redacted>',
    );
    value = value.replaceAll(
      RegExp(r'C:\\Users\\[^\\\s]+', caseSensitive: false),
      r'C:\Users\<user>',
    );
    return value;
  }
}
