import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'local_preferences_recovery_stub.dart';
export 'local_preferences_recovery_stub.dart'
    show LocalPreferencesRecoveryResult;

/// Repairs a malformed Windows shared-preferences JSON file before the
/// shared_preferences plugin attempts to cache it.
///
/// An interrupted synchronous write (for example, a power cut) can leave the
/// file truncated. The Windows plugin then throws on every get and set call,
/// which previously trapped the venue PIN screen on a progress indicator. The
/// original bytes are retained beside the repaired file for diagnosis, while
/// complete top-level entries before a truncated tail are preserved.
Future<LocalPreferencesRecoveryResult> recoverLocalPreferencesIfNeeded() async {
  if (!Platform.isWindows) {
    return const LocalPreferencesRecoveryResult(recovered: false);
  }
  final directory = await getApplicationSupportDirectory();
  final preferences = File('${directory.path}/shared_preferences.json');
  if (!await preferences.exists()) {
    return const LocalPreferencesRecoveryResult(recovered: false);
  }
  final raw = await preferences.readAsString();
  if (raw.trim().isEmpty) {
    return const LocalPreferencesRecoveryResult(recovered: false);
  }
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return const LocalPreferencesRecoveryResult(recovered: false);
    }
  } on FormatException {
    // Continue into the bounded recovery path below.
  }

  final recovered = recoverCompletePreferences(raw);
  final timestamp = DateTime.now().toUtc().millisecondsSinceEpoch;
  final backup = File(
    '${directory.path}/shared_preferences.corrupt.$timestamp.json',
  );
  await preferences.copy(backup.path);

  // Write the replacement through a temporary file and atomic rename so a
  // second interruption cannot repeat the same partial-file failure.
  final temporary = File('${preferences.path}.repairing');
  await temporary.writeAsString(jsonEncode(recovered), flush: true);
  if (await preferences.exists()) await preferences.delete();
  await temporary.rename(preferences.path);
  return LocalPreferencesRecoveryResult(
    recovered: true,
    recoveredEntryCount: recovered.length,
  );
}

/// Recovers complete key/value pairs from the start of a truncated top-level
/// JSON object. shared_preferences values are JSON scalars or arrays, so
/// repeatedly trimming to the previous comma safely retains the largest valid
/// prefix without inventing or altering a value.
Map<String, Object?> recoverCompletePreferences(String raw) {
  final trimmed = raw.trim();
  if (!trimmed.startsWith('{')) return <String, Object?>{};
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map) return Map<String, Object?>.from(decoded);
  } on FormatException {
    // Continue with prefix recovery.
  }
  var boundary = trimmed.length;
  while (boundary > 1) {
    final prefix = trimmed.substring(0, boundary).trimRight();
    final withoutTrailingComma = prefix.endsWith(',')
        ? prefix.substring(0, prefix.length - 1)
        : prefix;
    final candidate = '$withoutTrailingComma}';
    try {
      final decoded = jsonDecode(candidate);
      if (decoded is Map) return Map<String, Object?>.from(decoded);
    } on FormatException {
      // The current tail is incomplete; move to the preceding entry.
    }
    boundary = trimmed.lastIndexOf(',', boundary - 1);
    if (boundary < 0) break;
  }
  return <String, Object?>{};
}
