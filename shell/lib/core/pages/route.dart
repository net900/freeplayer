import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Short fade-through route. The outgoing page stays painted underneath while
/// the opaque page fades in, which reads as a scene transition instead of a
/// hard cut. The player uses its own zero-duration route.
Route<T> instantRoute<T>(WidgetBuilder builder) {
  return PageRouteBuilder<T>(
    transitionDuration: AppDuration.page,
    reverseTransitionDuration: AppDuration.page,
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.012),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// Paints the app background behind a pushed page so nothing below can show
/// through in the first frame.
class OpaquePage extends StatelessWidget {
  const OpaquePage({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Material (not just a colour box): pages pushed on the root navigator
    // have no Scaffold above them, and InkWell/Text need a Material ancestor.
    return Material(
      color: AppTokens.of(context).colors.bg,
      child: child,
    );
  }
}
