import 'dart:async';

enum TrustedClockAuthority { unsynchronised, firebase, venueHub }

class TrustedClockSnapshot {
  const TrustedClockSnapshot({
    required this.authority,
    required this.sampledAtDeviceUtc,
    required this.offset,
    required this.roundTrip,
    this.hubEpoch,
  });

  const TrustedClockSnapshot.unsynchronised()
    : authority = TrustedClockAuthority.unsynchronised,
      sampledAtDeviceUtc = null,
      offset = Duration.zero,
      roundTrip = Duration.zero,
      hubEpoch = null;

  final TrustedClockAuthority authority;
  final DateTime? sampledAtDeviceUtc;
  final Duration offset;
  final Duration roundTrip;
  final int? hubEpoch;

  bool get isSynchronised => authority != TrustedClockAuthority.unsynchronised;
  bool get hasMaterialSkew =>
      offset.inMilliseconds.abs() > const Duration(minutes: 2).inMilliseconds;

  DateTime trustedNowUtc([DateTime? deviceNow]) =>
      (deviceNow ?? DateTime.now().toUtc()).add(offset);
}

/// Maintains an estimated trusted clock without ever changing the operating
/// system clock. Online samples come from Firebase; during a venue outage the
/// enrolled hub replaces Firebase as the time authority.
class TrustedClock {
  TrustedClock._();

  static final TrustedClock instance = TrustedClock._();

  final StreamController<TrustedClockSnapshot> _changes =
      StreamController<TrustedClockSnapshot>.broadcast();
  TrustedClockSnapshot _snapshot = const TrustedClockSnapshot.unsynchronised();

  TrustedClockSnapshot get snapshot => _snapshot;
  Stream<TrustedClockSnapshot> get changes => _changes.stream;
  DateTime nowUtc() => _snapshot.trustedNowUtc();

  Future<TrustedClockSnapshot> synchroniseFirebase(
    Future<int> Function() fetchServerTimeMillis,
  ) async {
    final before = DateTime.now().toUtc();
    final serverMillis = await fetchServerTimeMillis();
    final after = DateTime.now().toUtc();
    final roundTrip = after.difference(before);
    final midpoint = before.add(
      Duration(microseconds: roundTrip.inMicroseconds ~/ 2),
    );
    final serverTime = DateTime.fromMillisecondsSinceEpoch(
      serverMillis,
      isUtc: true,
    );
    return _set(
      TrustedClockSnapshot(
        authority: TrustedClockAuthority.firebase,
        sampledAtDeviceUtc: after,
        offset: serverTime.difference(midpoint),
        roundTrip: roundTrip,
      ),
    );
  }

  TrustedClockSnapshot acceptHubSample({
    required int hubTimeMillis,
    required DateTime requestStartedUtc,
    required DateTime responseReceivedUtc,
    required int hubEpoch,
  }) {
    if (hubEpoch < 1) {
      throw ArgumentError.value(hubEpoch, 'hubEpoch', 'Must be positive.');
    }
    final roundTrip = responseReceivedUtc.difference(requestStartedUtc);
    if (roundTrip.isNegative) {
      throw ArgumentError('The hub clock sample has an invalid round trip.');
    }
    final midpoint = requestStartedUtc.add(
      Duration(microseconds: roundTrip.inMicroseconds ~/ 2),
    );
    final hubTime = DateTime.fromMillisecondsSinceEpoch(
      hubTimeMillis,
      isUtc: true,
    );
    return _set(
      TrustedClockSnapshot(
        authority: TrustedClockAuthority.venueHub,
        sampledAtDeviceUtc: responseReceivedUtc,
        offset: hubTime.difference(midpoint),
        roundTrip: roundTrip,
        hubEpoch: hubEpoch,
      ),
    );
  }

  TrustedClockSnapshot _set(TrustedClockSnapshot next) {
    _snapshot = next;
    _changes.add(next);
    return next;
  }
}
