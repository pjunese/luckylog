import 'package:flutter/material.dart';

/// Keep transient feedback current instead of queuing old completion messages.
void dismissAppSnackBars(BuildContext context) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.clearSnackBars();
  messenger?.removeCurrentSnackBar();
}

void showAppSnackBar(
  BuildContext context, {
  required Widget content,
  SnackBarAction? action,
  Duration? duration,
}) {
  final messenger = ScaffoldMessenger.of(context);
  dismissAppSnackBars(context);
  messenger.showSnackBar(
    SnackBar(
      content: content,
      action: action,
      duration: duration ?? Duration(seconds: action == null ? 4 : 6),
      // Flutter defaults action snackbars to persistent. Keep them timed for
      // ordinary use, but allow screen-reader users time to reach the action.
      persist: action != null && MediaQuery.accessibleNavigationOf(context),
      showCloseIcon: true,
    ),
  );
}
