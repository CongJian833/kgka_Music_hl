import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../config/app_config.dart';

/// ====【诊断/播放缓存清理卡顿】====
///
/// 播放缓存（LRU）清理在"冷启动 / 每首歌落盘后 / 改上限 / 手动清空"四处触发，
/// 期间全是同步文件系统调用（existsSync/lengthSync/deleteSync + listSync），
/// 在低端机/车机上可能阻塞主 isolate 造成掉帧。本模块只做一件事：
/// 把每次清理各阶段耗时 + 真实掉帧事件落到日志文件，供实机验证。
///
/// 日志位置（启动时会输出一行 LOGPATH 便于定位）：
///   %TEMP%\ka_music_cache_diag.log     本次运行的日志
///   %TEMP%\ka_music_cache_diag.1.log   上一次运行的日志（每次启动自动轮转）
///
/// 强制关闭：环境变量 KA_MUSIC_CACHE_DIAG=0
class CacheDiagLogger {
  CacheDiagLogger._();

  /// 运行批次号：每次 startFrameMonitor 自增。一次运行内所有日志段号一致。
  static int runId = 0;

  /// 总开关（默认开启，低开销：日志写盘走缓冲 + 异步）。
  static bool _enabled = true;
  static bool get enabled => _enabled;

  static File? _file;
  static final List<String> _buffer = <String>[];
  static Timer? _flushTimer;
  static bool _attached = false;
  static bool _flushing = false;

  /// 帧卡顿阈值：单帧「build + raster」超过该值即记一条。
  static const int _jankWarnMs = 24;
  static const int _jankBadMs = 50;
  static const int _jankSevereMs = 120;

  /// 掉帧判定阈值：相邻帧间隔超过该值即认为期间丢了帧。
  static const int _gapWarnMs = 34;

  /// 仅前台/非最小化时记录帧卡顿，避免窗口最小化或休眠产生假尖峰。
  static bool _appActive = true;
  static final Stopwatch _sinceStart = Stopwatch()..start();
  static int _lastRasterEndUs = 0;

  /// 分区域统计（供收尾汇总行）。
  static final Map<String, List<int>> _regionMs = <String, List<int>>{};

  /// 启动：准备日志文件并挂载帧监控。返回本次实际写入的日志文件路径。
  static Future<String?> startFrameMonitor() async {
    final env = Platform.environment['KA_MUSIC_CACHE_DIAG'];
    if (env == '0' || env == 'false') {
      _enabled = false;
      return null;
    }
    runId++;

    File? f;
    try {
      final tmp = Platform.environment['TEMP'] ??
          Platform.environment['TMP'] ??
          Directory.systemTemp.path;
      final sep = Platform.pathSeparator;
      f = File('$tmp${sep}ka_music_cache_diag.log');
      // 每次启动轮转：旧内容保留为 .1.log，绝不与上一次运行混淆。
      if (f.existsSync()) {
        try {
          await f.rename('$tmp${sep}ka_music_cache_diag.1.log');
        } catch (_) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
      _file = f;
    } catch (_) {
      _file = null;
    }

    _attach();
    _lastRasterEndUs = 0;
    _sinceStart.reset();
    _sinceStart.start();

    final path = f?.path ?? '(无法创建日志文件)';
    _write('===== RUN$runId HEADER =====');
    _write(
      'app=${AppConfig.appName} v${AppConfig.appVersion} '
      'pid=$pid platform=${Platform.operatingSystem} '
      'started=${DateTime.now().toIso8601String()}',
    );
    _write('LOGPATH=$path');
    _write(
      'jankThresholds=${_jankWarnMs}ms(warn)/${_jankBadMs}ms(bad)/'
      '${_jankSevereMs}ms(severe) gapWarn=${_gapWarnMs}ms',
    );
    _write('frameMonitor=on (仅前台/未最小化时采样)');
    _write('===== END HEADER =====');
    await _flush();
    debugPrint('[CacheDiag] log -> $path');
    return path;
  }

  /// 前后台切换：最小化/后台时暂停帧采样；恢复前台时重置帧间隔基线。
  ///
  /// ====【RUN1 实测教训】==== 窗口被遮挡/失焦时 Windows 引擎会把渲染节流到约 1fps，
  /// 帧回调依然会送达，于是恢复前台后的第一帧 gap 会出现 1000ms+ 的假尖峰
  /// （RUN1 里 88 条 WARN 全是这个来源）。因此：恢复前台即重置基线，
  /// 且 gap 明显超出阈值时只提示、不按卡顿计入。
  static void setAppActive(bool active) {
    _appActive = active;
    if (active) _lastRasterEndUs = 0;
    _write('LIFECYCLE active=$active');
  }

  /// 记录一条事件。region 为区域名（load/prune/scan/delete/persist/ui...），
  /// note 为自由文本，ms 为该区域本次耗时（可选）。
  static void log(String region, String note, {int? ms, int? extra}) {
    if (!_enabled) return;
    if (ms != null) {
      (_regionMs[region] ??= <int>[]).add(ms);
    }
    _write(
      '[CACHE_DIAG] t=${_sinceStart.elapsedMilliseconds}ms '
      'run=$runId region=$region'
      '${ms == null ? '' : ' ms=$ms'}'
      '${extra == null ? '' : ' extra=$extra'} $note',
    );
  }

  /// 写收尾汇总（每个区域 count/avg/max）。异常退出时可能不执行。
  static Future<void> flushSummary() async {
    if (!_enabled) return;
    _write('===== SUMMARY =====');
    final keys = _regionMs.keys.toList()..sort();
    for (final k in keys) {
      final v = _regionMs[k]!;
      if (v.isEmpty) continue;
      final sum = v.fold<int>(0, (a, b) => a + b);
      final max = v.reduce((a, b) => a > b ? a : b);
      _write(
        'SUMMARY region=$k count=${v.length} '
        'avg=${(sum / v.length).toStringAsFixed(1)}ms max=${max}ms',
      );
    }
    _write('===== END SUMMARY =====');
    await _flush();
  }

  static void _attach() {
    if (_attached) return;
    _attached = true;
    try {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
    } catch (_) {
      // 绑定未就绪等异常：仅记录，不影响功能。
    }
  }

  static void _onTimings(List<FrameTiming> timings) {
    if (!_enabled || !_appActive) return;
    for (final t in timings) {
      final buildUs = t.buildDuration.inMicroseconds;
      final rasterUs = t.rasterDuration.inMicroseconds;
      final totalMs = ((buildUs + rasterUs) / 1000).round();

      // 相邻帧间隔：超过阈值说明中间丢了帧（主 isolate 被阻塞的最直接证据）。
      final nowUs = _sinceStart.elapsedMicroseconds;
      int gapMs = 0;
      if (_lastRasterEndUs > 0) {
        gapMs = ((nowUs - _lastRasterEndUs) / 1000).round();
      }
      _lastRasterEndUs = nowUs;

      // gap 过大（>=500ms）视为窗口遮挡/前台切换造成的节流，不作为卡顿证据。
      final gapTrusted = gapMs >= _gapWarnMs && gapMs < 500;
      if (totalMs < _jankWarnMs && !gapTrusted) continue;

      final level = totalMs >= _jankSevereMs
          ? 'SEVERE'
          : totalMs >= _jankBadMs
              ? 'BAD'
              : 'WARN';
      final dropped = gapTrusted ? (gapMs ~/ 16) - 1 : 0;
      final vsyncUs = t.vsyncOverhead.inMicroseconds;
      _write(
        '===== FRAME $level t=${_sinceStart.elapsedMilliseconds}ms '
        'run=$runId total=${totalMs}ms '
        'build=${(buildUs / 1000).toStringAsFixed(1)}ms '
        'raster=${(rasterUs / 1000).toStringAsFixed(1)}ms '
        'gap=${gapMs}ms dropped~${dropped < 0 ? 0 : dropped}'
        '${vsyncUs > 0 ? ' vsync=${(vsyncUs / 1000).toStringAsFixed(1)}ms' : ''} '
        '=====',
      );
    }
  }

  static void _write(String line) {
    if (!_enabled) return;
    _buffer.add('[${DateTime.now().toIso8601String()}] $line\n');
    // 缓冲写：每 2s 或缓冲较长才落盘，避免日志本身成为卡顿来源。
    if (_buffer.length >= 200) {
      unawaited(_flush());
      return;
    }
    _flushTimer ??= Timer(const Duration(seconds: 2), () {
      _flushTimer = null;
      unawaited(_flush());
    });
  }

  static Future<void> _flush() async {
    final f = _file;
    if (f == null || _buffer.isEmpty || _flushing) return;
    _flushing = true;
    final batch = _buffer.join();
    _buffer.clear();
    _flushTimer?.cancel();
    _flushTimer = null;
    try {
      await f.writeAsString(batch, mode: FileMode.append, flush: true);
    } catch (_) {
      // 静默：日志失败绝不影响功能。
    } finally {
      _flushing = false;
    }
  }
}
