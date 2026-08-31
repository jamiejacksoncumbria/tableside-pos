import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/core/date_formats.dart';

void main() {
  test('user-facing dates use dd-MM-yyyy', () {
    expect(formatAppDate(DateTime(2026, 8, 31)), '31-08-2026');
    expect(formatAppDateTime(DateTime(2026, 8, 31, 19, 5)), '31-08-2026 19:05');
  });
}
