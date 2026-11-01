import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/strings.dart';
import '../sp/models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'loading.dart';
import 'page_title.dart';

/// 12345 → 1.2万, 9876 → 9876. Used by the feed overlay and detail page.
String formatCount(int value) {
  if (value <= 0) return '0';
  if (value < 10000) return '$value';
  final wan = value / 10000;
  if (wan < 10) return '${wan.toStringAsFixed(1)}万';
  if (wan < 10000) return '${wan.round()}万';
  return '${(wan / 10000).toStringAsFixed(1)}亿';
}

/// Like [formatCount], but keeps one decimal below 100万 (76.8万 rather than
/// 77万). Used by the detail metric strip.
String formatCountPrecise(int value) {
  if (value <= 0) return '0';
  if (value < 10000) return '$value';
  final wan = value / 10000;
  if (wan < 100) return '${wan.toStringAsFixed(1)}万';
  if (wan < 10000) return '${wan.round()}万';
  return '${(wan / 10000).toStringAsFixed(1)}亿';
}

class ContentFrame extends StatelessWidget {
  const ContentFrame({super.key, required this.child, this.scrollable = false});

  final Widget child;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSizes.contentPadX,
        vertical: AppSizes.contentPadY,
      ),
      child: scrollable ? SingleChildScrollView(child: child) : child,
    );
  }
}

/// Reports the page title to the window chrome instead of drawing it in the
/// content area. Only [trailing] actions still render here.
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.trailing,
  });

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final action = trailing;
    return PageTitleBinding(
      title: title,
      child: action == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.x2),
              child: Align(alignment: Alignment.centerRight, child: action),
            ),
    );
  }
}

/// Wraps an async load with skeleton, empty and error states (PRD §5.7.6).
class AppAsyncView<T> extends StatefulWidget {
  const AppAsyncView({
    super.key,
    required this.load,
    required this.builder,
    this.isEmpty,
    this.empty,
    this.skeleton,
    this.unsupportedMessage,
  });

  final Future<T> Function() load;
  final Widget Function(BuildContext context, T value) builder;
  final bool Function(T value)? isEmpty;
  final Widget? empty;
  final Widget? skeleton;
  final String? unsupportedMessage;

  @override
  State<AppAsyncView<T>> createState() => _AppAsyncViewState<T>();
}

class _AppAsyncViewState<T> extends State<AppAsyncView<T>> {
  late Future<T> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.load();
  }

  void _reload() {
    setState(() {
      _future = widget.load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return LoadingView(
            skeleton: widget.skeleton ?? const SkeletonGrid(),
          );
        }
        if (snapshot.hasError) {
          return _ErrorPanel(error: snapshot.error!, onRetry: _reload);
        }
        final value = snapshot.data;
        if (value == null) {
          return widget.empty ??
              const StatePanel(
                icon: Icons.inbox_outlined,
                title: AppStrings.emptyTitle,
                body: AppStrings.emptyBody,
              );
        }
        if (widget.isEmpty?.call(value) ?? false) {
          return widget.empty ??
              const StatePanel(
                icon: Icons.inbox_outlined,
                title: AppStrings.emptyTitle,
                body: AppStrings.emptyBody,
              );
        }
        return widget.builder(context, value);
      },
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final traceId = error is SpException ? (error as SpException).traceId : '';
    final message = error is SpException
        ? (error as SpException).message
        : AppStrings.errorBody;
    return StatePanel(
      icon: Icons.error_outline,
      title: AppStrings.errorTitle,
      body: message,
      traceId: traceId,
      action: FilledButton.icon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh, size: 18),
        label: const Text(AppStrings.retry),
      ),
    );
  }
}

class StatePanel extends StatelessWidget {
  const StatePanel({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.action,
    this.traceId,
  });

  final IconData icon;
  final String title;
  final String? body;
  final Widget? action;
  final String? traceId;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final hasTrace = traceId != null && traceId!.isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.x6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: tokens.colors.text3),
            const SizedBox(height: AppSpacing.x3),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            if (body != null) ...[
              const SizedBox(height: AppSpacing.x2),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Text(
                  body!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: AppFontSize.body,
                    height: AppLineHeight.body,
                    color: tokens.colors.text2,
                  ),
                ),
              ),
            ],
            if (hasTrace) ...[
              const SizedBox(height: AppSpacing.x2),
              InkWell(
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: traceId!));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text(AppStrings.copied)),
                    );
                  }
                },
                child: Text(
                  'trace_id: $traceId',
                  style: TextStyle(
                    fontSize: AppFontSize.xxs,
                    color: tokens.colors.text3,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: AppSpacing.x4),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Grid used by every poster page.
class ItemGrid extends StatelessWidget {
  const ItemGrid({
    super.key,
    required this.children,
    this.maxCrossAxisExtent = 180,
    this.padding = const EdgeInsets.all(AppSpacing.x1),
  });

  final List<Widget> children;
  final double maxCrossAxisExtent;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: padding,
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: maxCrossAxisExtent,
        mainAxisSpacing: AppSpacing.x4,
        crossAxisSpacing: AppSpacing.x4,
        childAspectRatio: AppSizes.posterAspect,
      ),
      itemCount: children.length,
      itemBuilder: (context, index) => children[index],
    );
  }
}
