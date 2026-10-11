// ====【新增/响度归一化·Windows 解码分析】====
//
// 职责：用 BASS 的【独立解码流】把本地文件（或可选 URL）解码成 float32 PCM，
// 分块喂给 LoudnessAnalyzer 得到 integrated LUFS 与采样峰值。
//
// 安全边界（务必遵守）：
//   * 只操作本次创建的独立解码流句柄，绝不触碰 BassEngine 的 _srcHandle/_tempoHandle，
//     因此不影响正在播放的音频；
//   * 句柄必须在 finally 中释放（freeDecodeStream），任何异常路径都不能泄漏；
//   * 分块之间让出事件循环（每 0.5s 音频让出 ~8ms），保证 UI 线程不被长任务霸占
//     ——本项目对切歌/滚动卡顿零容忍；
//   * 三重防挂死：取消标志、已处理样本上限、零读取超时。
//
// 为何不用 Isolate：
//   BASS 的 DynamicLibrary 句柄与 BassEngine 单例状态（_inited 等）按 isolate 独立，
//   在子 isolate 里操作 BASS 会与主 isolate 的播放状态割裂且易误调 BASS_Init/Free。
//   故 DSP 在主 isolate 分块执行 + 主动让出，这也是项目既有做法（提色曾踩过 isolate 坑）。
import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bass_engine.dart';
import 'loudness_analyzer.dart';

/// 每次读取的音频时长（0.5s）。越小让出越频繁、总耗时略增；0.5s 是实测平衡点。
const double _kChunkSeconds = 0.5;

/// ====【性能优化/缩短分析耗时（用户反馈"切歌后想快点生效"）】====
/// 原策略：每读一块（0.5s 音频）就让出 8ms。
/// 实测（120s 音频）：总耗时 2423ms，其中让出约 1920ms —— 占 79%，
/// 即绝大部分时间纯在等待，而非真实解码/滤波（单块解码+滤波实测仅约 2.1ms）。
/// 现策略：每 [_kYieldEveryChunks] 块（即 2s 音频）让出一次，让出时长降到 [_kYieldDuration]。
///   单次连续占用 ≈ 4×2.1 = 8.4ms < 一帧 16.7ms → 不会掉帧；
///   让出开销降至约 1/4。
/// 预期效果：120s 音频 2423ms → ≈620ms（约 3.9 倍）；4 分钟歌 ≈4.9s → ≈1.3s。
/// 若日后发现长音频分析时 UI 有可感卡顿，把 [_kYieldEveryChunks] 调小即可（1 最保守）。
const int _kYieldEveryChunks = 4;
const Duration _kYieldDuration = Duration(milliseconds: 4);

/// 单首分析墙钟超时（防止网络流/损坏文件无限挂住）。
const Duration _kAnalysisTimeout = Duration(seconds: 45);

/// 连续无数据读取的最大次数（每次间隔 [_kNoDataRetryDelay]，超过即判定失败）。
/// 仅 URL 流可能出现"暂无可读数据"，本地文件不会。
const int _kMaxZeroReads = 50;
const Duration _kNoDataRetryDelay = Duration(milliseconds: 20);

/// 已处理样本时长上限（防异常文件无限解码）：取歌曲时长 1.1 倍，且不超过 20 分钟。
const Duration _kMaxProcessedFallback = Duration(minutes: 20);

/// 用 BASS 解码流分析响度。
///
/// [pathOrUrl] 本地路径或 http(s) URL；[isUrl] 决定创建方式；
/// [duration] 歌曲时长（用于计算处理上限，可为 null）；
/// [isCancelled] 每个分块检查一次，返回 true 立即放弃并释放资源。
///
/// 返回 null 表示失败。调用方不要把 null 当作"响度为 0"。
Future<LoudnessResult?> analyzeWithBass({
  required String pathOrUrl,
  required bool isUrl,
  required Duration? duration,
  required bool Function() isCancelled,
}) async {
  final engine = BassEngine.instance;

  var handle = 0;
  Pointer<Float>? buffer;
  try {
    handle = isUrl
        ? engine.createDecodeStreamUrl(pathOrUrl)
        : engine.createDecodeStreamFile(pathOrUrl);
    if (handle == 0) {
      return null;
    }

    final info = engine.decodeStreamInfo(handle);
    if (info == null || info.freq <= 0 || info.chans <= 0) {
      return null;
    }
    // 采样率/声道数必须用【实际输出格式】，K 加权系数与分块大小都依赖它。
    final analyzer = LoudnessAnalyzer(sampleRate: info.freq, channels: info.chans);

    // 每块 0.5s 的字节数 = 帧数 × 声道 × 4（float32）
    final chunkFrames = (info.freq * _kChunkSeconds).round();
    final chunkBytes = chunkFrames * info.chans * 4;
    buffer = malloc<Float>(chunkBytes ~/ 4);

    // 处理时长上限（防异常文件）
    final maxProcessedSeconds = duration != null && duration > Duration.zero
        ? (duration.inMilliseconds / 1000.0) * 1.1
        : _kMaxProcessedFallback.inSeconds.toDouble();
    final maxProcessedFrames = (maxProcessedSeconds * info.freq).round();

    final deadline = DateTime.now().add(_kAnalysisTimeout);
    var processedFrames = 0;
    var zeroReads = 0;
    var chunksSinceYield = 0;

    while (true) {
      if (isCancelled()) {
        return null;
      }
      if (DateTime.now().isAfter(deadline)) {
        return null;
      }
      if (processedFrames >= maxProcessedFrames) {
        break;
      }

      final got = engine.readDecodeData(handle, buffer, chunkBytes);
      if (got == 0xFFFFFFFF) {
        // ====【关键】BASS 在解码流到达末尾时返回 (DWORD)-1，并把错误码置为
        // 45 = BASS_ERROR_ENDED —— 这是【正常结束】，不是读取失败！
        // 必须区分，否则会把已成功读完的音频误判为失败
        //（实测：10s@48kHz 的 WAV 读满 480000 帧后即出现该返回）。
        // 双重判定：位置>=长度（本地文件可靠），或错误码为 ENDED
        //（对长度未知的 URL 流——此时 isDecodeStreamEnded 恒为 false——尤为重要）。
        final err = engine.lastError;
        if (engine.isDecodeStreamEnded(handle) || err == kBassErrorEnded) break;
        // 真正的读取错误（损坏文件/解码失败）。
        return null;
      }
      if (got == 0) {
        // 无数据：区分"已到末尾"与"网络等待"
        if (engine.isDecodeStreamEnded(handle)) break;
        zeroReads++;
        if (zeroReads > _kMaxZeroReads) {
          return null;
        }
        await Future<void>.delayed(_kNoDataRetryDelay);
        continue;
      }
      zeroReads = 0;

      // 严格校验：BASS 不应返回超过请求的数据（防御性检查，异常即视为错误）
      if (got > chunkBytes || got % 4 != 0) {
        return null;
      }

      final samples = buffer.asTypedList(got ~/ 4);
      analyzer.addFloatPcm(samples);
      processedFrames += samples.length ~/ info.chans;

      // 让出事件循环：避免长时间占用主线程造成掉帧。
      // 按块计数让出（而非每块），把等待开销压到最低（见 _kYieldEveryChunks 说明）。
      chunksSinceYield++;
      if (chunksSinceYield >= _kYieldEveryChunks) {
        chunksSinceYield = 0;
        await Future<void>.delayed(_kYieldDuration);
      }
    }

    if (analyzer.blockCount == 0) {
      return null;
    }
    return analyzer.result();
  } catch (_) {
    return null;
  } finally {
    if (buffer != null) malloc.free(buffer);
    if (handle != 0) engine.freeDecodeStream(handle);
  }
}