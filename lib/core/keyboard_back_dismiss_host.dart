import 'package:flutter/material.dart';

/// Gives every text-entry screen the same predictable system-Back behaviour.
///
/// Android normally asks Flutter to pop a route even while an [EditableText]
/// still owns focus. Feature-level PopScopes may then clear a search, close a
/// category, or leave a sheet at the same time as the keyboard disappears.
/// This binding observer runs before the Navigator: the first Back press only
/// releases a focused text editor; a later Back press is left to normal route
/// navigation. It also covers dialogs and pages added after app startup.
class KeyboardBackDismissHost extends StatefulWidget {
  const KeyboardBackDismissHost({super.key, required this.child});

  final Widget child;

  @override
  State<KeyboardBackDismissHost> createState() =>
      _KeyboardBackDismissHostState();
}

class _KeyboardBackDismissHostState extends State<KeyboardBackDismissHost>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Future<bool> didPopRoute() async {
    final focus = FocusManager.instance.primaryFocus;
    final focusContext = focus?.context;
    final ownsTextInput =
        focus?.hasFocus == true &&
        focusContext != null &&
        (focusContext.widget is EditableText ||
            focusContext.findAncestorWidgetOfExactType<EditableText>() != null);
    if (!ownsTextInput) return false;

    focus!.unfocus(disposition: UnfocusDisposition.scope);
    return true;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
