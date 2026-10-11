import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class EqualizerBand {
  const EqualizerBand({required this.centerHz, required this.levelMillibels});

  final int centerHz;
  final int levelMillibels;

  factory EqualizerBand.fromMap(Map<Object?, Object?> map) {
    return EqualizerBand(
      centerHz: (map['centerHz'] as num?)?.round() ?? 0,
      levelMillibels: (map['level'] as num?)?.round() ?? 0,
    );
  }
}

class EqualizerConfig {
  const EqualizerConfig({
    required this.minMillibels,
    required this.maxMillibels,
    required this.bands,
  });

  final int minMillibels;
  final int maxMillibels;
  final List<EqualizerBand> bands;

  factory EqualizerConfig.fallback(List<int> levels) {
    const centers = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
    return EqualizerConfig(
      minMillibels: -1200,
      maxMillibels: 1200,
      bands: [
        for (var index = 0; index < centers.length; index++)
          EqualizerBand(
            centerHz: centers[index],
            levelMillibels: index < levels.length ? levels[index] : 0,
          ),
      ],
    );
  }

  factory EqualizerConfig.fromMap(Map<Object?, Object?> map) {
    final range = (map['range'] as List<Object?>?) ?? const [-1200, 1200];
    final rawBands = (map['bands'] as List<Object?>?) ?? const [];
    return EqualizerConfig(
      minMillibels: range.isNotEmpty
          ? ((range[0] as num?)?.round() ?? -1200)
          : -1200,
      maxMillibels: range.length > 1
          ? ((range[1] as num?)?.round() ?? 1200)
          : 1200,
      bands: rawBands
          .whereType<Map<Object?, Object?>>()
          .map(EqualizerBand.fromMap)
          .toList(growable: false),
    );
  }
}

class AudioEffectsService {
  static const _channel = MethodChannel('kgka_music_hl/audio_effects');

  bool get isAudioEffectsSupported {
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  }

  bool get isBassBoostSupported => isAudioEffectsSupported;

  Future<EqualizerConfig?> equalizerConfig({
    required int? audioSessionId,
  }) async {
    if (!isAudioEffectsSupported) {
      return null;
    }

    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'getEqualizerConfig',
        {'audioSessionId': audioSessionId},
      );
      if (result == null) {
        return null;
      }
      return EqualizerConfig.fromMap(result);
    } on PlatformException catch (error) {
      debugPrint('[KA Music][audio-effects] Equalizer config failed: $error');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<bool> configureEqualizer({
    required int? audioSessionId,
    required bool enabled,
    required List<int> levels,
  }) async {
    if (!isAudioEffectsSupported) {
      return false;
    }

    try {
      final result = await _channel.invokeMethod<bool>('configureEqualizer', {
        'audioSessionId': audioSessionId,
        'enabled': enabled,
        'levels': levels,
      });
      return result ?? false;
    } on PlatformException catch (error) {
      debugPrint('[KA Music][audio-effects] Equalizer failed: $error');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> configureBassBoost({
    required int? audioSessionId,
    required bool enabled,
    required double strength,
  }) async {
    if (!isBassBoostSupported) {
      return false;
    }

    final normalizedStrength = strength.clamp(0.0, 1.0);
    try {
      final result = await _channel.invokeMethod<bool>('configureBassBoost', {
        'audioSessionId': audioSessionId,
        'enabled': enabled,
        'strength': (normalizedStrength * 1000).round(),
      });
      return result ?? false;
    } on PlatformException catch (error) {
      debugPrint('[KA Music][audio-effects] BassBoost failed: $error');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  // ===== 原实现（备份，供回退）：实时动态压缩式"音量均衡" =====
  // 【已废弃·不再调用】原方案用 DynamicsProcessing 做曲内动态压缩，只压平歌曲内部
  // 强弱差，无法让不同歌曲的整体响度趋同，且压缩动态（听感泵动）。
  // 新方案为【响度归一化】：测量每首歌 integrated LUFS 后施加单一固定增益偏移，
  // 见 loudness_analyzer.dart / loudness_gain_policy.dart / loudness_normalization.dart，
  // 增益通道为 configureLoudnessGain（正向 LoudnessEnhancer / 负向播放器音量）。
  // Android 原生实现（configureVolumeNormalization）与通道分支原样保留，便于回退。
  Future<bool> configureVolumeNormalization({
    required int? audioSessionId,
    required bool enabled,
  }) async {
    if (!isAudioEffectsSupported) {
      return false;
    }

    try {
      final result = await _channel.invokeMethod<bool>('configureVolumeNormalization', {
        'audioSessionId': audioSessionId,
        'enabled': enabled,
      });
      return result ?? false;
    } on PlatformException catch (error) {
      debugPrint('[KA Music][audio-effects] VolumeNormalization failed: $error');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  // ====【新增/响度归一化·增益通道】====
  /// 设置响度归一化的输出增益（dB，正向提升；负向衰减走播放器 setVolume）。
  ///
  /// 正向由 Android 原生 `LoudnessEnhancer.setTargetGain(dB*100 毫贝)` 实现；
  /// 该效果为"纯提升"类，对负值不可靠，故调用方必须先按正负分流。
  /// [enabled] = false 时关闭效果（增益归零）。
  Future<bool> configureLoudnessGain({
    required int? audioSessionId,
    required bool enabled,
    required double gainDb,
  }) async {
    if (!isAudioEffectsSupported) {
      return false;
    }

    try {
      final result = await _channel.invokeMethod<bool>('configureLoudnessGain', {
        'audioSessionId': audioSessionId,
        'enabled': enabled,
        'gainDb': gainDb,
      });
      return result ?? false;
    } on PlatformException catch (error) {
      debugPrint('[KA Music][audio-effects] LoudnessGain failed: $error');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  // ====【新增/响度归一化·Android 离线分析通道】====
  /// 原生响度分析结果（只回传"每 100ms 子帧的通道加权均方 + 峰值"，
  /// 门限积分统一在 Dart 侧完成，保证与 Windows 路径同一份实现）。
  Future<AndroidLoudnessAnalysis?> analyzeLoudness({
    required String jobId,
    required String pathOrUrl,
    required bool isUrl,
    required int maxSeconds,
  }) async {
    if (!isAudioEffectsSupported) return null;
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'analyzeLoudness',
        {
          'jobId': jobId,
          'path': pathOrUrl,
          'isUrl': isUrl,
          'maxSeconds': maxSeconds,
        },
      );
      if (result == null) return null;
      return AndroidLoudnessAnalysis.fromMap(result);
    } on PlatformException catch (error) {
      debugPrint('[KA Music][audio-effects] analyzeLoudness failed: $error');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 请求取消某个分析任务（原生解码循环每次迭代检查该标志）。
  ///
  /// 说明：Dart 无法取消已发起的 invokeMethod，故用第二个通道方法置位原生侧的
  /// 取消标志，让解码循环尽快退出并释放 MediaCodec/MediaExtractor 资源。
  Future<void> cancelLoudnessAnalysis(String jobId) async {
    if (!isAudioEffectsSupported) return;
    try {
      await _channel.invokeMethod<void>('cancelLoudnessAnalysis', {
        'jobId': jobId,
      });
    } catch (_) {
      // 静默：取消失败不影响功能（原生侧仍有超时兜底）。
    }
  }
}

/// Android 原生响度分析结果。
class AndroidLoudnessAnalysis {
  const AndroidLoudnessAnalysis({
    required this.ok,
    required this.subframeMeanSquares,
    required this.peakDbfs,
    required this.sampleRate,
    required this.channels,
    this.error,
  });

  final bool ok;

  /// 每 100ms 子帧的"通道加权均方"序列（ΣᵢGᵢzᵢ）。
  final List<double> subframeMeanSquares;

  /// 采样峰值（dBFS）。
  final double peakDbfs;

  final int sampleRate;
  final int channels;
  final String? error;

  static AndroidLoudnessAnalysis fromMap(Map<Object?, Object?> map) {
    final raw = map['blockMsq'];
    final list = <double>[];
    if (raw is List) {
      for (final v in raw) {
        if (v is num) list.add(v.toDouble());
      }
    }
    return AndroidLoudnessAnalysis(
      ok: map['ok'] == true,
      subframeMeanSquares: list,
      peakDbfs: (map['peak'] as num?)?.toDouble() ?? -120.0,
      sampleRate: (map['sampleRate'] as num?)?.toInt() ?? 0,
      channels: (map['channels'] as num?)?.toInt() ?? 0,
      error: map['error'] as String?,
    );
  }
}
