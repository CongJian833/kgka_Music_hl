// ====【正式迁移/Windows 音频后端】BASS + BASS_FX 播放引擎（Windows 专用）====
// 由 PoC（lib/poc/bass_ffi.dart）提升并扩展：单例、生命周期管理、状态轮询、完成检测。
// BASS_FX Tempo（内核 SoundTouch 2.0）提供分离的变速(保音高)/变调(保速度)，非商业免费授权。
// 关键约定（PoC 验证）：
//   * 位置/总长从【源解码流】读取，Dart 侧换算（不调用 BASS_ChannelBytes2Seconds，
//     其 Float+Uint64 FFI 组合异常）；BASS_CHANNELINFO 按 32 字节分配防越界。
//   * 变速/变调用 Tempo 流上的 BASS_ATTRIB_TEMPO / BASS_ATTRIB_PITCH。
//   * 完成/缓冲状态用 BASS_ChannelIsActive 轮询（避免 Dart FFI 原生回调线程复杂度）。
import 'dart:ffi';
import 'dart:math' as math;

import 'package:ffi/ffi.dart'; // Utf8 / toNativeUtf16 / malloc

// ---- BASS 常量（win/x64, BASS 2.4.x）----
const _kPosByte = 0; // BASS_POS_BYTE
const _kStreamDecode = 0x200000; // BASS_STREAM_DECODE
const _kStreamPrescan = 0x20000; // BASS_STREAM_PRESCAN
const _kSampleFloat = 0x100; // BASS_SAMPLE_FLOAT
const _kUnicode = 0x80000000; // BASS_UNICODE（宽字符路径，中文/空格安全）
const _kAttribTempo = 0x10000; // BASS_ATTRIB_TEMPO（-95%~3000%）
const _kAttribPitch = 0x10001; // BASS_ATTRIB_PITCH（-60~+60 半音）
// ====【新增/响度归一化】BASS_ATTRIB_VOL：通道音量，线性系数（1.0 = 原始音量）。====
// 属性编号取自 BASS 头文件（FREQ=0x1, VOL=0x2, PAN=0x3）。
// 注：>1.0 是否被 BASS 放大取决于版本/设备，若被 clamp 则正增益退化为不提升
//（负增益不受影响，而流行歌曲绝大多数需要衰减），实测确认即可。
const _kAttribVol = 0x2;
const _kActiveStopped = 0; // BASS_ACTIVE_STOPPED
const _kActivePlaying = 1; // BASS_ACTIVE_PLAYING
const _kActiveStalled = 2; // BASS_ACTIVE_STALLED
const _kActivePaused = 3; // BASS_ACTIVE_PAUSED
// ====【新增/响度归一化】BASS 错误码：流已到末尾 ====
// 解码流读尽时 BASS_ChannelGetData 返回 (DWORD)-1 并置此错误码。
// 对"长度未知"的 URL 流（isDecodeStreamEnded 无法判定）尤为重要。
const kBassErrorEnded = 45;

/// BASS_CHANNELINFO（x64 POD，32 字节含 filename 指针，防越界写）。
final class _BassChannelInfo extends Struct {
  @Uint32()
  external int freq;
  @Uint32()
  external int chans;
  @Uint32()
  external int flags;
  @Uint32()
  external int ctype;
  @Uint32()
  external int origres;
  @Uint32()
  external int reserved;
  external Pointer<Void> filename;
}

// ---- DLL 加载（运行时从 exe 同目录；构建时经 CMake 安装到 Release）----
//
// ====【修复/安卓构建崩溃】==== 原实现是顶层直接 `DynamicLibrary.open('bass.dll')`：
// Android 构建同样会编译打包本文件（music_audio_handler 无条件 import 它），
// 于是安卓启动时会尝试加载 bass.dll → 立即抛错崩溃。改为**惰性初始化**：
// 只有首次真正用到 BASS 绑定（仅 Windows 分支会走到）时才 open。
// 非 Windows 平台永远不会触发，也就不会去加载 Windows 动态库。
DynamicLibrary? _bassLib;
DynamicLibrary? _bassFxLib;
DynamicLibrary get _bass => _bassLib ??= DynamicLibrary.open('bass.dll');
DynamicLibrary get _bassFx => _bassFxLib ??= DynamicLibrary.open('bass_fx.dll');

int Function(int, int, int, Pointer<Void>, Pointer<Void>) get _bassInit => _bass
    .lookupFunction<Int32 Function(Uint32, Uint32, Uint32, Pointer<Void>, Pointer<Void>), int Function(int, int, int, Pointer<Void>, Pointer<Void>)>('BASS_Init');

int Function(Pointer<Utf8>, int, int, Pointer<Void>, Pointer<Void>)
    get _streamCreateUrl => _bass.lookupFunction<
        Uint32 Function(Pointer<Utf8>, Uint32, Uint32, Pointer<Void>, Pointer<Void>),
        int Function(Pointer<Utf8>, int, int, Pointer<Void>, Pointer<Void>)>('BASS_StreamCreateURL');

int Function(int, Pointer<Void>, int, int, int) get _streamCreateFile =>
    _bass.lookupFunction<
        Uint32 Function(Uint32, Pointer<Void>, Uint64, Uint64, Uint32),
        int Function(int, Pointer<Void>, int, int, int)>('BASS_StreamCreateFile');

int Function(int) get _channelPause =>
    _bass.lookupFunction<Uint32 Function(Uint32), int Function(int)>('BASS_ChannelPause');
int Function(int) get _channelStop =>
    _bass.lookupFunction<Uint32 Function(Uint32), int Function(int)>('BASS_ChannelStop');
int Function(int, int) get _channelPlay =>
    _bass.lookupFunction<Uint32 Function(Uint32, Uint32), int Function(int, int)>('BASS_ChannelPlay');
int Function(int) get _channelIsActive =>
    _bass.lookupFunction<Uint32 Function(Uint32), int Function(int)>('BASS_ChannelIsActive');
int Function(int, int, int) get _channelSetPosition =>
    _bass.lookupFunction<Uint32 Function(Uint32, Uint64, Uint32), int Function(int, int, int)>('BASS_ChannelSetPosition');
int Function(int, int) get _channelGetPosition =>
    _bass.lookupFunction<Uint64 Function(Uint32, Uint32), int Function(int, int)>('BASS_ChannelGetPosition');
int Function(int, int) get _channelGetLength =>
    _bass.lookupFunction<Uint64 Function(Uint32, Uint32), int Function(int, int)>('BASS_ChannelGetLength');
int Function(int, Pointer<_BassChannelInfo>) get _channelGetInfo =>
    _bass.lookupFunction<Uint32 Function(Uint32, Pointer<_BassChannelInfo>), int Function(int, Pointer<_BassChannelInfo>)>('BASS_ChannelGetInfo');
int Function(int, int, double) get _channelSetAttr =>
    _bass.lookupFunction<Uint32 Function(Uint32, Uint32, Float), int Function(int, int, double)>('BASS_ChannelSetAttribute');
int Function() get _errorGetCode =>
    _bass.lookupFunction<Int32 Function(), int Function()>('BASS_ErrorGetCode');
void Function() get _bassFree =>
    _bass.lookupFunction<Void Function(), void Function()>('BASS_Free');

int Function(int, int) get _fxTempoCreate =>
    _bassFx.lookupFunction<Uint32 Function(Uint32, Uint32), int Function(int, int)>('BASS_FX_TempoCreate');

// ====【新增/响度归一化·离线解码分析】====
// 用途：创建【独立于播放流】的解码流读取 PCM 用于响度测量。
// 注意：分析只使用这些独立句柄，绝不触碰 _srcHandle/_tempoHandle（避免污染播放状态）。
// 返回语义：BASS_ChannelGetData 返回实际读到的字节数；失败返回 (DWORD)-1
//（Dart 侧 Uint32→int 为无符号，-1 会变成 0xFFFFFFFF，必须显式判断）。
int Function(int, Pointer<Void>, int) get _channelGetData => _bass.lookupFunction<
    Uint32 Function(Uint32, Pointer<Void>, Uint32),
    int Function(int, Pointer<Void>, int)>('BASS_ChannelGetData');

int Function(int) get _streamFree =>
    _bass.lookupFunction<Uint32 Function(Uint32), int Function(int)>('BASS_StreamFree');

// ====【诊断/冷启动无声期】==== BASS_ChannelGetLevel 返回瞬时电平：
//   低 16 位 = 左声道峰值、高 16 位 = 右声道峰值（0..32768）。
//   用途：Tempo 出声流在"预缓冲"阶段虽然状态是 PLAYING，但输出的是静音，
//   电平恒为 0；一旦 >0 即代表"真的出声了"。这是区分"进度在走"与"有声音"的唯一可靠信号。
int Function(int) get _channelGetLevel =>
    _bass.lookupFunction<Uint32 Function(Uint32), int Function(int)>('BASS_ChannelGetLevel');

/// 播放状态枚举（映射自 BASS_ChannelIsActive，供 handler 轮询映射）。
enum BassPlayState { stopped, playing, stalled, paused }

/// BASS 播放引擎（Windows 专用单例）。
class BassEngine {
  BassEngine._();
  static final BassEngine instance = BassEngine._();

  bool _inited = false;
  int _srcHandle = 0; // 源解码流（进度/总长/格式）
  int _tempoHandle = 0; // Tempo 播放流（实际出声）
  Pointer<Uint8>? _memPtr; // 本地文件字节的原生内存（换歌/dispose 时 free）
  bool _started = false; // 是否已调用 play（区分"加载未播"与"停止"）

  /// 初始化 BASS（默认设备 44100Hz）。可重复调用，已初始化则直接成功。
  bool ensureInit() {
    if (_inited) return true;
    final ok = _bassInit(-1, 44100, 0, nullptr, nullptr) != 0;
    _inited = ok;
    return ok;
  }

  /// 释放 BASS 全局资源（应用退出时）。
  void dispose() {
    if (_inited) {
      _freeCurrent();
      _bassFree();
      _inited = false;
    }
  }

  /// 从 URL 创建源+Tempo 流并加载（不自动播放）。
  /// 返回 true 成功；失败返回 false（错误码见 lastError）。
  bool loadUrl(String url) {
    final cUrl = url.toNativeUtf8();
    try {
      final src = _streamCreateUrl(
          cUrl, 0, _kStreamDecode | _kStreamPrescan, nullptr, nullptr);
      return _attachSrc(src);
    } finally {
      malloc.free(cUrl);
    }
  }

  /// 从本地文件创建源+Tempo 流（BASS 文件流模式 + Unicode 宽字符路径）。
  /// ====【修复/切歌卡顿·本地加载改文件流】原实现（备份）用内存流（readAsBytesSync 整读
  /// 文件进内存，大文件主线程同步读盘卡顿）。现改 BASS_StreamCreateFile 文件模式
  /// （BASS 流式按需读盘，不整读、不阻塞），配合 BASS_UNICODE 宽字符路径彻底解决
  /// 中文/空格路径，同时根治本地切歌的读盘卡顿。====
  bool loadFile(String path) {
    final w = path.toNativeUtf16();
    try {
      final src = _streamCreateFile(0, w.cast(), 0, 0,
          _kStreamDecode | _kStreamPrescan | _kSampleFloat | _kUnicode);
      return _attachSrc(src);
    } finally {
      malloc.free(w);
    }
  }

  /// 把新源流挂到引擎（释放旧流），并创建 Tempo 流。
  bool _attachSrc(int src) {
    if (src == 0) return false;
    _freeCurrent(); // 停旧流 + 释放旧资源
    final tempo = _fxTempoCreate(src, 0);
    if (tempo == 0) {
      _channelStop(src);
      return false;
    }
    _srcHandle = src;
    _tempoHandle = tempo;
    _started = false;
    // ====【新增/响度归一化】新流创建后通道属性为默认值（音量 1.0），
    // 必须在此补应用当前增益，否则切歌瞬间会先以 0dB 出声再被纠正（可听跳变）。
    // 这就是"换源预置增益"能避免台阶的关键：换流时用的已是正确值。====
    _applyOutputGain();
    return true;
  }

  void _freeCurrent() {
    if (_tempoHandle != 0) {
      _channelStop(_tempoHandle);
      _tempoHandle = 0;
    }
    if (_srcHandle != 0) {
      _channelStop(_srcHandle);
      _srcHandle = 0;
    }
    if (_memPtr != null) {
      malloc.free(_memPtr!);
      _memPtr = null;
    }
    _started = false;
  }

  /// 开始/恢复播放。restart=false（默认）从当前位置继续（暂停恢复正确）；首次播放
  /// 位置在 0 同样从头。原实现（备份）：restart 恒为 1 → 暂停后恢复会从头重播。
  bool play({bool restart = false}) {
    if (_tempoHandle == 0) return false;
    // 应用当前变速/变调设置（幂等）
    _channelSetAttr(_tempoHandle, _kAttribTempo, _tempoPercent);
    _channelSetAttr(_tempoHandle, _kAttribPitch, _pitchSemitones);
    // ====【新增/响度归一化】补应用输出增益（幂等）。
    // 与变速/变调同风格：属性可能因换流/引擎重建而丢失，每次播放补一次最稳。====
    _applyOutputGain();
    final ok = _channelPlay(_tempoHandle, restart ? 1 : 0) != 0;
    if (ok) _started = true;
    return ok;
  }

  // ====【新增/响度归一化·输出增益】====
  // 语义：按曲目响度算出的【单一固定增益偏移】（dB），0 表示不调整。
  // 与"动态压缩"完全不同——本引擎只做整体音量缩放，不改变歌曲动态。
  // 该字段是"用户设置级"状态：不随换歌清零（换歌时由上层在换源前写入新值）。
  double _gainDb = 0;

  /// 当前输出增益（dB）。
  double get outputGainDb => _gainDb;

  /// 设置输出增益（dB）。未加载流时仅记录，待加载/播放时自动应用。
  bool setOutputGainDb(double db) {
    _gainDb = db;
    if (_tempoHandle == 0) return false;
    return _applyOutputGain();
  }

  /// 把 [_gainDb] 应用到出声的 Tempo 流。返回是否成功写入。
  bool _applyOutputGain() {
    if (_tempoHandle == 0) return false;
    final linear = _gainDb == 0 ? 1.0 : math.pow(10, _gainDb / 20).toDouble();
    return _channelSetAttr(_tempoHandle, _kAttribVol, linear) != 0;
  }

  // ====【新增/响度归一化·离线解码流】====
  // 说明：以下方法创建/读取/释放【独立于播放流】的解码流，仅用于离线测量响度。
  // 它们不读写 _srcHandle / _tempoHandle，因此不会影响正在播放的音频。
  // 调用方（windows_loudness_decoder.dart）负责用完立即 freeDecodeStream。

  /// 创建分析用解码流（本地文件）。返回句柄，0 = 失败。
  /// 使用 BASS_UNICODE 保证中文/空格路径可用；BASS_SAMPLE_FLOAT 让输出为 float32
  ///（避免再传 GetData 标志位，规避不同版本标志定义差异）。
  ///
  /// 必须带 BASS_STREAM_PRESCAN（与播放路径 loadFile 一致）：实测缺省该标志时，
  /// 解码流的解码起点异常，BASS_ChannelGetData 首次调用即返回 -1（ENDED）。
  int createDecodeStreamFile(String path) {
    final w = path.toNativeUtf16();
    try {
      return _streamCreateFile(
        0,
        w.cast(),
        0,
        0,
        _kStreamDecode | _kStreamPrescan | _kSampleFloat | _kUnicode,
      );
    } finally {
      malloc.free(w);
    }
  }

  /// 创建分析用解码流（http/https URL）。返回句柄，0 = 失败。
  ///
  /// 注意：这会【再开一条 HTTP 连接】完整拉流，可能与正在播放的流抢带宽
  ///（酷狗 CDN 直链限速，易导致播放 stalled）。因此该路径仅作兜底，默认不用。
  int createDecodeStreamUrl(String url) {
    final cUrl = url.toNativeUtf8();
    try {
      return _streamCreateUrl(cUrl, 0, _kStreamDecode | _kSampleFloat, nullptr, nullptr);
    } finally {
      malloc.free(cUrl);
    }
  }

  /// 读取解码后的 float32 PCM 数据。
  ///
  /// 返回实际读到的【字节数】；`0xFFFFFFFF` 表示出错；`0` 表示当前暂无数据（网络等待）
  /// 或已到末尾（用 [isDecodeStreamEnded] 区分）。
  int readDecodeData(int handle, Pointer<Float> buffer, int bytes) {
    if (handle == 0) return 0xFFFFFFFF;
    return _channelGetData(handle, buffer.cast(), bytes);
  }

  /// 释放分析用解码流。幂等（句柄为 0 时忽略）。
  void freeDecodeStream(int handle) {
    if (handle == 0) return;
    _streamFree(handle);
  }

  /// 读取解码流的采样率/声道数/标志。失败返回 null。
  /// 分析侧据此决定 K 加权系数与分块大小（必须用实际输出格式，而非假定 44.1k）。
  ({int freq, int chans, int flags})? decodeStreamInfo(int handle) {
    if (handle == 0) return null;
    final info = malloc<_BassChannelInfo>();
    try {
      if (_channelGetInfo(handle, info) == 0) return null;
      final ref = info.ref;
      return (freq: ref.freq, chans: ref.chans, flags: ref.flags);
    } finally {
      malloc.free(info);
    }
  }

  /// 解码流是否已到末尾（位置 >= 总长）。
  bool isDecodeStreamEnded(int handle) {
    if (handle == 0) return true;
    final len = _channelGetLength(handle, _kPosByte);
    if (len <= 0) return false; // 长度未知（如部分 URL 流）→ 交给零读取计数兜底
    final pos = _channelGetPosition(handle, _kPosByte);
    return pos >= len;
  }

  bool pause() {
    if (_tempoHandle == 0) return false;
    return _channelPause(_tempoHandle) != 0;
  }

  bool stop() {
    if (_tempoHandle == 0) return false;
    final ok = _channelStop(_tempoHandle) != 0;
    _started = false;
    return ok;
  }

  /// 跳转（秒）。
  bool seek(double seconds) {
    if (_tempoHandle == 0) return false;
    return _channelSetPosition(_tempoHandle, _secondsToBytes(_tempoHandle, seconds), _kPosByte) != 0;
  }

  double _tempoPercent = 0;
  double _pitchSemitones = 0;

  /// 变速（%）：-95~3000，0=原速（保音高）。
  bool setSpeed(double percent) {
    _tempoPercent = percent;
    if (_tempoHandle == 0) return false;
    return _channelSetAttr(_tempoHandle, _kAttribTempo, percent) != 0;
  }

  /// 变调（半音）：-60~+60，0=原调（保速度）。
  bool setPitch(double semitones) {
    _pitchSemitones = semitones;
    if (_tempoHandle == 0) return false;
    return _channelSetAttr(_tempoHandle, _kAttribPitch, semitones) != 0;
  }

  /// 当前进度（秒，源时间轴）。未加载返回 0。
  double get position {
    if (_srcHandle == 0) return 0;
    return _bytesToSeconds(_srcHandle, _channelGetPosition(_srcHandle, _kPosByte));
  }

  /// 总时长（秒）。未加载返回 0。
  double get duration {
    if (_srcHandle == 0) return 0;
    return _bytesToSeconds(_srcHandle, _channelGetLength(_srcHandle, _kPosByte));
  }

  /// 播放状态（轮询 Tempo 流）。
  BassPlayState get state {
    if (_tempoHandle == 0) return BassPlayState.stopped;
    if (!_started) return BassPlayState.stopped;
    switch (_channelIsActive(_tempoHandle)) {
      case _kActivePlaying:
        return BassPlayState.playing;
      case _kActiveStalled:
        return BassPlayState.stalled;
      case _kActivePaused:
        return BassPlayState.paused;
      default:
        return BassPlayState.stopped;
    }
  }

  /// 是否已加载源（供 handler 轮询判断）。
  bool get isLoaded => _tempoHandle != 0;

  /// ====【诊断/冷启动无声期】==== 当前输出电平（0 = 静音，包含"状态 PLAYING 但还在
  /// 预缓冲"的情形）。取左右声道较大值。
  int get currentLevel {
    if (_tempoHandle == 0) return 0;
    // 未开始播放（stop/pause）时 BASS 的 level 读数没有意义，直接归零，
    // 避免把"未播放"误判成"已经出声"。
    if (!_started || state == BassPlayState.stopped) return 0;
    final lv = _channelGetLevel(_tempoHandle);
    final left = lv & 0xFFFF;
    final right = (lv >> 16) & 0xFFFF;
    return left > right ? left : right;
  }

  /// 是否正在出声（电平 > 0）。用于判断"无声期"是否结束。
  bool get isAudible => currentLevel > 0;

  /// 源解码流当前是否处于 PRESCAN 预扫描阶段（position 会先于出声前进）。
  bool get sourceHandleValid => _srcHandle != 0;

  /// 是否已播放完毕（自然结束）。
  bool get isCompleted {
    if (_tempoHandle == 0 || !_started) return false;
    return _channelIsActive(_tempoHandle) == _kActiveStopped;
  }

  /// 最近一次 FFI 错误码（调试）。
  int get lastError => _errorGetCode();

  // ---- 字节/秒换算（Dart 侧，绕开 BASS 换算 FFI 异常；bps 缓存防反复 GetInfo）----
  final Map<int, int> _bpsCache = {};

  int? _bytesPerSecond(int h) {
    final cached = _bpsCache[h];
    if (cached != null) return cached;
    final info = malloc<_BassChannelInfo>();
    try {
      if (_channelGetInfo(h, info) == 0) return null;
      final ref = info.ref;
      final bytesPerSample = (ref.flags & _kSampleFloat) != 0 ? 4 : 2;
      final bps = ref.freq * ref.chans * bytesPerSample;
      _bpsCache[h] = bps;
      return bps;
    } finally {
      malloc.free(info);
    }
  }

  double _bytesToSeconds(int h, int bytes) {
    final bps = _bytesPerSecond(h);
    if (bps == null || bps <= 0) return 0;
    return bytes / bps;
  }

  int _secondsToBytes(int h, double seconds) {
    final bps = _bytesPerSecond(h);
    if (bps == null || bps <= 0) return 0;
    return (seconds * bps).toInt();
  }
}
