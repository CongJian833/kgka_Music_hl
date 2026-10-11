// ====【新增/响度归一化·核心算法】ITU-R BS.1770-4 响度测量（integrated LUFS）====
//
// 用途：为"音量均衡"提供每首歌的【感知响度】基准值。
//   业界标准做法（Spotify / YouTube / Apple Music / foobar2000 ReplayGain 2.0）：
//     离线测量整曲 integrated LUFS → 播放时施加单一固定增益偏移(target − measured)，
//     不做多段压缩、不改变歌曲动态。
//   本类只负责【测量】，增益计算见 loudness_gain_policy.dart，编排见 loudness_normalization.dart。
//
// 算法实现要点（严格按 BS.1770-4）：
//   1) K 加权 = 两级双二阶 IIR：
//        stage1 高架滤波（pre-filter，模拟头部声学，提升高频）
//        stage2 RLB 高通（去掉人耳不敏感的极低频）
//      系数按实际采样率用 RBJ 双二阶公式解析生成（不能只硬编码 48kHz——
//      本项目素材有 44.1k/48k，Android 侧 SBR 输出还可能是 22.05k/24k 等）。
//   2) 分块：100ms 子帧 → 400ms 块、100ms 步进（即 75% 重叠）。每块求"加权后各声道均方"之和。
//   3) 双门限积分（gating）：
//        绝对门限 J1 = { j : l_j > −70 LUFS }          （剔除静音/极轻段）
//        相对门限 Γr = (−0.691 + 10log10(mean_{J1} z_j)) − 10
//        J2 = { j ∈ J1 : l_j > Γr }                     （剔除明显低于平均的段）
//        最终  L = −0.691 + 10log10( mean_{J2} z_j )
//      注意：两级门限都要【对均方 z_j 取平均】，而不是对 l_j（dB 值）取平均——
//      这是最常见的实现错误，会导致结果偏高。
//
// 两端共用的设计（关键）：
//   * Windows 侧 BASS 解出 float32 PCM → 走 addFloatPcm（Dart 内做 K 加权）
//   * Android 侧原生 Kotlin 做 K 加权与 100ms 子帧均方（避免把整首歌 PCM 回传 Dart）
//     → 走 addSubframeMeanSquare（Dart 只做 400ms 重组与门限积分）
//   两条路径都收敛到同一个 [_emitSubframe] / [integratedLufs]，
//   因此"400ms 重组"与"门限积分"这两处最易写错的逻辑【只有一份实现】，两端结果必然一致。
//
// 线程约定：本类为纯计算、无 IO、无平台依赖，可在主 isolate 分块调用
// （调用方负责分块让出事件循环），也可整体放入 Isolate.run。====
import 'dart:math' as math;
import 'dart:typed_data';

/// 一次响度测量的结果。
class LoudnessResult {
  const LoudnessResult({
    required this.lufs,
    required this.peakDbfs,
    required this.sampleRate,
    required this.channels,
    required this.blockCount,
  });

  /// 整曲 integrated LUFS。null = 无有效块（时长不足 400ms 或全程在绝对门限之下）。
  final double? lufs;

  /// 采样峰值（dBFS）。用于峰值保护，避免增益提升后削波。无信号为 -120。
  final double peakDbfs;

  final int sampleRate;
  final int channels;

  /// 参与统计的 400ms 块数量（诊断用）。
  final int blockCount;
}

/// BS.1770-4 的 K 加权 + 双门限 integrated LUFS 测量器（流式分块输入，内存恒定）。
class LoudnessAnalyzer {
  LoudnessAnalyzer({required this.sampleRate, required this.channels})
      : assert(sampleRate > 0),
        assert(channels > 0),
        _coeffs = kWeightingCoeffs(sampleRate.toDouble()),
        _hopFrames = (sampleRate * _hopMs / 1000).round() {
    // 每声道 4 个状态（两级双二阶各 x1,x2,y1,y2）
    _state = List.generate(channels, (_) => Float64List(8));
  }

  /// 400ms 块长（BS.1770 规定）。
  static const int _blockMs = 400;

  /// 100ms 步进（75% 重叠，BS.1770 规定）。
  static const int _hopMs = 100;

  /// 一个 400ms 块由 4 个 100ms 子帧组成（由上面两条规定推导，勿单独硬编码）。
  static const int _subframesPerBlock = _blockMs ~/ _hopMs;

  /// 响度换算常数：−0.691（BS.1770 定义，使 1kHz 满幅正弦约等于 0 LUFS）。
  static const double _offsetLufs = -0.691;

  /// 绝对门限（LUFS）。
  static const double _absoluteGateLufs = -70.0;

  /// 相对门限（LU，即比相对平均低 10 LU 以上的块被剔除）。
  static const double _relativeGateLu = 10.0;

  final int sampleRate;
  final int channels;

  /// [stage1(b0,b1,b2,a1,a2), stage2(b0,b1,b2,a1,a2)]
  final List<Float64List> _coeffs;
  final int _hopFrames;

  /// 各声道的滤波器状态（两级 × (x1,x2,y1,y2)）。
  late final List<Float64List> _state;

  /// 100ms 子帧累加器（K 加权后各声道平方和逐帧累加）。
  double _hopSum = 0;
  int _hopCounter = 0;

  /// 最近 4 个 100ms 子帧的"通道加权均方"环形缓冲，用于 400ms 块重组。
  final Float64List _subRing = Float64List(_subframesPerBlock);
  int _subPos = 0;
  int _subFilled = 0;
  double _subSum = 0;

  /// 每个 400ms 块的 z_j（通道加权均方之和）。
  final List<double> _blockSums = <double>[];

  double _peak = 0;

  /// Windows 路径：送入交错 float32 PCM（值域 [-1,1]）。
  ///
  /// 分块调用即可（例如每次 0.5s），内部维护滤波器状态与滑窗，结果与一次性送入相同。
  void addFloatPcm(Float32List interleaved) {
    final ch = channels;
    final frames = interleaved.length ~/ ch;
    if (frames <= 0) return;

    for (var f = 0; f < frames; f++) {
      final base = f * ch;
      var frameSq = 0.0;
      for (var c = 0; c < ch; c++) {
        final raw = interleaved[base + c];
        // 峰值统计用原始样本（不做加权——峰值保护针对真实信号幅度）
        final abs = raw < 0 ? -raw : raw;
        if (abs > _peak) _peak = abs;
        frameSq += _kWeightSample(c, raw);
      }
      _hopSum += frameSq;
      _hopCounter++;
      if (_hopCounter >= _hopFrames) {
        _emitSubframe(_hopSum / _hopFrames);
        _hopSum = 0;
        _hopCounter = 0;
      }
    }
  }

  /// Android 路径：送入一个 100ms 子帧的【通道加权均方】值。
  ///
  /// 语义：`Σ_i G_i · z_i`，其中 z_i 为该子帧内第 i 声道的均方（mean of squares），
  /// G_i 为 BS.1770 的声道权重（单/双声道均为 1.0）。Kotlin 侧已完成 K 加权与求和，
  /// 此处只做 400ms 重组 + 门限积分，与 Windows 路径共用同一份实现。
  void addSubframeMeanSquare(double meanSquare) {
    _emitSubframe(meanSquare);
  }

  /// 送入采样峰值（dBFS，Android 侧由原生算好；Windows 侧由 addFloatPcm 自动统计）。
  void addPeakDbfs(double peakDbfs) {
    if (peakDbfs <= -120) return;
    final linear = math.pow(10, peakDbfs / 20).toDouble();
    if (linear > _peak) _peak = linear;
  }

  /// 单声道样本过 K 加权两级双二阶，返回加权后样本的平方。
  double _kWeightSample(int channel, double x) {
    final s = _state[channel];
    final c1 = _coeffs[0];
    // stage1
    final y1 = c1[0] * x + c1[1] * s[0] + c1[2] * s[1] - c1[3] * s[2] - c1[4] * s[3];
    s[1] = s[0];
    s[0] = x;
    s[3] = s[2];
    s[2] = y1;
    // stage2
    final c2 = _coeffs[1];
    final y2 = c2[0] * y1 + c2[1] * s[4] + c2[2] * s[5] - c2[3] * s[6] - c2[4] * s[7];
    s[5] = s[4];
    s[4] = y1;
    s[7] = s[6];
    s[6] = y2;
    return y2 * y2;
  }

  /// 送入一个 100ms 子帧的通道加权均方 → 维护 4 子帧滑窗 → 每满 4 个产出 1 个 400ms 块。
  void _emitSubframe(double meanSquare) {
    final old = _subRing[_subPos];
    _subRing[_subPos] = meanSquare;
    _subSum += meanSquare - old;
    _subPos++;
    if (_subPos >= _subframesPerBlock) _subPos = 0;
    if (_subFilled < _subframesPerBlock) _subFilled++;
    if (_subFilled >= _subframesPerBlock) {
      _blockSums.add(_subSum / _subframesPerBlock);
    }
  }

  /// 已有完整 400ms 块的数量。
  int get blockCount => _blockSums.length;

  /// 采样峰值（dBFS）。
  double get samplePeakDbfs =>
      _peak <= 0 ? -120.0 : 20 * (math.log(_peak) / math.ln10);

  /// 计算 integrated LUFS。无有效块返回 null。
  double? integratedLufs() {
    if (_blockSums.isEmpty) return null;
    // 每块响度 l_j
    final l = List<double>.filled(_blockSums.length, 0);
    for (var j = 0; j < _blockSums.length; j++) {
      final z = _blockSums[j];
      l[j] = z <= 0
          ? double.negativeInfinity
          : _offsetLufs + 10 * (math.log(z) / math.ln10);
    }
    // 绝对门限 J1
    final j1 = <int>[];
    var sumJ1 = 0.0;
    for (var j = 0; j < l.length; j++) {
      if (l[j] > _absoluteGateLufs) {
        j1.add(j);
        sumJ1 += _blockSums[j];
      }
    }
    if (j1.isEmpty) return null;
    // 相对门限：对 J1 的均方取平均（不是对 l_j 取平均）
    final meanJ1 = sumJ1 / j1.length;
    if (meanJ1 <= 0) return null;
    final gammaR =
        _offsetLufs + 10 * (math.log(meanJ1) / math.ln10) - _relativeGateLu;
    // J2
    var sumJ2 = 0.0;
    var countJ2 = 0;
    for (final j in j1) {
      if (l[j] > gammaR) {
        sumJ2 += _blockSums[j];
        countJ2++;
      }
    }
    if (countJ2 == 0) return null;
    final meanJ2 = sumJ2 / countJ2;
    if (meanJ2 <= 0) return null;
    return _offsetLufs + 10 * (math.log(meanJ2) / math.ln10);
  }

  /// 汇总结果。
  LoudnessResult result() => LoudnessResult(
        lufs: integratedLufs(),
        peakDbfs: samplePeakDbfs,
        sampleRate: sampleRate,
        channels: channels,
        blockCount: blockCount,
      );

  /// 生成 K 加权两级双二阶系数（返回 [stage1(5), stage2(5)]）。
  ///
  /// stage1（高架 pre-filter）与 stage2（RLB 高通）的原型参数取自 BS.1770-4 公开定义，
  /// 用 RBJ 双二阶公式按实际采样率解析生成；48kHz 时应还原标准公开系数。
  static List<Float64List> kWeightingCoeffs(double fs) {
    // ---- stage1: 高架滤波器（pre-filter）----
    const f0a = 1681.974450955533;
    const gainDb = 3.999843853973347;
    const qa = 0.7071752369554196;
    final ka = math.tan(math.pi * f0a / fs);
    final vh = math.pow(10, gainDb / 20).toDouble();
    final vb = math.pow(vh, 0.4996667741545416).toDouble();
    final a0 = 1 + ka / qa + ka * ka;
    final b0 = (vh + vb * ka / qa + ka * ka) / a0;
    final b1 = 2 * (ka * ka - vh) / a0;
    final b2 = (vh - vb * ka / qa + ka * ka) / a0;
    final a1 = 2 * (ka * ka - 1) / a0;
    final a2 = (1 - ka / qa + ka * ka) / a0;

    // ---- stage2: RLB 高通 ----
    const f0b = 38.13547087602444;
    const qb = 0.5003270373238773;
    final kb = math.tan(math.pi * f0b / fs);
    final denom = 1 + kb / qb + kb * kb;
    const sb0 = 1.0;
    const sb1 = -2.0;
    const sb2 = 1.0;
    final sa1 = 2 * (kb * kb - 1) / denom;
    final sa2 = (1 - kb / qb + kb * kb) / denom;

    return [
      Float64List.fromList([b0, b1, b2, a1, a2]),
      Float64List.fromList([sb0, sb1, sb2, sa1, sa2]),
    ];
  }
}