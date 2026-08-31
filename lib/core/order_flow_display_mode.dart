import 'package:flutter_riverpod/flutter_riverpod.dart';

final orderFlowDisplayActiveProvider =
    NotifierProvider<OrderFlowDisplayModeController, bool>(
      OrderFlowDisplayModeController.new,
    );

class OrderFlowDisplayModeController extends Notifier<bool> {
  @override
  bool build() => false;

  void setActive(bool active) => state = active;
}
