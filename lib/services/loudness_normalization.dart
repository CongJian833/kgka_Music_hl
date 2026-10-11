// ====【新增/响度归一化·编排】全局常驻的"按曲目响度施加固定增益"====
//
// 目标（与业界一致）：
//   测量每首歌的 integrated LUFS（BS.1770），播放时施加单一固定增益偏移
//   `target − measured`（受真峰值预算约束），使不同歌曲听感音量一致，
//   且【完整保留歌曲动态】——这是与旧"曲内动态压缩"方案的本质区别。
//
// 为什么用"常驻单例 + 监听切歌"（而非在播放页内做）：
//   与 adaptive_lyric_color.dart 同因——功能必须在任何页面/任何播放状态下都生效，
//   不能依赖某个临时路由页存活。attach 一次即全局有效。
//
// 数据流（每首歌）：
//   1. 换源前（handler.onSourceLoaded）→ [onSourceLoaded]
//        · 内存命中该曲响度 → 立即算增益并写入（换流时值已正确，无跳变）
//        · 未命中 → 先归零（防止上一首增益误用于新歌），再排队后台分析
//   2. 后台分析（串行队列，一次只跑一首）
//        · 拿 PCM：优先复用已有本地文件（本地歌/播放缓存），在线首播则等待缓存落盘
//        · 分析结果写缓存 cache_loudness_v1_{hash}_{quality}_{source}
//   3. 分析完成 → 若仍是当前歌且处于早期（避免歌中途出现音量台阶）才应用增益
//
// 关键安全设计（对齐项目"卡顿零容忍"取向）：
//   * 串行队列：同一时刻只解码/分析一首，避免并发抢 IO/CPU
//   * 分块让出：解码每 0.5s 音频让出一次事件循环（见 windows_loudness_decoder）
//   * 延迟启动：换歌后延迟 600ms 再开始分析，避开切歌高峰
//   * 竞态防护：_serial 序号门禁 + 取消标志，切歌立即放弃上一次分析
//   * 失败静默：任何失败都只记日志 + 写负缓存，绝不影响播放
//
// 回退：[_kLoudnessEnabledOnWindows] / [_kLoudnessEnabledOnAndroid] 置 false 即完全不启动分析。
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;

import '../controllers/player_controller.dart';
import '../models/music_models.dart';
import 'android_loudness_decoder.dart';
import 'cache_service.dart';
import 'loudness_analyzer.dart';
import 'loudness_gain_policy.dart';
import 'music_audio_handler.dart';
import 'windows_loudness_decoder.dart';

// ====【新增/响度归一化·平台开关（一键回退）】====
// 置 false 即在该平台完全不启动分析（行为等价于未改造），便于快速回退排查。
const bool _kLoudnessEnabledOnWindows = true;
const bool _kLoudnessEnabledOnAndroid = true;

/// 分析结果的缓存版本号：算法/参数变更时递增，旧缓存自然失效。
const int _kLoudnessCacheVersion = 1;

/// 分析结果缓存 TTL（响度对固定文件是常量，TTL 仅作保险；读取时忽略过期）。
const Duration _kLoudnessCacheTtl = Duration(days: 180);

/// 失败负缓存 TTL（避免每次都重试同一首无法分析的歌）。
const Duration _kLoudnessNegativeTtl = Duration(days: 7);

/// 换歌后延迟多久开始分析。
/// ====【性能优化/缩短分析耗时】==== 原为 600ms，目的是避开切歌高峰；
/// 但分析本身已优化到约 1 秒（4 分钟歌），600ms 的启动延迟占比过大，
/// 会让"切歌后生效"明显变慢。现降至 200ms：足以避开切歌瞬间的 notify 风暴，
/// 又几乎不拖慢生效时间。
const Duration _kLoudnessStartDelay = Duration(milliseconds: 200);

/// 在线歌等待"播放缓存落盘"的最长时间（超时则本次播放不归一化，不影响播放）。
const Duration _kLoudnessCacheWaitTimeout = Duration(seconds: 90);

/// 预分析（空闲批量预扫描）的任务间隔。
/// 每分析完一首停顿这么久再继续，避免后台持续占用 CPU/IO；用户切歌/暂停会立即中止。
const Duration _kPrescanInterval = Duration(seconds: 3);

/// 单轮预扫描的最大首数：防止超大队列（如数千首歌单）长时间后台跑。
const int _kPrescanMaxPerRun = 100;

/// ====【新增/主动下载】==== 单个预下载的最长等待时间。
/// 超时视为失败（放弃该首，允许后续重试），避免某首拉不下来时卡住整个预扫描。
const Duration _kDownloadTimeout = Duration(seconds: 120);

/// ====【缓存可控：交由用户手动清理】====
/// 注：响度缓存（每首歌一条，约 200 字节）不做自动裁剪/过期删除——自动删除会让
/// 已分析好的歌重新分析、白费算力；改由设置页「缓存管理」的独立条目手动清理
///（见 CacheService.loudnessCachePrefix / prefixStats / removeByPrefix）。

/// 分析完成后允许"追认"增益的最大播放位置。
///
/// ====【性能优化/缩短生效等待】==== 原为 30s，导致"分析只要晚于 30 秒就失效、
/// 必须重播一次"，用户体感是"要等/要重播"。分析已优化到约 1 秒（4 分钟歌），
/// 现实中绝大多数情况会在几秒内完成，30s 的限制过严。现放宽到 90s：
/// 仍能避免"歌曲播到很后面才突然变音量"的突兀感（那时用户已适应音量）。
const Duration _kLoudnessApplyMaxPosition = Duration(seconds: 90);

/// [响度归一化] 全局编排（静态单例，应用启动时 attach 一次）。
class LoudnessNormalization {
  LoudnessNormalization._();

  static PlayerController? _player;
  static MusicAudioHandler? _handler;
  static CacheService? _cache;
  static bool _attached = false;

  /// 用户开关（与 PlayerController.volumeNormalizationEnabled 同步）。
  static bool _enabled = false;

  /// 目标响度档位。
  static LoudnessTarget _target = LoudnessTarget.normal;

  /// ====【响度归一化·预分析】空闲预分析开关（默认关闭，与设置页联动）====
  /// 关闭时 _schedulePrescan 直接返回：不做任何后台扫描/下载，
  /// 切歌仍走按需即时分析（约 1 秒生效）。
  static bool _prescanEnabled = false;

  /// 竞态门禁：只有最后一次请求的结果会被采用（防切歌把旧歌增益写到新歌上）。
  static int _serial = 0;

  /// 当前歌曲的缓存 key（换歌时更新）。
  static String _currentKey = '';

  /// 当前已施加的增益（诊断/UI 用）。null = 未归一化（关闭/无结果）。
  static double? _currentGainDb;

  /// 内存缓存：key → 测量结果（避免每次切歌都读盘）。
  /// 用简易 LRU（插入顺序淘汰最早的），上限 [_memoryCacheLimit] 条。
  static final Map<String, LoudnessResult> _memory = <String, LoudnessResult>{};
  static final List<String> _memoryOrder = <String>[];
  static const int _memoryCacheLimit = 200;

  /// 分析任务串行链（保证同一时刻只跑一首）。
  static Future<void> _queue = Future<void>.value();

  /// 当前分析任务的取消标志。
  static bool _cancelRequested = false;

  /// 是否已挂载。
  static bool get isAttached => _attached;

  /// 当前增益（dB）；null = 未施加。
  static double? get currentGainDb => _currentGainDb;

  /// 当前目标档位。
  static LoudnessTarget get target => _target;

  /// 本平台是否支持响度归一化。
  static bool get isSupported {
    if (kIsWeb) return false;
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return _kLoudnessEnabledOnWindows;
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      return _kLoudnessEnabledOnAndroid;
    }
    return false;
  }

  /// 挂载：应用启动构建 PlayerController 后调用一次。重复调用安全（幂等）。
  static void attach(
    PlayerController player,
    MusicAudioHandler handler, {
    required CacheService cache,
  }) {
    if (_attached) return;
    _attached = true;
    _player = player;
    _handler = handler;
    _cache = cache;
    _target = player.loudnessTarget;
    _enabled = player.volumeNormalizationEnabled;
    _prescanEnabled = player.loudnessPrescanEnabled;
    handler.onSourceLoaded = onSourceLoaded;
  }

  /// 卸载：应用退出时调用。
  static void detach() {
    if (!_attached) return;
    _handler?.onSourceLoaded = null;
    _attached = false;
    _player = null;
    _handler = null;
    _cache = null;
    _cancelRequested = true;
    _serial++;
    // 停止预扫描续扫定时器，避免退出后仍持有引用。
    _prescanTimer?.cancel();
    _prescanTimer = null;
  }

  /// 开关变化（由 PlayerController.setVolumeNormalizationEnabled 调用）。
  static Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    if (!enabled) {
      // 关闭：撤销增益并取消在跑的分析。
      _cancelRequested = true;
      _serial++;
      _currentGainDb = null;
      _prescanTimer?.cancel();
      _prescanTimer = null;
      await _handler?.setNormalizationGainDb(0);
      await _applyAndroidLoudnessGain(0, enabled: false);
      return;
    }
    // 打开：对当前歌立即尝试（缓存命中即刻生效；未命中则触发分析）。
    final song = _player?.currentSong;
    if (song != null) {
      _scheduleForSong(song);
    }
    // ====【性能优化】开启后即启动空闲预扫描，后续切歌尽快就绪。====
    _schedulePrescan();
  }

  /// ====【响度归一化·预分析】应用前后台状态 ====
  /// 应用进入后台时置 false：预扫描立即停止（不再触发新的下载/分析），
  /// 避免后台持续消耗移动流量与电量（Android 上尤其重要）。
  /// 已在进行的单次下载会自然完成（最多一首），不做强制中断。
  static bool _appActive = true;

  /// 由 main.dart 的生命周期回调驱动。
  static void setAppActive(bool active) {
    if (_appActive == active) return;
    _appActive = active;
    if (!active) {
      _prescanTimer?.cancel();
      _prescanTimer = null;
      _downloadInFlightSong = null;
      _downloadStartedAt = null;
      return;
    }
    _prescanSessionCount = 0;
    _schedulePrescan();
  }

  /// ====【响度归一化·预分析】开关空闲预分析（设置页联动）====
  ///
  /// 关闭：立即停止后续扫描（正在跑的一首会自然结束），并取消续扫定时器与
  ///   在途的预下载标记；切歌仍按需即时分析。
  /// 开启：立刻尝试启动一轮预扫描（由近及远、优先当前歌前后几首）。
  static Future<void> setPrescanEnabled(bool enabled) async {
    if (_prescanEnabled == enabled) return;
    _prescanEnabled = enabled;
    if (!enabled) {
      _prescanTimer?.cancel();
      _prescanTimer = null;
      _downloadInFlightSong = null;
      _downloadStartedAt = null;
      _skipCache.clear();
      _noSourceCache.clear();
      return;
    }
    _prescanSessionCount = 0;
    _skipCache.clear();
    _noSourceCache.clear();
    _schedulePrescan();
  }

  /// ====【响度缓存被手动清理后调用】====
  /// 用户在设置页清理了「响度分析缓存」后，需清空相关内存标记，
  /// 否则预扫描仍认为那些歌"已处理"，不会重新分析。
  static void onLoudnessCacheCleared() {
    _skipCache.clear();
    _noSourceCache.clear();
    _memory.clear();
    _memoryOrder.clear();
    _prescanSessionCount = 0;
    _schedulePrescan();
  }

  /// 目标档位变化：立即按新目标重算当前歌增益。
  static Future<void> setTarget(LoudnessTarget target) async {
    if (_target == target) return;
    _target = target;
    final song = _player?.currentSong;
    if (song == null || !_enabled) return;
    final result = _memory[_currentKey] ?? await _readCache(song);
    if (result != null) {
      await _applyGainFor(result);
      _schedulePrescan(); // 续跑预扫描（档位切换不应打断链条）
    } else {
      // 无测量结果：触发一次（可能此前未分析）。
      _scheduleForSong(song);
    }
  }

  /// 外部触发重放（音频会话变化 / 播放器重建后调用）。
  /// Android 上 gain 效果绑定 audioSessionId，会话重建后参数会丢，需要重放。
  static Future<void> refreshGain() async {
    if (!_enabled || !_attached) return;
    final result = _memory[_currentKey];
    if (result != null) {
      await _applyGainFor(result);
    }
  }

  /// 换源前钩子（handler.loadSong 内同步调用，必须快速返回）。
  ///
  /// 同步部分只做"命中即写增益 / 否则归零"，耗时分析一律异步排队。
  static void onSourceLoaded(Song song, String url) {
    if (!_attached || !_enabled || !isSupported) {
      // 未启用：确保没有残留增益。
      unawaited(_clearGain());
      return;
    }
    _serial++;
    _cancelRequested = true; // 取消上一次分析（若有）
    _currentKey = _cacheKeyFor(song);
    // ====【修复/预扫描重复扫描同一批歌】====
    // 原实现在切歌时清空 _skipCache / _noSourceCache，导致每次切歌后预扫描都要
    // 重新遍历并重新检查整批"已分析过/无本地文件"的歌 —— 在 1600+ 首的歌单里
    // 表现为"同一首歌在日志里反复出现"（用户实测反馈），并带来每轮上千次
    // 磁盘存在性检查的开销。
    // 现改为：这两个集合是【稳定的歌曲状态标记】，与切歌无关，故不再清空：
    //   * _skipCache（磁盘已有结果）：只有手动清理响度缓存后才会失效；
    //   * _noSourceCache（无本地文件）：下载完成时由 _updateDownloadInFlight 精确移除；
    //     当前播放的歌由播放路径自行分析，不依赖本标记。
    // 仅重置本次会话计数，让预扫描在新的一首上继续有额度可用。
    _prescanSessionCount = 0;

    final cached = _memory[_currentKey];
    if (cached != null) {
      // 命中内存：同步写入增益（换流时即为正确值，无跳变）。
      _applyGainSyncFor(cached);
      // ====【修复/预扫描链条断裂】==== 命中内存也要续跑预扫描（同"命中磁盘"，
      // 否则反复命中缓存会让后台预扫描彻底停摆，随机播放时又退回"当场等分析"）。
      // 注意：本项目绝大多数切歌都会命中缓存（听过即缓存），因此这里是预扫描
      // 最主要的续跑入口 —— 缺失它会表现为"预扫描只跑一次/几乎不跑"（实测暴露）。
      _schedulePrescan();
      return;
    }
    // 未命中：先归零，避免上一首的增益作用到新歌上。
    unawaited(_clearGain());
    _scheduleForSong(song);
    // ====【修复/预扫描不启动】==== 切歌是最常见的"状态变化"事件，
    // 也应作为续跑预扫描的触发点：仅靠"分析完成/命中缓存"回调，
    // 会出现"长时间听同一首或频繁切歌时预扫描迟迟不跑"的情况（实测暴露）。
    _schedulePrescan();
  }

  /// 把增益同步写入平台（内存命中路径，避免 await 造成切歌跳变）。
  static void _applyGainSyncFor(LoudnessResult result) {
    final gain = computeLoudnessGain(
      targetLufs: _target.lufs,
      songLufs: result.lufs,
      samplePeakDbfs: result.peakDbfs,
    );
    _currentGainDb = gain.isZero ? null : gain.gainDb;
    // Windows：BASS 提供同步接口，立即写入。
    // Android：正增益需原生通道（异步），此处仅处理音量衰减（同步性要求不高）。
    if (defaultTargetPlatform == TargetPlatform.windows) {
      _handler?.setNormalizationGainDbSync(gain.gainDb);
    } else {
      unawaited(_applyGainFor(result));
    }
  }

  /// 归零增益（切歌/关闭时调用）。
  static Future<void> _clearGain() async {
    _currentGainDb = null;
    await _handler?.setNormalizationGainDb(0);
    await _applyAndroidLoudnessGain(0, enabled: false);
  }

  /// 按测量结果计算并施加增益。
  static Future<void> _applyGainFor(LoudnessResult result) async {
    final gain = computeLoudnessGain(
      targetLufs: _target.lufs,
      songLufs: result.lufs,
      samplePeakDbfs: result.peakDbfs,
    );
    _currentGainDb = gain.isZero ? null : gain.gainDb;
    await _handler?.setNormalizationGainDb(gain.gainDb);
    // Android：正增益走 LoudnessEnhancer（纯提升类效果），负增益已由音量承担。
    await _applyAndroidLoudnessGain(
      gain.gainDb > 0 ? gain.gainDb : 0,
      enabled: gain.gainDb > 0,
    );
  }

  /// Android 原生 LoudnessEnhancer 通道（其它平台直接跳过）。
  static Future<void> _applyAndroidLoudnessGain(
    double gainDb, {
    required bool enabled,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final player = _player;
    if (player == null) return;
    try {
      await player.applyLoudnessEnhancerGain(gainDb, enabled: enabled);
    } catch (_) {
      // 静默：效果不可用（部分 ROM）时降级，不影响播放与衰减路径。
    }
  }

  /// 排队为该歌曲做分析（异步；内部串行、延迟启动、可取消）。
  static void _scheduleForSong(Song song) {
    if (!_enabled || !isSupported) return;
    final key = _cacheKeyFor(song);
    final mySerial = _serial;
    _queue = _queue.then((_) async {
      // 排队期间可能已切歌/关闭 → 直接放弃。
      if (mySerial != _serial || !_enabled) return;
      await _runAnalysis(song, key, mySerial);
    }).catchError((Object e) {
      // 静默：单首分析异常不影响播放，也不中断队列。
    });
  }

  /// 实际执行分析：解析音频来源 → 解码分析 → 缓存 → （满足条件则）应用。
  static Future<void> _runAnalysis(Song song, String key, int mySerial) async {
    // 入队期间已被切歌淘汰 → 立即让出队列，不占用延迟（否则快速连续切歌时，
    // 若干已失效任务各等 200ms 会拖慢最后那次真正需要的分析）。
    if (mySerial != _serial) return;
    // 延迟启动：避开切歌高峰（期间若被取消则退出）。
    await Future<void>.delayed(_kLoudnessStartDelay);
    if (mySerial != _serial) return;

    // 1) 先查磁盘缓存（可能由上次会话写入）。
    final fromDisk = await _readCache(song);
    if (fromDisk != null) {
      if (mySerial != _serial) return;
      _rememberInMemory(key, fromDisk);
      _applyIfStillCurrent(song, fromDisk, mySerial);
      // ====【修复/预扫描链条断裂】==== 命中磁盘缓存时同样要继续预扫描，
      // 否则"预取→命中缓存→不再预取"会让预扫描只发生一次（实测暴露）。
      _schedulePrescan();
      return;
    }

    // 1b) 已知不可分析（有效负缓存）→ 跳过本次，省 CPU/网络。
    if (await _hasValidNegativeCache(song)) {
      _schedulePrescan(); // 同上：链条不可断
      return;
    }
    if (mySerial != _serial) return;

    // 2) 解析可分析的音频来源。
    final source = await _resolveAudioSource(song, mySerial);
    if (source == null) {
      await _writeNegativeCache(key, 'no_source');
      return;
    }
    if (mySerial != _serial) return;

    // 3) 解码 + 测量。
    _cancelRequested = false;
    LoudnessResult? result;
    try {
      result = await _analyzeSource(source, song, () => _cancelRequested || mySerial != _serial);
    } catch (_) {
      // 静默：分析异常按"无结果"处理（写负缓存，避免反复重试）。
    }
    if (mySerial != _serial) return; // 已切歌：结果丢弃（但仍占用了一次分析）

    if (result == null) {
      await _writeNegativeCache(key, 'analyze_failed');
      return;
    }

    // 4) 写缓存 + 记忆 + 有条件应用。
    _rememberInMemory(key, result);
    await _writeCache(key, result, song);
    _applyIfStillCurrent(song, result, mySerial);
    // ====【性能优化】当前歌处理完后，启动空闲批量预扫描 ====
    // 让后续切歌（含随机播放）能直接命中缓存 → 增益立即生效。
    // 注意：命中缓存的多条路径也必须调用本方法，否则预扫描链条会断（实测踩到）。
    _schedulePrescan();
  }

  // ====【性能优化/空闲批量预扫描】====
  // 为什么不是"只预取队列下一首"（原实现的问题，实测暴露）：
  //   1) 链条会断：下一首被预取后，切过去时是"命中缓存"路径，而该路径不会再触发
  //      对第三首的预取 → 预取只发生一次；
  //   2) 随机播放必然失效：随机模式是当场 _random.nextInt() 抽曲，事先不可知，
  //      而"队列顺序的下一首"几乎永不等于它。
  // 业界做法参考（foobar2000 官方文档）：ReplayGain 扫描"很耗时"，应当
  //   "在文件加入库时就扫描"或"让电脑在空闲时算"——即【库级批量预扫描】。
  // 本实现按同一思路：播放稳定时，从当前曲目向两侧由近及远，逐首分析未缓存的歌；
  //   每首之间停顿 [_kPrescanInterval]、单轮上限 [_kPrescanMaxPerRun]、
  //   暂停/缓冲/切歌/关闭开关时立即中止本轮。这样无论顺序还是随机播放，
  //   听过的歌都已有结果，切歌基本零等待。

  /// 本轮预扫描是否正在运行（防止重复入队）。
  static bool _prescanRunning = false;

  /// 续扫定时器（用 Timer 而非占用串行队列，避免拖慢"切歌后的新歌分析"）。
  static Timer? _prescanTimer;

  /// 本次会话已自动扫描的累计首数（达到 [_kPrescanMaxPerRun] 后停止自动续扫，
  /// 避免长时间无人值守地持续占用 CPU/IO；后续切歌仍可再次触发）。
  static int _prescanSessionCount = 0;

  /// "本次会话内已确认无需再处理"的歌曲 key 缓存（= 磁盘已有结果 / 已有负缓存）。
  /// 用于避免重复分析、以及避免选中后反复跳过原地打转。切歌时清空。
  static final Set<String> _skipCache = <String>{};

  /// "当前确认为【没有本地文件】"的歌曲 key 缓存（仅供分析路径跳过用）。
  ///
  /// ====【修复/下载目标被自己屏蔽】====
  /// 必须与 [_skipCache] 分开：分析路径要把"无本地文件"的歌记为跳过（省磁盘检查），
  /// 但下载路径的目标恰恰就是这些歌。若共用一个集合，第一次扫描就会把
  /// "需要下载的歌"全部标记为跳过，导致下载路径永远找不到目标 ——
  /// 表现为"预扫描结束：队列内已无可分析的歌曲"、触发下载 0 次（实测暴露）。
  static final Set<String> _noSourceCache = <String>{};

  // ====【新增/主动下载：覆盖未听过的在线歌】====
  /// 当前正在预下载的歌曲（null = 没有下载在进行）。
  /// 用 Song 引用而非 key，便于直接检查"是否已生成本地文件"。
  /// 约束：同一时刻最多一个预下载 —— 并发下载会拉满带宽、拖垮正在播放的音频。
  static Song? _downloadInFlightSong;
  static DateTime? _downloadStartedAt;

  /// 维护预下载状态：下载完成则放行（交给分析路径），超时则放弃。
  static void _updateDownloadInFlight() {
    final s = _downloadInFlightSong;
    if (s == null) return;
    if (_hasAnalyzableSourceNow(s)) {
      // 下载完成 → 清除标志，下一轮由分析路径接管这首歌。
      _downloadInFlightSong = null;
      _downloadStartedAt = null;
      // ====【修复/下载完成的歌仍被当作"无本地文件"】====
      // 该歌在下载【之前】的扫描中已被记入 _noSourceCache（那时确实没有本地文件），
      // 若不在此移除，分析路径会继续跳过它 —— 表现为"下载完成了却迟迟不分析，
      // 只有等切歌清空缓存后才轮到"（实测日志暴露：触发下载 17 次但预扫描分析仅 2 次）。
      _noSourceCache.remove(_cacheKeyFor(s));
      return;
    }
    final started = _downloadStartedAt;
    if (started != null && DateTime.now().difference(started) > _kDownloadTimeout) {
      _downloadInFlightSong = null;
      _downloadStartedAt = null;
      _skipCache.add(_cacheKeyFor(s)); // 本轮不再尝试这首
    }
  }

  /// 启动/继续空闲预扫描（幂等）。
  ///
  /// ====【重构/单首扫描 + 定时续扫】====
  /// 原实现把"整批歌"放在一次队列任务里跑完（含 3 秒节流等待），会导致：
  ///   1) 新歌分析排在它后面，切歌后最多要等满一个节流间隔才轮到（体验倒退）；
  ///   2) 一旦中途被判定放弃，整批就结束了，需依赖外部事件重新拉起。
  /// 现改为：每次队列任务只分析【一首】，用 Timer 安排下一首（不占队列），
  /// 这样新歌分析最多等"当前这一首"（约 1 秒），且链条自然持续。
  static void _schedulePrescan({bool delayed = false}) {
    // ====【响度归一化·预分析】默认关闭：未开启预分析时不做任何后台扫描/下载。====
    if (!_prescanEnabled) return;
    if (!_enabled) return;
    if (!isSupported) return;
    if (_prescanRunning) return;
    if (_prescanSessionCount >= _kPrescanMaxPerRun) return;
    _prescanTimer?.cancel();
    if (delayed) {
      _prescanTimer = Timer(_kPrescanInterval, () => _schedulePrescan());
      return;
    }
    _prescanRunning = true;
    // ====【修复/预扫描被长任务堵死】====
    // 原实现把预扫描排在 _queue 串行队列尾部。而"当前歌分析"在在线歌首播时会
    // 等待播放缓存落盘（最多 90 秒），把队列堵住 → _prescanRunning 长期为 true，
    // 后续所有 _schedulePrescan 调用都被静默忽略，表现为"预扫描完全不工作"（实测暴露）。
    // 现在预扫描走独立通道，仅通过 [_decodeRunning] 与"解码期"互斥（避免并发解码抢 IO）。
    unawaited(_runPrescanOnce());
  }

  /// 预扫描一首（每次只做一首），结束后安排下一首。
  static Future<void> _runPrescanOnce() async {
    var analyzed = false;
    var abort = false;
    var hasTarget = false;
    var retry = false;
    try {
      if (!_prescanEnabled) return;
      if (!_appActive) {
        retry = false; // 后台时不重试，等回到前台由 setAppActive 重新启动
        return;
      }
      final player = _player;
      if (player == null) return;
      // 原实现在这里"等待播放就绪最长 2 秒"并占用串行队列，而切歌后 FLAC 大文件
      // 缓冲常超过 2 秒 → 每次都超时放弃；且等待本身堵住队列。现改为：
      // 不等待，条件不满足就安排 1 秒后重试（不占队列、不阻塞任何分析任务）。
      //   判据放宽为"未缓冲"（不再要求 isPlaying）：暂停时同样可以后台预分析，
      //   此时用户不在听，是最不打扰的时机。
      if (player.isBuffering) {
        retry = true;
        return;
      }
      // 与"正在解码"互斥：避免两路解码同时抢 CPU/IO（等待缓存落盘不算解码）。
      if (_decodeRunning) {
        retry = true;
        return;
      }

      // 维护预下载状态（完成→放行给分析路径；超时→放弃并跳过）。
      _updateDownloadInFlight();

      // 1) 优先分析"已有本地文件且未分析"的歌（零下载成本）。
      var song = _nextPrescanTarget();
      if (song != null) {
        hasTarget = true;
        final r = await _prescanOne(song, _cacheKeyFor(song), _serial);
        analyzed = r.analyzed;
        abort = r.abort;
        return;
      }

      // ====【主动下载：覆盖"没听过的在线歌"】====
      // 队列里已无"可立即分析"的歌时，取下一首就近且未下载的歌主动下载，
      // 下载完成后它就有了本地文件，后续轮次即可分析。
      // 关键约束：一次只触发一个下载 —— 否则会并发拉满带宽，直接拖垮正在播放的音频。
      if (_downloadInFlightSong != null) {
        // 已有下载在进行：安排下一轮来接手（不触发新下载）。
        retry = true;
        return;
      }
      song = _nextDownloadTarget();
      if (song == null) {
        return;
      }
      hasTarget = true;
      final ok = await _player?.preparePlayCacheForPrefetch(song) ?? false;
      if (ok) {
        _downloadInFlightSong = song;
        _downloadStartedAt = DateTime.now();
      } else {
        _skipCache.add(_cacheKeyFor(song)); // 无可用播放地址，跳过
      }
    } catch (_) {
      // 单轮预扫描异常不影响播放：静默忽略。
    } finally {
      _prescanRunning = false;
      if (analyzed) _prescanSessionCount++;
      if (retry) {
        // 条件暂不满足（缓冲中/正在解码/等下载）：1 秒后重试。
        _prescanTimer?.cancel();
        _prescanTimer = Timer(
          const Duration(seconds: 1),
          () => _schedulePrescan(),
        );
      } else if (hasTarget && !abort) {
        // 正常进展：按节流间隔继续下一首。
        _schedulePrescan(delayed: true);
      }
    }
  }

  /// 选取下一个"待下载"目标：就近且尚未下载的在线歌（同样先近后远、优先往后）。
  ///
  /// 与 [_nextPrescanTarget] 的区别：本方法专门挑"当前没有本地文件"的歌，
  /// 用于主动下载以覆盖"没听过的在线歌"。
  static Song? _nextDownloadTarget() {
    final player = _player;
    if (player == null) return null;
    final q = player.queue;
    if (q.length < 2) return null;
    final cur = player.currentIndex;
    if (cur < 0 || cur >= q.length) return null;
    final currentHash = player.currentSong?.hash;

    for (var d = 1; d < q.length; d++) {
      for (final idx in <int>[
        (cur + d) % q.length,
        (cur - d + q.length) % q.length,
      ]) {
        final s = q[idx];
        if (s.hash == currentHash) {
          continue; // 当前歌由播放路径负责缓存
        }
        if (s.source == SongSource.local) {
          continue; // 本地歌无需下载
        }
        final key = _cacheKeyFor(s);
        if (_skipCache.contains(key)) {
          continue;
        }
        if (_memory.containsKey(key)) {
          continue;
        }
        if (_hasAnalyzableSourceNow(s)) {
          continue; // 已有本地文件 → 交给分析路径
        }
        return s;
      }
    }
    return null;
  }

  /// 选取下一个预扫描目标：从当前曲目向两侧由近及远，找第一首"可立即分析且无结果"的歌。
  ///
  /// ====【修复/预扫描静默跳过】====
  /// 原实现只排除"内存已有结果"的歌，于是会选中大量【在线且尚无本地文件】的歌：
  /// _prescanOne 拿到 null 来源后静默 return，导致"预扫描看似 0 次、无任何日志"
  ///（实测暴露）。现在在选目标时就要求"当前已有可分析的本地来源"：
  ///   * 本地歌曲 → 文件存在
  ///   * 在线歌曲 → downloadController 已有下载/播放缓存文件
  /// 这样预扫描只处理"能立刻分析"的歌，零额外网络。
  static Song? _nextPrescanTarget() {
    final player = _player;
    if (player == null) return null;
    final q = player.queue;
    if (q.length < 2) {
      return null;
    }
    final cur = player.currentIndex;
    if (cur < 0 || cur >= q.length) {
      return null;
    }
    final currentHash = player.currentSong?.hash;

    for (var d = 1; d < q.length; d++) {
      // 先近后远：+d（往后）与 -d（往前）交替，优先"往后"（更可能是下一首）
      for (final idx in <int>[
        (cur + d) % q.length,
        (cur - d + q.length) % q.length,
      ]) {
        final s = q[idx];
        if (s.hash == currentHash) {
          continue;
        }
        final key = _cacheKeyFor(s);
        if (_skipCache.contains(key)) {
          continue;
        }
        if (_memory.containsKey(key)) {
          continue;
        }
        if (_noSourceCache.contains(key)) {
          continue;
        }
        if (!_hasAnalyzableSourceNow(s)) {
          _noSourceCache.add(key); // 记录"无本地文件"（下载路径仍会用它）
          continue;
        }
        return s;
      }
    }
    return null;
  }

  /// 该歌曲当前是否已有"可立即分析的本地来源"（不产生任何网络请求）。
  ///
  /// 说明：这是预扫描的硬前提。未听过的在线歌既无下载也无播放缓存，
  /// 要么等它自然产生缓存、要么另开网络下载（会与播放抢带宽），故此处不选它。
  static bool _hasAnalyzableSourceNow(Song song) {
    if (song.source == SongSource.local) {
      return File(song.id).existsSync();
    }
    final downloader = _player?.downloadController;
    if (downloader == null) return false;
    final quality = _player?.audioQuality;
    if (quality == null) return false;
    final p = downloader.localPathFor(song, quality);
    return p != null && File(p).existsSync();
  }

  /// 预扫描单首：只解码+测量+写缓存，不施加增益（用户还没听到这首歌）。
  ///
  /// [mySerial] 必须由调用方传入"本轮预扫描的起始序号"，不可在内部重读 _serial ——
  /// 否则切歌后内部会认为"没切歌"而继续分析，抢占用户正在听的新歌资源。
  ///
  /// 返回：(analyzed=本首是否真的完成了分析, abort=是否应中止整个预扫描)
  /// abort 仅在被切歌/暂停/缓冲/关闭开关时置位；"跳过"类情况（已有结果、
  /// 无本地来源）返回 analyzed=false 且 abort=false，让调用方继续尝试下一首。
  static Future<({bool analyzed, bool abort})> _prescanOne(
    Song song,
    String key,
    int mySerial,
  ) async {
    const skip = (analyzed: false, abort: false);
    const stop = (analyzed: false, abort: true);
    try {
      if (!_enabled) return stop;
      if (_player == null) return stop;

      // 已有结果（内存/磁盘）→ 无需重复劳动。
      if (_memory.containsKey(key)) return skip;
      if (await _readCache(song) != null) {
        _skipCache.add(key); // 磁盘已有结果：记下，避免下轮重复选中它
        return skip;
      }
      if (await _hasValidNegativeCache(song)) {
        _skipCache.add(key);
        return skip;
      }
      if (!_stillScanning(mySerial)) return stop;

      // 预扫描不为在线歌等待缓存落盘（低优先级，不占用队列）。
      final source = await _resolveAudioSource(
        song,
        mySerial,
        cacheWait: Duration.zero,
      );
      if (source == null) {
        _noSourceCache.add(key); // 记录"无本地文件"（下载路径仍会用它）
        return skip;
      }
      if (!_stillScanning(mySerial)) return stop;

      final result = await _analyzeSource(
        source,
        song,
        () => !_stillScanning(mySerial),
      );
      if (result == null || result.lufs == null) {
        // 写负缓存：避免每次预扫描都重试同一首无法分析的歌。
        await _writeNegativeCache(key, 'prescan_failed');
        return skip;
      }
      if (!_stillScanning(mySerial)) return stop;

      _rememberInMemory(key, result);
      await _writeCache(key, result, song);
      return (analyzed: true, abort: false);
    } catch (_) {
      return skip; // 单首异常不中止整轮
    }
  }

  /// 预扫描是否应继续：预分析开关开启、响度开关开启、未缓冲、且未切歌。
  /// 注：不要求 isPlaying —— 暂停时用户不在听，正是最适合后台预分析的时机。
  static bool _stillScanning(int mySerial) {
    if (!_prescanEnabled) return false; // 预分析开关关闭 → 立即停止
    if (!_appActive) return false; // 应用在后台 → 立即停止（省流量/电量）
    if (!_enabled) return false;
    if (mySerial != _serial) return false; // 已切歌 → 让位给新歌
    final player = _player;
    if (player == null) return false;
    if (player.isBuffering) return false; // 缓冲中不抢带宽/IO
    return true;
  }

  /// 分析完成后是否/如何应用增益（避免歌中途出现音量台阶）。
  static void _applyIfStillCurrent(
    Song song,
    LoudnessResult result,
    int mySerial,
  ) {
    if (mySerial != _serial) return; // 已切歌 → 只落缓存，下次播放生效
    final player = _player;
    if (player == null || player.currentSong?.hash != song.hash) return;
    // 播到较后位置才分析完 → 不追认（否则用户会听到音量突然变化）
    if (player.position > _kLoudnessApplyMaxPosition) {
      return;
    }
    unawaited(_applyGainFor(result));
  }

  /// 解析该歌曲可用于分析的音频来源。
  ///
  /// 策略（按优先级）：
  ///   1. 本地歌曲 → 直接用文件路径
  ///   2. 已有下载/播放缓存文件 → 直接用（零额外网络）
  ///   3. 在线且暂无缓存 → 等待播放缓存落盘（最多 90s），超时放弃
  /// 这样避免了"另开一路解码流与播放抢带宽"（酷狗 CDN 直链限速，易导致播放 stalled）。
  static Future<_AudioSource?> _resolveAudioSource(
    Song song,
    int mySerial, {
    Duration cacheWait = _kLoudnessCacheWaitTimeout,
  }) async {
    if (song.source == SongSource.local) {
      final f = File(song.id);
      if (f.existsSync()) {
        return _AudioSource(path: song.id, isUrl: false);
      }
      return null;
    }

    final downloader = _player?.downloadController;
    if (downloader == null) return null;

    // 已有本地文件（下载或播放缓存）
    final existing = downloader.localPathFor(song, _player!.audioQuality);
    if (existing != null && File(existing).existsSync()) {
      return _AudioSource(path: existing, isUrl: false);
    }

    // 预取场景（cacheWait 为 0）：不为在线歌长时间占用队列，只在有现成文件时分析。
    if (cacheWait <= Duration.zero) return null;

    // 等待播放缓存落盘（playSong 已在后台触发 cacheForPlayback）
    final completer = Completer<_AudioSource?>();
    Timer? timeout;
    void listener() {
      if (completer.isCompleted) return;
      final p = downloader.localPathFor(song, _player!.audioQuality);
      if (p != null && File(p).existsSync()) {
        completer.complete(_AudioSource(path: p, isUrl: false));
      }
    }

    downloader.addListener(listener);
    timeout = Timer(cacheWait, () {
      if (!completer.isCompleted) completer.complete(null);
    });
    try {
      return await completer.future;
    } finally {
      timeout.cancel();
      downloader.removeListener(listener);
    }
  }

  /// 按平台解码并测量。
  ///
  /// ====【性能/资源互斥】==== 解码期间置 [_decodeRunning]：
  /// 预扫描据此避免与"当前歌分析"同时解码（两路解码会抢 CPU/IO，可能引起卡顿）。
  /// 注意只在真正解码+测量期间为 true —— "等待播放缓存落盘"不算解码，
  /// 否则在线歌首播时会把预扫描长时间挡在门外。
  static bool _decodeRunning = false;

  static Future<LoudnessResult?> _analyzeSource(
    _AudioSource source,
    Song song,
    bool Function() isCancelled,
  ) async {
    if (defaultTargetPlatform == TargetPlatform.windows) {
      _decodeRunning = true;
      try {
        return await analyzeWithBass(
          pathOrUrl: source.path,
          isUrl: source.isUrl,
          duration: song.duration,
          isCancelled: isCancelled,
        );
      } finally {
        _decodeRunning = false;
      }
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      final effects = _player?.audioEffects;
      if (effects == null) return null;
      _decodeRunning = true;
      try {
        return await analyzeWithAndroid(
          pathOrUrl: source.path,
          isUrl: source.isUrl,
          duration: song.duration,
          isCancelled: isCancelled,
          effects: effects,
        );
      } finally {
        _decodeRunning = false;
      }
    }
    return null;
  }

  // ---- 缓存 key / 读写 ----

  /// 缓存 key：必须带【音质】与【来源】——同 hash 不同音质/来源是不同字节流，
  /// 响度可能相差 0.5~2 LU（不同母带/压制）。版本号用于算法变更时整体失效。
  static String _cacheKeyFor(Song song) {
    final safeHash = song.hash.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    final quality = _player?.audioQuality.apiValue ?? 'unknown';
    final sourceTag = song.isCloudDrive ? 'cloud' : song.source.name;
    return 'cache_loudness_v$_kLoudnessCacheVersion'
        '_${safeHash}_${quality}_$sourceTag';
  }

  static void _rememberInMemory(String key, LoudnessResult result) {
    if (!_memory.containsKey(key)) {
      _memoryOrder.add(key);
      if (_memoryOrder.length > _memoryCacheLimit) {
        final oldest = _memoryOrder.removeAt(0);
        _memory.remove(oldest);
      }
    }
    _memory[key] = result;
  }

  /// 读取缓存中的响度测量结果。
  ///
  /// 说明：成功结果用长 TTL、失败标记用短 TTL —— 但 CacheService.read 只接受一个 ttl，
  /// 所以这里先在"长 TTL"下读出原始 wrapper，再按 payload 的 ok 字段自行判断
  /// "是该按负缓存语义作废"。这样避免"每次播到无法分析的歌都重试"。
  static Future<LoudnessResult?> _readCache(Song song) async {
    final cache = _cache;
    if (cache == null) return null;
    final key = _cacheKeyFor(song);
    try {
      final res = await cache.read<Map<String, dynamic>>(
        key,
        decode: (json) => json,
        // 用较长 TTL 读出内容，实际有效期交给下面按 ok/analyzedAt 判断。
        ttl: _kLoudnessCacheTtl,
      );
      final json = res?.data;
      if (json == null) return null;

      final analyzedAt = (json['analyzedAt'] as num?)?.toInt() ?? 0;
      final ageMs = DateTime.now().millisecondsSinceEpoch - analyzedAt;
      if (ageMs < 0) return null; // 时钟异常，保守放弃

      if (json['ok'] != true) {
        // 负缓存不构成"有结果"（是否跳过分析由 _hasValidNegativeCache 判定）。
        return null;
      }

      final lufs = (json['lufs'] as num?)?.toDouble();
      if (lufs == null || !lufs.isFinite) return null;
      // 成功结果：忽略 isStale（响度对固定文件是常量，过期值依然正确），
      // 只把它当作"可后台重算"的信号，绝不在当前播放关键路径上重算。
      return LoudnessResult(
        lufs: lufs,
        peakDbfs: (json['peakDbfs'] as num?)?.toDouble() ?? -120.0,
        sampleRate: (json['sampleRate'] as num?)?.toInt() ?? 0,
        channels: (json['channels'] as num?)?.toInt() ?? 0,
        blockCount: (json['blockCount'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeCache(
    String key,
    LoudnessResult result,
    Song song,
  ) async {
    final cache = _cache;
    if (cache == null) return;
    await cache.write(key, {
      'ok': true,
      'lufs': result.lufs,
      'peakDbfs': result.peakDbfs,
      'sampleRate': result.sampleRate,
      'channels': result.channels,
      'blockCount': result.blockCount,
      'durSec': song.duration?.inMilliseconds != null
          ? song.duration!.inMilliseconds / 1000.0
          : 0.0,
      'ver': _kLoudnessCacheVersion,
      'analyzedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  static Future<void> _writeNegativeCache(String key, String error) async {
    final cache = _cache;
    if (cache == null) return;
    // 写失败标记（含 analyzedAt）：读取侧由 _hasValidNegativeCache 依据
    // _kLoudnessNegativeTtl 判定其有效期，避免每次播到这首无法分析的歌都重试。
    await cache.write(key, {
      'ok': false,
      'error': error,
      'ver': _kLoudnessCacheVersion,
      'analyzedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 是否存在"仍然有效"的失败标记（用于跳过重复分析）。
  static Future<bool> _hasValidNegativeCache(Song song) async {
    final cache = _cache;
    if (cache == null) return false;
    try {
      final res = await cache.read<Map<String, dynamic>>(
        _cacheKeyFor(song),
        decode: (json) => json,
        ttl: _kLoudnessCacheTtl,
      );
      final json = res?.data;
      if (json == null || json['ok'] == true) return false;
      final analyzedAt = (json['analyzedAt'] as num?)?.toInt() ?? 0;
      final ageMs = DateTime.now().millisecondsSinceEpoch - analyzedAt;
      if (ageMs < 0) return false;
      return ageMs <= _kLoudnessNegativeTtl.inMilliseconds;
    } catch (_) {
      return false;
    }
  }
}

/// 分析用的音频来源描述。
class _AudioSource {
  const _AudioSource({required this.path, required this.isUrl});

  /// 本地文件路径或 http(s) URL。
  final String path;

  /// 是否为网络地址（决定解码流的创建方式）。
  final bool isUrl;
}