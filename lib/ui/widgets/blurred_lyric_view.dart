import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart' hide LineMetrics;
import 'package:flutter_lyric/core/lyric_controller.dart';
import 'package:flutter_lyric/core/lyric_model.dart';
import 'package:flutter_lyric/core/lyric_style.dart';
import 'package:flutter_lyric/core/lyric_styles.dart';
import 'package:flutter_lyric/render/lyric_layout.dart';
import 'package:flutter_lyric/render/lyric_painter.dart';
import 'package:flutter_lyric/widgets/mixins/lyric_layout_mixin.dart';
import 'package:flutter_lyric/widgets/mixins/lyric_line_highlight.dart';
import 'package:flutter_lyric/widgets/mixins/lyric_line_switch_mixin.dart';
import 'package:flutter_lyric/widgets/mixins/lyric_mask_mixin.dart';
import 'package:flutter_lyric/widgets/mixins/lyric_scroll_mixin.dart';
import 'package:flutter_lyric/widgets/mixins/lyric_touch_mixin.dart';

// =============================================================================
// 【交互链路综述】原版歌词控件 —— 圆点在 flutter_lyric mixin 上做"播放器侧"覆盖
// -----------------------------------------------------------------------------
// 布局 / 滚动动画 / 遮罩 / 换行 复用 flutter_lyric 原生 mixin：
//   LyricLayoutMixin、LyricScrollMixin、LyricMaskMixin、LyricLineHightlightMixin、
//   LyricLineSwitchMixin，以及由 LyricTouchMixin 提供的 scrollY/dragScrollY 状态。
//
// 播放器侧对"触摸交互"做了两处有意覆盖（其余体验尽量对齐原版 mixin）：
//   1) 触摸（滚轮/拖拽/点击）不再维护 selectedIndex、不再置 isSelecting —— 原版
//      LyricTouchMixin 靠"选中行"实现"预览时暂停 active 高亮 + 把预览行整行高亮"，
//      但播放器需求是"手动滚动不打断播放行的高亮、预览行也不要整行高亮"。因此用
//      自写的 _wrapPreviewTouch 替代 wrapTouchWidget，active 高亮始终由
//      activeIndexNotifiter（播放行）驱动。
//   2) 手动滚动时叠加"画面居中行"第二模糊中心（双模糊）—— 自动播放只以播放行为
//      核心；用户滚动预览时额外以"画面正中那份歌词"为核心清晰，停止后回退。
//
// 为"除需求外体验同步原版"，以下手感均已对齐 LyricTouchMixin/LyricScrollMixin：
//   - 滚轮：逐行步进并吸附到整行中线（参考游标=画面居中行，替代原版 selectedIndex）；
//   - 拖拽：松手按初速度走 ClampingScrollSimulation 惯性（_startPreviewFling）；
//   - 回归：预览/惯性结束经 style.activeAutoResumeDuration 后平滑回归当前播放行、
//     恢复随播放时间轴自动跟随（_scheduleWheelResume）；
//   - 点击：命中某行发 notifyEvent(tapLine)（外部 seek），并把视图平滑定位到该行
//     （播放器要求，原版 mixin 只发事件不滚动）。
// =============================================================================
/// 在 flutter_lyric 的基础上给非当前行增加随距离递增的高斯模糊。
class BlurredLyricView extends StatefulWidget {
  const BlurredLyricView({
    super.key,
    required this.controller,
    this.width,
    this.height,
    this.style,
    this.maxBlurSigma = 6.0,
    this.blurStep = 1.4,
  });

  final LyricController controller;
  final double? width;
  final double? height;
  final LyricStyle? style;

  /// 距离当前行最远时的最大模糊强度。
  final double maxBlurSigma;

  /// 每远离当前行一行时增加的模糊强度。
  final double blurStep;

  @override
  State<BlurredLyricView> createState() => _BlurredLyricViewState();
}

class _BlurredLyricViewState extends State<BlurredLyricView>
    with
        TickerProviderStateMixin,
        LyricLayoutMixin,
        LyricScrollMixin,
        LyricMaskMixin,
        LyricTouchMixin,
        LyricLineHightlightMixin,
        LyricLineSwitchMixin {
  @override
  LyricController get controller => widget.controller;

  @override
  LyricStyle get style => widget.style ?? LyricStyles.default1;

  @override
  LyricLayout? layout;

  @override
  Size lyricSize = Size.zero;

  @override
  final scrollYNotifier = ValueNotifier<double>(0.0);

  @override
  void initState() {
    super.initState();
    // ===== 【还原手感·原版歌词惯性】初始化 fling 控制器（unbounded，便于衰减滑动）。=====
    _previewFlingController = AnimationController.unbounded(vsync: this)
      ..addListener(_previewFlingListener)
      ..addStatusListener(_previewFlingStatusListener);
  }

  @override
  void onLayoutChange(LyricLayout layout) {
    super.onLayoutChange(layout);
    updateHighlightWidth();
    updateScrollY(animate: false);
  }

  @override
  void didUpdateWidget(covariant BlurredLyricView oldWidget) {
    if (widget.style != oldWidget.style ||
        widget.maxBlurSigma != oldWidget.maxBlurSigma ||
        widget.blurStep != oldWidget.blurStep) {
      onStyleChange();
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  Widget build(BuildContext context) {
    // ===== 原实现：final Widget content = wrapTouchWidget(context, SizedBox(...)) ——
    // 委托给 flutter_lyric 的 LyricTouchMixin，其拖拽会在 onVerticalDragStart 置
    // isSelectingNotifier=true、并在 painter 的 onAnchorIndexChange 写入 selectedIndex，
    // 从而暂停 active 高亮、把预览行整行高亮。
    // ===== 【重构】改为自定义 _wrapPreviewTouch：滚轮/拖拽仅移动视图，不写 selectedIndex、
    // 不置 isSelecting，active 高亮始终由 activeIndexNotifiter（播放行）驱动。
    final Widget content = _wrapPreviewTouch(
      context,
      SizedBox(
        width: widget.width ?? double.infinity,
        height: widget.height ?? double.infinity,
        child: Padding(
          padding: style.contentPadding.copyWith(top: 0, bottom: 0),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = Size(constraints.maxWidth, constraints.maxHeight);
              if (size.width != lyricSize.width ||
                  size.height != lyricSize.height) {
                lyricSize = size;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  computeLyricLayout();
                });
              }
              if (layout == null) return const SizedBox.shrink();
              Widget result = buildLineSwitch((context, switchState) {
                return buildActiveHighlightWidth((double value) {
                  return ValueListenableBuilder(
                    valueListenable: scrollYNotifier,
                    builder: (context, double scrollY, child) {
                      return CustomPaint(
                        // ===== 【重构】painter 传入 isPreviewing / previewCenterIndex，
                        // playIndex 仍为 activeIndexNotifiter（播放行），active 高亮不受 preview 影响。
                        painter: _BlurredLyricPainter(
                          layout: layout!,
                          onShowLineRectsChange: (rects) {
                            showLineRects = rects;
                          },
                          style: style,
                          playIndex: controller.activeIndexNotifiter.value,
                          activeHighlightWidth: value,
                          isSelecting: controller.isSelectingNotifier.value,
                          scrollY: scrollY,
                          // ===== 原实现：onAnchorIndexChange 把画面/选中行写入 selectedIndexNotifier，
                          // 使预览行被整行高亮。===== 【重构】不再写入，预览行不高亮。
                          onAnchorIndexChange: (index) {},
                          switchState: switchState,
                          maxBlurSigma: widget.maxBlurSigma,
                          blurStep: widget.blurStep,
                          // 预览滚动时以“画面居中行”为第二个模糊中心。
                          isPreviewing: _previewing,
                          previewCenterIndex: _previewing
                              ? (indexAtScrollAnchor(scrollY) ?? 0)
                              : controller.activeIndexNotifiter.value,
                        ),
                        size: lyricSize,
                      );
                    },
                  );
                });
              });
              result = wrapMaskIfNeed(result);
              return result;
            },
          ),
        ),
      ),
    );
    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          _handleLyricMouseWheel(event.scrollDelta.dy);
        }
      },
      child: content,
    );
  }

  Timer? _wheelResumeTimer;

  /// 是否处于“手动预览滚动”状态（滚轮/拖拽触发），用于叠加画面居中行的模糊渐变。
  bool _previewing = false;

  bool _isDraggingPreview = false;

  // ===== 【还原手感·原版歌词惯性】fling 动画控制器 =====
  // 自定义 _wrapPreviewTouch 绕过了 flutter_lyric 的 wrapTouchWidget（后者通过
  // ClampingScrollSimulation 提供松手惯性，但会置 isSelecting 并写 selectedIndex，违反
  // 需求1/2/3）。这里自建 unbounded 控制器复刻同一手感：松手按初速度衰减滑动，
  // 滑动结束后再经 _scheduleWheelResume 延迟自动回归当前播放行。
  late final AnimationController _previewFlingController;

  void _previewFlingListener() {
    if (!mounted) return;
    setDragTranslationY(_previewFlingController.value);
  }

  void _previewFlingStatusListener(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _scheduleWheelResume();
    }
  }

  void _stopPreviewFling() {
    if (_previewFlingController.isAnimating) {
      _previewFlingController.stop();
    }
  }

  /// ===== 【还原手感·原版歌词惯性】启动松手惯性滑动 =====
  /// 严格对齐 flutter_lyric 权威实现（LyricTouchMixin.onVerticalDragEnd）：
  ///   _flingController.animateWith(ClampingScrollSimulation(position, velocity))
  /// 注意两点，缺一不可：
  ///   * 不要重置 controller.value —— animateWith 会从零作动画时长，而 simulation 的
  ///     x(t) 自带初始位置；强行置 value=0 会破坏仿真基准，导致位置瞬间被拉向顶部(0)，
  ///     表现为"突然回到所有歌词行顶部"。
  ///   * persistent/`..stop()` 仅在确有进行中的动画时才调用，避免误杀。
  void _startPreviewFling(double velocity) {
    if (_previewFlingController.isAnimating) {
      _previewFlingController.stop();
    }
    _previewFlingController.animateWith(
      ClampingScrollSimulation(
        position: dragScrollY ?? scrollY,
        velocity: velocity,
      ),
    );
  }

  /// ===== 【重构】进入预览态（滚轮/拖拽触发），需触发 setState 让 painter 叠加
  /// “画面居中行”模糊中心，同时保证不写 selectedIndex、不置 isSelecting。
  void _enterPreview() {
    if (!_previewing) {
      setState(() => _previewing = true);
    }
  }

  // ===== ===== ===== 原实现（备份，供回退）===== ===== =====
  // /// 鼠标滚轮滚动：按行索引逐行对齐，确保每次滚轮都停靠在一整行、不跳行。
  // void _handleLyricMouseWheel(double delta) {
  //   controller.isSelectingNotifier.value = true;
  //   final l = layout;
  //   if (l == null) return;
  //   final count = l.metrics.length;
  //   if (count <= 0) return;
  //   final cur = controller.selectedIndexNotifier.value;
  //   final dir = delta > 0 ? 1 : -1;
  //   final target = (cur + dir).clamp(0, count - 1);
  //   controller.selectedIndexNotifier.value = target;
  //   setDragTranslationY(
  //     l.lineOffsetY(
  //       target,
  //       controller.activeIndexNotifiter.value,
  //       l.selectionAnchorPosition,
  //       style.selectionAlignment,
  //     ),
  //     animate: true,
  //   );
  //   _scheduleWheelResume();
  // }

  // /// 滚轮后延迟回归当前播放行（复刻 mixin 的自动恢复逻辑）。
  // void _scheduleWheelResume() {
  //   _wheelResumeTimer?.cancel();
  //   _wheelResumeTimer = Timer(style.activeAutoResumeDuration, () {
  //     controller.isSelectingNotifier.value = false;
  //     dragScrollY = null;
  //     updateScrollY();
  //     controller.notifyEvent(LyricEvent.resumeActiveLine);
  //   });
  // }
  // ===== ===== ===== 原实现（备份，结束）===== ===== =====

  /// ===== 【重构】根据当前视图偏移 scrollY，反算出位于画面居中锚点(selectionAnchor)处的歌词行索引。
  /// 与 LyricPainter.paint 里的选中行计算逻辑保持一致（含半行距线距判定）。返回 null 表示无歌词。
  int? indexAtScrollAnchor(double scrollY) {
    final l = layout;
    if (l == null || l.metrics.isEmpty) return null;
    final halfLineGap = l.style.lineGap / 2;
    final selectionPos = l.selectionAnchorPosition;
    final active = controller.activeIndexNotifiter.value;
    var total = 0.0;
    for (var i = 0; i < l.metrics.length; i++) {
      total += l.getLineHeight(i == active, i);
      if ((total + halfLineGap) >= (selectionPos + scrollY)) return i;
      total += l.style.lineGap;
    }
    return l.metrics.length - 1;
  }

  /// 把视图滚动到指定行（仅移动视图，不高亮、不暂停播放高亮）。
  void _scrollViewToIndex(int index) {
    final l = layout;
    if (l == null || index < 0 || index >= l.metrics.length) return;
    _enterPreview();
    setDragTranslationY(
      l.lineOffsetY(
        index,
        controller.activeIndexNotifiter.value,
        l.selectionAnchorPosition,
        style.selectionAlignment,
      ),
      animate: true,
    );
    _scheduleWheelResume();
  }

  /// ===== 【还原手感】鼠标滚轮滚动：逐行步进、吸附到整行。对齐备份(183-204行)
  /// 原实现的手感 —— dir=±1 每次恰好推进一行，setDragTranslationY(lineOffsetY(target)
  /// ,animate:true) 使视图精确停靠在整行中线(吸附)。唯一差异：为守需求1/2/3（不写
  /// selectedIndexNotifier、不置 isSelecting、不高亮预览行），参考游标由 selectedIndex
  /// 换成“画面居中行”indexAtScrollAnchor；active 高亮仍由播放行(activeIndexNotifiter)驱动。
  void _handleLyricMouseWheel(double delta) {
    final l = layout;
    if (l == null || l.metrics.isEmpty) return;
    // 滚轮滚动应立即终止进行中的惯性滑动，避免二者叠加抢位置。
    _stopPreviewFling();
    final cur = indexAtScrollAnchor(scrollY);
    if (cur == null) return;
    final count = l.metrics.length;
    // 滚轮向上滚(scrollDelta.dy<0) → 上一行(查看更早歌词)；正 delta → 下一行。
    final dir = delta > 0 ? 1 : -1;
    final target = (cur + dir).clamp(0, count - 1);
    _scrollViewToIndex(target);
  }

  // ===== ===== ===== 原实现（备份，供回退）===== ===== =====
  // /// =====【重构】滚轮/拖拽停止后，延迟退出预览态（模糊只保留播放行渐变）。
  // /// 保留用户浏览时的滚动偏移，不做强制回归。
  // void _scheduleWheelResume() {
  //   _wheelResumeTimer?.cancel();
  //   _wheelResumeTimer = Timer(style.activeAutoResumeDuration, () {
  //     if (_previewing) {
  //       setState(() => _previewing = false);
  //     }
  //   });
  // }
  // ===== ===== ===== 原实现（备份，结束）===== ===== =====

  // ===== ===== ===== 原实现（备份，供回退）===== ===== =====
  // /// ===== 【恢复回归】滚轮/拖拽停止后，延迟退出预览态，并平滑回归到当前播放行。
  // /// 保留上一版正确行为：滚动/拖拽中不写 selectedIndex、不置 isSelecting、不高亮预览行，
  // /// active 高亮始终由播放行（activeIndexNotifiter）驱动；仅在"预览结束"时补回
  // /// "平滑滚动回 activeIndex 居中、继续随播放时间轴自动滚动"的原体验。
  // void _scheduleWheelResume() {
  //   _wheelResumeTimer?.cancel();
  //   _wheelResumeTimer = Timer(style.activeAutoResumeDuration, () {
  //     if (!mounted) return;
  //     if (_previewing) {
  //       setState(() => _previewing = false);
  //     }
  //     dragScrollY = null;
  //     updateScrollY();
  //   });
  // }
  // ===== ===== ===== 原实现（备份，结束）===== ===== =====

  /// ===== 【还原手感】回归节奏/时长/事件。预览(滚轮/拖拽/点击)结束后，经
  /// style.activeAutoResumeDuration 延迟，退出预览态并平滑回归当前播放行。
  /// 对照备份(206-215行)的原实现：dragScrollY=null; updateScrollY() —— 平滑回归的
  /// 时长/曲线由 mixin 的 scrollDuration/scrollCurve(offset 动态档位)决定；再补回原实现
  /// 的 notifyEvent(LyricEvent.resumeActiveLine)。该事件仅分发通知，不写 selectedIndex、
  /// 不置 isSelecting，故不破坏需求1/2/3；回归后 dragScrollY 恒 null，playIndexListener
  /// 继续随播放时间轴自动跟随(需求5)。_previewing=false 保留双模糊求需求4。
  void _scheduleWheelResume() {
    _wheelResumeTimer?.cancel();
    _wheelResumeTimer = Timer(style.activeAutoResumeDuration, () {
      if (!mounted) return;
      // 退出预览态：双模糊渐变只保留播放行核心（需求4，不影响 active 高亮、不选行）。
      if (_previewing) {
        setState(() => _previewing = false);
      }
      // 移除手动浏览偏移，平滑(默认动画)滚动回当前播放行 activeIndex 居中（需求5）。
      dragScrollY = null;
      updateScrollY();
      // ===== 【还原手感】回归事件，对齐重构前备份(212-213行)。=====
      controller.notifyEvent(LyricEvent.resumeActiveLine);
    });
  }

  /// ===== 【重构】自定义触摸包裹：拖拽/点击仅移动视图浏览，不置 isSelecting、
  /// 不高亮预览行，从而不暂停 active 播放高亮。（未使用 mixin 的 wrapTouchWidget，
  /// 因后者 onVerticalDragStart 会置 isSelecting=true。）
  Widget _wrapPreviewTouch(BuildContext context, Widget child) {
    if (style.disableTouchEvent || (layout?.metrics.isEmpty ?? true)) {
      return child;
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 兼容原 tapLine 语义：点击某行仍通知控制器，并同时把视图滚到该行浏览。
      // ===== 【还原手感】点击行行为：对齐备份/mixin 的 onTapUp —— 命中该行即发
      // tapLine 通知；并调用 _scrollViewToIndex 把视图平滑定位到该行中线，随后经
      // _scheduleWheelResume 延迟自动回归当前播放行(需求5)。不写 selectedIndex、
      // 不置 isSelecting，故不因此高亮预览行或暂停 active(需求1/2/3)。
      onTapUp: (details) {
        if (showLineRects == null || _isDraggingPreview) return;
        for (final entry in showLineRects!.entries) {
          if (entry.value.contains(details.localPosition)) {
            controller.notifyEvent(LyricEvent.tapLine, entry.key);
            _scrollViewToIndex(entry.key);
            return;
          }
        }
      },
      onVerticalDragDown: (details) {
        _stopPreviewFling();
        _isDraggingPreview = true;
        _enterPreview();
      },
      onVerticalDragUpdate: (details) {
        _enterPreview();
        setDragTranslationY(scrollY - details.delta.dy);
      },
      onVerticalDragEnd: (details) {
        _isDraggingPreview = false;
        // ===== 【还原手感·原版歌词惯性】松手按初速度触发惯性滑动 =====
        // velocity 取主轴 y 反号（与 mixin 一致）；速度过小时视为普通拖动，直接进入回归计时。
        final v = -details.velocity.pixelsPerSecond.dy;
        if (!v.isFinite || v.abs() < 40) {
          _scheduleWheelResume();
          return;
        }
        _startPreviewFling(v);
      },
      onVerticalDragCancel: () {
        _isDraggingPreview = false;
        _stopPreviewFling();
        _scheduleWheelResume();
      },
      onTap: () {},
      child: child,
    );
  }

  @override
  void dispose() {
    _previewFlingController.dispose();
    _wheelResumeTimer?.cancel();
    super.dispose();
  }
}

class _BlurredLyricPainter extends LyricPainter {
  // ===== 原实现（备份，供回退）见文件头原备份；改动字段、drawLine、shouldRepaint 如下。=====
  _BlurredLyricPainter({
    required super.layout,
    required super.playIndex,
    required super.scrollY,
    required super.onAnchorIndexChange,
    required super.activeHighlightWidth,
    required super.switchState,
    required super.isSelecting,
    required super.onShowLineRectsChange,
    required super.style,
    required this.maxBlurSigma,
    required this.blurStep,
    // ===== 【重构】预览态标志与“画面居中行”索引（第二个模糊中心）。=====
    required this.isPreviewing,
    required this.previewCenterIndex,
  });

  final double maxBlurSigma;
  final double blurStep;
  final bool isPreviewing;
  final int previewCenterIndex;

  @override
  void drawLine(
    Canvas canvas,
    LineMetrics metric,
    Size size,
    int index,
    bool isInAnchorArea,
  ) {
    // ===== 【重构】模糊渐变。以播放行 playIndex 为唯一基准（自动播放）；仅当预览滚动
    // isPreviewing 时，额外叠加“画面居中行”为中心：distance 取到两中心里更近的那一个
    // （即 max blur 需求较小者），使“播放行清晰核心”与“画面居中行清晰核心”并存，
    // 中间区域由两个中心共同渐变。离预览后只保留播放行渐变。
    // ===== 原实现：final distance = (index - playIndex).abs(); shouldStaySharp =
    // distance == 0 || (isSelecting && isInAnchorArea);
    var distance = (index - playIndex).abs();
    if (isPreviewing) {
      final viewDistance = (index - previewCenterIndex).abs();
      if (viewDistance < distance) distance = viewDistance;
    }
    final shouldStaySharp = distance == 0;
    if (shouldStaySharp) {
      super.drawLine(canvas, metric, size, index, isInAnchorArea);
      return;
    }

    final sigma = math.min(maxBlurSigma, blurStep * distance).toDouble();
    final blurPaint = Paint()
      ..imageFilter = ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
    canvas.saveLayer(null, blurPaint);
    super.drawLine(canvas, metric, size, index, isInAnchorArea);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BlurredLyricPainter oldDelegate) {
    return super.shouldRepaint(oldDelegate) ||
        oldDelegate.maxBlurSigma != maxBlurSigma ||
        oldDelegate.blurStep != blurStep ||
        // ===== 【重构】新增重绘条件，保证 preview 状态切换时立即生效。=====
        oldDelegate.isPreviewing != isPreviewing ||
        oldDelegate.previewCenterIndex != previewCenterIndex;
  }
}
