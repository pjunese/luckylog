import 'package:flutter/material.dart';

/// Keeps reading content away from landscape cutouts and comfortably sized on
/// tablets/foldables, while allowing the page's own scrolling to fill the height.
class AppContentFrame extends StatelessWidget {
  const AppContentFrame({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    bottom: false,
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: SizedBox.expand(child: child),
      ),
    ),
  );
}
