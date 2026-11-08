import 'package:flutter/foundation.dart';

enum VenueHubConnectivity { unknown, checking, online, lanOnly, unavailable }

/// Staff-facing explanation for a hub failure. This deliberately converts
/// security-sensitive technical errors into controlled operational guidance;
/// raw server responses and credentials must never be exposed in the UI.
class VenueHubIssuePresentation {
  const VenueHubIssuePresentation({
    required this.title,
    required this.message,
    required this.bannerLabel,
    required this.requiresManagerAttention,
  });

  final String title;
  final String message;
  final String bannerLabel;
  final bool requiresManagerAttention;
}

/// Recognises failures that must remain obvious until a manager corrects the
/// device enrolment or trusted certificate. Keep this intentionally narrow:
/// ordinary HTTP 401 responses (for example an expired staff session) must
/// not be misreported as a compromised or unauthorised terminal.
bool isVenueHubDeviceAuthorizationIssue(String message) {
  final value = message.toLowerCase();
  return value.contains('device is not enrolled') ||
      value.contains('device must be enrolled') ||
      value.contains('must be enrolled in venue offline hub') ||
      value.contains('device is not authorised') ||
      value.contains('device is not authorized') ||
      value.contains('printer is not enrolled') ||
      value.contains('device credential is not active') ||
      value.contains('active cloud-authorised') ||
      value.contains('active cloud-authorized') ||
      value.contains('no pinned venue certificate') ||
      value.contains('pinned venue certificate') ||
      value.contains('trusted certificate') ||
      value.contains('certificate or private key is missing') ||
      value.contains('no longer owns') ||
      value.contains('not authoritative for this venue');
}

VenueHubIssuePresentation venueHubIssuePresentation(String issue) {
  final value = issue.toLowerCase();
  final certificateFailure =
      value.contains('no pinned venue certificate') ||
      value.contains('certificate or private key is missing') ||
      value.contains('certificate is missing') ||
      value.contains('certificate is invalid') ||
      value.contains('check the trusted certificate');
  if (certificateFailure) {
    return const VenueHubIssuePresentation(
      title: 'Venue certificate required',
      message:
          'This device cannot process orders because its trusted venue '
          'certificate is missing or invalid. Ask a manager to open Settings '
          '→ Venue offline hub and import the venue certificate. A hub or '
          'backup hub also requires the matching private key.',
      bannerLabel: 'CERTIFICATE REQUIRED · ORDERS BLOCKED',
      requiresManagerAttention: true,
    );
  }
  if (isVenueHubDeviceAuthorizationIssue(issue)) {
    return const VenueHubIssuePresentation(
      title: 'This device is not authorised',
      message:
          'Orders are blocked on this device. Ask a manager to open '
          'Settings → Venue offline hub on this device, enrol it for this '
          'venue, and confirm that the device is active.',
      bannerLabel: 'DEVICE NOT AUTHORISED · ORDERS BLOCKED',
      requiresManagerAttention: true,
    );
  }
  if (value.contains('staff session') &&
      (value.contains('expired') ||
          value.contains('revoked') ||
          value.contains('unavailable'))) {
    return const VenueHubIssuePresentation(
      title: 'Staff session needs attention',
      message:
          'This device cannot process orders until a staff member '
          'selects their name and enters their PIN again.',
      bannerLabel: 'STAFF PIN REQUIRED · ORDERS BLOCKED',
      requiresManagerAttention: false,
    );
  }
  return const VenueHubIssuePresentation(
    title: 'Venue hub is unavailable',
    message:
        'This device cannot safely save orders until the venue hub '
        'responds. Join the venue network or restore the hub internet '
        'connection. Orders remain blocked until an authoritative hub '
        'confirms them.',
    bannerLabel: 'HUB UNAVAILABLE · ORDERS BLOCKED',
    requiresManagerAttention: false,
  );
}

class VenueHubConnectionStatus {
  const VenueHubConnectionStatus({required this.connectivity, this.detail});

  const VenueHubConnectionStatus.unknown()
    : connectivity = VenueHubConnectivity.unknown,
      detail = null;

  final VenueHubConnectivity connectivity;
  final String? detail;

  bool get canProcessOrders =>
      connectivity == VenueHubConnectivity.online ||
      connectivity == VenueHubConnectivity.lanOnly;

  String get shortLabel => switch (connectivity) {
    VenueHubConnectivity.unknown => 'Hub status unknown',
    VenueHubConnectivity.checking => 'Checking hub…',
    VenueHubConnectivity.online => 'Hub + internet online',
    VenueHubConnectivity.lanOnly => 'Hub online · LAN only',
    VenueHubConnectivity.unavailable => 'Hub offline · orders blocked',
  };
}

/// Process-local explanation of why the authoritative venue hub cannot be
/// reached. Operational commands still fail closed; this state exists only to
/// make that safety decision obvious to staff instead of leaving a spinner.
class VenueHubAvailability {
  VenueHubAvailability._();

  static final ValueNotifier<String?> issue = ValueNotifier<String?>(null);
  static final ValueNotifier<VenueHubConnectionStatus> status =
      ValueNotifier<VenueHubConnectionStatus>(
        const VenueHubConnectionStatus.unknown(),
      );

  static bool get canProcessOrders => status.value.canProcessOrders;

  static bool get hasDeviceAuthorizationIssue {
    final current = issue.value;
    return current != null && isVenueHubDeviceAuthorizationIssue(current);
  }

  static void reset() {
    issue.value = null;
    status.value = const VenueHubConnectionStatus.unknown();
  }

  static void markChecking([String? detail]) {
    if (hasDeviceAuthorizationIssue) return;
    issue.value = null;
    status.value = VenueHubConnectionStatus(
      connectivity: VenueHubConnectivity.checking,
      detail: detail,
    );
  }

  /// A live cloud heartbeat or accepted remote command proves both that the
  /// hub is running and that its internet route is operational.
  static void markOnline() {
    if (hasDeviceAuthorizationIssue) return;
    issue.value = null;
    status.value = const VenueHubConnectionStatus(
      connectivity: VenueHubConnectivity.online,
    );
  }

  /// A certificate-pinned HTTPS health response proves local hub reachability
  /// but says nothing about the venue's internet connection.
  static void markLanOnline({bool? internetAvailable}) {
    if (hasDeviceAuthorizationIssue) return;
    final internet =
        internetAvailable ??
        status.value.connectivity == VenueHubConnectivity.online;
    issue.value = null;
    status.value = VenueHubConnectionStatus(
      connectivity: internet
          ? VenueHubConnectivity.online
          : VenueHubConnectivity.lanOnly,
    );
  }

  static void markOffline([String? detail]) {
    final message = detail?.trim().isNotEmpty == true
        ? detail!.trim()
        : 'The venue hub is offline. Join the same Wi-Fi as the hub and check that it is running.';
    issue.value = message;
    status.value = VenueHubConnectionStatus(
      connectivity: VenueHubConnectivity.unavailable,
      detail: message,
    );
  }

  /// Clears a sticky device-security block only after the caller has
  /// independently validated both the cloud enrolment and pinned venue
  /// certificate. A heartbeat must never call this method.
  static void clearDeviceAuthorizationIssue() {
    if (!hasDeviceAuthorizationIssue) return;
    issue.value = null;
    status.value = const VenueHubConnectionStatus(
      connectivity: VenueHubConnectivity.checking,
      detail: 'Device authorisation verified; checking the venue hub.',
    );
  }

  /// Records a cloud/realtime presence failure without hiding a healthy LAN
  /// hub. The cloud heartbeat proves that remote terminals can reach the hub;
  /// it is not the authority for an enrolled terminal already connected to
  /// the hub's pinned HTTPS endpoint on the venue network.
  static void markRemoteOffline({
    required bool lanSessionAvailable,
    String? detail,
  }) {
    if (lanSessionAvailable) {
      markLanOnline(internetAvailable: false);
      return;
    }
    markOffline(detail);
  }
}
