import '../pos/domain.dart';

class ServiceWindow {
  const ServiceWindow({
    required this.weekday,
    required this.opensMinute,
    required this.closesMinute,
    this.enabled = true,
  });

  final int weekday;
  final int opensMinute;
  final int closesMinute;
  final bool enabled;
}

class ServiceArea {
  const ServiceArea({
    required this.id,
    required this.name,
    this.deliveryFeeMinor = 0,
    this.minimumOrderMinor = 0,
    this.estimatedMinutes = 45,
    this.active = true,
  });

  final String id;
  final String name;
  final int deliveryFeeMinor;
  final int minimumOrderMinor;
  final int estimatedMinutes;
  final bool active;
}

class ServiceDateOverride {
  const ServiceDateOverride({
    required this.id,
    required this.date,
    required this.channel,
    this.closed = true,
    this.windows = const <ServiceWindow>[],
    this.note = '',
  });

  final String id;
  final DateTime date;
  final OrderChannel channel;
  final bool closed;
  final List<ServiceWindow> windows;
  final String note;
}

class VenueCustomer {
  const VenueCustomer({
    required this.id,
    required this.displayName,
    required this.phoneNumbers,
    this.email,
    this.addresses = const <CustomerAddress>[],
    this.claimStatus = 'unclaimed',
    this.globalCustomerId,
    this.createdAt,
  });

  final String id;
  final String displayName;
  final List<String> phoneNumbers;
  final String? email;
  final List<CustomerAddress> addresses;
  final String claimStatus;
  final String? globalCustomerId;
  final DateTime? createdAt;
}

class CustomerAddress {
  const CustomerAddress({
    required this.id,
    required this.label,
    required this.country,
    required this.town,
    required this.area,
    required this.addressLines,
    this.notes = '',
  });

  final String id;
  final String label;
  final String country;
  final String town;
  final String area;
  final String addressLines;
  final String notes;
}

class VenueFulfilmentSettings {
  const VenueFulfilmentSettings({
    this.collectionEnabled = false,
    this.deliveryEnabled = false,
    this.courseControlEnabled = false,
    this.collectionLeadMinutes = 20,
    this.deliveryLeadMinutes = 20,
    this.collectionWindows = const <ServiceWindow>[],
    this.deliveryWindows = const <ServiceWindow>[],
    this.serviceAreas = const <ServiceArea>[],
    this.dateOverrides = const <ServiceDateOverride>[],
  });

  final bool collectionEnabled;
  final bool deliveryEnabled;
  final bool courseControlEnabled;
  final int collectionLeadMinutes;
  final int deliveryLeadMinutes;
  final List<ServiceWindow> collectionWindows;
  final List<ServiceWindow> deliveryWindows;
  final List<ServiceArea> serviceAreas;
  final List<ServiceDateOverride> dateOverrides;
}

class FulfilmentOrderSummary {
  const FulfilmentOrderSummary({
    required this.orderId,
    required this.channel,
    required this.status,
    required this.customerName,
    required this.totalMinor,
    this.scheduledFor,
    this.assignedDriverName,
  });

  final String orderId;
  final OrderChannel channel;
  final FulfilmentStatus status;
  final String customerName;
  final int totalMinor;
  final DateTime? scheduledFor;
  final String? assignedDriverName;
}

class FulfilmentStaffMember {
  const FulfilmentStaffMember({
    required this.id,
    required this.name,
    required this.roles,
    this.venueIds = const <String>[],
  });

  final String id;
  final String name;
  final List<String> roles;
  final List<String> venueIds;

  bool availableAt(String venueId) =>
      venueIds.isEmpty || venueIds.contains(venueId);
}
