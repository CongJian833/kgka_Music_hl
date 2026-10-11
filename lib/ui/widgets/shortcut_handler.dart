import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

/// 桌面快捷键处理器（Windows）。
///
/// 包在应用根部，监听键盘：
/// - F11  全屏 / 退出全屏
/// - Esc  退出全屏
///
/// 使用 autofocus 的 Focus 让顶层持续接收键盘事件，输入框失焦时也能生效。
/// 非 Windows 平台直接透传 child，不影响 Android。
class ShortcutHandler extends StatefulWidget {
  const ShortcutHandler({super.key, required this.child});

  final Widget child;

  @override
  State<ShortcutHandler> createState() => _ShortcutHandlerState();
}

class _ShortcutHandlerState extends State<ShortcutHandler> {
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    if (!Platform.isWindows) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (!Platform.isWindows) return KeyEventResult.ignored;

    final isF11 = event.logicalKey == LogicalKeyboardKey.f11;
    final isEsc = event.logicalKey == LogicalKeyboardKey.escape;
    if (!isF11 && !isEsc) return KeyEventResult.ignored;

    unawaited(_handleShortcut(isF11, isEsc));
    node.requestFocus();
    return KeyEventResult.handled;
  }

  Future<void> _handleShortcut(bool isF11, bool isEsc) async {
    final full = await windowManager.isFullScreen();
    if (isF11) {
      await windowManager.setFullScreen(!full);
    } else if (isEsc && full) {
      await windowManager.setFullScreen(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return widget.child;
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      canRequestFocus: true,
      onKeyEvent: _onKey,
      child: widget.child,
    );
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }
}