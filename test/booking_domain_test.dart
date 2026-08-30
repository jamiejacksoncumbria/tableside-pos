import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/features/bookings/booking.dart';

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
}
