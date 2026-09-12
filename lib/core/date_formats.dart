import 'package:intl/intl.dart';

/// User-facing dates use one unambiguous restaurant-wide format. Firestore
/// timestamps and API payloads remain ISO/epoch values and are never formatted
/// before persistence.
final DateFormat tablesideDateFormat = DateFormat('dd-MM-yyyy');
final DateFormat tablesideTimeFormat = DateFormat('HH:mm');
final DateFormat tablesideDateTimeFormat = DateFormat('dd-MM-yyyy HH:mm');

String formatAppDate(DateTime value) =>
    tablesideDateFormat.format(value.toLocal());

String formatAppTime(DateTime value) =>
    tablesideTimeFormat.format(value.toLocal());

String formatAppDateTime(DateTime value) =>
    tablesideDateTimeFormat.format(value.toLocal());

String formatVenueDateSnapshot(String value) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value.trim());
  return match == null
      ? value
      : '${match.group(3)}-${match.group(2)}-${match.group(1)}';
}

String formatVenueDateTimeSnapshot(String value) {
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::\d{2})?$',
  ).firstMatch(value.trim());
  return match == null
      ? value
      : '${match.group(3)}-${match.group(2)}-${match.group(1)} '
            '${match.group(4)}:${match.group(5)}';
}
