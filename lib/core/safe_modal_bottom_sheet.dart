import 'package:flutter/material.dart';

/// Opens a Material modal bottom sheet and completes only after its route has
/// removed every overlay entry.
///
/// The framework's [showModalBottomSheet] future resolves as soon as the route
/// is popped, while its reverse animation can still own overlay GlobalKeys.
/// Checkout owns several controllers and can also trigger a following payment
/// summary, so waiting for [TransitionRoute.completed] prevents controller
/// disposal or a subsequent route from overlapping that retiring overlay.
Future<T?> showAppModalBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool useRootNavigator = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool? showDragHandle,
  bool useSafeArea = false,
}) async {
  assert(debugCheckHasMediaQuery(context));
  assert(debugCheckHasMaterialLocalizations(context));

  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  final localizations = MaterialLocalizations.of(context);
  final route = ModalBottomSheetRoute<T>(
    builder: builder,
    capturedThemes: InheritedTheme.capture(
      from: context,
      to: navigator.context,
    ),
    isScrollControlled: isScrollControlled,
    barrierLabel: localizations.scrimLabel,
    barrierOnTapHint: localizations.scrimOnTapHint(
      localizations.bottomSheetLabel,
    ),
    modalBarrierColor: Theme.of(context).bottomSheetTheme.modalBarrierColor,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    showDragHandle: showDragHandle,
    useSafeArea: useSafeArea,
  );
  final result = await navigator.push<T>(route);
  await route.completed;
  return result;
}
