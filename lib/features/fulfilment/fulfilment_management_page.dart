import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../core/safe_dialog.dart';
import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../data/printer_device_repository.dart';
import '../../data/production_command_repository.dart';
import '../notifications/notification_centre.dart';
import '../auth/staff_pin_gate.dart';
import '../pos/domain.dart';
import 'customer_editor.dart';
import 'delivery_location_catalogue.dart';
import 'fulfilment_domain.dart';
import 'fulfilment_repository.dart';

part 'widgets/fulfilment_orders.dart';
part 'widgets/fulfilment_operations.dart';
part 'widgets/fulfilment_customers.dart';

class FulfilmentManagementPage extends ConsumerStatefulWidget {
  const FulfilmentManagementPage({required this.venue, super.key});

  final Venue venue;

  @override
  ConsumerState<FulfilmentManagementPage> createState() =>
      _FulfilmentManagementPageState();
}

class _FulfilmentManagementPageState
    extends ConsumerState<FulfilmentManagementPage> {
  VenueScope get _scope => ref.read(activeVenueScopeProvider)!;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 4,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Collection, delivery & courses'),
        bottom: const TabBar(
          tabs: [
            Tab(icon: Icon(Icons.storefront_outlined), text: 'Channels'),
            Tab(icon: Icon(Icons.room_service_outlined), text: 'Courses'),
            Tab(icon: Icon(Icons.people_outline), text: 'Customers'),
            Tab(
              icon: Icon(Icons.delivery_dining_outlined),
              text: 'Live orders',
            ),
          ],
        ),
      ),
      body: TabBarView(
        children: [
          _ChannelsTab(scope: _scope, venue: widget.venue),
          _CoursesTab(scope: _scope),
          _CustomersTab(scope: _scope),
          _FulfilmentOrdersTab(scope: _scope),
        ],
      ),
    ),
  );
}
