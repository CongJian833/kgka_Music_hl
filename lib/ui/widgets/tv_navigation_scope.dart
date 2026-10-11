import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/player_controller.dart';
import 'tv_focus.dart';

/// ====【新增/Android TV 遥控器适配】====
///
/// 根级遥控器/键盘作用域，放在 `MaterialApp.builder` 里包住所有页面。
///
/// 职责（只做"全局且与页面无关"的部分）：
///   1. 方向键（DPAD_UP/DOWN/LEFT/RIGHT）→ **焦点遍历**（Android TV 标准）；
///   2. 确定键（DPAD_CENTER / ENTER）→ 交给当前聚焦组件自己处理
///      （见 [TvFocusable]），这里不拦截；
///   3. 媒体键（播放/暂停/上一首/下一首）→ 直接控制播放，与系统媒体会话一致；
///   4. 与 Windows 桌面快捷键的差异处理：桌面端左右键是"切歌"，
///      TV 上是"遍历焦点"，二者互不干扰（见 [TvFocusMode.enabled]）。
///
/// 页面若需要覆盖方向键语义（例如播放器页：左右键 = ±5 秒），应在页面内再包一层
/// `Shortcuts`——Flutter 会优先匹配最近的 Shortcuts 作用域。
class TvNavigationScope extends StatefulWidget {
  const TvNavigationScope({
    super.key,
    required this.child,
    required this.player,
  });

  final Widget child;

  /// 用于媒体键控制。
  final PlayerController player;

  @override
  State<TvNavigationScope> createState() => _TvNavigationScopeState();
}

class _TvNavigationScopeState extends State<TvNavigationScope> {
  @override
  void initState() {
    super.initState();
    if (TvFocusMode.debugLogFocus) {
      FocusManager.instance.addListener(_logFocus);
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_logFocus);
    super.dispose();
  }

  void _logFocus() {
    final f = FocusManager.instance.primaryFocus;
    if (f == null) {
      debugPrint('[TV_FOCUS_NODE] null');
      return;
    }
    final chain = <String>[];
    chain.add('FOCUS:${f.context?.widget.runtimeType}');
    f.context?.visitAncestorElements((el) {
      final t = el.widget.runtimeType.toString();
      chain.add(t);
      return chain.length < 40;
    });
    debugPrint('[TV_FOCUS_NODE] ${chain.join(' < ')}');
  }

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        // 媒体键：与遥控器上的播放/暂停、上一首、下一首按钮对应。
        _TvMediaPlayPauseIntent: CallbackAction<_TvMediaPlayPauseIntent>(
          onInvoke: (_) {
            try {
              widget.player.togglePlay();
            } catch (_) {}
            return null;
          },
        ),
        _TvMediaNextIntent: CallbackAction<_TvMediaNextIntent>(
          onInvoke: (_) {
            try {
              widget.player.next();
            } catch (_) {}
            return null;
          },
        ),
        _TvMediaPreviousIntent: CallbackAction<_TvMediaPreviousIntent>(
          onInvoke: (_) {
            try {
              widget.player.previous();
            } catch (_) {}
            return null;
          },
        ),
      },
      child: Shortcuts(
        shortcuts: <ShortcutActivator, Intent>{
          // 媒体键（Android 遥控器/键盘都会发这些 logicalKey）
          const SingleActivator(LogicalKeyboardKey.mediaPlayPause):
              const _TvMediaPlayPauseIntent(),
          const SingleActivator(LogicalKeyboardKey.mediaPlay):
              const _TvMediaPlayPauseIntent(),
          const SingleActivator(LogicalKeyboardKey.mediaPause):
              const _TvMediaPlayPauseIntent(),
          const SingleActivator(LogicalKeyboardKey.mediaTrackNext):
              const _TvMediaNextIntent(),
          const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious):
              const _TvMediaPreviousIntent(),
        },
        // 包一层 Focus，保证"没有任何可聚焦组件"的页面也能接收按键
        // （避免遥控器按键丢失导致"完全没反应"）。
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          // ====【诊断/TV 焦点】==== 记录所有按键 + 当前焦点节点，排查遥控器导航。
          onKeyEvent: (node, event) {
            if (TvFocusMode.debugLogFocus && event is KeyDownEvent) {
              final f = FocusManager.instance.primaryFocus;
              debugPrint('[TV_KEY] ${event.logicalKey.keyLabel} '
                  'focus=${f?.debugLabel ?? f?.context?.widget.runtimeType ?? 'null'}');
            }
            return KeyEventResult.ignored;
          },
          child: widget.child,
        ),
      ),
    );
  }
}

class _TvMediaPlayPauseIntent extends Intent {
  const _TvMediaPlayPauseIntent();
}

class _TvMediaNextIntent extends Intent {
  const _TvMediaNextIntent();
}

class _TvMediaPreviousIntent extends Intent {
  const _TvMediaPreviousIntent();
}
