import 'package:flutter_riverpod/flutter_riverpod.dart';

class VenueScope {
  const VenueScope({required this.tenantId, required this.venueId});

  final String tenantId;
  final String venueId;

  @override
  bool operator ==(Object other) =>
      other is VenueScope &&
      other.tenantId == tenantId &&
      other.venueId == venueId;

  @override
  int get hashCode => Object.hash(tenantId, venueId);
}

final activeVenueScopeProvider =
    NotifierProvider<ActiveVenueScopeController, VenueScope?>(
      ActiveVenueScopeController.new,
    );

class ActiveVenueScopeController extends Notifier<VenueScope?> {
  @override
  VenueScope? build() => null;

  void select(VenueScope scope) => state = scope;

  void clear() => state = null;
}
