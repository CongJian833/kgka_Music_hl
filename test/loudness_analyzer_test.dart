// ====【新增/响度归一化·算法自测】BS.1770-4 LUFS 测量的正确性验证 ====
//
// 目的：在写任何平台代码之前，先用【已知信号】锁死算法正确性。
// 这些用例的期望值都由 BS.1770 定义直接推导，不依赖外部工具：
//   * 48kHz 系数必须还原标准公开系数（最强的一致性校验）
//   * 双声道 1kHz 峰值 −20dBFS 正弦 ≈ −20.0 LUFS（K 加权在 1kHz 处约 +0.66dB，
//     与 −0.691 偏移大致抵消）
//   * 单声道同信号比双声道低 3.01 LU（能量除以 2）
//   * 幅度减半（−6.02dB）结果同步减 6.02 LU（线性性）
//   * 相对门限：远低于平均的段落必须被剔除
//   * 绝对门限：全程低于 −70 LUFS 时无有效结果
// 若这些用例通过，再与 ffmpeg ebur128 对拍真实歌曲做最终确认。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/services/loudness_analyzer.dart';

/// 生成指定峰值（dBFS）的 1kHz 正弦，交错双声道/单声道 float32。
///
/// [bothChannels] = false 时只写左声道（右声道保持 0），用于验证声道求和。
Float32List _sine({
  required double peakDbfs,
  required double seconds,
  required int sampleRate,
  required int channels,
  bool bothChannels = true,
  double freq = 1000,
}) {
  final frames = (seconds * sampleRate).round();
  final out = Float32List(frames * channels);
  final amp = math.pow(10, peakDbfs / 20).toDouble();
  for (var f = 0; f < frames; f++) {
    final v = amp * math.sin(2 * math.pi * freq * f / sampleRate);
    if (bothChannels) {
      for (var c = 0; c < channels; c++) {
        out[f * channels + c] = v;
      }
    } else {
      out[f * channels] = v; // 仅第 0 声道
    }
  }
  return out;
}

/// 把 PCM 按 0.5s 分块送入（模拟 Windows 路径的真实调用方式）。
double? _analyzeChunked(
  Float32List pcm, {
  required int sampleRate,
  required int channels,
  int chunkFrames = 22050,
}) {
  final a = LoudnessAnalyzer(sampleRate: sampleRate, channels: channels);
  final totalFrames = pcm.length ~/ channels;
  var start = 0;
  while (start < totalFrames) {
    final end = math.min(start + chunkFrames, totalFrames);
    a.addFloatPcm(
      Float32List.sublistView(pcm, start * channels, end * channels),
    );
    start = end;
  }
  return a.integratedLufs();
}

void main() {
  group('K 加权系数（48kHz 应对齐 BS.1770 公开系数）', () {
    test('stage1/stage2 系数在 1e-6 内命中标准值', () {
      final c = LoudnessAnalyzer.kWeightingCoeffs(48000);
      final s1 = c[0];
      final s2 = c[1];

      expect(s1[0], closeTo(1.53512485958697, 1e-6), reason: 'stage1 b0');
      expect(s1[1], closeTo(-2.69169618940638, 1e-6), reason: 'stage1 b1');
      expect(s1[2], closeTo(1.19839281085285, 1e-6), reason: 'stage1 b2');
      expect(s1[3], closeTo(-1.69065929318241, 1e-6), reason: 'stage1 a1');
      expect(s1[4], closeTo(0.73248077421585, 1e-6), reason: 'stage1 a2');

      expect(s2[0], closeTo(1.0, 1e-6), reason: 'stage2 b0');
      expect(s2[1], closeTo(-2.0, 1e-6), reason: 'stage2 b1');
      expect(s2[2], closeTo(1.0, 1e-6), reason: 'stage2 b2');
      expect(s2[3], closeTo(-1.99004745483398, 1e-6), reason: 'stage2 a1');
      expect(s2[4], closeTo(0.99007225036621, 1e-6), reason: 'stage2 a2');
    });

    test('其它采样率也能生成稳定系数（44.1k 与 48k 不同）', () {
      final c48 = LoudnessAnalyzer.kWeightingCoeffs(48000);
      final c441 = LoudnessAnalyzer.kWeightingCoeffs(44100);
      expect(c441[0][0], isNot(closeTo(c48[0][0], 1e-9)));
    });
  });

  group('响度测量（已知信号）', () {
    test('双声道 1kHz 峰值 −20dBFS 正弦 ≈ −20 LUFS', () {
      final pcm = _sine(
        peakDbfs: -20,
        seconds: 10,
        sampleRate: 48000,
        channels: 2,
      );
      final lufs = _analyzeChunked(pcm, sampleRate: 48000, channels: 2);
      expect(lufs, isNotNull);
      expect(lufs!, closeTo(-20.0, 0.3));
    });

    test('单声道同信号 ≈ −23 LUFS（比双声道低 3.01）', () {
      final pcm = _sine(
        peakDbfs: -20,
        seconds: 10,
        sampleRate: 48000,
        channels: 1,
      );
      final lufs = _analyzeChunked(pcm, sampleRate: 48000, channels: 1);
      expect(lufs, isNotNull);
      expect(lufs!, closeTo(-23.0, 0.3));
    });

    test('仅左声道有信号 ≈ −23 LUFS（声道求和正确）', () {
      final pcm = _sine(
        peakDbfs: -20,
        seconds: 10,
        sampleRate: 48000,
        channels: 2,
        bothChannels: false,
      );
      final lufs = _analyzeChunked(pcm, sampleRate: 48000, channels: 2);
      expect(lufs, isNotNull);
      expect(lufs!, closeTo(-23.0, 0.3));
    });

    test('幅度 −6.02dB → 结果同步下移 6.02 LU（线性性）', () {
      final base = _analyzeChunked(
        _sine(peakDbfs: -20, seconds: 10, sampleRate: 48000, channels: 2),
        sampleRate: 48000,
        channels: 2,
      )!;
      final lower = _analyzeChunked(
        _sine(peakDbfs: -26.02, seconds: 10, sampleRate: 48000, channels: 2),
        sampleRate: 48000,
        channels: 2,
      )!;
      expect(base - lower, closeTo(6.02, 0.15));
    });

    test('44.1kHz 采样率下同样 ≈ −20 LUFS（系数按采样率正确换算）', () {
      final pcm = _sine(
        peakDbfs: -20,
        seconds: 10,
        sampleRate: 44100,
        channels: 2,
      );
      final lufs = _analyzeChunked(pcm, sampleRate: 44100, channels: 2);
      expect(lufs, isNotNull);
      expect(lufs!, closeTo(-20.0, 0.3));
    });
  });

  group('门限（gating）行为', () {
    test('相对门限：远低于平均的段落被剔除', () {
      // 前 10s −20dBFS + 后 10s −50dBFS（相差 30 LU > 10 LU）→ 结果≈前段 −20 LUFS
      final loud = _sine(
        peakDbfs: -20,
        seconds: 10,
        sampleRate: 48000,
        channels: 2,
      );
      final quiet = _sine(
        peakDbfs: -50,
        seconds: 10,
        sampleRate: 48000,
        channels: 2,
      );
      final joined = Float32List(loud.length + quiet.length)
        ..setRange(0, loud.length, loud)
        ..setRange(loud.length, loud.length + quiet.length, quiet);
      final lufs = _analyzeChunked(joined, sampleRate: 48000, channels: 2);
      expect(lufs, isNotNull);
      expect(lufs!, closeTo(-20.0, 0.4));
    });

    test('相对门限边界：仅低 9.5 LU 的段落应被纳入', () {
      // 前 10s −20dBFS + 后 10s −29.5dBFS（差 9.5 LU < 10 LU）→ 两段都计入
      // 期望 = −0.691 + 10log10((z1+z2)/2)，z1 对应 −20、z2 对应 −29.5
      final loud = _sine(
        peakDbfs: -20,
        seconds: 10,
        sampleRate: 48000,
        channels: 2,
      );
      final softer = _sine(
        peakDbfs: -29.5,
        seconds: 10,
        sampleRate: 48000,
        channels: 2,
      );
      final joined = Float32List(loud.length + softer.length)
        ..setRange(0, loud.length, loud)
        ..setRange(loud.length, loud.length + softer.length, softer);
      final lufs = _analyzeChunked(joined, sampleRate: 48000, channels: 2);
      expect(lufs, isNotNull);
      // 均值能量比单段低 10log10((1+10^-0.95)/2) ≈ 2.55 → 约 −22.55（放宽 0.5 容差）
      expect(lufs!, closeTo(-22.55, 0.5));
    });

    test('绝对门限：全程 −80dBFS → 无有效结果且不抛异常', () {
      final pcm = _sine(
        peakDbfs: -80,
        seconds: 5,
        sampleRate: 48000,
        channels: 2,
      );
      expect(_analyzeChunked(pcm, sampleRate: 48000, channels: 2), isNull);
    });

    test('时长不足 400ms → null', () {
      final pcm = _sine(
        peakDbfs: -20,
        seconds: 0.2,
        sampleRate: 48000,
        channels: 2,
      );
      expect(_analyzeChunked(pcm, sampleRate: 48000, channels: 2), isNull);
    });

    test('追加 30s 数字静音几乎不改变结果（门限抗静音）', () {
      final tone = _sine(
        peakDbfs: -20,
        seconds: 10,
        sampleRate: 48000,
        channels: 2,
      );
      final silence = Float32List(30 * 48000 * 2);
      final joined = Float32List(tone.length + silence.length)
        ..setRange(0, tone.length, tone);
      final withSilence =
          _analyzeChunked(joined, sampleRate: 48000, channels: 2)!;
      final without = _analyzeChunked(tone, sampleRate: 48000, channels: 2)!;

      // 说明：音调结束处有 3 个 400ms 块跨越了"有声→静音"边界（各含 1~3 个静音子帧），
      // 其能量天然偏低并被正确计入 J1，故结果会比纯音调低约 0.07 LU。这是 BS.1770 的正确行为。
      // 关键在于：门限把剩余 30s 静音全部剔除。若不做门限，10s 有声 + 30s 静音会把结果
      // 拉到约 −20 − 10log10(40/10) = −26 LUFS。二者相差 6 LU，足以证明门限生效。
      expect(withSilence, closeTo(without, 0.1));
      expect(withSilence, greaterThan(-21.0)); // 远高于未做门限时的 −26
    });
  });

  group('峰值统计', () {
    test('采样峰值与输入峰值一致', () {
      final a = LoudnessAnalyzer(sampleRate: 48000, channels: 2);
      a.addFloatPcm(
        _sine(peakDbfs: -6, seconds: 2, sampleRate: 48000, channels: 2),
      );
      // 正弦峰值即设定值（浮点/离散化误差放宽 0.1dB）
      expect(a.samplePeakDbfs, closeTo(-6.0, 0.1));
    });

    test('无信号时峰值为 −120（哨兵值）', () {
      final a = LoudnessAnalyzer(sampleRate: 48000, channels: 2);
      expect(a.samplePeakDbfs, -120.0);
    });

    test('Android 路径 addPeakDbfs 生效', () {
      final a = LoudnessAnalyzer(sampleRate: 48000, channels: 2);
      a.addPeakDbfs(-3.5);
      expect(a.samplePeakDbfs, closeTo(-3.5, 0.01));
    });
  });

  group('两条输入路径的重组逻辑一致（Windows float32 / Android 子帧均方）', () {
    // 48000Hz 下 100ms = 4800 帧；6s = 60 个子帧。
    // 400ms 块按 100ms 步进产出，数量 = 子帧数 − 3 = 57。
    const expectedBlocks = 57;

    test('addFloatPcm(6s) 产出 57 个 400ms 块', () {
      final a = LoudnessAnalyzer(sampleRate: 48000, channels: 2);
      a.addFloatPcm(
        _sine(peakDbfs: -20, seconds: 6, sampleRate: 48000, channels: 2),
      );
      expect(a.blockCount, expectedBlocks);
    });

    test('addSubframeMeanSquare × 60 产出同样的 57 个块（重组一致）', () {
      final a = LoudnessAnalyzer(sampleRate: 48000, channels: 2);
      for (var i = 0; i < 60; i++) {
        a.addSubframeMeanSquare(0.01);
      }
      expect(a.blockCount, expectedBlocks);
    });

    test('常量子帧均方 → LUFS 精确等于 −0.691 + 10log10(c)', () {
      final a = LoudnessAnalyzer(sampleRate: 48000, channels: 2);
      const c = 0.01;
      for (var i = 0; i < 60; i++) {
        a.addSubframeMeanSquare(c);
      }
      // 所有块值相同 → 门限不改变结果
      final expected = -0.691 + 10 * (math.log(c) / math.ln10);
      expect(a.integratedLufs()!, closeTo(expected, 1e-9));
    });

    test('1s（10 个子帧）产出 7 个块', () {
      final a = LoudnessAnalyzer(sampleRate: 48000, channels: 2);
      for (var i = 0; i < 10; i++) {
        a.addSubframeMeanSquare(0.01);
      }
      expect(a.blockCount, 7);
      expect(a.integratedLufs(), isNotNull);
    });
  });
}