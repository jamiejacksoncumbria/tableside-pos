/// Returns the age of a production ticket using absolute UTC instants.
///
/// The trusted venue clock can correct a device whose clock is wrong. A
/// correction can briefly place a locally cached ticket in the future, so the
/// UI deliberately reports zero instead of a negative duration.
Duration orderFlowElapsed(DateTime now, DateTime releasedAt) {
  final elapsed = now.toUtc().difference(releasedAt.toUtc());
  return elapsed.isNegative ? Duration.zero : elapsed;
}
