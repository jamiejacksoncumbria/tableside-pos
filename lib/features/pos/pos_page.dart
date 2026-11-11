import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/safe_dialog.dart';
import '../../core/safe_modal_bottom_sheet.dart';
import '../../core/app_logger.dart';
import '../../core/date_formats.dart';
import '../../core/money.dart';
import '../../core/tenant_scope.dart';
import '../../core/training_mode.dart';
import '../../data/production_command_repository.dart';
import '../../offline/venue_hub_client_registry.dart';
import '../../offline/venue_hub_offline_view.dart';
import '../../offline/venue_hub_realtime_client.dart';
import '../auth/staff_pin_gate.dart';
import '../fulfilment/customer_editor.dart';
import '../fulfilment/fulfilment_domain.dart';
import '../fulfilment/fulfilment_repository.dart';
import '../notifications/notification_centre.dart';
import 'domain.dart';
import 'pos_controller.dart';
import 'pos_quick_search_field.dart';
import 'product_configuration_sheet.dart';

part 'widgets/pos_tables.dart';
part 'widgets/pos_menu.dart';
part 'widgets/pos_order_panel.dart';
part 'widgets/pos_checkout.dart';
part 'widgets/pos_order_location.dart';

class PosPage extends ConsumerStatefulWidget {
  const PosPage({super.key, required this.currencyCode});

  final String currencyCode;

  @override
  ConsumerState<PosPage> createState() => _PosPageState();
}

class _PosPageState extends ConsumerState<PosPage>
    with SingleTickerProviderStateMixin {
  bool _tablesExpanded = false;
  late final TabController _compactTabController;

  @override
  void initState() {
    super.initState();
    _compactTabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: ref.read(posCompactTabProvider),
    )..addListener(_compactTabChanged);
  }

  void _compactTabChanged() {
    if (_compactTabController.indexIsChanging ||
        _compactTabController.animation?.value !=
            _compactTabController.index.toDouble()) {
      return;
    }
    final index = _compactTabController.index;
    if (ref.read(posCompactTabProvider) != index) {
      ref.read(posCompactTabProvider.notifier).select(index);
    }
  }

  @override
  void dispose() {
    _compactTabController
      ..removeListener(_compactTabChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final compactTab = ref.watch(posCompactTabProvider);
    if (_compactTabController.index != compactTab &&
        !_compactTabController.indexIsChanging) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _compactTabController.index != compactTab) {
          _compactTabController.animateTo(compactTab);
        }
      });
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // Three simultaneously visible panels need both a genuinely wide and
        // tall workspace. On a phone or a compact Windows window, stacking
        // tables, menu and order made the menu grid receive almost no height
        // at all, despite its Firestore data having loaded successfully.
        if (constraints.maxWidth >= 1100 && constraints.maxHeight >= 700) {
          if (_tablesExpanded) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: _TablesPanel(
                currencyCode: widget.currencyCode,
                expanded: true,
                onToggleExpanded: () => setState(() => _tablesExpanded = false),
                onSelection: () => setState(() => _tablesExpanded = false),
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 238,
                  child: _TablesPanel(
                    currencyCode: widget.currencyCode,
                    onToggleExpanded: () =>
                        setState(() => _tablesExpanded = true),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(child: _MenuPanel(currencyCode: widget.currencyCode)),
                const SizedBox(width: 16),
                SizedBox(
                  width: 360,
                  child: _OrderPanel(currencyCode: widget.currencyCode),
                ),
              ],
            ),
          );
        }

        // Phones, tablets, and compact desktop windows use one full-height
        // workspace at a time. Menu is the default tab because it is the
        // primary waiter action; tables and the live order stay one tap away.
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Builder(
                builder: (context) {
                  final order = ref.watch(activeOrderProvider);
                  final pending = order.lines
                      .where((line) => !line.isSentToProduction)
                      .fold<int>(0, (total, line) => total + line.quantity);
                  final sent = order.lines
                      .where((line) => line.isSentToProduction)
                      .fold<int>(0, (total, line) => total + line.quantity);
                  final shownCount = pending > 0 ? pending : sent;
                  final badgeColor = pending > 0 ? Colors.red : Colors.green;
                  final showTabLabels = constraints.maxWidth >= 400;
                  return SizedBox(
                    // Keep navigation touchable while returning vertical room
                    // to the table, product and order workspaces on tablets.
                    height: 38,
                    child: TabBar(
                      controller: _compactTabController,
                      dividerHeight: 0,
                      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                      labelStyle: Theme.of(context).textTheme.labelLarge,
                      onTap: (index) => ref
                          .read(posCompactTabProvider.notifier)
                          .select(index),
                      tabs: [
                        Tab(
                          child: showTabLabels
                              ? const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.table_restaurant_rounded,
                                      size: 17,
                                    ),
                                    SizedBox(width: 4),
                                    Flexible(child: Text('Tables')),
                                  ],
                                )
                              : const Icon(
                                  Icons.table_restaurant_rounded,
                                  size: 18,
                                ),
                        ),
                        Tab(
                          child: showTabLabels
                              ? const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.restaurant_menu_rounded,
                                      size: 17,
                                    ),
                                    SizedBox(width: 4),
                                    Flexible(child: Text('Menu')),
                                  ],
                                )
                              : const Icon(
                                  Icons.restaurant_menu_rounded,
                                  size: 18,
                                ),
                        ),
                        Tab(
                          child: showTabLabels
                              ? Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    shownCount == 0
                                        ? const Icon(
                                            Icons.receipt_long_rounded,
                                            size: 17,
                                          )
                                        : Badge.count(
                                            count: shownCount,
                                            backgroundColor: badgeColor,
                                            child: const Icon(
                                              Icons.receipt_long_rounded,
                                              size: 17,
                                            ),
                                          ),
                                    const SizedBox(width: 4),
                                    const Flexible(child: Text('Order')),
                                  ],
                                )
                              : shownCount == 0
                              ? const Icon(Icons.receipt_long_rounded, size: 18)
                              : Badge.count(
                                  count: shownCount,
                                  backgroundColor: badgeColor,
                                  child: const Icon(
                                    Icons.receipt_long_rounded,
                                    size: 18,
                                  ),
                                ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 6),
              Expanded(
                child: TabBarView(
                  controller: _compactTabController,
                  children: [
                    _TablesPanel(
                      currencyCode: widget.currencyCode,
                      compact: true,
                    ),
                    _MenuPanel(currencyCode: widget.currencyCode),
                    _OrderPanel(currencyCode: widget.currencyCode),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
