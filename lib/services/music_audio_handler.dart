import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import '../models/music_models.dart';
import 'bass_engine.dart'; // ====【正式迁移/Windows 音频后端】BASS 引擎（Windows 专用）====
import 'startup_diag_logger.dart'; // ====【诊断/冷启动有效性问题】====

/// 播放器音频处理器。
///
/// 【正式迁移/Windows 音频后端】平台分支：
///   * Windows → BASS + BASS_FX（bass_engine.dart）：变调/变速分离、无 WinRT 句柄累积；
///   * Android（及其它平台）→ just_audio/ExoPlayer：保持原能力（均衡器/变调等）不变。
/// PlayerController 通过本 handler 的统一事件源/状态 getter 消费播放信息，
/// 不再直接依赖 just_audio 流（Windows 由内部轮询驱动，Android 透传原流）。
class MusicAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  MusicAudioHandler() {
    if (Platform.isWindows) {
      // Windows：BASS 引擎 + 统一事件源轮询驱动。
      BassEngine.instance.ensureInit();
      _startWindowsPolling();
    } else {
      // 非 Windows：沿用 just_audio 管道。
      _pipePlaybackState();
    }
  }

  // ---- 后端对象 ----
  AudioPlayer audioPlayer = AudioPlayer(); // Android 等非 Windows 使用

  // ---- 统一事件源（Windows 轮询驱动 / 非 Windows 透传 just_audio）----
  final StreamController<Duration> _posCtrl = StreamController.broadcast();
  final StreamController<Duration> _durCtrl = StreamController.broadcast();
  final StreamController<bool> _playingCtrl = StreamController.broadcast();
  final StreamController<ProcessingState> _procCtrl = StreamController.broadcast();
  Timer? _pollTimer;
  ProcessingState _procState = ProcessingState.idle;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _lastSpeed = 1.0;
  double _lastPitch = 1.0;
  bool _completed = false;

  // ====【诊断/冷启动无声期】==== 把「进度条在走」与「扬声器出声」两条时间线分开。
  bool _diagAudible = false;
  BassPlayState? _diagLastState;
  bool _diagFirstPosLogged = false;
  int _diagTicks = 0;
  Duration _diagPlayCallPos = Duration.zero;
  int _diagPlayCallLevel = -1;

  /// 秒 → 两位小数字符串（诊断用）。
  static String _sec(Duration d) =>
      (d.inMilliseconds / 1000).toStringAsFixed(2);

  void _startWindowsPolling() {
    _pollTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final engine = BassEngine.instance;
      if (!engine.isLoaded) return; // 未加载
      // 进度/总长（源时间轴，秒 → Duration）
      final pos = Duration(milliseconds: (engine.position * 1000).round());
      final dur = Duration(milliseconds: (engine.duration * 1000).round());
      // 状态：stalled→buffering；stopped→（自然结束 completed / 手动停止 stopped）
      final st = engine.state;
      // ---- 诊断打点：状态迁移 / 首次进度前进 / 首次真正出声 ----
      _diagTicks++;
      final lv = engine.currentLevel;
      if (_diagTicks == 1 || _diagTicks % 25 == 0) {
        StartupDiagLogger.winPlay(
          'SNAP state=${st.name} pos=${_sec(pos)}s dur=${_sec(dur)}s '
          'level=$lv srcPos=${engine.position.toStringAsFixed(2)}s',
        );
      }
      if (!_diagAudible && lv > 0) {
        _diagAudible = true;
        StartupDiagLogger.winPlay(
          'FIRST_AUDIBLE level=$lv pos=${_sec(pos)}s '
          'playCallPos=${_sec(_diagPlayCallPos)}s playCallLevel=$_diagPlayCallLevel',
        );
      }
      if (st != _diagLastState) {
        StartupDiagLogger.winPlay(
          'STATE ${_diagLastState?.name ?? 'null'}->${st.name} '
          'pos=${_sec(pos)}s level=$lv',
        );
        _diagLastState = st;
      }
      if (!_diagFirstPosLogged && pos > Duration.zero) {
        _diagFirstPosLogged = true;
        StartupDiagLogger.winPlay(
          'POS_FIRST_ADVANCE pos=${_sec(pos)}s level=$lv state=${st.name}',
        );
      }
      var proc = _procState;
      if (st == BassPlayState.playing) {
        proc = _completed ? ProcessingState.idle : ProcessingState.ready;
      } else if (st == BassPlayState.stalled) {
        proc = ProcessingState.buffering;
      } else if (st == BassPlayState.paused) {
        proc = ProcessingState.ready;
      } else {
        // stopped
        if (_completed && _playing) {
          // 播放结束后 BASS 回到 stopped：映射 completed，等待外部下一首
        }
        proc = _playing ? ProcessingState.completed : ProcessingState.idle;
      }
      _completed = false;
      if (pos != _position) {
        _position = pos;
        _posCtrl.add(pos);
      }
      if (dur != _duration && dur > Duration.zero) {
        _duration = dur;
        _durCtrl.add(dur);
      }
      if (proc != _procState) {
        _procState = proc;
        _procCtrl.add(proc);
      }
      // 完成检测：自然结束（已播放过且 active 变 stopped 且位置≈总长）
      if (st == BassPlayState.stopped &&
          _startedFlag &&
          dur > Duration.zero &&
          pos >= dur - const Duration(seconds: 1)) {
        _startedFlag = false;
        _playing = false;
        _procState = ProcessingState.completed;
        _procCtrl.add(_procState);
        _playingCtrl.add(false);
        playbackState.add(_buildPlaybackState());
      }
    });
  }

  bool _startedFlag = false;

  // ---- 非 Windows：原 just_audio 管道 ----
  void _pipePlaybackState() {
    audioPlayer.playbackEventStream
        .map(_playbackStateForEvent)
        .pipe(playbackState);
  }

  Future<void> Function()? _onNext;
  Future<void> Function()? _onPrevious;
  int _queueIndex = 0;

  void attachTransportControls({
    required Future<void> Function() onNext,
    required Future<void> Function() onPrevious,
  }) {
    _onNext = onNext;
    _onPrevious = onPrevious;
  }

  void detachTransportControls() {
    _onNext = null;
    _onPrevious = null;
  }

  /// 统一事件源/状态（PlayerController 使用，替代直接订阅 audioPlayer.*Stream）。
  Stream<Duration> get positionStream =>
      Platform.isWindows ? _posCtrl.stream : audioPlayer.positionStream;
  Stream<Duration?> get durationStream =>
      Platform.isWindows ? _durCtrl.stream : audioPlayer.durationStream;
  Stream<bool> get playingStream =>
      Platform.isWindows ? _playingCtrl.stream : audioPlayer.playerStateStream.map((s) => s.playing);
  Stream<ProcessingState> get processingStateStream =>
      Platform.isWindows ? _procCtrl.stream : audioPlayer.processingStateStream;

  /// 当前播放状态（统一读取）。
  bool get playing => Platform.isWindows ? _playing : audioPlayer.playing;
  ProcessingState get processingState =>
      Platform.isWindows ? _procState : audioPlayer.processingState;
  Duration get position => Platform.isWindows ? _position : audioPlayer.position;
  Duration? get duration => Platform.isWindows ? _duration : audioPlayer.duration;

  /// Android 均衡器依赖的音频会话 id；Windows 无此概念返回 null。
  int? get androidAudioSessionId =>
      Platform.isWindows ? null : audioPlayer.androidAudioSessionId;

  // ====【新增/响度归一化】====
  /// 换源前回调（同步）：由 LoudnessNormalization 注入，用于定下本次歌曲的增益。
  /// 见 loadSong 内调用点说明。
  void Function(Song song, String url)? onSourceLoaded;

  /// 设置响度归一化的输出增益（dB）。
  ///
  /// 平台分流：
  ///   * Windows → BASS 通道音量属性（线性系数），在桥接层换算；
  ///   * Android → 负增益走播放器音量（LoudnessEnhancer 是"纯提升"类效果，
  ///     对负值不可靠），正向由 LoudnessNormalization 走原生 LoudnessEnhancer。
  /// 本方法只负责"衰减"与 Windows 增益；Android 的正增益由编排层直接调原生通道。
  Future<void> setNormalizationGainDb(double gainDb) async {
    if (Platform.isWindows) {
      BassEngine.instance.setOutputGainDb(gainDb);
      return;
    }
    // Android：把增益折算为播放器音量（仅衰减有意义；正增益由 LoudnessEnhancer 负责，
    // 此时音量保持 1.0，避免两条通道叠乘）。
    final linear = gainDb >= 0 ? 1.0 : _gainDbToLinear(gainDb);
    await audioPlayer.setVolume(linear.clamp(0.0, 1.0));
  }

  /// dB → 线性（10^(dB/20)）。仅用于 Android 音量衰减换算。
  static double _gainDbToLinear(double db) => math.pow(10, db / 20).toDouble();

  /// 同步设置增益（Windows 专用路径）。
  ///
  /// 用途：切歌换源前需要【同步】把增益定下来（BASS 换流会重置通道属性），
  /// 异步 await 会错过换流时机导致跳变。非 Windows 平台无同步通道，直接忽略
  ///（Android 的增益由异步方法 + 原生效果承担）。
  void setNormalizationGainDbSync(double gainDb) {
    if (Platform.isWindows) {
      BassEngine.instance.setOutputGainDb(gainDb);
    }
  }

  Future<void> loadSong({
    required Song song,
    required String url,
    required List<Song> queueSongs,
    required int queueIndex,
  }) async {
    _queueIndex = queueIndex < 0 ? 0 : queueIndex;
    // ====【诊断/安卓启动卡顿】==== 拆开三段：同步构造 MediaItem 列表 / 投递整个队列 / 平台加载。
    final t0 = DateTime.now();
    final currentItem = _mediaItemFor(song);
    final items = queueSongs.map(_mediaItemFor).toList(growable: false);
    final t1 = DateTime.now();

    if (items.isNotEmpty) {
      queue.add(items);
    }
    mediaItem.add(currentItem);
    final t2 = DateTime.now();

    // ====【新增/响度归一化·换源前钩子】====
    // 在真正切换平台音源【之前】回调上层，让响度归一化把本次歌曲的目标增益定下来：
    //   * 内存中已有该曲响度 → 立刻写入正确增益（换流时即生效，无跳变）
    //   * 否则先归零（避免上一首的增益错误地作用在新歌上）
    // 这是所有换源入口的唯一收敛点，故钩子放这里可覆盖全部加载路径。
    onSourceLoaded?.call(song, url);

    if (Platform.isWindows) {
      // ====【正式迁移/Windows 音频后端】BASS 加载：URL 流 / 本地内存流 ====
      // 本地用内存流天然规避中文/空格路径解析问题（原 just_audio_windows 需 ASCII 副本，
      // 见备份 _normalizeLocalPlayPath；BASS 方案不再需要）。
      final ok = url.startsWith('http://') || url.startsWith('https://')
          ? BassEngine.instance.loadUrl(url)
          : BassEngine.instance.loadFile(url);
      _resetForLoad();
      if (ok) {
        StartupDiagLogger.winPlay(
          'LOAD_OK kind=${url.startsWith('http') ? 'url' : 'file'} '
          'srcDur=${BassEngine.instance.duration.toStringAsFixed(2)}s '
          'state=${BassEngine.instance.state.name}',
        );
        // 恢复倍速/变调配置：统一走 setSpeed/setPitch（平台分支内换算一致）。
        // 原实现（备份）：BassEngine.instance.setPitch((_lastPitch - 1) * 12)
        // 为线性换算，与 setPitch 的 12*log2(pitch) 不一致（变调值会偏）。
        await setSpeed(_lastSpeed);
        await setPitch(_lastPitch);
        _duration = Duration(
          milliseconds: (BassEngine.instance.duration * 1000).round(),
        );
        _durCtrl.add(_duration);
        _startedFlag = false;
        _completed = false;
        _procState = ProcessingState.loading;
        _procCtrl.add(_procState);
      } else {
        _procState = ProcessingState.idle;
        _procCtrl.add(_procState);
      }
      return;
    }

    // ===== 本地歌曲播放：路径归一化 + 诊断（原实现，备份，供回退）=====
    // just_audio_windows 用 MediaSource::CreateFromUri 解析本地文件，对「带空格
    // 目录 + 长路径 + 中文文件名」等路径存在解析隐患，固定报「Item error: 系统
    // 找不到指定的文件」（文件实际存在、系统播放器可正常播放）。为规避该问题，
    // 本地播放路径若非纯净 ASCII（含中文/空格等），播放前先复制一份到纯 ASCII
    // 短路径的临时目录再交给播放器。诊断日志落在 %TEMP%\ka_music_audio_diagnose.log。
    if (!(url.startsWith('http://') || url.startsWith('https://'))) {
      final diagDir = Platform.environment['TEMP'] ?? Directory.systemTemp.path;
      final diag = File(
        '$diagDir${Platform.pathSeparator}ka_music_audio_diagnose.log',
      );
      try {
        diag.writeAsStringSync(
          '[${DateTime.now()}] song=${song.title} hash=${song.hash}\n'
          '  url=$url\n',
          mode: FileMode.append,
          flush: true,
        );
        final normalized = await _normalizeLocalPlayPath(File(url), diag);
        diag.writeAsStringSync(
          '  used=$normalized\n',
          mode: FileMode.append,
          flush: true,
        );
        url = normalized;
      } catch (e) {
        diag.writeAsStringSync(
          '[${DateTime.now()}] diagnose-probe-error: $e\n',
          mode: FileMode.append,
          flush: true,
        );
      }
    }
    final t3 = DateTime.now();
    if (url.startsWith('http://') || url.startsWith('https://')) {
      await audioPlayer.setUrl(url);
    } else {
      await audioPlayer.setAudioSource(AudioSource.file(url));
    }
    final t4 = DateTime.now();
    StartupDiagLogger.phase(
      'loadSongBreakdown',
      note: 'queueLen=${items.length} '
          'buildItems=${t1.difference(t0).inMilliseconds}ms '
          'queueAndMediaItem=${t2.difference(t1).inMilliseconds}ms '
          'beforePlatform=${t3.difference(t2).inMilliseconds}ms '
          'platformSetSource=${t4.difference(t3).inMilliseconds}ms '
          'total=${t4.difference(t0).inMilliseconds}ms',
    );
  }

  void _resetForLoad() {
    _position = Duration.zero;
    _duration = Duration.zero;
    _playing = false;
    _completed = false;
    _startedFlag = false;
  }

  /// 返回本地文件在 Windows 下可被 just_audio_windows 稳定解析的播放路径。
  ///（原实现，备份，供回退；BASS 方案已用内存流，此方法保留给非 Windows 使用。）
  Future<String> _normalizeLocalPlayPath(File file, File diag) async {
    void diagLine(String s) {
      diag.writeAsStringSync('  $s\n', mode: FileMode.append, flush: true);
    }

    if (!Platform.isWindows) return file.path;
    if (!file.existsSync()) {
      diagLine('WARN file missing; use original path');
      return file.path;
    }
    // 含空格或任意非 ASCII 字符视为「易触发解析问题」路径。
    final risky = RegExp(r'[\u0020\u0080-\uFFFF]').hasMatch(file.path);
    if (!risky) {
      diagLine('ASCII-clean path; use original');
      return file.path;
    }
    final tmpBase = Platform.environment['TEMP'] ?? Directory.systemTemp.path;
    final dir = Directory('$tmpBase${Platform.pathSeparator}ka_music_play_ascii');
    try {
      dir.createSync(recursive: true);
    } catch (e) {
      diagLine('create dir FAILED: $e; use original');
      return file.path;
    }
    final dest = File(
      '${dir.path}${Platform.pathSeparator}${_asciiKey(file.path)}${_extOf(file.path)}',
    );
    if (!dest.existsSync()) {
      try {
        await file.copy(dest.path);
        diagLine('copied -> $dest');
      } catch (e) {
        diagLine('copy FAILED: $e; use original');
        return file.path;
      }
    } else {
      diagLine('reuse ascii copy $dest');
    }
    return dest.path;
  }

  /// 由绝对路径生成稳定的纯 ASCII 键（避免文件名碰撞，同时可跨会话复用副本）。
  String _asciiKey(String path) {
    var h = 17;
    for (final c in path.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return 'ka_${h.toRadixString(36)}';
  }

  /// 提取文件扩展名（小写），无扩展名则返回空串。
  String _extOf(String path) {
    final i = path.lastIndexOf('.');
    if (i < 0 || i == path.length - 1) return '';
    return path.substring(i).toLowerCase();
  }

  @override
  Future<void> updateQueue(List<MediaItem> queue) async {
    this.queue.add(queue);
  }

  Future<void> setSongQueue({
    required List<Song> queueSongs,
    required int queueIndex,
    Song? currentSong,
  }) async {
    _queueIndex = queueIndex < 0 ? 0 : queueIndex;
    queue.add(queueSongs.map(_mediaItemFor).toList(growable: false));
    if (currentSong != null) {
      mediaItem.add(_mediaItemFor(currentSong));
    }
  }

  // ====【正式迁移/Windows 音频后端】控制方法平台分支 ====

  @override
  Future<void> play() async {
    if (Platform.isWindows) {
      _playing = true;
      _startedFlag = true;
      _playingCtrl.add(true);
      playbackState.add(_buildPlaybackState());
      // ====【诊断/冷启动无声期】==== 调用 BASS play 前的高度：此时电平/位置是多少。
      final engine = BassEngine.instance;
      _diagAudible = false;
      _diagFirstPosLogged = false;
      _diagLastState = null;
      _diagTicks = 0;
      _diagPlayCallPos =
          Duration(milliseconds: (engine.position * 1000).round());
      _diagPlayCallLevel = engine.currentLevel;
      StartupDiagLogger.winPlay(
        'PLAY_CALL posAtCall=${_sec(_diagPlayCallPos)}s '
        'levelAtCall=$_diagPlayCallLevel stateAtCall=${engine.state.name} '
        'isLoaded=${engine.isLoaded} ttsState=${engine.state.name}',
      );
      final sw = Stopwatch()..start();
      final ok = engine.play();
      sw.stop();
      final posAfter =
          Duration(milliseconds: (engine.position * 1000).round());
      StartupDiagLogger.winPlay(
        'PLAY_RETURN ok=$ok levelAfter=${engine.currentLevel} '
        'posAfter=${_sec(posAfter)}s',
        ms: sw.elapsedMilliseconds,
      );
      return;
    }
    // ===== 原实现（备份，供回退）=====
    // await audioPlayer.play();
    //
    // ====【修复/低端设备切歌后 UI 永久不刷新（歌名/封面/歌词/播放模式停在旧歌）】====
    // just_audio 的 audioPlayer.play() 返回的 Future **在"播放结束或被暂停"时才完成**，
    // 而非"开始播放"时。直接 await 会让调用方（PlayerController.playSong）整个阻塞到
    // 这首歌播完 —— 而 playSong 用 _notifyBatch 合并切歌期间的通知、并在 finally 里
    // 统一广播一次；阻塞期间该计数一直 >0，导致之后所有 notifyListeners 全被吞掉：
    // UI 永久停在旧歌，只有"暂停"（令该 Future 完成、finally 得以执行）或页面重建
    // 才恢复。Windows 分支是同步 return，因此无此问题 —— 这也是该缺陷只在 Android
    // （尤其低性能设备）暴露的原因。
    // 修复：改为 fire-and-forget（播放状态由 playingStream/playbackState 正常传播）；
    // 异常不再向上抛给 playSong（否则会在播放结束时才延迟触发错误提示）。
    unawaited(audioPlayer.play().catchError((Object _) {}));
  }

  @override
  Future<void> pause() async {
    if (Platform.isWindows) {
      _playing = false;
      _playingCtrl.add(false);
      playbackState.add(_buildPlaybackState());
      BassEngine.instance.pause();
      return;
    }
    await audioPlayer.pause(); // 原实现（备份）
  }

  @override
  Future<void> seek(Duration position) async {
    if (Platform.isWindows) {
      _position = position;
      _posCtrl.add(position);
      BassEngine.instance.seek(position.inMilliseconds / 1000.0);
      return;
    }
    await audioPlayer.seek(position); // 原实现（备份）
  }

  /// 倍速（0.5~3.0）。Windows → BASS Tempo（变速保音高）；其它 → just_audio。
  @override
  Future<void> setSpeed(double speed) async {
    _lastSpeed = speed;
    if (Platform.isWindows) {
      BassEngine.instance.setSpeed((speed - 1) * 100);
      return;
    }
    await audioPlayer.setSpeed(speed); // 原实现（备份）
  }

  /// 变调（0.5~2.0 映射为半音 ≈12*log2(v)）。Windows → BASS PITCH；其它 → just_audio。
  Future<void> setPitch(double pitch) async {
    _lastPitch = pitch;
    if (Platform.isWindows) {
      // 用户配置是倍率(0.5~2.0)，转为半音：semitones = 12*log2(pitch)
      final semitones = 12 * (pitch > 0 ? math.log(pitch) / math.ln2 : 0.0);
      BassEngine.instance.setPitch(semitones.clamp(-60, 60));
      return;
    }
    await audioPlayer.setPitch(pitch); // 原实现（备份）
  }

  @override
  Future<void> skipToNext() async {
    await _onNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    await _onPrevious?.call();
  }

  @override
  Future<void> stop() async {
    if (Platform.isWindows) {
      _playing = false;
      _startedFlag = false;
      _playingCtrl.add(false);
      BassEngine.instance.stop();
      return;
    }
    await audioPlayer.stop(); // 原实现（备份）
  }

  Future<void> close() async {
    _pollTimer?.cancel();
    if (Platform.isWindows) {
      BassEngine.instance.dispose();
      return;
    }
    await audioPlayer.dispose(); // 原实现（备份）
  }

  /// 重建底层的 [AudioPlayer]。
  ///
  /// 用途：Windows 上 just_audio_windows 在反复切歌后会累积 WinRT USER 资源，
  /// 导致播放卡死（时长 0:00、无声、按钮失效）。此方法销毁旧 player 并新建一个，
  /// 从而释放累积的原生资源（自愈兜底）。
  /// ====【正式迁移/Windows 音频后端】Windows 已切 BASS（无 WinRT 资源累积），
  /// 该方法在 Windows 上为空操作；非 Windows 保留原重建逻辑。====
  Future<void> recreatePlayer() async {
    if (Platform.isWindows) return; // BASS 无需自愈重建
    await audioPlayer.dispose();
    audioPlayer = AudioPlayer();
    _pipePlaybackState();
  }

  MediaItem _mediaItemFor(Song song) {
    return MediaItem(
      id: song.hash.isEmpty ? song.id : song.hash,
      album: song.albumName,
      title: song.title,
      artist: song.artist,
      duration: song.duration,
      artUri: song.coverUrl == null ? null : Uri.tryParse(song.coverUrl!),
      extras: {'hash': song.hash, 'songId': song.id},
    );
  }

  /// Windows：从统一状态构建 audio_service PlaybackState。
  PlaybackState _buildPlaybackState() {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (_playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekBackward,
        MediaAction.seekForward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: _procState == ProcessingState.completed
          ? AudioProcessingState.completed
          : _procState == ProcessingState.loading
              ? AudioProcessingState.loading
              : _procState == ProcessingState.buffering
                  ? AudioProcessingState.buffering
                  : AudioProcessingState.ready,
      playing: _playing,
      updatePosition: _position,
      bufferedPosition: _position,
      speed: _lastSpeed,
      queueIndex: _queueIndex,
    );
  }

  // ==== 非 Windows：原 just_audio 事件 → playbackState 映射（备份）====
  PlaybackState _playbackStateForEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (audioPlayer.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekBackward,
        MediaAction.seekForward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[audioPlayer.processingState]!,
      playing: audioPlayer.playing,
      updatePosition: audioPlayer.position,
      bufferedPosition: audioPlayer.bufferedPosition,
      speed: audioPlayer.speed,
      queueIndex: _queueIndex,
    );
  }
}
