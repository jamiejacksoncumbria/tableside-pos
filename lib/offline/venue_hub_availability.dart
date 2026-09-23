import 'package:flutter/foundation.dart';

/// Process-local explanation of why the authoritative venue hub cannot be
/// reached. Operational commands still fail closed; this state exists only to
/// make that safety decision obvious to staff instead of leaving a spinner.
class VenueHubAvailability {
  VenueHubAvailability._();

  static final ValueNotifier<String?> issue = ValueNotifier<String?>(null);

  static void markOnline() => issue.value = null;

  static void markOffline([String? detail]) {
    issue.value = detail?.trim().isNotEmpty == true
        ? detail!.trim()
        : 'The venue hub is offline. Join the same Wi-Fi as the hub and check that it is running.';
  }
}
