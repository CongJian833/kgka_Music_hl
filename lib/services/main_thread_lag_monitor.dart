import 'dart:async';

import 'startup_diag_logger.dart';

/// ====【诊断/主线程阻塞全景】====
///
/// 目标：在**不知道是谁阻塞主线程**的情况下也能定位。
///
/// 原理：Dart 的主 isolate 只有一个事件循环。若某段同步代码（IO / 解析 / 解码 /
/// 大量重建）占住它，**定时器就会迟到**。因此用一个高频 Timer 测量
/// "本次 tick 实际比预期晚了多少"，即为该段时间内主线程被同步占用的大致时长。
/// 这个方法不依赖任何埋点，能捕获我们没有预先打点的代码路径。
///
/// 同时提供 [measure]：包住一次 notifyListeners 之类的同步广播，
/// 记录其耗时并归属到具体控制器（回答"是谁通知的"）。
class MainThreadLagMonitor {
  MainThreadLagMonitor._();

  /// 采样间隔。越大越省电、越小越精确；50ms 对启动期诊断足够。
  static const int _intervalMs = 50;

  /// 只有超过该阈值才记录（过滤正常抖动）。
  static const int _logThresholdMs = 80;

  static Timer? _timer;
  static int _lastTickMs = 0;
  static bool _enabled = false;

  /// 统计。
  static int _blockedEvents = 0;
  static int _blockedTotalMs = 0;
  static int _blockedMaxMs = 0;

  static bool get enabled => _enabled;

  /// 启动监控（幂等）。仅在诊断期开启，可用 KA_MUSIC_DIAG=0 关闭。
  static void start() {
    if (_enabled) return;
    _enabled = true;
    _lastTickMs = StartupDiagLogger.appElapsedMs;
    _timer = Timer.periodic(const Duration(milliseconds: _intervalMs), (_) {
      final now = StartupDiagLogger.appElapsedMs;
      final drift = now - _lastTickMs - _intervalMs;
      _lastTickMs = now;
      if (drift < _logThresholdMs) return;
      _blockedEvents++;
      _blockedTotalMs += drift;
      if (drift > _blockedMaxMs) _blockedMaxMs = drift;
      StartupDiagLogger.phase(
        'mainBlocked',
        ms: drift,
        note: '主线程被同步占用约 $drift ms | 阻塞前最后路标: '
            '${recentCrumbs(3).join(" -> ")} | 累计 $_blockedEvents 次 / '
            '共 $_blockedTotalMs ms / 最大 $_blockedMaxMs ms',
      );
    });
  }

  /// 包住一次同步广播/计算，记录耗时并归属到 [label]。
  ///
  /// 用法：`MainThreadLagMonitor.measure('PlayerController.notifyListeners', () => super.notifyListeners())`
  static T measure<T>(String label, T Function() body, {int? thresholdMs}) {
    final sw = Stopwatch()..start();
    try {
      return body();
    } finally {
      sw.stop();
      final ms = sw.elapsedMilliseconds;
      if (ms >= (thresholdMs ?? 40)) {
        StartupDiagLogger.phase('notify', ms: ms, note: label);
      }
    }
  }

  // ===== 阻塞归因：每 tick 留一个"路标"，阻塞发生后即可知道卡在哪一段 =====
  //
  // 原理：主线程被占住时，Dart 代码不会执行，因此我们无法在阻塞期间采样自身。
  // 但可以在每次 tick 时留下"最后一次经过的路标"。当检测到 drift 时，
  // 报告的就是**阻塞发生前最后执行的代码位置**，从而定位到具体函数。
  static final Map<int, String> _breadcrumbs = <int, String>{};
  static int _crumbCursor = 0;

  /// 打一个路标（在可疑代码段的入口/出口调用）。成本极低（一次 Stopwatch 读 + map 写）。
  static void crumb(String label) {
    _crumbCursor++;
    _breadcrumbs[_crumbCursor % 64] = label;
  }

  /// 最近 [n] 个路标（按时间从早到晚）。
  static List<String> recentCrumbs(int n) {
    final keys = _breadcrumbs.keys.toList()..sort();
    final tail = keys.length <= n ? keys : keys.sublist(keys.length - n);
    return [for (final k in tail) _breadcrumbs[k]!];
  }

  /// 手动记录一段同步耗时。
  ///
  /// ====【诊断调整】==== 阈值从 40ms 降到 `_recordThresholdMs`：
  /// 实测这台设备稳态下区块构建只有 10~25ms，40ms 阈值会把它们全部过滤掉
  /// （导致"插了计时却一条日志都没有"）。当前为了定位单帧 2.4s 的构成，
  /// 需要看到所有 >4ms 的记录。
  static int _recordThresholdMs = 4;

  /// 运行期调整记录阈值（诊断用）。
  static void setRecordThreshold(int ms) => _recordThresholdMs = ms;

  static void record(String label, int ms) {
    if (ms < _recordThresholdMs) return;
    StartupDiagLogger.phase('syncWork', ms: ms, note: label);
  }

  static Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _enabled = false;
    StartupDiagLogger.phase(
      'mainBlockedSummary',
      note: '阻塞事件=$_blockedEvents 次 累计=${_blockedTotalMs}ms '
          '最大=${_blockedMaxMs}ms',
    );
  }

  static int get blockedMaxMs => _blockedMaxMs;
}
