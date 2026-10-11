import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// ====【新增/Android TV 遥控器适配】====
///
/// 目标：按 Android TV 标准支持方向键（D-pad）与确定键：
///   * **遍历顺序**：一个页面内先按"行"从上到下，行内从左到右 —— 交给
///     `FocusTraversalOrder` / 几何遍历策略处理（见页面级的 [TvFocusScope]）；
///   * **视觉焦点**：10 英尺 UI 需要明显的高亮边框，见 [TvFocusHighlight]；
///   * **确定键 = 点击**：把 DPAD_CENTER / ENTER / SELECT 映射为 onTap，
///     见 [TvFocusable]；
///   * **初始焦点**：页面进入后要有第一落点，见 [TvFocusScope]。
///
/// 设计取舍：
///   * 不引入第三方 TV 框架；全部基于 Flutter 内建 Focus/Intent/Actions。
///   * 焦点高亮默认只在"键盘/遥控器交互"下显示（见 [TvFocusMode] 的
///     `enabled`），桌面端鼠标点击不会出现刺眼边框。
///   * 全部 API 在非 TV 设备上无副作用（只是普通 Focus 包装）。

/// 遥控器上被当作"确定"的按键集合。
final Set<LogicalKeyboardKey> tvSelectKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.select, // DPAD_CENTER
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.numpadEnter,
  LogicalKeyboardKey.gameButtonA,
};

/// 遥控器"返回"键（Android 上通常由系统 pop 路由处理，这里用于页面内自定义返回）。
final Set<LogicalKeyboardKey> tvBackKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.escape,
  LogicalKeyboardKey.goBack,
};

/// 全局 TV 交互开关/状态。
///
/// `enabled` 由 main 在启动时根据平台设置（见 `main.dart`）：
/// Android 全部开启（车机/TV/手机都可能接遥控器或键盘），桌面端默认关闭以避免
/// 鼠标点击后出现焦点框。
class TvFocusMode {
  TvFocusMode._();

  /// 是否显示焦点高亮与启用 TV 行为。
  static bool enabled = false;

  /// 是否把方向键当作"遍历焦点"（TV 标准行为）。
  /// 播放器页会把左右键改成"±5 秒"，由页面自行覆盖 Shortcuts。
  static bool directionalTraversal = true;

  /// 焦点高亮的基础参数（10 英尺 UI：底色 + 边框 + 轻微放大）。
  static const double highlightBorderWidth = 2.5;
  static const double highlightRadius = 14;
  static const double highlightScale = 1.03;

  /// 是否处于"给用户看焦点"的状态。默认跟随 [enabled]。
  static bool get highlightVisible => enabled;

  /// 是否把焦点变化打到日志（排查遥控器导航用）。
  static bool debugLogFocus = false;
}

/// 焦点高亮样式：包裹任意子组件，聚焦时显示边框/底色/轻微放大。
///
/// 与可点击组件配合使用，避免各页面重复写高亮逻辑：
/// ```dart
/// TvFocusHighlight(
///   focused: focused,
///   radius: 14,
///   child: card,
/// )
/// ```
class TvFocusHighlight extends StatelessWidget {
  const TvFocusHighlight({
    super.key,
    required this.focused,
    required this.child,
    this.radius = TvFocusMode.highlightRadius,
    this.color,
    this.scale = TvFocusMode.highlightScale,
    this.glow = true,
  });

  /// 当前是否聚焦。
  final bool focused;

  final Widget child;
  final double radius;

  /// 高亮色；默认取主题的 primary。
  final Color? color;

  /// 聚焦时的放大倍数（1.0 = 不放大）。
  final double scale;

  /// 是否叠加外发光（TV 上更醒目；低端设备可关）。
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final highlight = color ?? scheme.primary;
    final show = focused && TvFocusMode.highlightVisible;

    Widget result = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: show ? highlight : Colors.transparent,
          width: TvFocusMode.highlightBorderWidth,
        ),
        boxShadow: show && glow
            ? <BoxShadow>[
                BoxShadow(
                  color: highlight.withValues(alpha: 0.45),
                  blurRadius: 16,
                  spreadRadius: 1,
                ),
              ]
            : const <BoxShadow>[],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: child,
      ),
    );

    if (show && scale != 1.0) {
      result = AnimatedScale(
        scale: scale,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: result,
      );
    }
    return result;
  }
}

/// 让一段 UI 可被遥控器聚焦并在确定键（D-pad 中心/Enter）时触发 [onTap]。
///
/// 内部用 [Focus] + `onKeyEvent`：只处理"确定/返回"，方向键一律交还框架做遍历，
/// 这样不会破坏 Flutter 内建的几何遍历顺序（上→下、左→右）。
///
/// [autofocus] 用于页面首个可聚焦元素；同一作用域内只应有一个为 true。
class TvFocusable extends StatefulWidget {
  const TvFocusable({
    super.key,
    required this.child,
    this.onTap,
    this.onFocusChange,
    this.autofocus = false,
    this.focusNode,
    this.canRequestFocus = true,
    this.consumeBack = false,
    this.onBack,
    this.radius = TvFocusMode.highlightRadius,
    this.scale = TvFocusMode.highlightScale,
    this.highlightColor,
    this.glow = true,
    this.highlightChild = true,
  });

  /// 内容；若 [highlightChild] 为 true，会自动套 [TvFocusHighlight]。
  final Widget child;

  /// 确定键/点击触发。为 null 时仍可聚焦（用于纯展示的落点）。
  final VoidCallback? onTap;

  /// 焦点变化回调（页面可用它做滚动跟随等）。
  final ValueChanged<bool>? onFocusChange;

  final bool autofocus;

  /// 外部传入的 focusNode（需要主动 requestFocus 时用）。
  final FocusNode? focusNode;

  final bool canRequestFocus;

  /// 是否拦截返回键并调用 [onBack]（默认 false：交还框架 pop 路由）。
  final bool consumeBack;
  final VoidCallback? onBack;

  final double radius;
  final double scale;
  final Color? highlightColor;
  final bool glow;

  /// 是否由本组件负责画高亮（嵌套使用时置 false，交给外层统一画）。
  final bool highlightChild;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  late FocusNode _node;
  bool _ownsNode = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _attachNode(widget.focusNode);
  }

  void _attachNode(FocusNode? external) {
    if (external != null) {
      _node = external;
      _ownsNode = false;
    } else {
      _node = FocusNode(debugLabel: 'tv-focusable');
      _ownsNode = true;
    }
    _node.addListener(_handleFocus);
  }

  void _handleFocus() {
    if (!mounted) return;
    setState(() => _focused = _node.hasFocus);
    if (TvFocusMode.debugLogFocus) {
      debugPrint('[TV_FOCUS] focusable focused=${_node.hasFocus}');
    }
    widget.onFocusChange?.call(_node.hasFocus);
  }

  @override
  void didUpdateWidget(covariant TvFocusable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      _node.removeListener(_handleFocus);
      if (_ownsNode) _node.dispose();
      _attachNode(widget.focusNode);
      _focused = _node.hasFocus;
    }
  }

  @override
  void dispose() {
    _node.removeListener(_handleFocus);
    if (_ownsNode) _node.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // 确定键 → 等同点击。
    if (tvSelectKeys.contains(event.logicalKey)) {
      if (widget.onTap == null) return KeyEventResult.ignored;
      widget.onTap!.call();
      return KeyEventResult.handled;
    }
    // 返回键：仅当显式要求接管时处理，否则交还框架（pop 路由/退出）。
    if (widget.consumeBack && tvBackKeys.contains(event.logicalKey)) {
      final cb = widget.onBack;
      if (cb == null) return KeyEventResult.ignored;
      cb();
      return KeyEventResult.handled;
    }
    // 方向键不拦截：交给 Flutter 内建遍历策略（几何顺序 = 上→下、左→右）。
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    Widget content = widget.child;
    if (widget.highlightChild) {
      content = TvFocusHighlight(
        focused: _focused,
        radius: widget.radius,
        scale: widget.scale,
        color: widget.highlightColor,
        glow: widget.glow,
        child: content,
      );
    }
    return Focus(
      focusNode: _node,
      autofocus: widget.autofocus,
      canRequestFocus: widget.canRequestFocus,
      onKeyEvent: _onKey,
      child: content,
    );
  }
}

/// 页面级焦点作用域：
///   * 进入页面后自动把焦点交给第一个可聚焦元素（[autofocusFirstChild]）；
///   * 离开再回来时恢复到上次聚焦的元素（[restoreFocus]）；
///   * 保证页面内有一个 [FocusTraversalGroup]，使遍历限定在本页（弹窗/底栏除外）。
class TvFocusScope extends StatefulWidget {
  const TvFocusScope({
    super.key,
    required this.child,
    this.autofocusFirstChild = true,
    this.restoreFocus = true,
    this.debugLabel,
  });

  final Widget child;
  final bool autofocusFirstChild;
  final bool restoreFocus;
  final String? debugLabel;

  @override
  State<TvFocusScope> createState() => _TvFocusScopeState();
}

class _TvFocusScopeState extends State<TvFocusScope> {
  static final Map<String, FocusNode?> _memorized = <String, FocusNode?>{};

  @override
  void initState() {
    super.initState();
    if (!TvFocusMode.enabled) return;
    final label = widget.debugLabel;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 1) 优先恢复上次焦点（从子页面返回时回到原来的位置）。
      if (widget.restoreFocus && label != null) {
        final remembered = _memorized[label];
        if (remembered != null &&
            remembered.canRequestFocus &&
            remembered.context != null) {
          remembered.requestFocus();
          return;
        }
      }
      // 2) 否则把焦点交给**子树里第一个可聚焦组件**。
      //    不用 FocusScope.focusInDirection（它依赖当前已有焦点在本作用域内），
      //    改为直接遍历元素树取第一个 canRequestFocus 的 FocusNode —— 行为确定、可预期。
      if (widget.autofocusFirstChild) {
        final node = _firstFocusableNode(context);
        node?.requestFocus();
      }
    });
  }

  /// 深度优先找子树里第一个可聚焦的 FocusNode。
  FocusNode? _firstFocusableNode(BuildContext context) {
    FocusNode? found;
    void visit(Element element) {
      if (found != null) return;
      final w = element.widget;
      if (w is Focus && (w.canRequestFocus != false)) {
        final n = w.focusNode;
        if (n != null && n.canRequestFocus) {
          found = n;
          return;
        }
      }
      element.visitChildren(visit);
    }

    final el = context as Element;
    el.visitChildren(visit);
    return found;
  }

  @override
  void deactivate() {
    final label = widget.debugLabel;
    if (label != null && widget.restoreFocus) {
      _memorized[label] = FocusManager.instance.primaryFocus;
    }
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) {
    // ====【关键】==== 用**几何遍历**（WidgetOrderTraversalPolicy）而不是阅读顺序：
    // 遥控器 D-pad 的期望是"按几何就近移动"（上/下/左/右找最近的邻居），
    // 阅读顺序策略会按构建顺序跳，列表/网格里会出现"按右键跳到很远"的问题。
    // 这正是 Android TV 上 Flutter 默认使用的策略（FocusScope 默认即它），
    // 这里显式声明是为了避免被其它地方的策略覆盖。
    return FocusTraversalGroup(
      policy: WidgetOrderTraversalPolicy(),
      child: widget.child,
    );
  }
}

/// 便捷方法：在任意 widget 上包一层可聚焦 + 高亮。
///
/// 典型用法（卡片）：
/// ```dart
/// return tvTapTarget(
///   context,
///   onTap: () => open(song),
///   child: Card(...),
/// );
/// ```
Widget tvTapTarget(
  BuildContext context, {
  required VoidCallback onTap,
  required Widget child,
  bool autofocus = false,
  ValueChanged<bool>? onFocusChange,
  FocusNode? focusNode,
  double radius = TvFocusMode.highlightRadius,
}) {
  return TvFocusable(
    onTap: onTap,
    autofocus: autofocus,
    onFocusChange: onFocusChange,
    focusNode: focusNode,
    radius: radius,
    child: child,
  );
}

/// 让任意子树**可被聚焦**，并把"当前是否聚焦"回传给 builder。
///
/// 与 [TvFocusable] 的分工：
///   * [TvFocusable] 自己负责"确定键 = onTap"，适合没有点击组件的场景；
///   * [TvFocusTarget] 只负责**焦点**，点击仍由子树自己的 `InkWell`/`GestureDetector`
///     处理 —— 适合给已有的 Material 组件补上 TV 焦点与高亮，改动最小。
///
/// 用法（在已有 InkWell 外面包一层，高亮画在 InkWell 外层以免被裁掉）：
/// ```dart
/// TvFocusTarget(
///   onSelect: onTap,
///   builder: (context, focused) => TvFocusHighlight(
///     focused: focused,
///     radius: 12,
///     child: InkWell(onTap: onTap, child: card),
///   ),
/// )
/// ```
class TvFocusTarget extends StatefulWidget {
  const TvFocusTarget({
    super.key,
    required this.builder,
    this.onSelect,
    this.debugLabel,
    this.focusNode,
    this.autofocus = false,
    this.canRequestFocus = true,
    this.onFocusChange,
    this.descendantsAreFocusable = false,
  });

  final Widget Function(BuildContext context, bool focused) builder;

  /// 确定键触发；为 null 时只做焦点落点。
  final VoidCallback? onSelect;

  /// 调试标签（焦点日志中显示，便于确认遥控器焦点走到了哪里）。
  final String? debugLabel;

  final FocusNode? focusNode;
  final bool autofocus;
  final bool canRequestFocus;
  final ValueChanged<bool>? onFocusChange;

  /// 是否允许子树内部的焦点节点参与遍历。
  ///
  /// 默认 **false**：只保留本组件这一个焦点落点，避免"卡片里再套 InkWell"时
  /// 出现两个相邻焦点、按一下方向键画面不动的"顿挫感"（Android TV 上尤其明显）。
  /// 若子树里确实有需要独立聚焦的子控件（如歌曲行里的点赞/更多按钮），
  /// 显式传 `true`。
  final bool descendantsAreFocusable;

  @override
  State<TvFocusTarget> createState() => _TvFocusTargetState();
}

class _TvFocusTargetState extends State<TvFocusTarget> {
  late FocusNode _node;
  bool _ownsNode = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _attach(widget.focusNode);
  }

  void _attach(FocusNode? external) {
    if (external != null) {
      _node = external;
      _ownsNode = false;
    } else {
      _node = FocusNode(debugLabel: 'tv-focus-target');
      _ownsNode = true;
    }
    _node.addListener(_handle);
  }

  void _handle() {
    if (!mounted) return;
    setState(() => _focused = _node.hasFocus);
    if (TvFocusMode.debugLogFocus) {
      debugPrint('[TV_FOCUS] target '
          '${widget.debugLabel ?? _node.debugLabel ?? ''} focused=${_node.hasFocus}');
    }
    widget.onFocusChange?.call(_node.hasFocus);
  }

  @override
  void didUpdateWidget(covariant TvFocusTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      _node.removeListener(_handle);
      if (_ownsNode) _node.dispose();
      _attach(widget.focusNode);
      _focused = _node.hasFocus;
    }
  }

  @override
  void dispose() {
    _node.removeListener(_handle);
    if (_ownsNode) _node.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (tvSelectKeys.contains(event.logicalKey)) {
      final cb = widget.onSelect;
      if (cb == null) return KeyEventResult.ignored;
      cb();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      autofocus: widget.autofocus,
      canRequestFocus: widget.canRequestFocus,
      // 只保留外层这一个焦点节点：子树里若还有 InkWell 等内部焦点节点，
      // 会让方向键"原地停一拍"，故默认屏蔽（见 [descendantsAreFocusable]）。
      descendantsAreFocusable: widget.descendantsAreFocusable,
      onKeyEvent: _onKey,
      child: widget.builder(context, _focused),
    );
  }
}

/// 便捷函数：给"可点击但不可聚焦"的子树（如自绘卡片）补上 TV 焦点 + 高亮 + 确定键。
Widget tvFocusTarget({
  required BuildContext context,
  required VoidCallback? onTap,
  required Widget child,
  bool autofocus = false,
  FocusNode? focusNode,
  ValueChanged<bool>? onFocusChange,
  double radius = TvFocusMode.highlightRadius,
  double scale = TvFocusMode.highlightScale,
  Color? highlightColor,
  bool glow = true,
  bool descendantsAreFocusable = false,
}) {
  return TvFocusTarget(
    autofocus: autofocus,
    focusNode: focusNode,
    onFocusChange: onFocusChange,
    onSelect: onTap,
    descendantsAreFocusable: descendantsAreFocusable,
    builder: (context, focused) => TvFocusHighlight(
      focused: focused,
      radius: radius,
      scale: scale,
      color: highlightColor,
      glow: glow,
      child: child,
    ),
  );
}
