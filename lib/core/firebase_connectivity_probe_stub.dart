/// Browsers manage their own network lifecycle. Native startup is the only
/// path that needs to avoid a platform Firebase call while the executable is
/// explicitly firewalled from the internet.
Future<bool> canReachFirebaseNetwork({
  Duration timeout = const Duration(seconds: 2),
}) async => true;
