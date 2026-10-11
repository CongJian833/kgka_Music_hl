import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'startup_diag_logger.dart';

/// ====【诊断/安卓启动后渲染卡顿】====
///
/// 目的：TV 上冷启动后仍有约 10 秒掉帧（Choreographer 记录 Skipped 62/47/37 帧），
/// 而启动逻辑（我们的 startup.* 埋点）只占约 1.2 秒。所以卡在**首帧之后的渲染**。
///
/// 本模块用 [SchedulerBinding.addTimingsCallback] 记录每一帧的
/// build（UI 线程）与 raster（GPU 线程）耗时，并带上当前路由名，
/// 从而区分：build 高 = Dart 侧构建太重 / raster 高 = GPU 光栅化太重（如 BackdropFilter 模糊）。
///
/// 阈值：单帧 build+raster 超过 24ms 即记录（60fps 预算 16.7ms）。
class FrameDiagLogger {
  FrameDiagLogger._();

  /// 判定阈值（毫秒）。
  static const int warnMs = 24;
  static const int badMs = 50;

  /// 是否记录所有帧（默认只记超阈值帧；需要逐帧曲线时置 true）。
  static bool logAllFrames = false;

  /// 当前路由名（由 [FrameDiagObserver] 维护），用于把卡顿归到具体页面。
  static String route = '(initial)';

  /// 累计统计。
  static int frames = 0;
  static int jankFrames = 0;
  static int maxBuildUs = 0;
  static int maxRasterUs = 0;
  static int maxTotalMs = 0;
  static int _lastHeartbeatMs = 0;

  static bool _attached = false;

  /// 是否关闭 BackdropFilter 模糊（A/B 实验用；由 main 里的 dart-define 打开）。
  static const bool disableBlur =
      bool.fromEnvironment('KA_DIAG_DISABLE_BLUR', defaultValue: false);

  static void attach() {
    if (_attached) return;
    _attached = true;
    try {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
    } catch (_) {
      // 绑定未就绪：忽略（调用方在 runApp 之后才 attach）。
    }
  }

  static void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final buildMs = t.buildDuration.inMicroseconds;
      final rasterMs = t.rasterDuration.inMicroseconds;
      final totalMs = ((buildMs + rasterMs) / 1000).round();
      frames++;
      if (buildMs > maxBuildUs) maxBuildUs = buildMs;
      if (rasterMs > maxRasterUs) maxRasterUs = rasterMs;
      if (totalMs > maxTotalMs) maxTotalMs = totalMs;

      if (totalMs >= warnMs) {
        jankFrames++;
        StartupDiagLogger.phase(
          'frame',
          ms: totalMs,
          note: 'route=$route '
              'build=${(buildMs / 1000).toStringAsFixed(1)}ms '
              'raster=${(rasterMs / 1000).toStringAsFixed(1)}ms '
              '${totalMs >= badMs ? 'SEVERE' : ''} '
              'frameNo=$frames',
        );
      } else if (logAllFrames) {
        StartupDiagLogger.phase(
          'frame',
          ms: totalMs,
          note: 'route=$route '
              'build=${(buildMs / 1000).toStringAsFixed(1)}ms '
              'raster=${(rasterMs / 1000).toStringAsFixed(1)}ms',
        );
      }

      // 心跳：每 5 秒汇总一次，便于看到"卡顿期持续多久"。
      final nowMs = StartupDiagLogger.appElapsedMs;
      if (nowMs - _lastHeartbeatMs >= 5000) {
        _lastHeartbeatMs = nowMs;
        StartupDiagLogger.phase(
          'frames5s',
          note: 'route=$route frames=$frames jank=$jankFrames '
              'maxBuild=${(maxBuildUs / 1000).toStringAsFixed(1)}ms '
              'maxRaster=${(maxRasterUs / 1000).toStringAsFixed(1)}ms '
              'maxTotal=${maxTotalMs}ms',
        );
        // 每 5 秒归零"窗口内"统计，便于看趋势。
        _resetWindow();
      }
    }
  }

  static void _resetWindow() {
    frames = 0;
    jankFrames = 0;
    maxBuildUs = 0;
    maxRasterUs = 0;
    maxTotalMs = 0;
  }

  /// 显式打一条当前状态（排查时用）。
  static void dump(String tag) {
    StartupDiagLogger.phase(
      'frameDump',
      note: '$tag route=$route frames=$frames jank=$jankFrames '
          'maxBuild=${(maxBuildUs / 1000).toStringAsFixed(1)}ms '
          'maxRaster=${(maxRasterUs / 1000).toStringAsFixed(1)}ms',
    );
  }
}

/// 路由观察者：把当前页面名喂给 [FrameDiagLogger]，让卡顿能归因到页面。
class FrameDiagObserver extends NavigatorObserver {
  FrameDiagObserver();

  void _set(Route<dynamic>? route, String action) {
    final name = route?.settings.name ??
        (route?.settings.arguments is String
            ? route!.settings.arguments as String
            : null) ??
        route.runtimeType.toString();
    FrameDiagLogger.route = name;
    StartupDiagLogger.phase('route', note: '$action $name');
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _set(route, 'push');

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _set(previousRoute, 'pop');

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _set(newRoute, 'replace');
}
