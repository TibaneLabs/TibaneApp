import 'package:flutter/material.dart';

/// Wraps a bottom-aligned form — a [Column] that ends in a `Spacer()` then a
/// pinned button — so the button stays reachable when the on-screen keyboard
/// shrinks the viewport.
///
/// With enough room the `Spacer` bottom-aligns the button as before; when the
/// keyboard would cover it, the whole form scrolls instead of throwing a
/// "RenderFlex overflowed" error. Use it in place of a `Padding(child: Column(
/// … Spacer(), button))` body.
class KeyboardSafeForm extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;

  const KeyboardSafeForm({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(24),
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          padding: padding,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              // Keep the column at least viewport-tall (minus our own
              // padding) so the Spacer can still bottom-align the button when
              // there's room; the scroll view takes over when there isn't.
              minHeight: (constraints.maxHeight - padding.vertical).clamp(
                0.0,
                double.infinity,
              ),
            ),
            child: IntrinsicHeight(child: child),
          ),
        );
      },
    );
  }
}
