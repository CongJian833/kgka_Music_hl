// ====【新增/响度归一化·增益策略】由测量结果推导播放增益（纯函数）====
//
// 职责：把"歌曲实测响度 + 采样峰值 + 用户目标响度"换算成【单一固定增益偏移】。
//   与 loudness_analyzer.dart（测量）和 loudness_normalization.dart（编排/施加）分离，
//   便于纯 Dart 单测覆盖全部边界，不需要任何平台依赖。
//
// 公式（业界通用做法，与 Spotify/YouTube 一致）：
//   gainDb = min( targetLufs − songLufs ,  peakBudgetDbfs − samplePeakDbfs )
//   即：既要把响度拉到目标，又不能让峰值越过 headroom 造成削波，取两者较小值。
//   最后 clamp 到 [−24, +12] 防止异常值导致爆音或几乎无声。
//
// 为什么需要峰值保护：
//   分析只能得到【采样峰值】而非【真峰值(inter-sample)】，且向上增益最容易削波。
//   故 peakBudget 取 −1.5 dBFS（−1 dB 上限 + 0.5 dB 补偿真峰低估）。
//   这是 Spotify 强制留 1dB headroom 的同类做法。
//
// 为何 |gain| < 1dB 时归零：
//   小于 1dB 的调整听感上无意义，归零可避免"每首歌都动一下音量"的无谓变动，
//   也减少切换瞬间的可感知台阶。====
import 'dart:math' as math;

/// 目标响度档位（对应 Spotify 的 Loud / Normal / Quiet）。
enum LoudnessTarget {
  /// 响亮：嘈杂环境（车载、户外）。
  loud('响亮', -11.0, '适合嘈杂环境'),

  /// 标准：默认，与主流流媒体平台一致。
  normal('标准', -14.0, '推荐，与主流音乐平台一致'),

  /// 安静：夜深人静时。
  quiet('安静', -19.0, '适合安静环境');

  const LoudnessTarget(this.label, this.lufs, this.description);

  final String label;

  /// 目标 integrated LUFS。
  final double lufs;

  final String description;

  /// 持久化用值（存字符串比 double 更稳，避免精度/类型问题）。
  String get storageValue => name;

  static LoudnessTarget fromStorage(String? value) {
    for (final t in LoudnessTarget.values) {
      if (t.name == value) return t;
    }
    return LoudnessTarget.normal;
  }
}

/// 增益计算结果（含原因，便于日志排查与 UI 展示）。
class LoudnessGain {
  const LoudnessGain({required this.gainDb, required this.reason});

  /// 要施加的增益（dB）。0 表示不做调整。
  final double gainDb;

  /// 计算依据（诊断用，例如 "peak_limited" / "no_analysis" / "applied"）。
  final String reason;

  bool get isZero => gainDb == 0;
}

/// 增益上下限（防异常值）。
const double kLoudnessMinGainDb = -24.0;
const double kLoudnessMaxGainDb = 12.0;

/// 峰值预算（dBFS）：向上提升到此峰值即止。
/// −1.0 dBFS 上限，另留 0.5 dB 补偿"采样峰值低估真峰"。
const double kLoudnessPeakBudgetDbfs = -1.5;

/// 小于此值（dB）的调整视为无意义，归零。
const double kLoudnessMinAudibleGainDb = 1.0;

/// 采样峰值哨兵值（无信号）。
const double kLoudnessSilentPeakDbfs = -120.0;

/// 计算应施加的增益。
///
/// [songLufs] 为 null 表示无分析结果（分析失败/时长过短/全程静音）→ 增益 0。
LoudnessGain computeLoudnessGain({
  required double targetLufs,
  required double? songLufs,
  required double samplePeakDbfs,
}) {
  if (songLufs == null || !songLufs.isFinite) {
    return const LoudnessGain(gainDb: 0, reason: 'no_analysis');
  }

  // 1) 按响度差算基础增益
  final byLoudness = targetLufs - songLufs;

  // 2) 峰值保护：只约束"向上提升"，衰减路径完全不受影响。
  //
  // ====【修复/峰值保护方向错误】====
  // 原实现为 `if (byPeak < gain) gain = byPeak;`，未区分 gain 正负，导致两种反效果：
  //   a) 需要提升 + 峰值顶格（如纯音乐 peak=0.00dBFS、响度 −15.4）→ byPeak=−1.5，
  //      min(+1.40, −1.5) = −1.5 → 把"本该提升"变成"衰减"，越均衡越轻；
  //   b) 需要轻微衰减 + 峰值超过 0dBFS（peak>0）→ byPeak 可达 −2.5，会把 −1.0dB 的
  //      正常衰减放大到 −2.5dB，造成过度衰减。
  // 正确语义：峰值预算是"最多允许提升到哪里"的上限，只能把正增益压到 0，
  // 既不能把提升变成衰减，也不该参与衰减路径。
  // 实测来源：用户回测数据中「破旧世界」(−13.99/peak 0.00) 与
  //「かたわれ時」(−15.40/peak 0.00) 两首被错误衰减 1.5dB。
  var gain = byLoudness;
  var reason = 'applied';
  if (byLoudness > 0 && samplePeakDbfs > kLoudnessSilentPeakDbfs) {
    final byPeak = kLoudnessPeakBudgetDbfs - samplePeakDbfs;
    if (byPeak < byLoudness) {
      // 提升空间不足：最多只能提升到 byPeak；若已无空间（byPeak<=0）则不提升。
      gain = byPeak > 0 ? byPeak : 0;
      reason = 'peak_limited';
    }
  }

  // 3) 上下限
  if (gain > kLoudnessMaxGainDb) {
    gain = kLoudnessMaxGainDb;
    reason = reason == 'applied' ? 'max_clamped' : '$reason+max_clamped';
  } else if (gain < kLoudnessMinGainDb) {
    gain = kLoudnessMinGainDb;
    reason = reason == 'applied' ? 'min_clamped' : '$reason+min_clamped';
  }

  // 4) 过小的调整归零
  if (gain.abs() < kLoudnessMinAudibleGainDb) {
    return LoudnessGain(gainDb: 0, reason: 'below_audible');
  }

  // 5) 消除 -0.0
  if (gain == 0) gain = 0;

  return LoudnessGain(gainDb: gain, reason: reason);
}

/// 增益（dB）→ 线性音量系数（0..+∞，用于 setVolume / BASS 线性增益）。
double gainDbToLinear(double gainDb) => math.pow(10, gainDb / 20).toDouble();

/// 线性系数 → dB（诊断用）。
double linearToGainDb(double linear) {
  if (linear <= 0) return kLoudnessMinGainDb;
  return 20 * math.log(linear) / math.ln10;
}