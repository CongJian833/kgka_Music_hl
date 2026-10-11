import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

/// 沉浸式窗口顶栏：替代系统标题栏。
///
/// 隐藏系统标题栏后（见 DesktopController.attach 的 setTitleBarStyle(hidden)），
/// 由本组件承载：整条可拖拽移动窗口 + 右侧最小化/最大化/关闭按钮。
/// 背景透明，跟随所在层的应用背景色，从而"融入"主窗口。
///
/// 悬停高亮统一由本组件管理：用单个 [Listener] 按指针实时位置计算命中按钮，
/// 指针离开按钮区即清除高亮。相比各按钮各自用 MouseRegion（onExit 在快速划过时
/// 偶发丢失），可避免高亮残留成一块"颜色覆盖"。
class WindowTitleBar extends StatefulWidget {
  const WindowTitleBar({super.key, this.height = 40});

  final double height;

  static const double _buttonWidth = 46;

  /// 右上角窗口控制按钮区占据的宽度（3 × 46）。
  /// 供各页面顶部栏按此在右侧让位，避免与窗口按钮重叠。
  static const double controlAreaRight = _buttonWidth * 3;

  @override
  State<WindowTitleBar> createState() => _WindowTitleBarState();
}

class _WindowTitleBarState extends State<WindowTitleBar> {
  /// 当前悬停的按钮索引（0=最小化，1=最大化，2=关闭），-1 表示无。
  int _hoverIndex = -1;

  void _setHover(int index) {
    if (index != _hoverIndex && mounted) {
      setState(() => _hoverIndex = index);
    }
  }

  /// 根据指针在按钮区内的实时位置计算命中按钮；离开按钮区则清除高亮。
  void _handleHover(PointerHoverEvent event) {
    final x = event.localPosition.dx;
    final y = event.localPosition.dy;
    if (y < 0 ||
        y >= widget.height ||
        x < 0 ||
        x >= WindowTitleBar.controlAreaRight) {
      _setHover(-1);
      return;
    }
    final index = (x / WindowTitleBar._buttonWidth).floor();
    _setHover(index.clamp(0, 2));
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 顶部可拖拽条（透明，覆盖窗口顶部一条，***右端让出按钮区***），右侧按钮区独立不参与拖拽，避免手势冲突。
        Positioned(
          top: 0,
          left: 0,
          right: WindowTitleBar.controlAreaRight,
          height: widget.height,
          child: DragToMoveArea(child: const SizedBox.expand()),
        ),
        // 右上角窗口控制按钮（始终覆盖在页面内容之上）。
        Positioned(
          top: 0,
          right: 0,
          height: widget.height,
          // MouseRegion 只在"整个按钮区"这一个区域上响应移入/移出，
          // onExit 可靠清除残留高亮；区内命中由内部的 Listener 实时计算。
          child: MouseRegion(
            onExit: (_) => _setHover(-1),
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerHover: _handleHover,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _TitleBarButton(
                    width: WindowTitleBar._buttonWidth,
                    icon: Icons.remove,
                    isHovered: _hoverIndex == 0,
                    onTap: () => windowManager.minimize(),
                  ),
                  _MaximizeButton(
                    width: WindowTitleBar._buttonWidth,
                    isHovered: _hoverIndex == 1,
                  ),
                  _TitleBarButton(
                    width: WindowTitleBar._buttonWidth,
                    icon: Icons.close,
                    isClose: true,
                    isHovered: _hoverIndex == 2,
                    onTap: () => windowManager.close(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 最大化 / 还原按钮：根据窗口当前是否最大化切换图标与行为。
class _MaximizeButton extends StatefulWidget {
  const _MaximizeButton({required this.width, required this.isHovered});

  final double width;
  final bool isHovered;

  @override
  State<_MaximizeButton> createState() => _MaximizeButtonState();
}

class _MaximizeButtonState extends State<_MaximizeButton> {
  bool _maximized = false;

  /// Native (Windows runner) pushes window state transitions over this channel,
  /// replacing the previous 400ms polling so the icon updates instantly.
  static const MethodChannel _windowStateChannel =
      MethodChannel('ka_music/window_state');

  @override
  void initState() {
    super.initState();
    _windowStateChannel.setMethodCallHandler(_onNativeMessage);
    _refresh();
  }

  @override
  void dispose() {
    _windowStateChannel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<dynamic> _onNativeMessage(MethodCall call) async {
    // Any window sizing / maximize / fullscreen transition.
    if (call.method == 'windowStateChanged') {
      await _refresh();
    }
  }

  Future<void> _refresh() async {
    bool state;
    try {
      state = await windowManager.isMaximized();
    } catch (_) {
      state = false;
    }
    if (mounted && state != _maximized) setState(() => _maximized = state);
  }

  void _onPressed() {
    if (_maximized) {
      windowManager.restore();
    } else {
      windowManager.maximize();
    }
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return _TitleBarButton(
      width: widget.width,
      icon: _maximized ? Icons.filter_none : Icons.crop_square,
      isHovered: widget.isHovered,
      onTap: _onPressed,
    );
  }
}

/// 单个窗口控制按钮：高亮由上层（[WindowTitleBar]）统一按指针位置驱动，
/// 关闭按钮高亮为红色，其余为半透明白晶。
///
/// 不使用 Tooltip：按钮位于窗口右边缘，Tooltip 会翻转显示在按钮左/旁侧且可被
/// 点击 dismiss，易残留成顶栏的浅色覆盖条。
class _TitleBarButton extends StatelessWidget {
  const _TitleBarButton({
    required this.width,
    required this.icon,
    this.onTap,
    this.isClose = false,
    this.isHovered = false,
  });

  final double width;
  final IconData icon;
  final VoidCallback? onTap;
  final bool isClose;
  final bool isHovered;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hovered = isHovered;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: width,
        height: double.infinity,
        color: !hovered
            ? Colors.transparent
            : (isClose
                  ? Colors.redAccent.shade400
                  : scheme.onSurface.withValues(alpha: .10)),
        child: Icon(
          icon,
          size: 15,
          color: hovered && isClose
              ? Colors.white
              : scheme.onSurface.withValues(alpha: .75),
        ),
      ),
    );
  }
}