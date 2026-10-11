// ====【新增/响度归一化·策略自测】增益计算的边界行为 ====
//
// 覆盖：响度差计算、峰值保护、上下限 clamp、小增益归零、无分析结果降级，
// 以及 dB↔线性换算的正确性。
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/services/loudness_gain_policy.dart';

void main() {
  group('响度差（无峰值约束时）', () {
    test('偏轻的歌曲被提升到目标', () {
      final g = computeLoudnessGain(
        targetLufs: -14,
        songLufs: -20,
        samplePeakDbfs: -10, // 峰值有余量，不构成约束
      );
      expect(g.gainDb, closeTo(6.0, 1e-9));
      expect(g.reason, 'applied');
    });

    test('偏响的歌曲被衰减到目标', () {
      final g = computeLoudnessGain(
        targetLufs: -14,
        songLufs: -9,
        samplePeakDbfs: -0.1,
      );
      expect(g.gainDb, closeTo(-5.0, 1e-9));
    });

    test('刚好等于目标 → 归零（低于可闻阈值）', () {
      final g = computeLoudnessGain(
        targetLufs: -14,
        songLufs: -14,
        samplePeakDbfs: -10,
      );
      expect(g.gainDb, 0);
      expect(g.reason, 'below_audible');
    });

    test('相差小于 1dB → 归零', () {
      final g = computeLoudnessGain(
        targetLufs: -14,
        songLufs: -14.8,
        samplePeakDbfs: -10,
      );
      expect(g.gainDb, 0);
      expect(g.reason, 'below_audible');
    });

    test('刚好达到 1dB 阈值 → 不归零', () {
      final g = computeLoudnessGain(
        targetLufs: -14,
        songLufs: -15,
        samplePeakDbfs: -10,
      );
      expect(g.gainDb, closeTo(1.0, 1e-9));
    });
  });

  group('峰值保护', () {
    test('响度差与峰值限制取较小值', () {
      // 响度差需要 +6dB，但峰值 -5.0dBFS 只允许 +3.5dB → 取 3.5
      final g = computeLoudnessGain(
        targetLufs: -14,
        songLufs: -20,
        samplePeakDbfs: -5.0,
      );
      expect(g.gainDb, closeTo(3.5, 1e-9));
      expect(g.reason, 'peak_limited');
    });

    test('峰值限制结果低于可闻阈值时归零', () {
      // 响度差需要 +6dB，但峰值 -1.6dBFS 只允许 +0.1dB → 低于 1dB 阈值，归零
      final g = computeLoudnessGain(
        targetLufs: -14,
        songLufs: -20,
        samplePeakDbfs: -1.6,
      );
      expect(g.gainDb, 0);
      expect(g.reason, 'below_audible');
    });

    test('峰值顶到预算时被限制（不削波）', () {
      // 峰值 -1.5dBFS 正好等于预算 → 不允许任何提升
      final g = computeLoudnessGain(
        targetLufs: -14,
        songLufs: -24,
        samplePeakDbfs: -1.5,
      );
      expect(g.gainDb, 0);
    });

    test('衰减不受峰值保护影响', () {
      final g = computeLoudnessGain(
        targetLufs: -19,
        songLufs: -9,
        samplePeakDbfs: -0.05, // 峰值很高，但衰减是安全的
      );
      expect(g.gainDb, closeTo(-10.0, 1e-9));
      expect(g.reason, 'applied');
    });

    test('峰值预算被触发时 reason 标注 peak_limited', () {
      final g = computeLoudnessGain(
        targetLufs: -11,
        songLufs: -20,
        samplePeakDbfs: -3.0, // 只允许 +1.5dB
      );
      expect(g.gainDb, closeTo(1.5, 1e-9));
      expect(g.reason, 'peak_limited');
    });

    // ====【回归/峰值保护方向错误】==== 以下三例对应实测踩到的反向效果，
    // 修复前会分别给出 −1.5dB（把提升变衰减）与 −2.5dB（过度衰减）。
    test('回到实测案例1：响度偏轻且峰值顶格 → 不提升也不衰减（0dB）', () {
      // 实测歌曲「かたわれ時」：LUFS=−15.40、peak=0.00（纯音乐，动态大但已顶格）
      final g = computeLoudnessGain(
        targetLufs: -14,
        songLufs: -15.40,
        samplePeakDbfs: 0.00,
      );
      // 需要 +1.40dB，但峰值已无提升空间 → 应为 0（既不是 +1.4，也绝不能是 −1.5）
      expect(g.gainDb, 0, reason: '不得把"需要提升"变成"衰减"');
    });

    test('回到实测案例2：响度已达标且峰值顶格 → 不被无谓衰减', () {
      // 实测歌曲「破旧世界」：LUFS=−13.99、peak=0.00（几乎正好在目标上）
      final g = computeLoudnessGain(
        targetLufs: -14,
        songLufs: -13.99,
        samplePeakDbfs: 0.00,
      );
      expect(g.gainDb, 0, reason: '响度已达标，不应被峰值预算压成 −1.5dB');
    });

    test('峰值超过 0dBFS 时，正常衰减不被放大', () {
      // 需衰减 −2.0dB，但峰值 +1.0 → 旧实现 byPeak=−2.5 会把衰减放大到 −2.5dB
      final g = computeLoudnessGain(
        targetLufs: -14,
        songLufs: -12.0,
        samplePeakDbfs: 1.0,
      );
      expect(g.gainDb, closeTo(-2.0, 1e-9), reason: '衰减路径不应受峰值保护影响');
    });

    test('提升空间充足时仍正常提升（修复未削弱原能力）', () {
      final g = computeLoudnessGain(
        targetLufs: -14,
        songLufs: -20,
        samplePeakDbfs: -25,
      );
      expect(g.gainDb, closeTo(6.0, 1e-9));
      expect(g.reason, 'applied');
    });
  });

  group('上下限 clamp', () {
    test('超大幅提升被限到 +12dB', () {
      final g = computeLoudnessGain(
        targetLufs: -11,
        songLufs: -40,
        samplePeakDbfs: -30,
      );
      expect(g.gainDb, kLoudnessMaxGainDb);
      expect(g.reason, contains('max_clamped'));
    });

    test('超大幅衰减被限到 −24dB', () {
      final g = computeLoudnessGain(
        targetLufs: -19,
        songLufs: 10,
        samplePeakDbfs: 0,
      );
      expect(g.gainDb, kLoudnessMinGainDb);
      expect(g.reason, contains('min_clamped'));
    });
  });

  group('无分析结果降级', () {
    test('songLufs 为 null → 增益 0 且标注原因', () {
      final g = computeLoudnessGain(
        targetLufs: -14,
        songLufs: null,
        samplePeakDbfs: -10,
      );
      expect(g.gainDb, 0);
      expect(g.reason, 'no_analysis');
    });

    test('songLufs 非有限值 → 增益 0', () {
      for (final bad in [double.nan, double.infinity, double.negativeInfinity]) {
        final g = computeLoudnessGain(
          targetLufs: -14,
          songLufs: bad,
          samplePeakDbfs: -10,
        );
        expect(g.gainDb, 0, reason: 'songLufs=$bad');
        expect(g.reason, 'no_analysis');
      }
    });

    test('峰值为静音哨兵值时不施加峰值约束', () {
      final g = computeLoudnessGain(
        targetLufs: -14,
        songLufs: -20,
        samplePeakDbfs: kLoudnessSilentPeakDbfs,
      );
      expect(g.gainDb, closeTo(6.0, 1e-9));
    });
  });

  group('三档目标响度', () {
    test('档位 LUFS 值符合业界参考（−11 / −14 / −19）', () {
      expect(LoudnessTarget.loud.lufs, -11.0);
      expect(LoudnessTarget.normal.lufs, -14.0);
      expect(LoudnessTarget.quiet.lufs, -19.0);
    });

    test('同一首歌在不同档位得到不同增益（差距等于档位差）', () {
      // 峰值设得很低（-30dBFS），使峰值预算不介入，从而隔离出纯档位差异。
      // 注意：真实素材若峰值很高，高响度档位会被峰值预算限制（这是必要的削波保护），
      // 此时档位间差异会小于理论值。
      const song = -20.0;
      final loud = computeLoudnessGain(
        targetLufs: LoudnessTarget.loud.lufs,
        songLufs: song,
        samplePeakDbfs: -30,
      );
      final normal = computeLoudnessGain(
        targetLufs: LoudnessTarget.normal.lufs,
        songLufs: song,
        samplePeakDbfs: -30,
      );
      final quiet = computeLoudnessGain(
        targetLufs: LoudnessTarget.quiet.lufs,
        songLufs: song,
        samplePeakDbfs: -30,
      );
      expect(loud.gainDb - normal.gainDb, closeTo(3.0, 1e-9));
      expect(normal.gainDb - quiet.gainDb, closeTo(5.0, 1e-9));
    });

    test('高峰值素材下响度档位差异被峰值预算吸收（保护优先）', () {
      const song = -20.0;
      const peak = -10.0; // 只允许 +8.5dB
      final loud = computeLoudnessGain(
        targetLufs: LoudnessTarget.loud.lufs,
        songLufs: song,
        samplePeakDbfs: peak,
      );
      final normal = computeLoudnessGain(
        targetLufs: LoudnessTarget.normal.lufs,
        songLufs: song,
        samplePeakDbfs: peak,
      );
      // loud 理论需 +9dB，被峰值限制到 +8.5dB；normal 需 +6dB 不受限
      expect(loud.gainDb, closeTo(8.5, 1e-9));
      expect(loud.reason, 'peak_limited');
      expect(normal.gainDb, closeTo(6.0, 1e-9));
      expect(normal.reason, 'applied');
    });

    test('持久化往返正确，非法值回退到 standard', () {
      for (final t in LoudnessTarget.values) {
        expect(LoudnessTarget.fromStorage(t.storageValue), t);
      }
      expect(LoudnessTarget.fromStorage(null), LoudnessTarget.normal);
      expect(LoudnessTarget.fromStorage('bogus'), LoudnessTarget.normal);
    });
  });

  group('dB ↔ 线性换算', () {
    test('0dB → 1.0，−6.02dB → 0.5，+6.02dB → 2.0', () {
      expect(gainDbToLinear(0), closeTo(1.0, 1e-9));
      expect(gainDbToLinear(-6.0206), closeTo(0.5, 1e-4));
      expect(gainDbToLinear(6.0206), closeTo(2.0, 1e-4));
    });

    test('往返换算一致', () {
      for (final db in [-24.0, -10.5, -1.0, 0.0, 3.3, 12.0]) {
        expect(linearToGainDb(gainDbToLinear(db)), closeTo(db, 1e-9));
      }
    });

    test('非正线性值返回下限', () {
      expect(linearToGainDb(0), kLoudnessMinGainDb);
      expect(linearToGainDb(-1), kLoudnessMinGainDb);
    });
  });
}