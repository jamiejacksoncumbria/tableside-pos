import 'package:flutter/material.dart';

/// Opens a Material dialog and completes only after its overlay is removed.
///
/// Flutter's standard [showDialog] future completes when `Navigator.pop` is
/// called, while the reverse transition and semantics tree may still be
/// active. Opening another dialog, rebuilding the POS shell, or disposing a
/// controller in that interval can leave dirty semantics parent data and make
/// the application unusable in debug builds. TableSide chains several dialogs
/// (for example location -> customer -> delivery details), so every app dialog
/// uses this route-lifecycle boundary.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  TraversalEdgeBehavior? traversalEdgeBehavior,
  bool? requestFocus,
}) async {
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  final route = DialogRoute<T>(
    context: context,
    builder: builder,
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor ?? Colors.black54,
    barrierLabel: barrierLabel,
    useSafeArea: useSafeArea,
    settings: routeSettings,
    themes: themes,
    anchorPoint: anchorPoint,
    traversalEdgeBehavior:
        traversalEdgeBehavior ?? TraversalEdgeBehavior.closedLoop,
    requestFocus: requestFocus,
  );
  final result = await navigator.push<T>(route);
  await route.completed;
  return result;
}
