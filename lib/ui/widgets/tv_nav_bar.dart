import 'package:flutter/material.dart';

import 'tv_focus.dart';

/// ====【新增/Android TV 遥控器适配】====
///
/// 遥控器友好的底部导航栏。替换 `BottomNavigationBar`：
/// 后者的 item 无法被 D-pad 稳定聚焦/遍历；TV 上每一项都必须是独立焦点落点。
///
/// 行为：
///   * 左/右键在各项之间移动焦点（几何遍历）；
///   * 确定键（D-pad 中心）＝ 选择该项并切换页面；
///   * 当前项用主题色 + 填充背景表示"已选中"，焦点项额外加高亮边框。
class TvNavDestination {
  const TvNavDestination({
    required this.icon,
    required this.label,
    this.activeIcon,
  });

  final IconData icon;
  final IconData? activeIcon;
  final String label;
}

class TvBottomNavBar extends StatelessWidget {
  const TvBottomNavBar({
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
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: dark
            ? scheme.surfaceContainerHighest.withValues(alpha: .72)
            : scheme.surfaceContainerHighest.withValues(alpha: .64),
        border: Border(
          top: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: .38),
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            for (var i = 0; i < destinations.length; i++)
              _TvNavItem(
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

class _TvNavItem extends StatelessWidget {
  const _TvNavItem({
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
    return TvFocusTarget(
      onSelect: onSelect,
      builder: (context, focused) => TvFocusHighlight(
        focused: focused,
        radius: 14,
        scale: 1.0,
        child: InkWell(
          onTap: onSelect,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  selected
                      ? (destination.activeIcon ?? destination.icon)
                      : destination.icon,
                  color: selected ? scheme.primary : scheme.onSurface,
                ),
                const SizedBox(height: 2),
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
    );
  }
}
