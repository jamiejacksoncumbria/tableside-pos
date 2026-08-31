import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/features/reports/reports_page.dart';

void main() {
  test('business day remains incomplete until its configured cut-off', () {
    final saturday = DateTimeRange(
      start: DateTime(2026, 8, 29),
      end: DateTime(2026, 8, 29),
    );

    expect(
      isSalesReportPeriodComplete(saturday, 240, DateTime(2026, 8, 30, 3, 59)),
      isFalse,
    );
    expect(
      isSalesReportPeriodComplete(saturday, 240, DateTime(2026, 8, 30, 4)),
      isTrue,
    );
  });

  test('a report ending on the current business date is incomplete', () {
    final sunday = DateTimeRange(
      start: DateTime(2026, 8, 30),
      end: DateTime(2026, 8, 30),
    );
    expect(
      isSalesReportPeriodComplete(sunday, 240, DateTime(2026, 8, 30, 18)),
      isFalse,
    );
  });
}
