import 'package:flutter/material.dart';

import 'tv_focus.dart';
import 'tv_nav_bar.dart' show TvNavDestination;

/// ====【新增/Android TV 遥控器适配】====
///
/// 一组"遥控器友好"的基础控件：都保证 **单一焦点落点** + **明显的焦点高亮** +
/// **确定键（D-pad 中心/Enter）触发**，同时保留鼠标/触摸点击能力。
///
/// 页面里凡是"图标按钮 / 文字按钮 / 标签芯片 / 可点区域"都建议改用这里的控件，
/// 而不是直接使用 `IconButton` / `ChoiceChip` / `GestureDetector`——
/// 后几者在遥控器上要么高亮太弱，要么根本不能聚焦。

/// 遥控器友好的图标按钮。
class TvIconButton extends StatelessWidget {
  const TvIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.iconSize = 24,
    this.color,
    this.autofocus = false,
    this.radius = 12,
    this.padding = const EdgeInsets.all(8),
  });

  final IconData icon;

  /// 为 null 时按钮不可用（仍保留占位，不可聚焦）。
  final VoidCallback? onTap;
  final String? tooltip;
  final double iconSize;
  final Color? color;
  final bool autofocus;
  final double radius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? Theme.of(context).colorScheme.onSurface;
    final enabled = onTap != null;
    final button = TvFocusTarget(
      onSelect: onTap,
      autofocus: autofocus,
      canRequestFocus: enabled,
      builder: (context, focused) => TvFocusHighlight(
        focused: focused,
        radius: radius,
        scale: 1.0,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(radius),
          child: Padding(
            padding: padding,
            child: Icon(
              icon,
              size: iconSize,
              color: enabled
                  ? effectiveColor
                  : effectiveColor.withValues(alpha: .38),
            ),
          ),
        ),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

/// 遥控器友好的文字按钮（用于"清空/取消/确定"等）。
class TvTextButton extends StatelessWidget {
  const TvTextButton({
    super.key,
    required this.label,
    required this.onTap,
    this.color,
    this.autofocus = false,
    this.radius = 12,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
  });

  final String label;
  final VoidCallback? onTap;
  final Color? color;
  final bool autofocus;
  final double radius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final effectiveColor = color ?? scheme.primary;
    return TvFocusTarget(
      onSelect: onTap,
      autofocus: autofocus,
      canRequestFocus: onTap != null,
      builder: (context, focused) => TvFocusHighlight(
        focused: focused,
        radius: radius,
        scale: 1.0,
        color: effectiveColor,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(radius),
          child: Padding(
            padding: padding,
            child: Text(
              label,
              style: TextStyle(
                color: onTap != null
                    ? effectiveColor
                    : effectiveColor.withValues(alpha: .38),
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 遥控器友好的标签芯片（用于顶部标签导航，替代 `ChoiceChip`）。
class TvChipButton extends StatelessWidget {
  const TvChipButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.autofocus = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TvFocusTarget(
      onSelect: onTap,
      autofocus: autofocus,
      builder: (context, focused) => TvFocusHighlight(
        focused: focused,
        radius: 14,
        scale: 1.0,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primary.withValues(alpha: .18)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 17,
                fontWeight: selected ? FontWeight.w900 : FontWeight.w600,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 遥控器友好的"可点区域"：把任意自绘内容（如搜索胶囊）变成可聚焦 + 可确定键触发。
class TvTapArea extends StatelessWidget {
  const TvTapArea({
    super.key,
    required this.onTap,
    required this.child,
    this.autofocus = false,
    this.radius = 14,
  });

  final VoidCallback onTap;
  final Widget child;
  final bool autofocus;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return TvFocusTarget(
      onSelect: onTap,
      autofocus: autofocus,
      builder: (context, focused) => TvFocusHighlight(
        focused: focused,
        radius: radius,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(radius),
          child: child,
        ),
      ),
    );
  }
}

/// 竖向的遥控器友好导航栏（用于宽屏 / TV 的左侧导航，替代 `NavigationRail`）。
class TvNavRail extends StatelessWidget {
  const TvNavRail({
    super.key,
    required this.currentIndex,
    required this.onSelect,
    required this.destinations,
  });

  final int currentIndex;
  final ValueChanged<int> onSelect;
  final List<TvNavDestination> destinations;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 96,
      color: scheme.surfaceContainerLow,
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 16),
            for (var i = 0; i < destinations.length; i++)
              _TvRailItem(
                destination: destinations[i],
                selected: i == currentIndex,
                onSelect: () => onSelect(i),
              ),
          ],
        ),
      ),
    );
  }
}

class _TvRailItem extends StatelessWidget {
  const _TvRailItem({
    required this.destination,
    required this.selected,
    required this.onSelect,
  });

  final TvNavDestination destination;
  final bool selected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TvFocusTarget(
        onSelect: onSelect,
        builder: (context, focused) => TvFocusHighlight(
          focused: focused,
          radius: 14,
          scale: 1.0,
          child: InkWell(
            onTap: onSelect,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    selected
                        ? (destination.activeIcon ?? destination.icon)
                        : destination.icon,
                    color: selected ? scheme.primary : scheme.onSurface,
                    size: 26,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    destination.label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                      color: selected ? scheme.primary : scheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
