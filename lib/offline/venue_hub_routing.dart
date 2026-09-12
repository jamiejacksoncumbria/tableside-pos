enum VenueClientPlatform { android, ios, windows, web }

enum VenueMutationRoute { firebase, venueHub, readOnly, unavailable }

class VenueHubRoutingInput {
  const VenueHubRoutingInput({
    required this.platform,
    required this.cloudReachable,
    required this.hubReachable,
    required this.hubOwnsAuthority,
    this.webAppAvailableOffline = false,
  });

  final VenueClientPlatform platform;
  final bool cloudReachable;
  final bool hubReachable;
  final bool hubOwnsAuthority;
  final bool webAppAvailableOffline;
}

/// Fail-closed routing policy for order, payment, stock and print mutations.
/// A cloud-connected 3G browser must never create a second source of truth
/// while the venue hub is accepting offline work on the restaurant LAN.
VenueMutationRoute chooseVenueMutationRoute(VenueHubRoutingInput input) {
  if (input.hubOwnsAuthority) {
    // Browser clients remain cloud read-only in the pilot. They deliberately
    // do not keep native device credentials or write to the LAN authority.
    if (input.platform == VenueClientPlatform.web) {
      return input.cloudReachable
          ? VenueMutationRoute.readOnly
          : VenueMutationRoute.unavailable;
    }
    if (input.hubReachable) {
      return VenueMutationRoute.venueHub;
    }
    return input.cloudReachable
        ? VenueMutationRoute.readOnly
        : VenueMutationRoute.unavailable;
  }
  return input.cloudReachable
      ? VenueMutationRoute.firebase
      : VenueMutationRoute.unavailable;
}
