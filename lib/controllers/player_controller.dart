import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/music_models.dart';
import '../services/audio_effects_service.dart';
import '../services/cache_service.dart';
import '../services/desktop_lyrics_service.dart';
import '../services/loudness_gain_policy.dart'; // ====【新增/响度归一化】档位与增益策略 ====
import '../services/loudness_normalization.dart'; // ====【新增/响度归一化】编排 ====
import '../services/music_api.dart';
import '../services/music_audio_handler.dart';
import '../services/playback_history_service.dart';
import '../services/playback_stats_service.dart';
import '../services/main_thread_lag_monitor.dart'; // ====【诊断/主线程阻塞全景】====
import '../services/startup_diag_logger.dart'; // ====【诊断/安卓渲染卡顿】====
import 'download_controller.dart';
import 'local_music_controller.dart';
import '../ui/widgets/artwork.dart'; // ====【修复/封面与背景同步】复用统一封面 ImageProvider ====
// 全局 Toast(挂根 Overlay,任意页面可见、不被遮挡)。播放失败时用于弹全局提示。
import '../ui/widgets/toast.dart';

enum PlaybackMode { playlistLoop, shuffle, singleLoop }

class AudioEffectPreset {
  const AudioEffectPreset({required this.name, required this.levels});

  final String name;
  final List<int> levels;
}

class PlayerController extends ChangeNotifier {
  // ====【需求/性能优化·位置广播节流】====
  // 播放中的 audioPlayer.positionStream 每个 tick 都 notifyListeners() 全量广播（约 ~15 次/秒），
  // 会持续唤醒播放器页+mini+车机+home 等全部监听者整树 rebuild → 播放中 GPU/CPU 持续占用。
  // 内部 `position` 仍每 tick 实时更新；仅当位置推进超过 240ms 才全量广播（进度约 4~5fps 刷新，
  // 观感平滑无差）。结构性状态变化(切歌/暂停/队列等)仍即时 notifyListeners，不受此节流影响。
  int _lastPositionNotifyMs = 0;
  bool _shouldBroadcastPosition() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastPositionNotifyMs >= 240) {
      _lastPositionNotifyMs = now;
      return true;
    }
    return false;
  }
  // ====【调试/低频统计日志】5s 聚合播放器元素频率/耗时/资源数据，追加写 %TEMP%\ka_player_stats.log====
  // 统计：位置事件次数+平均/最大处理耗时、notifyListeners 全量广播次数、音源加载(播放/切歌)次数。
  // 低频采样不干扰性能；用 static 便于后续增删钩子点。
  int _stPosEvt = 0, _stNotify = 0, _stLoad = 0;
  int _stPosSumMs = 0, _stPosMaxMs = 0;
  Timer? _statsTimer;
  // ====【修复/切歌卡顿·批量广播】切歌流程多次结构性 notify 合并为一次最终广播，
  // 减少播放器页整页 rebuild 次数；批内其它来源的 notify 同样被吸收（切歌瞬间
  // 状态抖动统一刷新一次，避免多次整页重建与闪烁）。====
  int _notifyBatch = 0;
  bool _notifyPending = false;
  // ====【修复/低端设备切歌后 UI 不刷新】帧阶段延迟广播标记 ====
  bool _frameNotifyPending = false;
  // ====【修复/低端设备切歌后 UI 永久不刷新·批量计数泄漏兜底】====
  Timer? _batchGuardTimer;

  /// 进入"切歌批量通知"区间（替代裸的 `_notifyBatch++`）。
  ///
  /// ====【根因】==== playSong 全程用 _notifyBatch 吸收零散通知、结束时统一广播一次。
  /// 但它依赖 finally 复位计数；若中途某个 await 永不返回（低端设备上网络解析/加载
  /// 无超时、平台调用挂起等），finally 就不会执行 → 计数永久 >0 → **之后所有
  /// notifyListeners 全被吞掉**，表现为"切歌后歌名/封面/歌词/播放模式永久停在旧歌，
  /// 必须切页/退出重进才刷新"（实测抓到的 batch=2 即为此泄漏）。
  ///
  /// ====【处理】==== 加超时兜底：无论切歌流程是否正常收尾，超时后强制归零并广播一次，
  /// 保证 UI 永远不会失联；正常切歌（秒级）不会触发该兜底，不改变任何既有行为。
  void _enterNotifyBatch() {
    _notifyBatch++;
    _batchGuardTimer?.cancel();
    _batchGuardTimer = Timer(const Duration(seconds: 12), () {
      if (_notifyBatch <= 0) return;
      _notifyBatch = 0;
      _notifyPending = false;
      _isChangingSource = false;
      if (isPreparing) {
        isPreparing = false;
      }
      _broadcastSafely();
    });
  }

  /// 退出"切歌批量通知"区间（替代裸的 `_notifyBatch--`），并统一广播一次。
  void _exitNotifyBatch() {
    _notifyBatch--;
    if (_notifyBatch > 0) {
      return; // 仍有并发的切歌流程未结束
    }
    _notifyBatch = 0; // 防御：兜底已归零时避免出现负计数
    _batchGuardTimer?.cancel();
    _batchGuardTimer = null;
    if (_notifyPending) {
      _notifyPending = false;
      // ====【修复/低端设备 UI 不刷新】必须走 _broadcastSafely：
      // 此处是切歌唯一的"统一广播"，若恰好处于 build 阶段，直接广播会丢失重建机会。====
      _broadcastSafely();
    }
  }

  @override
  void notifyListeners() {
    _stNotify++;
    if (_notifyBatch > 0) {
      _notifyPending = true;
      return;
    }
    _broadcastSafely();
  }

  /// ====【修复/低端设备切歌后 UI 不刷新（mini 栏/歌名/封面/歌词/播放模式停在旧歌）】====
  ///
  /// 根因：若在 **build/layout/paint 阶段**（SchedulerPhase.persistentCallbacks）同步广播，
  /// 订阅者（如播放器页 _PlayerGate）会先更新自己的"上次状态记录"再调用 setState；
  /// 而 release 模式下构建期间 markNeedsBuild 会被丢弃 —— 于是【记录已更新、重建被丢弃】。
  /// 之后的位置 tick 再通知时，`song != _lastSong` 已为 false，永远不再 setState，
  /// 表现为"UI 永久停在旧歌，必须切页/退出重进/暂停才刷新"。
  /// 低端设备 build·layout 耗时长，切歌的 await 链更容易落在构建窗口内，故症状明显；
  /// 进度条不受影响是因为它走 smoothPosition（getter + 时间外推，不经过该门控）。
  ///
  /// 处理：检测到构建阶段则把广播推迟到本帧结束（postFrameCallback）执行，
  /// 确保订阅者总在安全时机被通知；同帧内多次通知自动合并为一次。
  void _broadcastSafely() {
    try {
      final binding = SchedulerBinding.instance;
      if (binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
        if (_frameNotifyPending) {
          return; // 本帧已安排，合并为一次
        }
        _frameNotifyPending = true;
        binding.addPostFrameCallback((_) {
          _frameNotifyPending = false;
          MainThreadLagMonitor.measure('player.notifyListeners(postFrame)', () {
            super.notifyListeners();
          });
        });
        return;
      }
    } catch (_) {
      // 绑定未就绪等异常：退回直接广播，保证功能不受影响。
    }
    MainThreadLagMonitor.measure('player.notifyListeners', () {
      super.notifyListeners();
    });
  }
  void _startStats() {
    _statsTimer ??= Timer.periodic(
      const Duration(seconds: 5),
      (_) => _flushStats(),
    );
  }
  void _stopStats() {
    _statsTimer?.cancel();
    _statsTimer = null;
  }
  void _flushStats() {
    try {
      final tmp = Platform.environment['TEMP'];
      if (tmp == null || tmp.isEmpty) return;
      final avg = _stPosEvt == 0 ? 0.0 : (_stPosSumMs / _stPosEvt);
      File('$tmp\\ka_player_stats.log').writeAsStringSync(
        '[${DateTime.now().toIso8601String()}] '
        'playing=$isPlaying '
        'posEvt=$_stPosEvt '
        'posAvgMs=${avg.toStringAsFixed(2)} '
        'posMaxMs=$_stPosMaxMs '
        'notify=$_stNotify '
        'load=$_stLoad\n',
        mode: FileMode.append,
      );
    } catch (_) {
      // 静默：统计日志失败不影响功能。
    }
    _stPosEvt = 0;
    _stNotify = 0;
    _stLoad = 0;
    _stPosSumMs = 0;
    _stPosMaxMs = 0;
  }
  static const _listenTimeSettingKey = 'settings.add_listening_time_enabled';
  static const _audioQualitySettingKey = 'settings.audio_quality';
  static const _equalizerEnabledSettingKey = 'settings.equalizer_enabled';
  static const _equalizerLevelsSettingKey = 'settings.equalizer_levels';
  static const _equalizerPresetSettingKey = 'settings.equalizer_preset';
  static const _bassBoostEnabledSettingKey = 'settings.bass_boost_enabled';
  static const _bassBoostStrengthSettingKey = 'settings.bass_boost_strength';
  static const _audioInterruptionEnabledSettingKey =
      'settings.audio_interruption_enabled';
  static const _autoResumeAfterInterruptionSettingKey =
      'settings.auto_resume_after_interruption';
  static const _playbackSpeedSettingKey = 'settings.playback_speed';
  // ====【需求/音调不持久化】音调为会话级设置，不再持久化（原 _pitchSettingKey 常量已删除）====
  // ===== 原实现（备份，供回退）=====
  // static const _pitchSettingKey = 'settings.pitch';
  // ===== 原实现（备份，供回退）=====
  // static const _performanceModeSettingKey = 'settings.performance_mode';
  // static const _perfRestoreRotationSettingKey = 'settings.perf_restore_rotation';
  // ===== 【重构】性能 4 个独立开关的持久化 key =====
  static const _perfLyricBlurOffSettingKey = 'settings.perf_lyric_blur_off';
  static const _perfBgAnimOffSettingKey = 'settings.perf_bg_anim_off';
  static const _perfCoverAnimOffSettingKey = 'settings.perf_cover_anim_off';
  static const _perfLightLyricSettingKey = 'settings.perf_light_lyric';
  static const _autoSkipUnplayableSettingKey = 'settings.auto_skip_unplayable';
  static const _desktopLyricsEnabledSettingKey =
      'settings.desktop_lyrics_enabled';
  static const _desktopLyricsSettingsKey = 'settings.desktop_lyrics_settings';
  static const _smartQualitySettingKey = 'settings.smart_quality_enabled';
  static const _autoPlayOnStartupSettingKey = 'settings.auto_play_on_startup';
  static const _autoPlayOnDeviceConnectedSettingKey =
      'settings.auto_play_on_device_connected';
  static const _volumeNormalizationEnabledSettingKey =
      'settings.volume_normalization_enabled';
  /// ====【响度归一化】目标响度档位持久化 key（存档位名字符串，避免 double 精度/类型问题）====
  static const _loudnessTargetSettingKey = 'settings.loudness_target';
  /// ====【响度归一化·预分析】空闲预分析开关的持久化 key（默认关闭）====
  static const _loudnessPrescanEnabledSettingKey =
      'settings.loudness_prescan_enabled';
  static const _queueKey = 'playback.queue';
  static const _currentSongKey = 'playback.current_song';
  static const _currentPositionKey = 'playback.current_position';
  static const _playbackModeKey = 'playback.mode';
  static const _queueSaveDebounceMs = 500;
  // =====【方案A·二期】位置保存间隔回到 5s =====
  // 位置已改独立小文件 + 异步 IO（见 _savePositionToFile），不再因 SharedPreferences 同步写盘卡顿，
  // 因此兜底间隔可保持 5s 的及时性。此前为排查卡顿临时改为 30s（已实锤是同步写盘所致）。
  static const _positionSaveInterval = Duration(seconds: 5);
  static const _listenTimeReportInterval = Duration(minutes: 30);
  static const _listenTimeCheckInterval = Duration(minutes: 1);
  static const _defaultEqualizerLevels = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
  static const equalizerPresets = [
    AudioEffectPreset(name: '平直', levels: _defaultEqualizerLevels),
    AudioEffectPreset(
      name: '流行',
      levels: [0, 250, 450, 350, 100, -100, 50, 300, 450, 500],
    ),
    AudioEffectPreset(
      name: '摇滚',
      levels: [500, 350, 150, -100, -250, -150, 150, 350, 550, 650],
    ),
    AudioEffectPreset(
      name: '人声',
      levels: [-250, -150, 0, 250, 500, 550, 350, 100, -100, -200],
    ),
    AudioEffectPreset(
      name: '低音',
      levels: [750, 650, 500, 250, 0, -100, -150, -200, -250, -300],
    ),
    AudioEffectPreset(
      name: '古典',
      levels: [350, 250, 100, 0, 150, 250, 300, 350, 250, 100],
    ),
    AudioEffectPreset(
      name: '电子',
      levels: [650, 450, 120, -120, -180, 100, 350, 550, 650, 700],
    ),
  ];

  /// 下载控制器（由 main.dart 在创建后注入，供 UI 访问下载功能）。
  DownloadController? downloadController;

  /// 缓存服务（由 main.dart 在创建后注入，用于歌词等缓存）。
  CacheService? cacheService;

  /// 本地音乐控制器（由 main.dart 在创建后注入，用于读取内嵌歌词等）。
  LocalMusicController? localMusic;

  PlayerController(this._api, this._audioHandler) {
    unawaited(_restoreSettings());
    _audioHandler.attachTransportControls(onNext: next, onPrevious: previous);
    _desktopLyrics.setVisibilityChangedHandler(_handleDesktopLyricsVisibility);
    // 桌面歌词卡拉OK进度在显示刷新时同步。仅构造时注册一次：该回调不依赖具体
    // audioPlayer 实例，若放进 _subscribeToAudioPlayer 会在 Windows 自愈重建时重复注册。
    SchedulerBinding.instance.addPersistentFrameCallback((_) {
      if (_shouldShowDesktopLyrics &&
          isPlaying &&
          lyrics.isNotEmpty &&
          !_isScrubbing) {
        _syncDesktopKaraokeProgress();
      }
    });
    _subscribeToAudioPlayer();
    unawaited(_setupAudioSessionListeners());
  }

  /// 订阅 AudioPlayer 的各状态/事件流（Android 卡拉OK帧回调、时长、播放状态、
  /// 处理状态、sessionId 效果器配置）。
  ///
  /// 抽成独立方法以便 Windows 自愈兜底重建 AudioPlayer 后重新订阅。
  /// 原构造内逻辑整体保留于本方法，语义不变。
  void _subscribeToAudioPlayer() {
    // ====【调试/低频统计】订阅播放相关事件时启动低频统计器 ====
    _startStats();
    // ====【正式迁移/Windows 音频后端】订阅改为 handler 统一事件源（Windows 轮询 BASS /
    // Android 透传 just_audio）。原直接订阅 audioPlayer.*Stream 见文件内备份注释。====
    _positionSub = _audioHandler.positionStream.listen((value) {
      // =====【诊断打点·排查播放器持续偶发卡顿】每次位置事件处理总耗时，仅记录尖峰 =====
      final posSw = Stopwatch()..start();
      if (!_isSeeking) {
        _setPositionBase(value, playing: isPlaying);
      }
      _maybeCompleteFromPosition(value);
      _maybeStopClimaxPreview(value);
      _maybeSyncDesktopLyricFromPosition();
      // ====【需求/性能优化·位置广播节流】位置 tick 不每次全量广播，内部 position 已实时更新；
      // 进度以 ≥240ms 节流广播，播放器页进度仍平滑，观感无差；结构性事件仍即时广播。====
      if (_shouldBroadcastPosition()) {
        notifyListeners();
      }
      posSw.stop();
      // ====【调试/低频统计】位置事件次数与耗时聚合 ====
      _stPosEvt++;
      _stPosSumMs += posSw.elapsedMilliseconds;
      if (posSw.elapsedMilliseconds > _stPosMaxMs) {
        _stPosMaxMs = posSw.elapsedMilliseconds;
      }
      if (posSw.elapsedMilliseconds >= 6) {
        try {
          File('${Platform.environment['TEMP']}\\ka_jank_pos.log')
              .writeAsStringSync(
                  '${DateTime.now().toIso8601String()} posEvt ${posSw.elapsedMilliseconds}ms\n',
                  mode: FileMode.append);
        } catch (_) {}
      }
    });
    _durationSub = _audioHandler.durationStream.listen((value) {
      duration = value ?? Duration.zero;
      notifyListeners();
    });
    // 播放状态（playing）流：Windows 由 handler 轮询，Android 透传 just_audio。
    // 原 playerStateStream 同时给 playing+processingState，此处拆分为两路订阅。
    _stateSub = _audioHandler.playingStream.listen((playing) {
      isPlaying = playing;
      if (!_isSeeking) {
        _setPositionBase(_audioHandler.position, playing: isPlaying);
      }
      _syncListeningTimeTracker();
      _syncDesktopPlayState();
      notifyListeners();
    });
    // 处理状态（loading/buffering/ready/completed）流
    _processingStateSub = _audioHandler.processingStateStream.listen((state) {
      isBuffering =
          state == ProcessingState.loading || state == ProcessingState.buffering;
      if (state == ProcessingState.completed) {
        if (!_isChangingSource) {
          unawaited(_handleCompleted());
        }
      }
      notifyListeners();
    });
    // ====【正式迁移/Windows 音频后端】Android 专属：audio session（均衡器依赖）。
    // Windows 的 BASS 无会话 id（handler.androidAudioSessionId 恒 null），跳过订阅。====
    if (!Platform.isWindows) {
      _androidAudioSessionSub = audioPlayer.androidAudioSessionIdStream.listen((
        sessionId,
      ) {
        _androidAudioSessionId = sessionId;
        unawaited(_refreshEqualizerConfig());
        unawaited(_applyEqualizer());
        unawaited(_applyBassBoost());
        // ===== 原实现（备份，供回退）：动态压缩式音量均衡 =====
        // unawaited(_applyVolumeNormalization());
        // ====【响度归一化】Android 的增益效果绑定 audioSessionId，
        // 播放器重建/会话变更后参数会丢，需要重放当前增益。====
        unawaited(LoudnessNormalization.refreshGain());
      });
    }
    // ===== 原实现（备份，供回退）=====
    // _positionSub = audioPlayer.positionStream.listen((value) { ... });
    // _durationSub = audioPlayer.durationStream.listen(...);
    // _stateSub = audioPlayer.playerStateStream.listen(...); // playing+processingState 合一
    // _processingStateSub = audioPlayer.processingStateStream.distinct().listen(...);
    // _androidAudioSessionSub = audioPlayer.androidAudioSessionIdStream.listen(...);
  }

  final MusicApi _api;
  final MusicAudioHandler _audioHandler;
  final AudioEffectsService _audioEffects = AudioEffectsService();
  final DesktopLyricsService _desktopLyrics = DesktopLyricsService();
  final PlaybackHistoryService _historyService = PlaybackHistoryService();
  final PlaybackStatsService _statsService = PlaybackStatsService();

  AudioPlayer get audioPlayer => _audioHandler.audioPlayer;

  MusicApi get api => _api;

  // 缓存标记的流订阅：重建 AudioPlayer 时（Windows 自愈兜底）需取消并重新订阅，
  // 故不能为 final，改为可重新赋值的 late（重建时先 cancel 旧订阅再覆盖）。
  late StreamSubscription<Duration> _positionSub;
  late StreamSubscription<Duration?> _durationSub;
  late StreamSubscription<bool> _stateSub;
  late StreamSubscription<ProcessingState> _processingStateSub;
  late StreamSubscription<int?> _androidAudioSessionSub;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<void>? _becomingNoisySub;
  StreamSubscription<Set<AudioDevice>>? _devicesSub;
  Set<AudioDevice>? _previousDevices;
  final Stopwatch _positionClock = Stopwatch();
  // 平滑位置的上一次取值：用于过滤位置流的小幅倒退（音频缓冲/时钟抖动），
  // 避免歌词高亮和卡拉OK进度出现回跳。seek/换歌的大跨度回退会重建基线。
  Duration _lastSmoothPosition = Duration.zero;
  final _random = math.Random();
  /// 高潮试听结束时间（播放到该时间自动暂停）。
  Duration? _climaxEndTime;

  /// 当前歌曲的高潮片段时间（用于进度条标记），可能为 null。
  SongClimax? climax;
  Timer? _completionFallbackTimer;
  // Windows 自愈兜底：探测"播放卡死"的计时器与重试次数（见 _armStallWatcher/selfHealPlayback）。
  Timer? _stallWatchTimer;
  int _healRetryCount = 0;
  // 累计"判定卡死"的次数：用于区分「单首源无效」与「引擎资源累积」。
  // 单首源无效只做轻量处理(清缓存+提示)，不重建播放器；累计到阈值才重建引擎。
  int _stallStreakCount = 0;
  // 是否已 dispose（用于异步回调/自愈定时器里判断实例是否仍可用）。
  bool _disposed = false;
  Timer? _listenTimeTimer;
  Timer? _queueSaveTimer;
  Timer? _positionSaveTimer;
  DateTime? _listenTimeStartedAt;
  Duration _pendingListenTime = Duration.zero;
  bool _isReportingListenTime = false;
  int _seekSerial = 0;
  bool _isSeeking = false;
  bool _isScrubbing = false;
  bool _isHandlingCompletion = false;
  String? _completedSongHash;
  bool _isAppForeground = true;
  bool _desktopLyricsPreviewVisible = false;

  Song? currentSong;
  List<Song> queue = const [];
  List<LyricLine> lyrics = const [];
  // ====【需求/视觉优先·歌词加载中】切歌后歌词异步加载期间置 true（UI 显示"歌词加载中…"
  // 而非误导性的"暂无歌词"）；loadLyrics 各分支完成（成功/空/失败）后置 false。====
  bool lyricsLoading = false;
  PlaybackMode playbackMode = PlaybackMode.playlistLoop;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool isPlaying = false;
  bool isBuffering = false;
  bool isPreparing = false;
  bool _isChangingSource = false;

  /// 主窗口是否对用户可见（Windows 托盘隐藏时由 DesktopController 置为 false）。
  /// 用于在收进托盘后停掉窗口内持续请求帧的 UI Ticker（如歌词滚动），
  /// 以降低隐藏状态下的 GPU 占用；仅影响 UI 渲染，不影响音频播放。
  bool _isUIVisible = true;
  bool get isUIVisible => _isUIVisible;
  bool addListeningTimeEnabled = true;
  AudioQuality audioQuality = AudioQuality.standard;

  /// 是否开启音质智能切换（播放失败时自动降级重试）。
  bool smartQualityEnabled = false;
  bool autoPlayOnStartupEnabled = false;
  double playbackSpeed = 1.0;
  // ====【需求/音调调节】播放音调（独立于倍速）。仅真正生效于支持独立变调的后端(如 Android
  // ExoPlayer)；Windows 的 just_audio_windows 原生 MediaPlayer 不支持 pitch(会抛 UnimplementedError)，
  // 故 Windows 上仅保存配置(供架构预留/将来换后端启用)，UI 层禁用该调节项并提示。
  double pitch = 1.0;
  bool equalizerEnabled = false;
  List<int> equalizerLevels = List<int>.of(_defaultEqualizerLevels);
  String equalizerPresetName = '平直';
  EqualizerConfig equalizerConfig = EqualizerConfig.fallback(
    _defaultEqualizerLevels,
  );
  bool bassBoostEnabled = false;
  double bassBoostStrength = 0.45;
  bool audioInterruptionEnabled = true;
  bool autoResumeAfterInterruption = false;
  bool autoPlayOnDeviceConnected = false;
  bool volumeNormalizationEnabled = false;
  // ====【响度归一化】目标响度档位（响亮 −11 / 标准 −14 / 安静 −19 LUFS，默认标准）。
  // 与 volumeNormalizationEnabled 共同决定每首歌施加的固定增益偏移。====
  LoudnessTarget loudnessTarget = LoudnessTarget.normal;
  // ====【响度归一化·预分析】空闲预分析（后台逐首分析队列歌曲，含主动下载在线歌）====
  // 默认【关闭】：它会占用后台 CPU/带宽（在线歌需下载），属可选增强功能。
  // 关闭时：切歌仍按需即时分析（约 1 秒生效），只是没有"提前就绪"的加速。
  bool loudnessPrescanEnabled = false;
  bool desktopLyricsEnabled = false;
  // ===== 原实现（备份，供回退）=====
  // /// 性能模式：开启后播放器页面的歌词模糊效果、背景动画消失，降低 GPU 占用。
  // /// 仅影响 UI 渲染，不影响音频播放（与 isUIVisible 的用途一致）。
  // bool performanceMode = false;
  // /// 性能模式下是否恢复"封面/背景旋转动画"。
  // /// 默认 false：性能模式暂停旋转以省 GPU；开启后则在性能模式下也随播放旋转。
  // bool perfRestoreRotation = false;
  // ===== 【重构】性能 4 个完全独立的开关 =====
  // 原「性能模式」总开关拆分为以下 4 个独立开关，各自独立影响一项渲染行为。
  // 仅影响 UI 渲染，不影响音频播放。

  /// 关闭歌词模糊：开启后歌词的 maxBlurSigma 置 0（消除高斯模糊）。
  bool perfLyricBlurOff = false;
  /// 关闭背景旋转动画：开启后 _ArtworkBackground 背景图不再旋转（省 GPU）。
  bool perfBgAnimOff = false;
  /// 关闭车机封面旋转动画：开启后 _LandscapeArtworkShowcase 封面不再旋转（省 GPU）。
  bool perfCoverAnimOff = false;
  /// 轻量歌词：开启后歌词走自绘整行高亮（_PerfLyricList/两行预览/仅行切换低采样）。
  bool perfLightLyric = false;
  /// 自动跳过无法播放的歌曲：开启后，当某首歌"播放卡死"（零进度持续约 8 秒）时，
  /// 自动切到队列下一首，而不是停在当前无法播放的歌上。
  bool autoSkipUnplayable = false;
  DesktopLyricsSettings desktopLyricsSettings = const DesktopLyricsSettings();
  Timer? _autoResumeTimer;
  Duration? sleepTimerRemaining;
  Timer? _sleepTimer;
  DateTime? _sleepTimerEnd;
  bool _sleepFinishCurrentSong = false;
  bool _sleepFinishCurrentSongOption = false;
  String? errorMessage;
  int seekRevision = 0;
  int? _androidAudioSessionId;
  bool get isScrubbing => _isScrubbing;
  bool get isAudioEffectsSupported => _audioEffects.isAudioEffectsSupported;
  bool get isBassBoostSupported => _audioEffects.isBassBoostSupported;
  /// ====【响度归一化】暴露音效服务给编排层（Android 解码分析/增益通道需要）。====
  AudioEffectsService get audioEffects => _audioEffects;
  String get audioEffectsLabel {
    if (!isAudioEffectsSupported) {
      return '当前平台暂不支持';
    }
    if (equalizerEnabled) {
      return '均衡器：$equalizerPresetName';
    }
    if (bassBoostEnabled) {
      return 'Bass ${(bassBoostStrength * 100).round()}%';
    }
    return '关闭';
  }

  String get playbackSpeedLabel {
    if (playbackSpeed == playbackSpeed.roundToDouble()) {
      return '${playbackSpeed.round()}x';
    }
    return '${playbackSpeed}x';
  }

  Duration get smoothPosition {
    final raw = _isScrubbing
        ? position
        : (!isPlaying ? position : position + _positionClock.elapsed);
    var value = raw;
    if (value < Duration.zero) {
      value = Duration.zero;
    } else if (duration > Duration.zero && value > duration) {
      value = duration;
    }
    if (_isScrubbing) {
      // 拖动进度条时位置必须严格跟随手指。
      _lastSmoothPosition = value;
      return value;
    }
    if (value < _lastSmoothPosition) {
      if (_lastSmoothPosition - value > const Duration(milliseconds: 250)) {
        // 明显回退：视为 seek 或切歌，直接重建基线。
        _lastSmoothPosition = value;
      }
    } else {
      _lastSmoothPosition = value;
    }
    return _lastSmoothPosition;
  }

  int get currentIndex {
    final song = currentSong;
    if (song == null) {
      return -1;
    }
    return queue.indexWhere((item) => item.hash == song.hash);
  }

  /// 供歌词行高亮/判定用的"实位置"。
  ///
  /// ===== 【修复】歌词高亮超前一句 =====
  ///
  /// 原因：原来的 activeLyricIndex 用 smoothPosition 判定。smoothPosition 在两次
  /// position 通知之间会用 _positionClock 向前外推（position + clock.elapsed），虽然
  /// 让进度条/滚动更顺滑，但外推会使"位置"轻微快于实际演唱，在歌词行边界处恰好跨到
  /// 下一句，导致高亮比演唱超前一句（尤其封面歌词预览最明显）。
  ///
  /// 修复：歌词行判定改用"不含过度外推"的真实 position，严格对齐实际演唱行。
  /// 注意：进度条等需要平滑滚动的场景仍应使用 smoothPosition，二者用途不同，
  /// 这里不修改 smoothPosition，避免影响进度条体验。此 getter 仅用于歌词高亮/行判定。
  Duration get lyricPosition => position;

  int get activeLyricIndex {
    if (lyrics.isEmpty) {
      return -1;
    }
    var index = 0;
    // =====【回退至原版】用 smoothPosition 判定当前歌词行 =====
    // 优化版（已保留，供后续启用，勿删）：if (lyricPosition >= lyrics[i].time)
    //   lyricPosition(=position，无外推真实位置) 可避免 smoothPosition 外推导致"高亮超前一句"。
    // 现按指挥回退到原版 smoothPosition 判定。
    for (var i = 0; i < lyrics.length; i++) {
      if (smoothPosition >= lyrics[i].time) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  String get playbackModeLabel {
    return switch (playbackMode) {
      PlaybackMode.playlistLoop => '歌单循环',
      PlaybackMode.shuffle => '随机播放',
      PlaybackMode.singleLoop => '单曲循环',
    };
  }

  PlaybackMode cyclePlaybackMode() {
    playbackMode = switch (playbackMode) {
      PlaybackMode.playlistLoop => PlaybackMode.shuffle,
      PlaybackMode.shuffle => PlaybackMode.singleLoop,
      PlaybackMode.singleLoop => PlaybackMode.playlistLoop,
    };
    _saveQueueState();
    notifyListeners();
    return playbackMode;
  }

  Future<void> setAddListeningTimeEnabled(bool enabled) async {
    if (addListeningTimeEnabled == enabled) {
      return;
    }
    addListeningTimeEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_listenTimeSettingKey, enabled);
    if (!enabled) {
      _resetListeningTimeTracker();
    } else {
      _syncListeningTimeTracker();
    }
    notifyListeners();
  }

  Future<void> playSong(Song song, {List<Song>? queue}) async {
    // ====【修复/切歌卡顿·批量广播】切歌全程批量吸收 notify，结束时统一广播一次 ====
    // ====【修复/低端设备 UI 永久不刷新】改走带超时兜底的入口：
    // 若本次切歌中途 await 挂起导致 finally 不执行，兜底会把计数归零并广播，
    // 避免 UI 永久停在旧歌（详见 _enterNotifyBatch）。====
    _enterNotifyBatch();
    // ====【调试/低频统计】音源加载(播放/切歌)计数 ====
    _stLoad++;
    _climaxEndTime = null;
    climax = null;
    _completionFallbackTimer?.cancel();
    _completedSongHash = null;
    isPreparing = true;
    _isChangingSource = true;
    errorMessage = null;
    currentSong = song;
    if (queue != null && queue.isNotEmpty) {
      this.queue = queue;
    } else if (this.queue.isEmpty) {
      this.queue = [song];
    }
    lyrics = const [];
    lyricsLoading = true; // ====【需求/视觉优先·歌词加载中】====
    _lastDesktopLyricIndex = -1;
    _saveQueueState();
    _startPositionSaving();
    notifyListeners();
    // 预缓存封面图，避免打开播放页时出现纯色背景闪烁
    _precacheCover(song);
    unawaited(_syncDesktopLyricsVisibility());
    unawaited(_loadClimax(song));

    try {
      // 进入加载态：切换瞬间清空时长/进度并置 buffering，避免 UI 停留在 0:00
      // 或上一首的残留值（加载属于正常 buffering 间隔）。
      duration = Duration.zero;
      position = Duration.zero;
      isBuffering = true;
      String url;
      String? networkUrl;
      var local = downloadController?.localPathFor(song, audioQuality);
      // ===== 【自愈】本地文件有效性校验 =====
      // 命中损坏的播放缓存是「切回歌曲就卡死/零进度」的常见元凶（cacheForPlayback
      // 落盘的缓存文件内容可能无效/损坏，文件头既非 FLAC 也非 MP3，但扩展名仍为
      // .flac，WinRT 无法解码）。命中时先校验文件头是否有效音频；无效则删除损坏
      // 缓存并把 local 视为不存在，走下方原「在线/来源」分支在线重新拉取。
      if (local != null && !_isFileAudioPlayable(local)) {
        final wasDownload = downloadController?.isDownloaded(song) ?? false;
        if (!wasDownload) {
          await downloadController?.deletePlayCache(song, audioQuality);
        }
        local = null; // 不可用 → 复用原有分支（在线解析）
        // =====【立即提示】此刻已判断到该歌获取的内容不是有效音频（常见于
        // 在线源返回网页/损坏缓存），无需等加载超时，立即弹出指定文案提示用户。=====
        Toast.error('该歌曲可能不支持在线播放，请尝试其他歌曲');
      }
      if (local != null) {
        url = local;
      } else if (song.source == SongSource.local) {
        url = song.id;
      } else {
        final playUrl = await _resolvePlayUrl(song);
        if (playUrl.url.isEmpty) {
          throw Exception(
            song.isCloudDrive
                ? '云盘歌曲暂时没有可播放地址'
                : song.source == SongSource.netease
                ? '网易云歌曲暂时没有可播放地址'
                : '这首歌暂时没有可播放地址',
          );
        }
        url = playUrl.url;
        networkUrl = playUrl.url;
      }
      // ===== 【自愈】Windows 播放卡死兜底：布防卡死探测 =====
      // 必须在加载/播放之前布防：若 WinRT 加载卡死导致 play() 的 Future 永不
      // resolve，在 play() 之后布防将永远不执行（自愈随之失效）。每次换歌重新
      // 布防并归零重试计数；非 Windows 平台 _armStallWatcher 内部直接返回。
      _healRetryCount = 0;
      // 累计卡死计数按"单首歌曲"独立：切歌即归零，避免连续多首坏歌把累计推到
      // 阈值、误触发无意义的播放器重建(重建救不回坏歌，且会把刚恢复的车机按钮
      // 再禁用)。引擎重建兜底仅在"同一首歌仍持续卡死"时才有意义。
      _stallStreakCount = 0;
      _armStallWatcher();

      // =====【修复】切歌前先 stop() 旧源 =====
      // 若上一首歌的源失败/挂起（如坏歌的 HTTP 源未清理），直接 setUrl 换源可能
      // 让这次切换被旧源阻塞数秒。先显式 stop() 释放旧源，再用干净播放器加载新歌。
      try {
        await _audioHandler.stop();
      } catch (_) {}
      MainThreadLagMonitor.crumb('playSong:loadSong');
      await _audioHandler.loadSong(
        song: song,
        url: url,
        queueSongs: this.queue,
        queueIndex: currentIndex,
      );
      isPreparing = false;
      notifyListeners();
      unawaited(loadLyrics(song));
      MainThreadLagMonitor.crumb('playSong:play');
      await _audioHandler.play();
      // 记录播放历史与本地播放统计（后台执行，不阻塞播放）
      unawaited(_historyService.record(song));
      unawaited(_statsService.recordPlay(song));
      // 首播后后台缓存（仅当本次用的是网络 URL）
      if (networkUrl != null) {
        unawaited(
          downloadController
              ?.cacheForPlayback(song, audioQuality, networkUrl)
              .catchError((_) {}),
        );
      }
    } catch (error) {
      errorMessage = error.toString();
      isPreparing = false;
      notifyListeners();
    } finally {
      _isChangingSource = false;
      if (isPreparing) {
        isPreparing = false;
      }
      // ====【修复/切歌卡顿·批量广播】批结束：统一广播一次（吸收期间所有 notify）====
      // ====【修复/低端设备 UI 不刷新】由 _exitNotifyBatch 统一收尾：
      // 归零计数、取消兜底定时器、并在需要时安全广播一次。====
      _exitNotifyBatch();
    }
  }

  /// 预缓存歌曲封面到 Flutter ImageCache，打开播放页时可立即显示。
  ///
  /// ====【修复/封面与背景过渡不同步】==== 必须使用 [playerCoverProvider]（与播放器页
  /// 封面、背景模糊完全相同的 ImageProvider），否则预缓存的条目与它们请求的不是同一条，
  /// 预热失效、封面与背景又会各自重新下载（不同步）。
  void _precacheCover(Song song) {
    final coverUrl = song.coverUrl;
    if (coverUrl == null || coverUrl.isEmpty) return;
    if (coverUrl.startsWith('content://')) return; // 本地封面走原生加载，不预缓存
    playerCoverProvider(coverUrl).resolve(ImageConfiguration.empty);
  }

  /// 解析播放地址。
  ///
  /// - 云盘歌曲走 [MusicApi.cloudSongUrl]
  /// - 网易云歌曲使用外链地址
  /// - 其它歌曲走 [MusicApi.songUrl]，开启智能音质时在网络请求失败
  ///   或返回空地址时自动降级重试（lossless -> high -> standard）。
  Future<PlayUrl> _resolvePlayUrl(Song song) async {
    if (song.source == SongSource.local) {
      return PlayUrl(url: song.id, hash: song.hash);
    }
    if (song.isCloudDrive) {
      return _api.cloudSongUrl(song);
    }
    if (song.source == SongSource.netease) {
      // 网易云歌曲使用外链播放地址
      return PlayUrl(
        url: 'https://music.163.com/song/media/outer/url?id=${song.id}.mp3',
        hash: song.hash,
      );
    }

    try {
      final playUrl = await _api.songUrl(song, quality: audioQuality);
      if (playUrl.url.isNotEmpty || !smartQualityEnabled) {
        return playUrl;
      }
      // 返回空地址：按智能音质策略降级重试
      final fallback = _nextLowerQuality(audioQuality);
      if (fallback == null) return playUrl;
      return _api.songUrl(song, quality: fallback);
    } catch (error) {
      if (!smartQualityEnabled) rethrow;
      // 网络请求失败：尝试降级重试
      final fallback = _nextLowerQuality(audioQuality);
      if (fallback == null) rethrow;
      try {
        final retryUrl = await _api.songUrl(song, quality: fallback);
        if (retryUrl.url.isNotEmpty) {
          debugPrint(
            '[KA Music][smart-quality] ${audioQuality.badge} 失败，'
            '已降级为 ${fallback.badge}',
          );
          return retryUrl;
        }
      } catch (_) {
        // 降级也失败，抛出原始错误
      }
      rethrow;
    }
  }

  /// 返回更低一档的音质；已是最低档时返回 null。
  AudioQuality? _nextLowerQuality(AudioQuality quality) {
    switch (quality) {
      case AudioQuality.lossless:
        return AudioQuality.high;
      case AudioQuality.high:
        return AudioQuality.standard;
      case AudioQuality.standard:
        return null;
    }
  }

  Future<bool> addToQueue(Song song) async {
    final songKey = song.hash.isNotEmpty ? song.hash : song.id;
    final currentSongKey = currentSong == null
        ? ''
        : (currentSong!.hash.isNotEmpty ? currentSong!.hash : currentSong!.id);
    if (songKey.isNotEmpty && songKey == currentSongKey) {
      return false;
    }

    final nextQueue = List<Song>.of(queue);
    final existingIndex = nextQueue.indexWhere((item) {
      final itemKey = item.hash.isNotEmpty ? item.hash : item.id;
      return itemKey.isNotEmpty && itemKey == songKey;
    });
    if (existingIndex >= 0) {
      nextQueue.removeAt(existingIndex);
    }

    if (nextQueue.isEmpty) {
      nextQueue.add(song);
    } else {
      final index = currentIndex;
      final insertIndex = index < 0
          ? 0
          : (index + 1).clamp(0, nextQueue.length);
      nextQueue.insert(insertIndex, song);
    }

    queue = nextQueue;
    await _audioHandler.setSongQueue(
      queueSongs: queue,
      queueIndex: currentIndex,
      currentSong: currentSong,
    );
    _saveQueueState();
    notifyListeners();
    return true;
  }

  Future<void> setAudioQuality(
    AudioQuality quality, {
    bool reloadCurrent = false,
  }) async {
    final sameQuality = audioQuality == quality;
    if (sameQuality && !reloadCurrent) {
      return;
    }

    audioQuality = quality;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_audioQualitySettingKey, quality.apiValue);
    notifyListeners();

    if (reloadCurrent && currentSong != null && !sameQuality) {
      await _reloadCurrentSongForQuality();
    }
  }

  /// 开关音质智能切换（播放失败时自动降级重试）。
  Future<void> setSmartQualityEnabled(bool enabled) async {
    if (smartQualityEnabled == enabled) return;
    smartQualityEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_smartQualitySettingKey, enabled);
    notifyListeners();
  }

  /// 开关开机自启播放歌曲功能。
  Future<void> setAutoPlayOnStartupEnabled(bool enabled) async {
    if (autoPlayOnStartupEnabled == enabled) return;
    autoPlayOnStartupEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoPlayOnStartupSettingKey, enabled);
    notifyListeners();
  }

  /// 开关连接新音频设备自动播放功能。
  Future<void> setAutoPlayOnDeviceConnected(bool enabled) async {
    if (autoPlayOnDeviceConnected == enabled) return;
    autoPlayOnDeviceConnected = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoPlayOnDeviceConnectedSettingKey, enabled);
    notifyListeners();
  }

  /// 开关音量均衡功能。
  ///
  /// ====【响度归一化】==== 语义已从"曲内动态压缩"改为"按曲目响度施加固定增益偏移"
  ///（业界标准做法，完整保留动态）。双端生效，不再是 Android 专属。
  Future<void> setVolumeNormalizationEnabled(bool enabled) async {
    if (volumeNormalizationEnabled == enabled) return;
    volumeNormalizationEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_volumeNormalizationEnabledSettingKey, enabled);
    await LoudnessNormalization.setEnabled(enabled);
    notifyListeners();
  }

  /// 设置目标响度档位（响亮 / 标准 / 安静）。
  ///
  /// ====【响度归一化】==== 对应 Spotify 的 Loud / Normal / Quiet（−11 / −14 / −19 LUFS）。
  Future<void> setLoudnessTarget(LoudnessTarget target) async {
    if (loudnessTarget == target) return;
    loudnessTarget = target;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_loudnessTargetSettingKey, target.storageValue);
    await LoudnessNormalization.setTarget(target);
    notifyListeners();
  }

  /// ====【响度归一化·预分析】开关空闲预分析 ====
  ///
  /// 开启后：播放稳定时后台逐首分析队列歌曲（由近及远、优先前后几首），
  ///   在线歌会主动下载到播放缓存后再分析；这样切歌（含随机播放）基本零等待。
  /// 代价：占用后台 CPU 与带宽。默认关闭。
  Future<void> setLoudnessPrescanEnabled(bool enabled) async {
    if (loudnessPrescanEnabled == enabled) return;
    loudnessPrescanEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_loudnessPrescanEnabledSettingKey, enabled);
    await LoudnessNormalization.setPrescanEnabled(enabled);
    notifyListeners();
  }

  /// ====【新增/响度预扫描】为预扫描准备播放缓存（主动下载）====
  ///
  /// 用途：预扫描要分析"尚未听过的在线歌"时，本地没有音频文件可解码。
  /// 本方法解析播放地址并触发一次后台缓存下载（生成播放缓存文件），
  /// 下载完成后预扫描即可在下一轮分析它。
  ///
  /// 说明：
  ///   * 只负责"触发"，不等待下载完成（下载由 DownloadController 内部异步进行），
  ///     避免长时间占用响度分析的串行队列；
  ///   * 失败静默（返回 false），预扫描会跳过这首，不影响播放；
  ///   * 下载产物是普通播放缓存（%TEMP%\ka_music_play_cache），
  ///     受"播放缓存上限"约束会自动清理，不会无限增长磁盘。
  Future<bool> preparePlayCacheForPrefetch(Song song) async {
    final downloader = downloadController;
    if (downloader == null) return false;
    if (song.source == SongSource.local) return false; // 本地歌无需下载
    try {
      final playUrl = await _resolvePlayUrl(song);
      if (playUrl.url.isEmpty) return false;
      // 不 await：下载在后台进行，完成后再由预扫描下一轮接管。
      unawaited(
        downloader
            .cacheForPlayback(song, audioQuality, playUrl.url)
            .catchError((Object _) {}),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Android 原生 LoudnessEnhancer 增益通道（正向提升）。
  ///
  /// ====【响度归一化】==== 供 LoudnessNormalization 调用；非 Android 平台直接返回。
  Future<void> applyLoudnessEnhancerGain(
    double gainDb, {
    required bool enabled,
  }) => _applyLoudnessEnhancerGain(gainDb, enabled: enabled);

  /// 内部实现（避免与公开方法同名冲突）。
  Future<void> _applyLoudnessEnhancerGain(
    double gainDb, {
    required bool enabled,
  }) async {
    if (Platform.isWindows) return;
    await _audioEffects.configureLoudnessGain(
      audioSessionId:
          _androidAudioSessionId ?? _audioHandler.androidAudioSessionId,
      enabled: enabled,
      gainDb: gainDb,
    );
  }

  /// 读取本地播放统计。
  Future<PlaybackStats> getPlaybackStats() => _statsService.getStats();

  /// 清空本地播放统计。
  Future<void> clearPlaybackStats() => _statsService.clear();

  /// 读取播放历史。
  Future<List<Song>> getPlaybackHistory({int limit = 100}) =>
      _historyService.getHistory(limit: limit);

  /// 读取播放历史总数（轻量计数，不反序列化 Song 对象）。
  Future<int> getPlaybackHistoryCount() => _historyService.count();

  /// 清空播放历史。
  Future<void> clearPlaybackHistory() => _historyService.clear();

  Future<void> setPlaybackSpeed(double speed) async {
    final clamped = speed.clamp(0.5, 3.0);
    if ((playbackSpeed - clamped).abs() < 0.001) {
      return;
    }
    playbackSpeed = clamped;
    await _audioHandler.setSpeed(clamped);
    notifyListeners();
    // ====【修复/界面卡顿】倍速持久化改独立小文件 + File 异步写（不阻塞 UI）。
    // 原 SharedPreferences.setDouble 每次同步写整个 JSON 文件（unawaited 也无法跳过其
    // 同步部分），是"调倍速小卡一下"的根因。与播放位置小文件同一模式。====
    try {
      final f = await _speedFile();
      unawaited(f.writeAsString('$clamped'));
    } catch (_) {}
  }

  /// 倍速小文件（独立文件 + File 异步写，避免 SharedPreferences 同步写盘卡顿）。
  Future<File> _speedFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}playback_speed');
  }

  /// 播放队列小文件（大 JSON 项移出 prefs，根治同步序列化整个 JSON 的卡顿）。
  Future<File> _queueFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}playback_queue');
  }

  /// 当前歌曲小文件（同上，移出 prefs）。
  Future<File> _currentSongFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}current_song');
  }

  // ====【需求/音调调节】设置播放音调（独立于倍速，不影响播放速度）。
  // ====【正式迁移/Windows 音频后端】Windows 已切 BASS（支持独立变调），调用 handler.setPitch。
  // ====【需求/不持久化】音调为用户会话级设置：不写入用户配置，重启应用恢复默认 1.0。
  // 倍速(playbackSpeed)仍持久化，不受影响。====
  Future<void> setPitch(double value) async {
    final clamped = value.clamp(0.5, 2.0);
    if ((pitch - clamped).abs() < 0.001) {
      return;
    }
    pitch = clamped;
    try {
      await _audioHandler.setPitch(clamped);
    } catch (_) {
      // 个别后端不支持时静默，不影响其它功能。
    }
    notifyListeners();
  }

  Future<void> setBassBoostEnabled(bool enabled) async {
    if (bassBoostEnabled == enabled) {
      return;
    }
    bassBoostEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_bassBoostEnabledSettingKey, enabled);
    await _applyBassBoost();
    notifyListeners();
  }

  Future<void> setBassBoostStrength(
    double strength, {
    bool persist = true,
  }) async {
    final nextStrength = strength.clamp(0.0, 1.0);
    if ((bassBoostStrength - nextStrength).abs() < 0.001) {
      return;
    }
    bassBoostStrength = nextStrength;
    if (bassBoostEnabled) {
      unawaited(_applyBassBoost());
    }
    notifyListeners();

    if (persist) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_bassBoostStrengthSettingKey, nextStrength);
    }
  }

  Future<void> setEqualizerEnabled(bool enabled) async {
    if (equalizerEnabled == enabled) {
      return;
    }
    equalizerEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_equalizerEnabledSettingKey, enabled);
    await _applyEqualizer();
    notifyListeners();
  }

  Future<void> setEqualizerBandLevel(
    int index,
    int levelMillibels, {
    bool persist = true,
  }) async {
    if (index < 0 || index >= equalizerLevels.length) {
      return;
    }
    final clamped = levelMillibels.clamp(
      equalizerConfig.minMillibels,
      equalizerConfig.maxMillibels,
    );
    if (equalizerLevels[index] == clamped) {
      return;
    }
    equalizerLevels = List<int>.of(equalizerLevels)..[index] = clamped;
    equalizerPresetName = '自定义';
    if (equalizerEnabled) {
      unawaited(_applyEqualizer());
    }
    notifyListeners();

    if (persist) {
      await _persistEqualizer();
    }
  }

  Future<void> applyEqualizerPreset(AudioEffectPreset preset) async {
    equalizerPresetName = preset.name;
    equalizerLevels = _levelsForBandCount(
      preset.levels,
      equalizerLevels.length,
    );
    await _persistEqualizer();
    if (equalizerEnabled) {
      await _applyEqualizer();
    }
    notifyListeners();
  }

  Future<void> resetEqualizer() async {
    await applyEqualizerPreset(equalizerPresets.first);
  }

  Future<void> loadLyrics(Song song) async {
    final cache = cacheService;
    final cacheKey = 'cache_lyric_${song.hash}';
    if (song.source == SongSource.local) {
      // 1. 优先尝试同名 .lrc 文件
      try {
        final songFile = File(song.id);
        final dotIndex = songFile.path.lastIndexOf('.');
        final lrcPath =
            '${dotIndex != -1 ? songFile.path.substring(0, dotIndex) : songFile.path}.lrc';
        final file = File(lrcPath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          String content;
          try {
            content = utf8.decode(bytes);
          } catch (_) {
            content = utf8.decode(bytes, allowMalformed: true);
          }
          final lines = parseLyrics(content);
          if (currentSong?.hash == song.hash) {
            lyrics = lines;
            lyricsLoading = false;
            notifyListeners();
            _syncDesktopLyrics();
          }
          return;
        }
      } catch (e) {
        debugPrint('Failed to load local .lrc lyrics: $e');
      }

      // 2. 尝试从音频文件内嵌元数据读取歌词
      try {
        final embedded = await localMusic?.getEmbeddedLyrics(song.id);
        if (embedded != null && embedded.isNotEmpty) {
          final lines = parseLyrics(embedded);
          if (currentSong?.hash == song.hash) {
            lyrics = lines;
            lyricsLoading = false;
            notifyListeners();
            _syncDesktopLyrics();
          }
          return;
        }
      } catch (e) {
        debugPrint('Failed to load embedded lyrics: $e');
      }

      if (currentSong?.hash == song.hash) {
        lyrics = const [];
        lyricsLoading = false;
        notifyListeners();
        _syncDesktopLyrics();
      }
      return;
    }

    // 1. 先读缓存，命中则立即显示（无感）
    if (cache != null) {
      try {
        final cached = await cache.read<List<LyricLine>>(
          cacheKey,
          decode: (json) => (json['lines'] as List? ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(LyricLine.fromCache)
              .toList(),
          ttl: const Duration(days: 30),
        );
        if (cached != null &&
            !listEquals(lyrics, cached.data) &&
            currentSong?.hash == song.hash) {
          lyrics = cached.data;
          lyricsLoading = false;
          notifyListeners();
          _syncDesktopLyrics();
        }
      } catch (_) {}
    }

    // 2. 后台静默刷新
    try {
      final fresh = await _api.lyrics(song);
      if (currentSong?.hash != song.hash) return; // 已切歌，丢弃
      if (!listEquals(lyrics, fresh)) {
        lyrics = fresh;
        lyricsLoading = false;
        notifyListeners();
      }
      // 写缓存（空歌词也缓存，避免重复请求）
      if (cache != null) {
        unawaited(
          cache.write(cacheKey, {
            'lines': fresh.map((l) => l.toCache()).toList(),
          }),
        );
      }
    } catch (_) {
      if (currentSong?.hash == song.hash && lyrics.isEmpty) {
        lyrics = const [];
        lyricsLoading = false;
        notifyListeners();
      }
    }
    // ====【修复/歌词加载中·永不结束】在线分支末尾无条件复位 loading：纯音乐/无歌词时
    // lyrics 保持空且与 fresh 相同（listEquals 跳过赋值），若只在赋值分支清 loading 会
    // 卡在"歌词加载中..."；此处确保任何在线路径（缓存/成功/空/失败）结束都复位。====
    lyricsLoading = false;
    if (currentSong?.hash == song.hash) {
      _syncDesktopLyrics();
    }
  }

  Future<void> togglePlay() async {
    if (_audioHandler.playing) {
      await _audioHandler.pause();
    } else {
      if (_audioHandler.processingState == ProcessingState.completed) {
        await _audioHandler.seek(Duration.zero);
      }
      await _audioHandler.play();
    }
    // 【方案A】暂停/继续是低频关键事件：即时落盘一次进度，保证及时（不 await，避免拖慢切换）
    unawaited(_saveCurrentPosition());
  }

  /// 试听当前歌曲的高潮片段：定位到高潮开始并播放，到高潮结束自动暂停。
  /// 返回是否成功（无高潮片段或失败时返回 false）。
  Future<bool> playClimaxPreview() async {
    final song = currentSong;
    if (song == null) return false;
    try {
      final climax = await _api.songClimax(song.hash);
      if (climax == null) return false;
      this.climax = climax;
      _climaxEndTime = climax.endTime;
      await seek(climax.startTime);
      await play();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 高潮试听播放到结束时间时自动暂停。
  void _maybeStopClimaxPreview(Duration value) {
    final end = _climaxEndTime;
    if (end == null || value < end) return;
    _climaxEndTime = null;
    unawaited(pause());
  }

  /// 异步获取当前歌曲高潮时间，用于进度条标记（失败静默）。
  Future<void> _loadClimax(Song song) async {
    // ====【诊断/安卓渲染卡顿】==== 高潮点加载（网络 + 解析）计时。
    final sw = Stopwatch()..start();
    try {
      await _loadClimaxInner(song);
    } finally {
      sw.stop();
      StartupDiagLogger.phase(
        'loadClimax',
        ms: sw.elapsedMilliseconds,
        note: 'song=${song.title}',
      );
    }
  }

  Future<void> _loadClimaxInner(Song song) async {
    MainThreadLagMonitor.crumb('loadClimax:enter');
    try {
      final result = await _api.songClimax(song.hash);
      if (currentSong?.hash != song.hash) return;
      climax = result;
      notifyListeners();
    } catch (_) {
      if (currentSong?.hash == song.hash) {
        climax = null;
      }
    }
  }

  Future<void> play() async {
    if (!_audioHandler.playing) {
      await togglePlay();
    }
  }

  Future<void> pause() async {
    if (_audioHandler.playing) {
      await togglePlay();
    }
  }

  void previewSeek(Duration position) {
    _isScrubbing = true;
    _isSeeking = true;
    _setPositionBase(position, playing: false);
    notifyListeners();
  }

  Future<void> seek(Duration position) async {
    final serial = ++_seekSerial;
    final target = _clampPosition(position);
    seekRevision++;
    _isScrubbing = false;
    _isSeeking = true;
    _setPositionBase(target, playing: isPlaying);
    notifyListeners();

    try {
      await _audioHandler.seek(target);
      if (serial != _seekSerial) {
        return;
      }
      _setPositionBase(target, playing: isPlaying);
      notifyListeners();
    } finally {
      if (serial == _seekSerial) {
        _isSeeking = false;
        _isScrubbing = false;
      }
    }
  }

  Future<void> next() async {
    final nextSong = _nextSong();
    if (nextSong == null) return;
    await playSong(nextSong, queue: queue);
  }

  Future<void> previous() async {
    final index = currentIndex;
    if (index > 0) {
      await playSong(queue[index - 1], queue: queue);
    } else {
      await seek(Duration.zero);
    }
  }

  /// 切到下一首（队列末尾循环到开头）。队列少于 2 首时无操作。
  /// 供 Windows 托盘"上一曲/下一曲"使用。
  Future<void> skipToNext() async {
    final i = currentIndex;
    if (i < 0 || queue.length < 2) return;
    await playSong(queue[(i + 1) % queue.length]);
  }

  /// 切到上一首（队列开头循环到末尾）。队列少于 2 首时无操作。
  /// 供 Windows 托盘"上一曲/下一曲"使用。
  Future<void> skipToPrevious() async {
    final i = currentIndex;
    if (i < 0 || queue.length < 2) return;
    await playSong(queue[(i - 1 + queue.length) % queue.length]);
  }

  Future<void> _handleCompleted() async {
    if (_isHandlingCompletion || currentSong == null) return;
    if (_completedSongHash == currentSong!.hash) return;
    _isHandlingCompletion = true;
    _completionFallbackTimer?.cancel();
    _completedSongHash = currentSong!.hash;

    try {
      if (_sleepFinishCurrentSong) {
        _sleepFinishCurrentSong = false;
        _sleepFinishCurrentSongOption = false;
        sleepTimerRemaining = null;
        notifyListeners();
        unawaited(_audioHandler.pause());
        return;
      }

      // Windows 上 just_audio_windows 的 WinRT MediaPlayer 在触发 completed
      // 事件时，native 回调仍在后台线程执行。若立即调用 setUrl() 加载新音源，
      // 会与 COM 平台线程产生竞态，导致 "Lost connection to device" 进程崩溃。
      // 延迟 100ms 让 native 层完成 completed 状态的清理，再切换到下一首。
      if (Platform.isWindows) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        // 延迟后重新检查状态，避免在延迟期间用户手动切歌
        if (_completedSongHash != currentSong?.hash) return;
      }

      if (playbackMode == PlaybackMode.singleLoop) {
        _completedSongHash = null;
        await _audioHandler.seek(Duration.zero);
        await _audioHandler.play();
        return;
      }

      final nextSong = _nextSong();
      if (nextSong == null) {
        await _audioHandler.seek(Duration.zero);
        return;
      }
      await playSong(nextSong, queue: queue);
    } finally {
      _isHandlingCompletion = false;
    }
  }

  void _maybeCompleteFromPosition(Duration value) {
    if (_isSeeking || _isScrubbing || !isPlaying || duration <= Duration.zero) {
      return;
    }
    if (_audioHandler.processingState == ProcessingState.completed) {
      return;
    }

    final remaining = duration - value;
    if (remaining.inMilliseconds <= 750 &&
        (_completionFallbackTimer?.isActive != true)) {
      final delay =
          (remaining > Duration.zero ? remaining : Duration.zero) +
          const Duration(milliseconds: 180);
      _completionFallbackTimer = Timer(delay, () {
        if (!isPlaying || _isSeeking || _isScrubbing) return;
        final currentPosition = _audioHandler.position;
        if (duration > Duration.zero &&
            duration - currentPosition <= const Duration(milliseconds: 220)) {
          unawaited(_handleCompleted());
        }
      });
    }
  }

  Future<void> _reloadCurrentSongForQuality() async {
    final song = currentSong;
    if (song == null) {
      return;
    }

    final resumePlayback = isPlaying;
    final targetPosition = smoothPosition;
    isPreparing = true;
    errorMessage = null;
    notifyListeners();

    try {
      String url;
      String? networkUrl;
      final local = downloadController?.localPathFor(song, audioQuality);
      if (local != null) {
        url = local;
      } else if (song.source == SongSource.local) {
        url = song.id;
      } else {
        final PlayUrl playUrl;
        if (song.isCloudDrive) {
          playUrl = await _api.cloudSongUrl(song);
        } else if (song.source == SongSource.netease) {
          playUrl = PlayUrl(
            url: 'https://music.163.com/song/media/outer/url?id=${song.id}.mp3',
            hash: song.hash,
          );
        } else {
          playUrl = await _api.songUrl(song, quality: audioQuality);
        }
        if (playUrl.url.isEmpty) {
          throw Exception('当前音质暂时没有可播放地址');
        }
        url = playUrl.url;
        networkUrl = playUrl.url;
      }
      await _audioHandler.loadSong(
        song: song,
        url: url,
        queueSongs: queue,
        queueIndex: currentIndex,
      );
      if (targetPosition > Duration.zero) {
        await _audioHandler.seek(_clampPosition(targetPosition));
      }
      if (resumePlayback) {
        await _audioHandler.play();
      }
      // 切音质后后台缓存
      if (networkUrl != null) {
        unawaited(
          downloadController?.cacheForPlayback(song, audioQuality, networkUrl),
        );
      }
    } catch (error) {
      errorMessage = error.toString();
    } finally {
      isPreparing = false;
      notifyListeners();
    }
  }

  Future<void> _setupAudioSessionListeners() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(_audioSessionConfiguration);
      _interruptionSub = session.interruptionEventStream.listen((event) {
        if (event.begin) {
          // 打断开始：系统可能已自动暂停播放器。
          // 若开启了"阻止打断"，立即恢复播放以对抗暂停。
          if (!audioInterruptionEnabled && isPlaying && currentSong != null) {
            _autoResumeTimer?.cancel();
            _autoResumeTimer = Timer(const Duration(milliseconds: 300), () {
              if (!isPlaying && currentSong != null) {
                unawaited(_audioHandler.play());
              }
            });
          }
        } else {
          // 打断结束：若开启了"自动恢复"或"阻止打断"，恢复播放。
          if ((autoResumeAfterInterruption || (!audioInterruptionEnabled)) &&
              currentSong != null) {
            _autoResumeTimer?.cancel();
            _autoResumeTimer = Timer(const Duration(milliseconds: 500), () {
              if (!isPlaying && currentSong != null) {
                unawaited(_audioHandler.play());
              }
            });
          }
        }
      });
      _becomingNoisySub = session.becomingNoisyEventStream.listen((_) {
        if (!audioInterruptionEnabled) {
          // 阻止打断模式下忽略耳机拔出
          return;
        }
        if (autoResumeAfterInterruption && currentSong != null) {
          _autoResumeTimer?.cancel();
          _autoResumeTimer = Timer(const Duration(milliseconds: 500), () {
            if (!isPlaying && currentSong != null) {
              unawaited(_audioHandler.play());
            }
          });
        }
      });
      _previousDevices = await session.getDevices();
      _devicesSub = session.devicesStream.listen((devices) {
        if (_previousDevices != null) {
          final addedDevices = devices.difference(_previousDevices!);
          if (addedDevices.isNotEmpty) {
            // ignore: experimental_member_use
            final hasNewAudioDevice = addedDevices.any((d) =>
                // ignore: experimental_member_use
                d.type == AudioDeviceType.bluetoothA2dp ||
                // ignore: experimental_member_use
                d.type == AudioDeviceType.bluetoothLe ||
                // ignore: experimental_member_use
                d.type == AudioDeviceType.bluetoothSco ||
                // ignore: experimental_member_use
                d.type == AudioDeviceType.wiredHeadset ||
                // ignore: experimental_member_use
                d.type == AudioDeviceType.wiredHeadphones ||
                // ignore: experimental_member_use
                d.type == AudioDeviceType.carAudio);

            if (hasNewAudioDevice &&
                autoPlayOnDeviceConnected &&
                currentSong != null &&
                !isPlaying) {
              _autoResumeTimer?.cancel();
              _autoResumeTimer = Timer(const Duration(milliseconds: 500), () {
                if (!isPlaying && currentSong != null) {
                  unawaited(_audioHandler.play());
                }
              });
            }
          }
        }
        _previousDevices = devices;
      });
    } catch (_) {
      // AudioSession not available on this platform
    }
  }

  /// 根据打断设置生成 AudioSessionConfiguration。
  ///
  /// 阻止打断时使用 [AndroidAudioFocusGainType.gain] 并禁用 androidWillPauseWhenDucked，
  /// 向系统声明不希望被其他 App 打断。同时配合 interruptionEventStream 中的
  /// 主动恢复播放作为双保险。
  AudioSessionConfiguration get _audioSessionConfiguration {
    if (audioInterruptionEnabled) {
      return const AudioSessionConfiguration.music();
    }
    // 阻止打断模式：声明需要独占音频焦点，不因降音暂停
    return const AudioSessionConfiguration(
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.music,
        usage: AndroidAudioUsage.media,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
      // 不因其他 App 降音而暂停
      androidWillPauseWhenDucked: false,
    );
  }

  Future<void> setAudioInterruptionEnabled(bool enabled) async {
    if (audioInterruptionEnabled == enabled) return;
    audioInterruptionEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_audioInterruptionEnabledSettingKey, enabled);
    // 设置变更后立即重新配置 AudioSession，使新策略生效
    unawaited(_reconfigureAudioSession());
    notifyListeners();
  }

  /// 重新配置 AudioSession 以应用最新的打断策略。
  Future<void> _reconfigureAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(_audioSessionConfiguration);
    } catch (_) {
      // AudioSession not available on this platform
    }
  }

  Future<void> setAutoResumeAfterInterruption(bool enabled) async {
    if (autoResumeAfterInterruption == enabled) return;
    autoResumeAfterInterruption = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoResumeAfterInterruptionSettingKey, enabled);
    notifyListeners();
  }

  Future<void> setDesktopLyricsEnabled(bool enabled) async {
    if (desktopLyricsEnabled == enabled) return;
    desktopLyricsEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_desktopLyricsEnabledSettingKey, enabled);
    notifyListeners();

    if (enabled) {
      final hasPermission = await _desktopLyrics.checkPermission();
      if (!hasPermission) {
        desktopLyricsEnabled = false;
        await prefs.setBool(_desktopLyricsEnabledSettingKey, false);
        notifyListeners();
        await _desktopLyrics.requestPermission();
        return;
      }
      final song = currentSong;
      if (song != null) {
        await _syncDesktopLyricsVisibility();
      }
    } else {
      await _desktopLyrics.hide();
    }
  }

  // ===== 原实现（备份，供回退）=====
  // /// 开启/关闭性能模式。
  // /// 开启后播放器页面的歌词模糊效果与背景动画消失，降低 GPU 占用；仅影响 UI
  // /// 渲染，不影响音频。设置即时生效并持久化。
  // Future<void> setPerformanceMode(bool enabled) async {
  //   if (performanceMode == enabled) return;
  //   performanceMode = enabled;
  //   final prefs = await SharedPreferences.getInstance();
  //   await prefs.setBool(_performanceModeSettingKey, enabled);
  //   notifyListeners();
  // }
  // /// 开关"性能模式下恢复封面/背景旋转动画"。
  // Future<void> setPerfRestoreRotation(bool enabled) async {
  //   if (perfRestoreRotation == enabled) return;
  //   perfRestoreRotation = enabled;
  //   final prefs = await SharedPreferences.getInstance();
  //   await prefs.setBool(_perfRestoreRotationSettingKey, enabled);
  //   notifyListeners();
  // }
  // ===== 【重构】性能 4 个独立开关的 setter（各自独立持久化）=====

  /// 开关"关闭歌词模糊"。
  Future<void> setPerfLyricBlurOff(bool enabled) async {
    if (perfLyricBlurOff == enabled) return;
    perfLyricBlurOff = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_perfLyricBlurOffSettingKey, enabled);
    notifyListeners();
  }

  /// 开关"关闭背景旋转动画"。
  Future<void> setPerfBgAnimOff(bool enabled) async {
    if (perfBgAnimOff == enabled) return;
    perfBgAnimOff = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_perfBgAnimOffSettingKey, enabled);
    notifyListeners();
  }

  /// 开关"关闭车机封面旋转动画"。
  Future<void> setPerfCoverAnimOff(bool enabled) async {
    if (perfCoverAnimOff == enabled) return;
    perfCoverAnimOff = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_perfCoverAnimOffSettingKey, enabled);
    notifyListeners();
  }

  /// 开关"轻量歌词"。
  Future<void> setPerfLightLyric(bool enabled) async {
    if (perfLightLyric == enabled) return;
    perfLightLyric = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_perfLightLyricSettingKey, enabled);
    notifyListeners();
  }

  /// 开启/关闭"自动跳过无法播放的歌曲"。
  ///
  /// 开启后，当某首歌播放卡死（零进度持续约 8 秒）时自动切到队列下一首。
  Future<void> setAutoSkipUnplayable(bool enabled) async {
    if (autoSkipUnplayable == enabled) return;
    autoSkipUnplayable = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoSkipUnplayableSettingKey, enabled);
    notifyListeners();
  }

  bool get _shouldShowDesktopLyrics {
    return desktopLyricsEnabled &&
        currentSong != null &&
        (!_isAppForeground || _desktopLyricsPreviewVisible);
  }

  Future<void> _syncDesktopLyricsVisibility() async {
    if (!_shouldShowDesktopLyrics) {
      await _desktopLyrics.hide();
      return;
    }

    final song = currentSong;
    if (song == null) return;
    final shown = await _desktopLyrics.show(
      title: song.title,
      artist: song.artist,
    );
    if (shown) {
      _syncDesktopLyrics();
      _syncDesktopPlayState();
      _syncDesktopKaraokeProgress();
    }
  }

  void _syncDesktopLyrics() {
    if (!_shouldShowDesktopLyrics) return;
    final index = activeLyricIndex;
    if (lyrics.isEmpty) {
      _desktopLyrics.updateLyrics(current: '', next: '');
      return;
    }
    final current = lyrics[index.clamp(0, lyrics.length - 1)].text;
    final nextIndex = index + 1;
    final next = nextIndex < lyrics.length ? lyrics[nextIndex].text : '';
    _desktopLyrics.updateLyrics(current: current, next: next);
  }

  void _syncDesktopPlayState() {
    if (!_shouldShowDesktopLyrics) return;
    _desktopLyrics.updatePlayState(isPlaying: isPlaying);
  }

  int _lastDesktopLyricIndex = -1;

  void _maybeSyncDesktopLyricFromPosition() {
    if (!_shouldShowDesktopLyrics || lyrics.isEmpty) return;
    final index = activeLyricIndex;
    if (index != _lastDesktopLyricIndex) {
      _lastDesktopLyricIndex = index;
      _syncDesktopLyrics();
    }
    // Karaoke progress for current line
    _syncDesktopKaraokeProgress();
  }

  void _syncDesktopKaraokeProgress() {
    if (!_shouldShowDesktopLyrics || lyrics.isEmpty) return;
    final index = activeLyricIndex;
    final line = lyrics[index.clamp(0, lyrics.length - 1)];
    final position = smoothPosition;
    final lineDuration = line.duration ?? _estimatedLineDuration(index);

    if (line.words.isEmpty) {
      // No word-level data: estimate progress from line duration
      final lineStart = line.time.inMilliseconds;
      final lineDurationMs = lineDuration?.inMilliseconds ?? 0;
      if (lineDurationMs > 0) {
        final elapsed = position.inMilliseconds - lineStart;
        final progress = (elapsed / lineDurationMs).clamp(0.0, 1.0);
        _desktopLyrics.updateKaraokeProgress(
          progress: progress,
          lineDuration: lineDuration,
          isPlaying: isPlaying,
        );
      } else {
        _desktopLyrics.updateKaraokeProgress(
          progress: 1.0,
          lineDuration: null,
          isPlaying: isPlaying,
        );
      }
    } else {
      // Word-level: find active word and compute progress
      final lineStart = line.time.inMilliseconds;
      final lineDurationMs = lineDuration?.inMilliseconds ?? 0;
      if (lineDurationMs > 0) {
        final elapsed = position.inMilliseconds - lineStart;
        final progress = (elapsed / lineDurationMs).clamp(0.0, 1.0);
        _desktopLyrics.updateKaraokeProgress(
          progress: progress,
          lineDuration: lineDuration,
          isPlaying: isPlaying,
        );
      }
    }
  }

  Duration? _estimatedLineDuration(int index) {
    if (index < 0 || index >= lyrics.length) {
      return null;
    }
    final explicit = lyrics[index].duration;
    if (explicit != null && explicit > Duration.zero) {
      return explicit;
    }
    if (index + 1 < lyrics.length) {
      final nextDuration = lyrics[index + 1].time - lyrics[index].time;
      if (nextDuration > Duration.zero) {
        return nextDuration;
      }
    }
    if (duration > lyrics[index].time) {
      final tailDuration = duration - lyrics[index].time;
      if (tailDuration > Duration.zero) {
        return tailDuration;
      }
    }
    return null;
  }

  Future<void> updateDesktopLyricsSettings(
    DesktopLyricsSettings settings,
  ) async {
    desktopLyricsSettings = settings;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _desktopLyricsSettingsKey,
      jsonEncode(settings.toMap()),
    );
    notifyListeners();
    await _desktopLyrics.updateSettings(settings);
  }

  bool get isDesktopLyricsSupported => DesktopLyricsService.isSupportedPlatform;

  void setAppForeground(bool isForeground) {
    if (_isAppForeground == isForeground) return;
    _isAppForeground = isForeground;
    if (desktopLyricsEnabled) {
      _desktopLyrics.setAppForeground(isForeground: isForeground);
      unawaited(_syncDesktopLyricsVisibility());
    }
  }

  /// 设置主窗口对用户可见性（Windows 托盘隐藏/显示时由 DesktopController 调用）。
  /// 仅改变"是否在窗口内渲染 UI Ticker"的状态并通知 UI（歌词页据此停/启 Ticker
  /// 以降低隐藏时的 GPU 占用），**不会暂停音频播放**——收进托盘后音乐继续播是该
  /// 托盘应用的核心用途。
  void setUIVisible(bool visible) {
    if (_isUIVisible == visible) return;
    _isUIVisible = visible;
    notifyListeners();
  }

  Future<void> setDesktopLyricsPreviewVisible(bool visible) async {
    if (_desktopLyricsPreviewVisible == visible) return;
    _desktopLyricsPreviewVisible = visible;
    await _syncDesktopLyricsVisibility();
  }

  Future<void> _handleDesktopLyricsVisibility({
    required bool visible,
    required bool userClosed,
  }) async {
    if (!userClosed || !desktopLyricsEnabled) {
      return;
    }
    desktopLyricsEnabled = false;
    _desktopLyricsPreviewVisible = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_desktopLyricsEnabledSettingKey, false);
    notifyListeners();
  }

  Future<bool> checkDesktopLyricsPermission() =>
      _desktopLyrics.checkPermission();

  Future<void> requestDesktopLyricsPermission() =>
      _desktopLyrics.requestPermission();

  bool get isSleepTimerActive =>
      sleepTimerRemaining != null && sleepTimerRemaining! > Duration.zero;

  bool get isSleepFinishCurrentSong => _sleepFinishCurrentSong;
  bool get sleepFinishCurrentSongOption => _sleepFinishCurrentSongOption;

  /// Set a sleep timer that pauses playback immediately or after current song finishes when it expires.
  void setSleepTimer(Duration duration, {bool finishCurrentSong = false}) {
    _sleepFinishCurrentSongOption = finishCurrentSong;
    _sleepFinishCurrentSong = false;
    _sleepTimer?.cancel();
    _sleepTimerEnd = DateTime.now().add(duration);
    sleepTimerRemaining = duration;
    notifyListeners();

    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final end = _sleepTimerEnd;
      if (end == null) return;
      final remaining = end.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        if (_sleepFinishCurrentSongOption) {
          _sleepTimer?.cancel();
          _sleepTimer = null;
          _sleepTimerEnd = null;
          _sleepFinishCurrentSong = true;
          notifyListeners();
        } else {
          _executeSleepTimer();
        }
      } else {
        sleepTimerRemaining = remaining;
        notifyListeners();
      }
    });
  }

  /// Set a sleep timer that finishes the current song, then stops.
  void setSleepTimerFinishSong(Duration duration) {
    setSleepTimer(duration, finishCurrentSong: true);
  }

  /// Update the sleep timer finish song option dynamically.
  void updateSleepTimerOption(bool finishCurrentSong) {
    if (_sleepTimer != null || _sleepFinishCurrentSong) {
      _sleepFinishCurrentSongOption = finishCurrentSong;
      // If the timer has already expired and is waiting for song to finish,
      // and they turn it OFF, we should stop immediately.
      if (!finishCurrentSong && _sleepFinishCurrentSong) {
        _executeSleepTimer();
      } else {
        notifyListeners();
      }
    }
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerEnd = null;
    _sleepFinishCurrentSong = false;
    _sleepFinishCurrentSongOption = false;
    sleepTimerRemaining = null;
    notifyListeners();
  }

  void _executeSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerEnd = null;
    _sleepFinishCurrentSong = false;
    _sleepFinishCurrentSongOption = false;
    sleepTimerRemaining = null;
    notifyListeners();
    unawaited(_audioHandler.pause());
  }

  Future<void> _restoreSettings() async {
    final prefs = await SharedPreferences.getInstance();
    addListeningTimeEnabled =
        prefs.getBool(_listenTimeSettingKey) ?? addListeningTimeEnabled;
    audioQuality = AudioQuality.fromApiValue(
      prefs.getString(_audioQualitySettingKey),
    );
    smartQualityEnabled =
        prefs.getBool(_smartQualitySettingKey) ?? smartQualityEnabled;
    autoPlayOnStartupEnabled =
        prefs.getBool(_autoPlayOnStartupSettingKey) ?? autoPlayOnStartupEnabled;
    equalizerEnabled =
        prefs.getBool(_equalizerEnabledSettingKey) ?? equalizerEnabled;
    equalizerPresetName =
        prefs.getString(_equalizerPresetSettingKey) ?? equalizerPresetName;
    equalizerLevels = _restoreEqualizerLevels(
      prefs.getString(_equalizerLevelsSettingKey),
    );
    equalizerConfig = EqualizerConfig.fallback(equalizerLevels);
    bassBoostEnabled =
        prefs.getBool(_bassBoostEnabledSettingKey) ?? bassBoostEnabled;
    bassBoostStrength =
        prefs.getDouble(_bassBoostStrengthSettingKey) ?? bassBoostStrength;
    audioInterruptionEnabled =
        prefs.getBool(_audioInterruptionEnabledSettingKey) ??
        audioInterruptionEnabled;
    autoResumeAfterInterruption =
        prefs.getBool(_autoResumeAfterInterruptionSettingKey) ??
        autoResumeAfterInterruption;
    autoPlayOnDeviceConnected =
        prefs.getBool(_autoPlayOnDeviceConnectedSettingKey) ??
        autoPlayOnDeviceConnected;
    volumeNormalizationEnabled =
        prefs.getBool(_volumeNormalizationEnabledSettingKey) ??
        volumeNormalizationEnabled;
    // ====【响度归一化】恢复目标响度档位（非法值回退标准档）。====
    loudnessTarget = LoudnessTarget.fromStorage(
      prefs.getString(_loudnessTargetSettingKey),
    );
    // ====【响度归一化·预分析】恢复预分析开关（默认关闭）。====
    loudnessPrescanEnabled =
        prefs.getBool(_loudnessPrescanEnabledSettingKey) ??
        loudnessPrescanEnabled;
    // ====【修复/界面卡顿】倍速读取：优先独立小文件，回退旧 prefs key 并迁移。
    // 原实现（备份）：playbackSpeed = prefs.getDouble(_playbackSpeedSettingKey) ?? playbackSpeed;
    try {
      final f = await _speedFile();
      if (f.existsSync()) {
        final v = double.tryParse(await f.readAsString());
        if (v != null) playbackSpeed = v.clamp(0.5, 3.0);
      } else {
        final old = prefs.getDouble(_playbackSpeedSettingKey);
        if (old != null) {
          playbackSpeed = old.clamp(0.5, 3.0);
          unawaited(f.writeAsString('$playbackSpeed')); // 迁移旧值到小文件
        }
      }
    } catch (_) {
      final old = prefs.getDouble(_playbackSpeedSettingKey);
      if (old != null) playbackSpeed = old.clamp(0.5, 3.0);
    }
    // ====【需求/音调不持久化】音调为用户会话级设置：启动保持默认 1.0，不读取旧值。
    // 原实现（备份）：prefs.getDouble(_pitchSettingKey) 恢复上次音调。====
    desktopLyricsEnabled =
        prefs.getBool(_desktopLyricsEnabledSettingKey) ??
        desktopLyricsEnabled;
    // ===== 原实现（备份，供回退）=====
    // performanceMode =
    //     prefs.getBool(_performanceModeSettingKey) ?? performanceMode;
    // perfRestoreRotation =
    //     prefs.getBool(_perfRestoreRotationSettingKey) ?? perfRestoreRotation;
    // ===== 【重构】性能 4 个独立开关的读取 =====
    perfLyricBlurOff =
        prefs.getBool(_perfLyricBlurOffSettingKey) ?? perfLyricBlurOff;
    perfBgAnimOff =
        prefs.getBool(_perfBgAnimOffSettingKey) ?? perfBgAnimOff;
    perfCoverAnimOff =
        prefs.getBool(_perfCoverAnimOffSettingKey) ?? perfCoverAnimOff;
    perfLightLyric =
        prefs.getBool(_perfLightLyricSettingKey) ?? perfLightLyric;

    autoSkipUnplayable =
        prefs.getBool(_autoSkipUnplayableSettingKey) ?? autoSkipUnplayable;
    final dlSettingsRaw = prefs.getString(_desktopLyricsSettingsKey);
    if (dlSettingsRaw != null && dlSettingsRaw.isNotEmpty) {
      try {
        final map = jsonDecode(dlSettingsRaw);
        if (map is Map<String, dynamic>) {
          desktopLyricsSettings = DesktopLyricsSettings.fromMap(map);
        }
      } catch (_) {}
    }
    unawaited(_audioHandler.setSpeed(playbackSpeed));
    // ====【需求/音调不持久化】启动音调恒为默认 1.0，不应用任何旧值。
    // 原实现（备份）：非 Windows 时 unawaited(_audioHandler.setPitch(pitch)) 恢复。====
    if (desktopLyricsEnabled) {
      unawaited(_desktopLyrics.updateSettings(desktopLyricsSettings));
    }
    _syncListeningTimeTracker();
    unawaited(_refreshEqualizerConfig());
    unawaited(_applyEqualizer());
    unawaited(_applyBassBoost());
    // ====【响度归一化】启动恢复：按持久化开关与档位驱动新方案。
    // ===== 原实现（备份，供回退）：动态压缩式音量均衡 =====
    // unawaited(_applyVolumeNormalization());
    //
    // ====【修复/启动时设置未同步到编排层】====
    // LoudnessNormalization.attach() 在 initState 中调用，早于本方法（_restoreSettings），
    // 因此 attach 时读到的 player 字段还是默认值（开关全关）。若用户上次已开启
    // 响度归一化/预分析，本次启动编排层仍是"关闭"状态 → 不生效，必须手动重开一次
    //（实测暴露：日志显示设置已开启但预分析不动）。
    // 故这里把三项设置一并同步给编排层（setPrescanEnabled 会顺带启动预扫描）。
    unawaited(LoudnessNormalization.setEnabled(volumeNormalizationEnabled));
    unawaited(LoudnessNormalization.setTarget(loudnessTarget));
    unawaited(
      LoudnessNormalization.setPrescanEnabled(loudnessPrescanEnabled),
    );
    notifyListeners();
  }

  List<int> _restoreEqualizerLevels(String? raw) {
    if (raw == null || raw.isEmpty) {
      return List<int>.of(_defaultEqualizerLevels);
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final levels = decoded
            .whereType<num>()
            .map((value) => value.round())
            .toList();
        if (levels.isNotEmpty) {
          return _levelsForBandCount(levels, _defaultEqualizerLevels.length);
        }
      }
    } catch (_) {}
    return List<int>.of(_defaultEqualizerLevels);
  }

  Future<void> _persistEqualizer() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_equalizerEnabledSettingKey, equalizerEnabled);
    await prefs.setString(_equalizerPresetSettingKey, equalizerPresetName);
    await prefs.setString(
      _equalizerLevelsSettingKey,
      jsonEncode(equalizerLevels),
    );
  }

  Future<void> _refreshEqualizerConfig() async {
    if (!isAudioEffectsSupported) {
      return;
    }
    final config = await _audioEffects.equalizerConfig(
      audioSessionId:
          _androidAudioSessionId ?? _audioHandler.androidAudioSessionId,
    );
    if (config == null || config.bands.isEmpty) {
      return;
    }
    equalizerConfig = config;
    if (equalizerLevels.length != config.bands.length) {
      equalizerLevels = _levelsForBandCount(
        equalizerLevels,
        config.bands.length,
      );
      unawaited(_persistEqualizer());
    }
    notifyListeners();
  }

  Future<void> _applyEqualizer() async {
    if (!isAudioEffectsSupported) {
      return;
    }
    await _audioEffects.configureEqualizer(
      audioSessionId:
          _androidAudioSessionId ?? _audioHandler.androidAudioSessionId,
      enabled: equalizerEnabled,
      levels: equalizerLevels,
    );
  }

  Future<void> _applyBassBoost() async {
    if (!isBassBoostSupported) {
      return;
    }

    await _audioEffects.configureBassBoost(
      audioSessionId:
          _androidAudioSessionId ?? _audioHandler.androidAudioSessionId,
      enabled: bassBoostEnabled,
      strength: bassBoostStrength,
    );
  }

  // ===== 原实现（备份，供回退）：动态压缩式音量均衡 =====
  // 【已废弃·不再调用】原方案用 DynamicsProcessing 做曲内动态压缩（threshold −15dB、
  // ratio 4:1 + 限制器），只压平歌曲内部强弱差，无法让不同歌曲的整体响度趋同，
  // 且会压缩动态（听感泵动）。新方案为【响度归一化】（见 LoudnessNormalization）：
  // 测量每首歌 integrated LUFS 后施加单一固定增益偏移，完整保留动态，双端生效。
  // 另注：本方法依赖的 isAudioEffectsSupported 为 Android 专属门禁，这也是原方案
  // 在 Windows 上完全无效的原因之一。Android 原生实现与通道分支均保留，便于回退。
  // 回退方式：恢复上方各调用点的 unawaited(_applyVolumeNormalization()) 即可。
  // ignore: unused_element  保留但不调用的备份实现（供快速回退）
  Future<void> _applyVolumeNormalization() async {
    if (!isAudioEffectsSupported) {
      return;
    }

    await _audioEffects.configureVolumeNormalization(
      audioSessionId:
          _androidAudioSessionId ?? _audioHandler.androidAudioSessionId,
      enabled: volumeNormalizationEnabled,
    );
  }

  void _syncListeningTimeTracker() {
    final shouldTrack =
        addListeningTimeEnabled && isPlaying && currentSong != null;
    if (shouldTrack) {
      _listenTimeStartedAt ??= DateTime.now();
      _listenTimeTimer ??= Timer.periodic(
        _listenTimeCheckInterval,
        (_) => unawaited(_maybeReportListeningTime()),
      );
      return;
    }

    _pauseListeningTimeTracker();
  }

  void _pauseListeningTimeTracker() {
    final startedAt = _listenTimeStartedAt;
    if (startedAt != null) {
      _pendingListenTime += DateTime.now().difference(startedAt);
      _listenTimeStartedAt = null;
    }
    _listenTimeTimer?.cancel();
    _listenTimeTimer = null;
  }

  void _resetListeningTimeTracker() {
    _listenTimeStartedAt = null;
    _pendingListenTime = Duration.zero;
    _listenTimeTimer?.cancel();
    _listenTimeTimer = null;
  }

  Duration _trackedListeningTime() {
    final startedAt = _listenTimeStartedAt;
    if (startedAt == null) {
      return _pendingListenTime;
    }
    return _pendingListenTime + DateTime.now().difference(startedAt);
  }

  Future<void> _maybeReportListeningTime() async {
    if (_isReportingListenTime || !addListeningTimeEnabled) {
      return;
    }
    if (_trackedListeningTime() < _listenTimeReportInterval) {
      return;
    }

    _isReportingListenTime = true;
    try {
      await _api.addListeningTime();
      // 上报成功，同步记录本地统计的听歌时长
      unawaited(_statsService.addListenTime(_listenTimeReportInterval));
      final stillPlaying = isPlaying && currentSong != null;
      final remainder = _trackedListeningTime() - _listenTimeReportInterval;
      _pendingListenTime = remainder > Duration.zero
          ? remainder
          : Duration.zero;
      _listenTimeStartedAt = stillPlaying ? DateTime.now() : null;
      if (!stillPlaying) {
        _listenTimeTimer?.cancel();
        _listenTimeTimer = null;
      }
    } catch (error) {
      debugPrint('[KA Music][listen-time] report failed: $error');
    } finally {
      _isReportingListenTime = false;
    }
  }

  Song? _nextSong() {
    if (queue.isEmpty) {
      return currentSong;
    }

    final index = currentIndex;
    if (playbackMode == PlaybackMode.shuffle) {
      if (queue.length == 1) return queue.first;

      var nextIndex = _random.nextInt(queue.length);
      if (index >= 0) {
        while (nextIndex == index) {
          nextIndex = _random.nextInt(queue.length);
        }
      }
      return queue[nextIndex];
    }

    if (index >= 0 && index < queue.length - 1) {
      return queue[index + 1];
    }

    return queue.first;
  }

  @override
  void dispose() {
    _disposed = true;
    _stopStats();
    _stallWatchTimer?.cancel();
    _pauseListeningTimeTracker();
    _stopPositionSaving();
    _queueSaveTimer?.cancel();
    _autoResumeTimer?.cancel();
    _sleepTimer?.cancel();
    _positionSub.cancel();
    _durationSub.cancel();
    _stateSub.cancel();
    _processingStateSub.cancel();
    _androidAudioSessionSub.cancel();
    _interruptionSub?.cancel();
    _becomingNoisySub?.cancel();
    _devicesSub?.cancel();
    _completionFallbackTimer?.cancel();
    unawaited(
      _audioEffects.configureEqualizer(
        audioSessionId:
            _androidAudioSessionId ?? _audioHandler.androidAudioSessionId,
        enabled: false,
        levels: equalizerLevels,
      ),
    );
    unawaited(
      _audioEffects.configureBassBoost(
        audioSessionId:
            _androidAudioSessionId ?? _audioHandler.androidAudioSessionId,
        enabled: false,
        strength: bassBoostStrength,
      ),
    );
    // ===== 原实现（备份，供回退）：动态压缩式音量均衡（DynamicsProcessing）=====
    // unawaited(
    //   _audioEffects.configureVolumeNormalization(
    //     audioSessionId:
    //         _androidAudioSessionId ?? _audioHandler.androidAudioSessionId,
    //     enabled: false,
    //   ),
    // );
    // ====【响度归一化】dispose 时撤销增益（含原生 LoudnessEnhancer）====
    unawaited(LoudnessNormalization.setEnabled(false));
    unawaited(_applyLoudnessEnhancerGain(0, enabled: false));
    // ====【修复/低端设备 UI 不刷新】取消切歌兜底定时器，避免 dispose 后回调。====
    _batchGuardTimer?.cancel();
    _batchGuardTimer = null;
    _audioHandler.detachTransportControls();
    _desktopLyrics.setVisibilityChangedHandler(null);
    unawaited(_audioHandler.close());
    unawaited(_desktopLyrics.hide());
    super.dispose();
  }

  /// ====【诊断/歌词高亮卡在行首】==== 上一次位置流到达的时刻，用于测量"位置流到达间隔"。
  /// smoothPosition = position + _positionClock.elapsed，只在位置流到达时重建基线；
  /// 因此**位置流越稀疏，逐字高亮推进得越慢**（相邻两次通知之间只按真实时间外推一小段）。
  /// 若该间隔远大于音频位置应有的更新频率，即可解释"高亮只在行首一点点"。
  static final Stopwatch _sinceStart = Stopwatch()..start();
  int _lastPositionBaseMs = 0;
  int _positionGapMaxMs = 0;
  int _positionBaseCount = 0;

  /// ====【修复/低端设备歌词高亮卡在行首】====
  ///
  /// 根因（TV 实测）：位置流到达间隔高达 **2.3s / 6.0s / 8.2s / 9.6s**，且期间
  /// `position` 完全不更新（实测停在 218570ms 十几秒）。而 `smoothPosition` 的算法是
  /// `position + _positionClock.elapsed`，**只在位置流到达时重建基线** ——
  /// 于是相邻两次通知之间高亮只按真实时间推进极小一段，表现为「每行只有开头一点点高亮」；
  /// 暂停时 `smoothPosition` 走 `!isPlaying ? position` 分支、不再外推，读数立刻正确，
  /// 这就是「暂停后才跳到正确位置」的原因。
  ///
  /// 修法：不依赖稀疏的位置流 —— 由歌词 ticker（16ms）主动从 handler 读取位置并重建基线。
  /// `MusicAudioHandler.position` 在 Android 上是 just_audio 的即时缓存值（非 Future），
  /// 读取无阻塞；Windows 侧本来就是 200ms 轮询的即时值。
  void refreshPositionFromHandler() {
    try {
      final pos = _audioHandler.position;
      // 位置没有前进时不重建基线（避免把外推时钟反复清零、反而更卡）。
      if (pos <= position) return;
      _setPositionBase(pos, playing: isPlaying);
    } catch (_) {
      // 读取失败：保持现有基线，不影响功能。
    }
  }

  void _setPositionBase(Duration value, {required bool playing}) {
    final nowMs = _sinceStart.elapsedMilliseconds;
    if (_lastPositionBaseMs > 0) {
      final gap = nowMs - _lastPositionBaseMs;
      if (gap > _positionGapMaxMs) _positionGapMaxMs = gap;
      if (gap >= 300) {
        StartupDiagLogger.phase(
          'positionStreamGap',
          ms: gap,
          note: '位置流到达间隔 $gap ms（此次 pos=${value.inMilliseconds}ms '
              'playing=$playing 次数=$_positionBaseCount '
              '历史最大=${_positionGapMaxMs}ms）',
        );
      }
    }
    _lastPositionBaseMs = nowMs;
    _positionBaseCount++;
    position = _clampPosition(value);
    _positionClock
      ..stop()
      ..reset();
    if (playing) {
      _positionClock.start();
    }
  }

  Duration _clampPosition(Duration value) {
    if (value < Duration.zero) {
      return Duration.zero;
    }
    if (duration > Duration.zero && value > duration) {
      return duration;
    }
    return value;
  }

  List<int> _levelsForBandCount(List<int> source, int count) {
    if (count <= 0) {
      return const [];
    }
    if (source.length == count) {
      return List<int>.of(source);
    }
    if (source.length == 1) {
      return List<int>.filled(count, source.first);
    }

    return [
      for (var index = 0; index < count; index++)
        source[((index / math.max(1, count - 1)) * (source.length - 1))
            .round()],
    ];
  }

  // ===== 播放队列持久化 =====

  /// 保存播放队列状态到本地存储（防抖 500ms）。
  void _saveQueueState() {
    _queueSaveTimer?.cancel();
    _queueSaveTimer = Timer(
      const Duration(milliseconds: _queueSaveDebounceMs),
      () => _persistQueueState(),
    );
  }

  /// 立即持久化播放队列、当前歌曲和播放模式。
  /// ====【修复/界面卡顿·队列/当前歌曲移出 prefs】播放队列可能很大（几百首歌），而
  /// SharedPreferences 每次 setString 会同步序列化并写整个 JSON 文件——队列越大，任何
  /// 其它 setXXX（含切歌时的开关）都变慢。现队列与当前歌曲改存独立小文件 + File 异步写
  /// （与位置/倍速同一模式）；prefs 只留小项（播放模式/进度兜底），主 JSON 大瘦身。
  /// 兼容性：restoreQueueState 优先读小文件、回退旧 prefs key 并迁移（见该方法）。====
  Future<void> _persistQueueState() async {
    final prefs = await SharedPreferences.getInstance();
    final song = currentSong;
    if (song != null) {
      // 当前歌曲 → 独立小文件异步写
      try {
        final f = await _currentSongFile();
        unawaited(f.writeAsString(jsonEncode(song.toCache())));
      } catch (_) {}
      // 位置主存：独立小文件（异步 IO，不卡顿，供 5s 定时/暂停/退出高频写）
      // 用安全进度 max(播放器位置, position)（恢复早期播放器未 seek 时不为 0 覆盖真实进度）
      final currentPos = _audioHandler.position > position
          ? _audioHandler.position
          : position;
      await _savePositionToFile(currentPos);
      // =====【修复/切歌卡顿·位置兜底快照移出 prefs】原实现此处额外 prefs.setInt 位置兜底快照，
      // 实测在 prefs 文件膨胀到数 MB 时单次 setInt 同步整写需 ~450ms，正好落在切歌淡入动画
      // 窗口内造成明显卡顿。位置小文件（playback_position）已是权威数据源，兜底快照无必要，
      // 故整块移除（_currentPositionKey 仅保留"读取时兼容旧数据"，不再写入）。=====
      // ===== 原实现（备份，供回退）=====
      // try {
      //   final sw = Stopwatch()..start();
      //   await prefs.setInt(_currentPositionKey, currentPos.inMilliseconds);
      //   SwitchTrace.mark('prefs写入:位置兜底',
      //       'setInt耗时=${sw.elapsedMilliseconds}ms');
      // } catch (_) {}
    } else {
      // 无当前歌曲：清空 current_song 小文件与旧 prefs key，避免残留旧歌
      try {
        final f = await _currentSongFile();
        if (f.existsSync()) await f.delete();
      } catch (_) {}
      try {
        await prefs.remove(_currentSongKey);
      } catch (_) {}
      // 清空位置小文件，避免残留旧进度
      await _savePositionToFile(Duration.zero);
    }
    // 队列 → 独立小文件异步写（不再进 prefs）
    try {
      final f = await _queueFile();
      unawaited(
        f.writeAsString(
          jsonEncode(queue.map((s) => s.toCache()).toList()),
        ),
      );
    } catch (_) {}
    // ====【修复/切歌卡顿·播放模式移出 prefs】原实现 prefs.setString 播放模式，实测同步整写
    // 膨胀后的 prefs 需 ~440ms（与位置兜底连续执行共约 890ms 主线程阻塞）。改存独立小文件
    // playback_mode + File 异步写；读取优先小文件、回退旧 prefs key 并迁移。====
    try {
      final f = await _playbackModeFile();
      unawaited(f.writeAsString(playbackMode.name));
    } catch (_) {}
    // ===== 原实现（备份，供回退）=====
    // final swMode = Stopwatch()..start();
    // await prefs.setString(_playbackModeKey, playbackMode.name);
    // SwitchTrace.mark('prefs写入:播放模式',
    //     'setString耗时=${swMode.elapsedMilliseconds}ms');
  }

  /// 启动定时保存播放进度（每 5 秒）。
  void _startPositionSaving() {
    _positionSaveTimer?.cancel();
    _positionSaveTimer = Timer.periodic(_positionSaveInterval, (_) {
      // 兜底低频写盘（30s，几乎不卡）；不阻塞等待
      unawaited(_saveCurrentPosition());
    });
  }

  // =====【方案A·二期】播放位置改用独立小文件 + 异步 IO，根治 SharedPreferences 同步写盘卡顿 =====
  // 原因：SharedPreferences 在 Windows 每次 setInt 都序列化并同步写整个 JSON，会在主线程
  // 同步阻塞一小段 -> 即便降频为 30s，写的那一次仍会卡帧。位置属高频小数据，改存独立小文件
  // 并用 File 异步写（不占主帧），从而彻底消除进度保存导致的卡顿，且间隔可缩短回 5s。
  // 读取时优先小文件，小文件不存在则回退旧 SharedPreferences key（_currentPositionKey）兼容旧数据。
  /// 播放位置小文件（跨平台：Android/桌面 用应用支持目录）。
  Future<File> _positionFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}playback_position');
  }

  // ====【修复/切歌卡顿·播放模式移出 prefs】====
  /// 播放模式小文件（避免 prefs 同步整写膨胀文件造成切歌卡顿）。
  Future<File> _playbackModeFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}playback_mode');
  }

  /// 异步写入播放位置到小文件（IO 不进主线程同步阻塞，不卡顿）。
  Future<void> _savePositionToFile(Duration pos) async {
    try {
      final f = await _positionFile();
      await f.writeAsString('${pos.inMilliseconds}', flush: true);
    } catch (_) {}
  }

  /// 保存当前播放进度（返回 Future，退出/关键事件可 await）。
  Future<void> _saveCurrentPosition() async {
    if (currentSong == null) return;
    // =====【修复】冷启动恢复早期 audioPlayer 尚未 seek（仍为 0），若直接用会把真实进度覆盖为 0。
    // 改用 max(播放器位置, 已恢复的 position 变量)：恢复期取恢复值，播放中取更新的实时位置；
    // 合法"seek/回到 0"时两者皆 0，仍正常存 0。=====
    await _savePositionToFile(
      _audioHandler.position > position ? _audioHandler.position : position,
    );
  }

  /// 停止定时保存播放进度。
  void _stopPositionSaving() {
    _positionSaveTimer?.cancel();
    _positionSaveTimer = null;
  }

  /// 校验本地音频文件头是否为有效格式（FLAC / M4A / MP3(含 ID3) / ADTS AAC）。
  /// 用于识别 cacheForPlayback 落盘的损坏缓存：扩展名虽为 .flac，但文件头是
  /// 乱码/破碎数据（如在线拉流中断、受保护流未解密就被落盘），WinRT 无法解码。
  bool _isFileAudioPlayable(String path) {
    try {
      final raf = File(path).openSync();
      List<int> head;
      try {
        head = raf.readSync(8);
      } finally {
        try {
          raf.closeSync();
        } catch (_) {}
      }
      if (head.length < 4) return false;
      final isFlac = head[0] == 0x66 && head[1] == 0x4c && head[2] == 0x61 &&
          head[3] == 0x43; // "fLaC"
      final isM4a = head.length >= 8 && head[4] == 0x66 && head[5] == 0x74 &&
          head[6] == 0x79 && head[7] == 0x70; // "ftyp"
      final isId3 = head[0] == 0x49 && head[1] == 0x44 &&
          head[2] == 0x33; // "ID3"
      final isMp3Frame = head[0] == 0xff && (head[1] & 0xe0) == 0xe0;
      final isAac = head[0] == 0xff && (head[1] & 0xf0) == 0xf0;
      return isFlac || isM4a || isId3 || isMp3Frame || isAac;
    } catch (_) {
      return false;
    }
  }

  // ===== Windows 播放卡死自愈兜底 =====
  // 背景：just_audio_windows 在反复切歌后会累积 WinRT USER 资源，导致某些歌播放
  // 卡死——总时长 0:00、按钮呈"播放中"但无声、进度不动、播放/暂停无效。重启恢复。
  // 本兜底在播放启动后布防一段延时，若到时仍判定"未真正开始（时长未就绪/状态未到
  // ready）"，则销毁底层 AudioPlayer 并重建（释放累积的原生资源），重新加载当前歌。

  /// 播放开始后布防一段探测：若届时仍未就绪，判定卡死并触发自愈（仅 Windows）。
  /// 限重试 1 次避免死循环。
  void _armStallWatcher() {
    if (!Platform.isWindows) return;
    _stallWatchTimer?.cancel();
    final thisHash = currentSong?.hash;
    _stallWatchTimer = Timer(const Duration(seconds: 8), () {
      if (_disposed) return;
      // 已切歌则忽略（不是当前歌的卡死探测）。
      if (currentSong?.hash != thisHash) return;
      // 重试一次，仍卡则不再折腾。
      if (_healRetryCount >= 1) return;
      // 判定卡死的两个条件：时长仍为 0（从未就绪），或仍在 loading/buffering。
      final stalled = duration <= Duration.zero ||
          _audioHandler.processingState == ProcessingState.loading ||
          _audioHandler.processingState == ProcessingState.buffering;
      if (!stalled) return;
      _healRetryCount++;
      // 解除"正在准备"状态并刷新 UI：让车机小播放器的"上一首/下一首"按钮恢复
      // 可点（其 onPressed 依赖 !isPreparing），方便用户在坏歌上直接切走。
      if (isPreparing) {
        isPreparing = false;
        notifyListeners();
      }
      // 确定触发：此路径在"判定卡死"时必执行，弹全局红提示使用户知情。
      final stalledName = currentSong?.title;
      if (stalledName != null && stalledName.isNotEmpty) {
        Toast.error('《$stalledName》无法播放：播放源异常或加载超时'
            '（可能版权受限/源无效），可尝试其它版本或渠道。');
      }
      // 清理当前歌损坏的播放缓存，避免下次切回再次命中坏文件。
      final stalledSong = currentSong;
      if (stalledSong != null) {
        unawaited(
          downloadController?.deletePlayCache(stalledSong, audioQuality),
        );
      }
      // ===== 【自动跳过无法播放的歌曲】=====
      // 开启 autoSkipUnplayable 时，播放卡死（约 8 秒）即自动切到队列下一首，
      // 而不是停在当前无法播放的歌上。
      if (autoSkipUnplayable) {
        final skipName = currentSong?.title;
        if (skipName != null && skipName.isNotEmpty) {
          Toast.error('《$skipName》无法播放，已自动切换到下一首。');
        }
        unawaited(next());
        return;
      }
      // =====【自愈】轻量处理 =====
      // 单首源无效(如网易云外链返回 HTML)时无需重建播放器——重建救不回无效源，
      // 反而迫使下一首用冷启动的新播放器，产生"坏歌之后第一首零进度/按钮禁用"。
      // 仅当"累计多次卡死(疑似引擎资源累积)"时才重建 AudioPlayer 兜底。
      _stallStreakCount++;
      if (_stallStreakCount >= 2) {
        _stallStreakCount = 0;
        unawaited(selfHealPlayback());
      }
    });
  }

  /// 自愈：销毁并重建底层 AudioPlayer，重接各事件流，并重新加载当前歌。
  ///
  /// 通过释放累积的 WinRT 资源来恢复播放。任何步骤失败都以尽力而为处理：
  /// 尽力恢复，不抛出未捕获异常。
  Future<void> selfHealPlayback() async {
    // ====【正式迁移/Windows 音频后端】Windows 已切 BASS：无 WinRT 资源累积，
    // 无需"重建播放器"自愈（重建反而会打断 BASS 引擎流）。加载失败/卡死由
    // _armStallWatcher 的"提示 + 清缓存 + 可选自动跳过"处理即可。====
    if (Platform.isWindows) return;
    final song = currentSong;
    if (song == null) return;
    debugPrint('[KA Music][heal] 检测到播放卡死，重建 AudioPlayer 自愈：${song.title}');
    try {
      // ===== 【自愈】提前校验：自愈启动时若用户已切到其它歌，放弃整个自愈 =====
      // 必须在 recreatePlayer 之前判断。否则播放器已被重建(全新实例)，此时对
      // 下一首就成了"冷启动加载"，表现为「坏歌切走后的第一首几秒零进度」。
      if (currentSong?.hash != song.hash) {
        debugPrint('[KA Music][heal] 已切歌，放弃重建自愈');
        return;
      }
      // 1) 取消旧订阅，避免重建后旧 Stream 事件流入。
      await _positionSub.cancel();
      await _durationSub.cancel();
      await _stateSub.cancel();
      await _processingStateSub.cancel();
      await _androidAudioSessionSub.cancel();

      // 2) 销毁旧 player 并新建（真正释放 WinRT 资源）。
      await _audioHandler.recreatePlayer();

      // 3) 重接各事件流到新 player。
      _subscribeToAudioPlayer();

      // 4) 重置播放状态，重新加载当前歌并从 0 播放。
      isPreparing = true;
      isPlaying = false;
      duration = Duration.zero;
      position = Duration.zero;
      notifyListeners();
      String url;
      final local = downloadController?.localPathFor(song, audioQuality);
      if (local != null) {
        url = local;
      } else if (song.source == SongSource.local) {
        url = song.id;
      } else {
        final playUrl = await _resolvePlayUrl(song);
        if (playUrl.url.isEmpty) {
          debugPrint('[KA Music][heal] 恢复地址为空，放弃自愈');
          return;
        }
        url = playUrl.url;
      }
      // 自愈期间若用户已切到其它歌，放弃对旧歌的自愈，避免其重载覆盖新歌播放
      // （否则会导致"从坏歌切到好歌时又短暂被拉回/零进度"）。
      if (currentSong?.hash != song.hash) {
        isPreparing = false;
        notifyListeners();
        return;
      }
      await _audioHandler.loadSong(
        song: song,
        url: url,
        queueSongs: queue,
        queueIndex: currentIndex,
      );
      await _audioHandler.play();
      isPreparing = false;
      unawaited(loadLyrics(song));
      notifyListeners();
      debugPrint('[KA Music][heal] 自愈完成：${song.title}');
    } catch (e) {
      // 尽力而为：自愈失败不抛未捕获异常，也不影响应用其它部分。
      debugPrint('[KA Music][heal] 自愈失败: $e');
      isPreparing = false;
      notifyListeners();
    }
  }

  /// 同步保存当前播放状态（用于 dispose 时紧急保存）。
  // ===== 【方案A优化】持久化改为可 await，供退出前同步落盘 =====
  /// 保存当前队列/歌曲 + 播放进度；返回 Future 以便退出前 await 保证落盘。
  ///（旧为 fire-and-forget：`_persistQueueState(); _saveCurrentPosition();` 可能未落盘即退出。）
  Future<void> persistCurrentStateSync() async {
    await _persistQueueState();
    await _saveCurrentPosition();
  }

  /// 用服务端「继续播放」列表填充队列并定位到第一首（不自动播放）。
  void restoreFromServerQueue(List<Song> songs) {
    if (songs.isEmpty || currentSong != null) return;
    queue = List<Song>.of(songs);
    currentSong = songs.first;
    position = Duration.zero;
    notifyListeners();
  }

  /// 从本地存储恢复播放队列、当前歌曲和播放进度。
  Future<void> restoreQueueState() async {
    final prefs = await SharedPreferences.getInstance();

    // 恢复播放模式
    // ====【修复/切歌卡顿·播放模式移出 prefs】优先读独立小文件；无则回退旧 prefs key 并迁移。====
    String? modeName;
    var modeFromFile = false;
    try {
      final f = await _playbackModeFile();
      if (f.existsSync()) {
        final raw = await f.readAsString();
        if (raw.trim().isNotEmpty) {
          modeName = raw.trim();
          modeFromFile = true;
        }
      }
    } catch (_) {}
    if (modeName == null) {
      final old = prefs.getString(_playbackModeKey);
      if (old != null && old.isNotEmpty) {
        modeName = old;
        try {
          final f = await _playbackModeFile();
          unawaited(f.writeAsString(old)); // 迁移旧值到小文件
        } catch (_) {}
      }
    }
    if (modeName != null) {
      for (final mode in PlaybackMode.values) {
        if (mode.name == modeName) {
          playbackMode = mode;
          break;
        }
      }
    }

    // 恢复播放队列
    // ====【修复/界面卡顿·兼容】优先读独立小文件；无则回退旧 prefs key 并迁移到小文件。====
    String? queueJson;
    var queueFromFile = false;
    try {
      final f = await _queueFile();
      if (f.existsSync()) {
        final raw = await f.readAsString();
        if (raw.isNotEmpty) {
          queueJson = raw;
          queueFromFile = true;
        }
      }
    } catch (_) {}
    final prefsGetSw = Stopwatch()..start();
    if (queueJson == null) {
      final old = prefs.getString(_queueKey); // 升级前旧数据回退
      if (old != null && old.isNotEmpty) {
        queueJson = old;
        try {
          final f = await _queueFile();
          unawaited(f.writeAsString(old)); // 迁移旧值到小文件
        } catch (_) {}
      }
    }
    prefsGetSw.stop();
    if (prefsGetSw.elapsedMilliseconds >= 20) {
      StartupDiagLogger.phase(
        'restoreQueuePrefsFallback',
        ms: prefsGetSw.elapsedMilliseconds,
        note: 'queueJson==null 时走 prefs 回退的耗时',
      );
    }
    if (queueJson != null) {
      // ====【诊断/启动卡顿】==== 队列解析逐段计时（实测 jsonDecode≈93ms / fromCache≈12ms，
      // 合计仅约 105ms —— 已确认**不是**主线程阻塞的主要来源，故不做 isolate 改造）。
      final qSw = Stopwatch()..start();
      try {
        final decoded = jsonDecode(queueJson);
        final decodeMs = qSw.elapsedMilliseconds;
        if (decoded is List) {
          final dSw = Stopwatch()..start();
          final restored2 = decoded
              .whereType<Map<String, dynamic>>()
              .map(Song.fromCache)
              .where((s) => s.hash.isNotEmpty)
              .toList();
          dSw.stop();
          StartupDiagLogger.phase(
            'restoreQueueParse',
            ms: qSw.elapsedMilliseconds,
            note: 'len=${decoded.length} bytes=${queueJson.length} '
                'jsonDecode=${decodeMs}ms fromCache=${dSw.elapsedMilliseconds}ms',
          );
          if (restored2.isNotEmpty) {
            queue = restored2;
          }
        }
      } catch (_) {}
    }

    // 恢复当前歌曲
    // ====【修复/界面卡顿·兼容】优先读独立小文件；无则回退旧 prefs key 并迁移到小文件。====
    String? songJson;
    var songFromFile = false;
    try {
      final f = await _currentSongFile();
      if (f.existsSync()) {
        final raw = await f.readAsString();
        if (raw.isNotEmpty) {
          songJson = raw;
          songFromFile = true;
        }
      }
    } catch (_) {}
    if (songJson == null) {
      final old = prefs.getString(_currentSongKey); // 升级前旧数据回退
      if (old != null && old.isNotEmpty) {
        songJson = old;
        try {
          final f = await _currentSongFile();
          unawaited(f.writeAsString(old)); // 迁移旧值到小文件
        } catch (_) {}
      }
    }
    if (songJson != null) {
      try {
        final decoded = jsonDecode(songJson);
        if (decoded is Map<String, dynamic>) {
          currentSong = Song.fromCache(decoded);
        }
      } catch (_) {}
    }

    // 恢复播放进度
    // =====【方案A·二期】位置优先从独立小文件读；小文件不存在/损坏则回退旧 key，并在此刻迁移旧数据 =====
    int? posMs;
    var posFromFile = false;
    try {
      final f = await _positionFile();
      final raw = await f.readAsString();
      final parsed = int.tryParse(raw.trim());
      if (parsed != null) {
        posMs = parsed;
        posFromFile = true;
      }
    } catch (_) {}
    if (posMs == null) {
      posMs = prefs.getInt(_currentPositionKey); // 旧数据（升级前）回退
      if (posMs != null) {
        // 合适的时机（恢复时）把旧数据迁移到小文件，此后以新位置为准
        await _savePositionToFile(Duration(milliseconds: posMs));
      }
    }
    if (posMs != null && posMs > 0) {
      position = Duration(milliseconds: posMs);
    }

    // ====【修复/切歌卡顿·机会式清理 prefs 旧键】====
    // 独立小文件已成为权威数据源（*FromFile=true）时，顺手删除 prefs 中对应历史键。
    // 时机安全：此时 prefs 已在 main() 最早期瘦身，删除代价为毫秒级；且仅删"数据已确定
    // 来自小文件"的键 —— 未升级用户（数据仍只在 prefs）或本次刚从小文件迁移的键都不删，
    // 避免任何数据丢失风险（迁移键会在下次启动"文件命中"时被清理）。
    try {
      if (modeFromFile) unawaited(prefs.remove(_playbackModeKey));
      if (queueFromFile) unawaited(prefs.remove(_queueKey));
      if (songFromFile) unawaited(prefs.remove(_currentSongKey));
      if (posFromFile) unawaited(prefs.remove(_currentPositionKey));
    } catch (_) {}

    notifyListeners();
  }

  /// 在恢复队列后加载并准备播放当前歌曲（不自动播放，仅预加载）。
  Future<void> prepareRestoredSong() async {
    MainThreadLagMonitor.crumb('prepareRestoredSong:enter');
    final song = currentSong;
    if (song == null) return;
    climax = null;
    unawaited(_loadClimax(song));

    // 在加载前保存恢复的进度（loadSong 会重置 position 为 0）
    final restoredPosition = position;

    isPreparing = true;
    notifyListeners();

    // ====【诊断/安卓渲染卡顿】==== 恢复播放链路逐段计时。
    final totalSw = Stopwatch()..start();
    try {
      String url;
      final local = downloadController?.localPathFor(song, audioQuality);
      if (local != null) {
        url = local;
      } else if (song.source == SongSource.local) {
        url = song.id;
      } else {
        final urlSw = Stopwatch()..start();
        final playUrl = await _resolvePlayUrl(song);
        urlSw.stop();
        StartupDiagLogger.phase(
          'resolvePlayUrl',
          ms: urlSw.elapsedMilliseconds,
          note: 'song=${song.title}',
        );
        if (playUrl.url.isEmpty) return;
        url = playUrl.url;
      }

      final loadSw = Stopwatch()..start();
      await _audioHandler.loadSong(
        song: song,
        url: url,
        queueSongs: queue,
        queueIndex: currentIndex,
      );
      loadSw.stop();
      StartupDiagLogger.phase(
        'handler.loadSong',
        ms: loadSw.elapsedMilliseconds,
        note: 'queueLen=${queue.length}',
      );

      // 跳转到保存的进度
      if (restoredPosition > Duration.zero) {
        final seekSw = Stopwatch()..start();
        await _audioHandler.seek(_clampPosition(restoredPosition));
        seekSw.stop();
        StartupDiagLogger.phase(
          'handler.seek',
          ms: seekSw.elapsedMilliseconds,
        );
      }

      final lyrSw = Stopwatch()..start();
      unawaited(loadLyrics(song));
      StartupDiagLogger.phase(
        'loadLyricsCall',
        ms: lyrSw.elapsedMilliseconds,
        note: 'song=${song.title}',
      );
      _startPositionSaving();
      totalSw.stop();
      StartupDiagLogger.phase(
        'prepareRestoredSong',
        ms: totalSw.elapsedMilliseconds,
        note: 'song=${song.title}',
      );
    } catch (e) {
      debugPrint('[KA Music] Failed to prepare restored song: $e');
    } finally {
      isPreparing = false;
      notifyListeners();
    }
  }
}
