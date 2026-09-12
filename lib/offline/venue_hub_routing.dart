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
    if (input.hubReachable) {
      if (input.platform == VenueClientPlatform.web &&
          !input.webAppAvailableOffline &&
          !input.cloudReachable) {
        return VenueMutationRoute.unavailable;
      }
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
