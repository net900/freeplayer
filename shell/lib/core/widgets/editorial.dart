import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Text tab with a short accent underline. Replaces pills for page-level
/// navigation so sections read as an index, not a row of buttons.
class UnderlineTab extends StatelessWidget {
  const UnderlineTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.count = 0,
    this.compact = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int count;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return InkWell(
      onTap: onTap,
      mouseCursor: SystemMouseCursors.click,
      child: Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.x2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize:
                        compact ? AppFontSize.xs : AppFontSize.bodyLg,
                    fontWeight:
                        selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? tokens.colors.text
                        : tokens.colors.text2,
                  ),
                ),
                if (count > 0) ...[
                  const SizedBox(width: AppSpacing.x1),
                  Text(
                    '$count',
                    style: TextStyle(
                      fontSize: AppFontSize.xxs,
                      color: tokens.colors.text3,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.x1),
            AnimatedContainer(
              duration: AppDuration.micro,
              height: 2,
              width: selected ? 18 : 0,
              decoration: BoxDecoration(
                color: tokens.colors.accent,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A horizontal row of [UnderlineTab]s on a hairline.
class UnderlineTabBar extends StatelessWidget {
  const UnderlineTabBar({
    super.key,
    required this.labels,
    required this.selected,
    required this.onPick,
    this.counts = const [],
    this.compact = false,
    this.trailing,
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onPick;
  final List<int> counts;
  final bool compact;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: tokens.colors.border),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < labels.length; i++) ...[
                    UnderlineTab(
                      label: labels[i],
                      selected: selected == i,
                      onTap: () => onPick(i),
                      count: i < counts.length ? counts[i] : 0,
                      compact: compact,
                    ),
                    if (i < labels.length - 1)
                      const SizedBox(width: AppSpacing.x6),
                  ],
                ],
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Filter option as text: selected options get accent text and an underline.
class FilterText extends StatelessWidget {
  const FilterText({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return InkWell(
      onTap: onTap,
      mouseCursor: SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.x1,
          vertical: 3,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: AppFontSize.xs,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? tokens.colors.accent : tokens.colors.text2,
            decoration:
                selected ? TextDecoration.underline : TextDecoration.none,
            decorationColor: tokens.colors.accent,
          ),
        ),
      ),
    );
  }
}

/// Section title with a thin rule filling the remaining width.
class SectionHeading extends StatelessWidget {
  const SectionHeading({
    super.key,
    required this.title,
    this.count = 0,
    this.trailing,
  });

  final String title;
  final int count;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Row(
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: AppFontSize.title,
            fontWeight: FontWeight.w700,
            color: tokens.colors.text,
          ),
        ),
        if (count > 0) ...[
          const SizedBox(width: AppSpacing.x2),
          Text(
            '$count',
            style: TextStyle(
              fontSize: AppFontSize.xs,
              color: tokens.colors.text3,
            ),
          ),
        ],
        const SizedBox(width: AppSpacing.x3),
        Expanded(
          child: Container(height: 1, color: tokens.colors.border),
        ),
        if (trailing != null) ...[
          const SizedBox(width: AppSpacing.x3),
          trailing!,
        ],
      ],
    );
  }
}
