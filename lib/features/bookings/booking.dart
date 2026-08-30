enum BookingStatus { requested, confirmed, arrived, cancelled, noShow }

extension BookingStatusLabel on BookingStatus {
  String get label => switch (this) {
    BookingStatus.requested => 'Requested',
    BookingStatus.confirmed => 'Confirmed',
    BookingStatus.arrived => 'Arrived',
    BookingStatus.cancelled => 'Cancelled',
    BookingStatus.noShow => 'No-show',
  };

  bool get blocksTable =>
      this != BookingStatus.cancelled && this != BookingStatus.noShow;
}

class VenueBooking {
  const VenueBooking({
    required this.id,
    required this.venueId,
    required this.tableId,
    required this.customerName,
    required this.guestCount,
    required this.startsAt,
    required this.endsAt,
    required this.durationMinutes,
    required this.status,
    this.phone = '',
    this.notes = '',
  });

  final String id;
  final String venueId;
  final String tableId;
  final String customerName;
  final String phone;
  final String notes;
  final int guestCount;
  final DateTime startsAt;
  final DateTime endsAt;
  final int durationMinutes;
  final BookingStatus status;
}

BookingStatus bookingStatusFromName(Object? value) {
  for (final status in BookingStatus.values) {
    if (status.name == value) return status;
  }
  return BookingStatus.requested;
}
