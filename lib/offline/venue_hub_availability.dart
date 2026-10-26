import 'package:flutter/foundation.dart';

enum VenueHubConnectivity { unknown, checking, online, lanOnly, unavailable }

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

  static void reset() {
    issue.value = null;
    status.value = const VenueHubConnectionStatus.unknown();
  }

  static void markChecking([String? detail]) {
    issue.value = null;
    status.value = VenueHubConnectionStatus(
      connectivity: VenueHubConnectivity.checking,
      detail: detail,
    );
  }

  /// A live cloud heartbeat or accepted remote command proves both that the
  /// hub is running and that its internet route is operational.
  static void markOnline() {
    issue.value = null;
    status.value = const VenueHubConnectionStatus(
      connectivity: VenueHubConnectivity.online,
    );
  }

  /// A certificate-pinned HTTPS health response proves local hub reachability
  /// but says nothing about the venue's internet connection.
  static void markLanOnline({bool? internetAvailable}) {
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
