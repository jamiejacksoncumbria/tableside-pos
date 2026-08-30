import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/features/bookings/booking.dart';
import 'package:tableside_pos/features/pos/domain.dart';

void main() {
  test('only cancelled and no-show bookings release their table', () {
    expect(BookingStatus.requested.blocksTable, isTrue);
    expect(BookingStatus.confirmed.blocksTable, isTrue);
    expect(BookingStatus.arrived.blocksTable, isTrue);
    expect(BookingStatus.cancelled.blocksTable, isFalse);
    expect(BookingStatus.noShow.blocksTable, isFalse);
  });

  test('unknown stored booking status safely becomes requested', () {
    expect(bookingStatusFromName('unexpected'), BookingStatus.requested);
    expect(bookingStatusFromName(null), BookingStatus.requested);
  });

  test('venues expose a safe configurable booking duration', () {
    const fallback = Venue(
      id: 'venue-1',
      tenantId: 'tenant-1',
      name: 'Restaurant',
      timeZone: 'Europe/London',
    );
    const configured = Venue(
      id: 'venue-2',
      tenantId: 'tenant-1',
      name: 'Restaurant Two',
      timeZone: 'Europe/London',
      defaultBookingDurationMinutes: 90,
    );

    expect(fallback.defaultBookingDurationMinutes, 120);
    expect(configured.defaultBookingDurationMinutes, 90);
  });
}
