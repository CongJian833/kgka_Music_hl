import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// ====【诊断/冷启动两个问题】====
///
/// 统一写入一个**容易取出**的日志文件（与缓存诊断同一套 region/t= 风格）：
///   * Android：\`/storage/emulated/0/Android/data/<包名>/files/ka_startup_diag.log\`
///     —— 可用文件管理器或 USB 直接拷出，不需要 adb；
///   * Windows / 其它：\`%TEMP%\\ka_startup_diag.log\`。
///
/// 输出通道有三条，任意一条能拿到即可：
///   1) 文件（上面的路径，缓冲异步写）；
///   2) \`debugPrint\` → Android logcat（\`adb logcat -s flutter\`）；
///   3) 内存环形缓冲（[recent]，供后续在界面上展示）。
///
/// region 约定：
///   * \`startup.*\` —— Dart 侧冷启动各阶段
///   * \`native.*\`  —— 原生侧（Kotlin）耗时
///   * \`win.play\` / \`android.play\` —— 播放出声道
class StartupDiagLogger {
  StartupDiagLogger._();

  /// 冷启动起点（main() 最早期调用 [markAppStart]）。
  static final Stopwatch _app = Stopwatch();
  static bool _firstFrameLogged = false;

  /// 文件句柄（首次写入时解析并缓存）。
  static File? _file;
  static bool _fileResolved = false;

  /// 内存环形缓冲（最近 500 条，便于后续在界面里查看）。
  static final List<String> _recent = <String>[];
  static List<String> get recent => List.unmodifiable(_recent);

  static final List<String> _pending = <String>[];
  static Timer? _flushTimer;
  static bool _flushing = false;

  /// 日志开关（诊断期默认开启；\`KA_MUSIC_DIAG=0\` 可关）。
  static bool _enabled = true;
  static bool get enabled => _enabled;

  /// 日志文件的展示路径（未就绪时返回 null；异步解析完成前用 [resolveLogPath])。
  static String? get logPath => _file?.path;

  /// 等待日志文件位置解析完成并返回路径（测试/诊断用）。
  static Future<String?> resolveLogPath() async {
    await _resolveFile();
    return _file?.path;
  }

  /// 诊断用：暴露内部状态，便于排查"路径为什么是 null"。
  static Map<String, Object?> get debugState => {
        'enabled': _enabled,
        'fileResolved': _fileResolved,
        'filePath': _file?.path,
        'appRunning': _app.isRunning,
      };

  /// 在 main() 最早期调用：作为"启动相对时间"零点，并解析日志文件位置。
  static void markAppStart() {
    if (!_app.isRunning) _app.start();
    final env = Platform.environment['KA_MUSIC_DIAG'];
    if (env == '0' || env == 'false') _enabled = false;
    _ensureNativeChannel();
    unawaited(_resolveFile());
  }

  /// 应用启动起点的毫秒数（其它模块可用它对齐时间轴）。
  static int get appElapsedMs => _app.elapsedMilliseconds;

  static bool _nativeChannelReady = false;

  /// 监听原生（Kotlin）主动上报的耗时。\`markAppStart\` 会自动调用一次。
  static void _ensureNativeChannel() {
    if (_nativeChannelReady) return;
    _nativeChannelReady = true;
    try {
      const channel = MethodChannel('kgka_music_hl/diag');
      channel.setMethodCallHandler((call) async {
        if (call.method == 'log') {
          final args = call.arguments;
          if (args is Map) {
            final stage = args['stage']?.toString() ?? '?';
            final ms = args['ms'] is num ? (args['ms'] as num).toInt() : null;
            final note = args['note']?.toString();
            native(stage, ms: ms, note: note);
          }
        }
        return null;
      });
    } catch (_) {
      // 通道不可用（如 Windows 无原生实现）：忽略。
    }
  }

  /// Android 上优先用「外部私有目录」（文件管理器可见、免 adb），其它平台用 TEMP。
  ///
  /// ====【修复】==== 必须共享同一个 Future：`markAppStart` 会 fire-and-forget 调一次，
  /// 之后 `resolveLogPath()` 会再调一次；若不共享，第二次会因 `_fileResolved` 已置位而
  /// 立即返回，导致 `_file` 尚未赋值就取到 null。
  static Future<void>? _resolving;
  static Future<void> _resolveFile() => _resolving ??= _resolveFileOnce();

  static Future<void> _resolveFileOnce() async {
    _fileResolved = true;
    const name = 'ka_startup_diag.log';
    final candidates = <String>[];
    if (Platform.isAndroid) {
      candidates.add(
        '/storage/emulated/0/Android/data/com.hoilai.mm.music/files/$name',
      );
      candidates.add('/sdcard/Android/data/com.hoilai.mm.music/files/$name');
    }
    final tmp = Platform.environment['TEMP'] ??
        Platform.environment['TMP'] ??
        Directory.systemTemp.path;
    candidates.add('$tmp${Platform.pathSeparator}$name');
    for (final path in candidates) {
      try {
        final f = File(path);
        await f.parent.create(recursive: true);
        _file = f;
        break;
      } catch (_) {
        // 试下一个候选位置。
      }
    }
    _write('===== STARTUP DIAG =====');
    _write(
      'path=${_file?.path ?? "(无法创建)"} '
      'platform=${Platform.operatingSystem} pid=$pid '
      'started=${DateTime.now().toIso8601String()}',
    );
    _write('========================');
    await _flush();
  }

  /// 通用阶段日志：ms 为本次阶段耗时。
  static void phase(String stage, {int? ms, String? note, int? extra}) {
    _write(
      '[DIAG] t=${_app.elapsedMilliseconds}ms region=startup.$stage'
      '${ms == null ? '' : ' ms=$ms'}'
      '${extra == null ? '' : ' extra=$extra'}'
      '${note == null ? '' : ' $note'}',
    );
  }

  /// 原生侧（Kotlin）耗时：由 MethodChannel 传进来。
  static void native(String stage, {int? ms, String? note}) {
    _write(
      '[DIAG] t=${_app.elapsedMilliseconds}ms region=native.$stage'
      '${ms == null ? '' : ' ms=$ms'}'
      '${note == null ? '' : ' $note'}',
    );
  }

  /// 播放链路打点（Windows 专用别名，music_audio_handler 使用）。
  static void winPlay(String note, {int? ms}) => play(note, ms: ms);

  /// 播放链路打点（Windows/Android 通用）。
  static void play(String note, {int? ms}) {
    final region = Platform.isAndroid ? 'android.play' : 'win.play';
    _write(
      '[DIAG] t=${_app.elapsedMilliseconds}ms region=$region'
      '${ms == null ? '' : ' ms=$ms'} $note',
    );
  }

  /// 本地音乐扫描打点（用于确认"歌很少时是否仍慢"）。
  static void localMusic(String note, {int? ms, int? extra}) {
    _write(
      '[DIAG] t=${_app.elapsedMilliseconds}ms region=startup.localMusic'
      '${ms == null ? '' : ' ms=$ms'}'
      '${extra == null ? '' : ' extra=$extra'} $note',
    );
  }

  /// 记录首帧上屏的近似时刻（启动可用性最直观的指标）。
  static void markFirstFrame() {
    if (_firstFrameLogged) return;
    _firstFrameLogged = true;
    Future<void>.delayed(Duration.zero, () => phase('firstFrameTick'));
  }

  /// 刷盘（启动阶段日志需要尽快可见）。
  static Future<void> flush() => _flush();

  static void _write(String line) {
    if (!_enabled) return;
    final stamped = '[${DateTime.now().toIso8601String()}] $line';
    _recent.add(stamped);
    if (_recent.length > 500) _recent.removeRange(0, _recent.length - 500);
    // 2) logcat / 控制台
    debugPrint(line);
    // 1) 文件（缓冲）
    _pending.add('$stamped\n');
    if (_pending.length >= 100) {
      unawaited(_flush());
      return;
    }
    _flushTimer ??= Timer(const Duration(seconds: 1), () {
      _flushTimer = null;
      unawaited(_flush());
    });
  }

  static Future<void> _flush() async {
    final f = _file;
    if (f == null || _pending.isEmpty || _flushing) return;
    _flushing = true;
    final batch = _pending.join();
    _pending.clear();
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
