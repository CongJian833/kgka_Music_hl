// ====【新增/响度归一化·Android 解码分析】====
//
// 职责：调用 Android 原生通道把音频解码成 PCM，并在原生侧完成 K 加权与
// 每 100ms 子帧的"通道加权均方"统计，只把几十 KB 的统计序列回传 Dart；
// 门限积分（gating）复用 Dart 侧 LoudnessAnalyzer，保证与 Windows 路径
// 同一份实现、结果一致。
//
// 为什么把 K 加权放在 Kotlin：
//   整首歌 PCM 若回传 Dart 需要传输上百 MB（5 分钟 44.1k 立体声 ≈ 100MB+），
//   MethodChannel 无法承受；而原生侧做双二阶滤波 + 子帧均方只需一次遍历，
//   回传数据量降到"每 100ms 一个 double"（5 分钟 ≈ 3000 个 double ≈ 24KB）。
//   注意：K 加权系数必须用【解码器输出格式】的采样率生成（HE-AAC/SBR 会输出
//   2 倍采样率），该逻辑与 Dart 侧 kWeightingCoeffs 使用同一套原型参数与公式。
import 'dart:async';

import 'audio_effects_service.dart';
import 'loudness_analyzer.dart';

/// 分析任务 ID 计数器（用于原生侧取消标志的匹配）。
int _jobCounter = 0;

/// 原生解码超时（秒）：超过则该次分析失败。原生侧亦有超时兜底，此处为双保险。
const int _kAndroidAnalyzeTimeoutSeconds = 60;

/// 调 Android 原生解码并测量响度。
///
/// 返回 null 表示失败。调用方不要把 null 当作"响度为 0"。
Future<LoudnessResult?> analyzeWithAndroid({
  required String pathOrUrl,
  required bool isUrl,
  required Duration? duration,
  required bool Function() isCancelled,
  required AudioEffectsService effects,
}) async {
  final jobId = 'loudness_${DateTime.now().microsecondsSinceEpoch}_${_jobCounter++}';

  // 处理时长上限：与原生长度取小由原生侧负责；这里传入上限秒数防异常文件。
  final maxSeconds = duration != null && duration > Duration.zero
      ? (duration.inSeconds * 1.1).ceil()
      : _kAndroidAnalyzeTimeoutSeconds;

  // 取消联动：Dart 无法取消已发起的 invokeMethod，故监听 isCancelled 并调用
  // 第二个通道方法置位原生标志，让解码循环尽快退出。
  Timer? cancelWatcher;
  cancelWatcher = Timer.periodic(const Duration(milliseconds: 300), (_) async {
    if (isCancelled()) {
      cancelWatcher?.cancel();
      await effects.cancelLoudnessAnalysis(jobId);
    }
  });

  try {
    final res = await effects.analyzeLoudness(
      jobId: jobId,
      pathOrUrl: pathOrUrl,
      isUrl: isUrl,
      maxSeconds: maxSeconds,
    );
    if (res == null || !res.ok) {
      return null;
    }
    if (res.sampleRate <= 0 || res.channels <= 0) {
      return null;
    }

    // 用同一份 Dart 实现完成 400ms 重组与门限积分。
    final analyzer = LoudnessAnalyzer(
      sampleRate: res.sampleRate,
      channels: res.channels,
    );
    for (final msq in res.subframeMeanSquares) {
      analyzer.addSubframeMeanSquare(msq);
    }
    analyzer.addPeakDbfs(res.peakDbfs);

    if (analyzer.blockCount == 0) {
      return null;
    }
    return analyzer.result();
  } catch (_) {
    return null;
  } finally {
    cancelWatcher.cancel();
  }
}