// ====【新增/歌词调整】歌词调整集中配置服务（大小 / 行距 / 透明度 / 高亮色 / 进度偏移）====
//
// 说明：
//   * 持久化 key 约定（新增 key 在此统一说明）：
//       1. settings.lyric_scale        (double, 已有) —— 歌词字体大小缩放，本次复用；
//       2. settings.lyric_adjustments  (json) —— 全局外观配置：
//            {"lineSpacing": double(行距,默认1.3), "opacity": double(非当前行/底色透明度,0.3~1.0,默认1.0),
//             "highlightColor": int(当前行高亮色ARGB,默认 0xFFFFFFFF),
//             "highlightOpacity": double(当前行/高光透明度,0.3~1.0,默认1.0),
//             "unifiedOpacity": bool(是否统一歌词透明度,默认 true)}
//            ※ 旧数据无 highlightOpacity / unifiedOpacity 时用默认值，向后兼容。
//       3. settings.lyric_offset_map   (json) —— 按歌曲保存的进度偏移(秒,double)：
//            {"<songHash|id>": seconds}，仅用于"当前播放行"判定与滚动的歌词对齐，不改音频/进度条。
//   * 本类为静态单例工具：从 SharedPreferences 读取后缓存在内存，并暴露 ChangeNotifier 通知，
//     让"歌词调整页"与"歌词渲染处（player_page 内 _LyricViewport / _PerfLyricList）"共用同一份
//     最新值、实时生效，且避免渲染热路径重复读取磁盘。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show FontWeight; // ====【需求/字体粗细】映射字重用 ====
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// [歌词调整] 全局歌词外观配置（行距 / 透明度 / 高亮色）。
class LyricAdjustmentConfig {
  /// 行距比例，默认 1.3（对应原版歌词 textStyle height≈1.24 的观感，作为基准换算）。
  final double lineSpacing;

  /// 非当前行歌词透明度缩放（0.3~1.0，默认 1.0）。在"统一歌词透明度"开启时也作为当前行
  /// 高光透明度使用；关闭统一时则仅作用于非当前行（底色）。
  final double opacity;

  // ====【需求/拆分透明度】新增当前行(高光)透明度 + 统一开关 =====
  /// 当前行/高光透明度缩放（0.3~1.0，默认 1.0）。仅在"统一歌词透明度"关闭时生效。
  final double highlightOpacity;

  /// 是否统一歌词透明度（默认 true）。为 true 时当前行高光透明度跟随 [opacity]；
  /// 为 false 时当前行用 [highlightOpacity]，非当前行用 [opacity]。
  final bool unifiedOpacity;

  /// 当前行高亮颜色（ARGB int，默认白色 0xFFFFFFFF）。
  final int highlightColor;

  // ====【需求/颜色统一】新增底色颜色 + 统一歌词颜色开关 =====
  /// 非当前行（底色）颜色（ARGB int，默认白色 0xFFFFFFFF）。
  /// 仅在"统一歌词颜色"([unifiedColor]) 关闭时生效；开启时底色与高亮同色。
  final int baseColor;

  /// 是否统一歌词颜色（默认 true）。为 true 时非当前行（底色）与当前行同为
  /// [highlightColor]；为 false 时非当前行（底色）用 [baseColor]。
  final bool unifiedColor;

  // ====【需求/自适应歌词颜色】新增"自适应歌词颜色"开关 =====
  /// 是否开启"自适应歌词颜色"（默认 false）。开启后：根据当前歌曲封面图自动提取
  /// 主色作为歌词颜色（统一时一种主色、关闭统一时高亮+底色两种），并禁用页面的
  /// 手动歌词颜色设置项。仅持久化开关本身；自动提取结果直接写入 [highlightColor]/
  /// [baseColor]（沿用现有 setGlobal/notifier 通知机制，渲染层无需改动）。
  final bool adaptiveColor;

  // ====【需求/中心区域取色可选项】====
  /// 是否仅从封面中心区域取色（默认 false）。为 false（默认）时按【全图】采样提取主色；
  /// 为 true 时仅对封面中心约 70%（中心 crop=0.15 矩形）区域采样，避免四周边缘
  /// （边框/装饰色）干扰主导色。仅影响"取色来源"，不影响主导色面积优先、对比度矫正、
  /// 失败回退、切歌自动换色、自动重试等其它既有逻辑。
  final bool centerCrop;

  // ====【需求/字体粗细】====
  /// 歌词字体整体粗细（400~900，默认 700）。作用于【所有歌词行】：当前行(高亮)、
  /// 非当前行(底色)、翻译行都按此字重渲染，实现"整体加粗/变细"。
  /// 默认 700（接近原版高亮 w900 / 底色 w700 的中间观感）。
  final int fontWeight;

  const LyricAdjustmentConfig({
    this.lineSpacing = 1.3,
    this.opacity = 1.0,
    this.highlightOpacity = 1.0,
    this.unifiedOpacity = true,
    this.highlightColor = 0xFFFFFFFF,
    this.baseColor = 0xFFFFFFFF,
    this.unifiedColor = true,
    this.adaptiveColor = false,
    this.centerCrop = false,
    this.fontWeight = 700,
  });

  LyricAdjustmentConfig copyWith({
    double? lineSpacing,
    double? opacity,
    double? highlightOpacity,
    bool? unifiedOpacity,
    int? highlightColor,
    int? baseColor,
    bool? unifiedColor,
    bool? adaptiveColor,
    bool? centerCrop,
    int? fontWeight,
  }) {
    return LyricAdjustmentConfig(
      lineSpacing: lineSpacing ?? this.lineSpacing,
      opacity: opacity ?? this.opacity,
      highlightOpacity: highlightOpacity ?? this.highlightOpacity,
      unifiedOpacity: unifiedOpacity ?? this.unifiedOpacity,
      highlightColor: highlightColor ?? this.highlightColor,
      baseColor: baseColor ?? this.baseColor,
      unifiedColor: unifiedColor ?? this.unifiedColor,
      adaptiveColor: adaptiveColor ?? this.adaptiveColor,
      centerCrop: centerCrop ?? this.centerCrop,
      fontWeight: fontWeight ?? this.fontWeight,
    );
  }

  Map<String, dynamic> toJson() => {
    'lineSpacing': lineSpacing,
    'opacity': opacity,
    'highlightOpacity': highlightOpacity,
    'unifiedOpacity': unifiedOpacity,
    'highlightColor': highlightColor,
    'baseColor': baseColor,
    'unifiedColor': unifiedColor,
    'adaptiveColor': adaptiveColor,
    'centerCrop': centerCrop,
    'fontWeight': fontWeight,
  };

  factory LyricAdjustmentConfig.fromJson(Map<String, dynamic> json) {
    return LyricAdjustmentConfig(
      lineSpacing: (json['lineSpacing'] as num?)?.toDouble() ?? 1.3,
      opacity: (json['opacity'] as num?)?.toDouble() ?? 1.0,
      // ====【需求/拆分透明度】旧数据无这些字段时用默认值，向后兼容 =====
      highlightOpacity:
          (json['highlightOpacity'] as num?)?.toDouble() ?? 1.0,
      unifiedOpacity: (json['unifiedOpacity'] as bool?) ?? true,
      highlightColor: (json['highlightColor'] as num?)?.toInt() ?? 0xFFFFFFFF,
      // ====【需求/颜色统一】旧数据无 baseColor / unifiedColor 时用默认值，向后兼容 =====
      baseColor: (json['baseColor'] as num?)?.toInt() ?? 0xFFFFFFFF,
      unifiedColor: (json['unifiedColor'] as bool?) ?? true,
      // ====【需求/自适应歌词颜色】旧 JSON 缺该字段时用默认值 false，向后兼容 =====
      adaptiveColor: (json['adaptiveColor'] as bool?) ?? false,
      // ====【需求/中心区域取色可选项】旧 JSON 缺该字段时用默认值 false（全图），向后兼容 =====
      centerCrop: (json['centerCrop'] as bool?) ?? false,
      // ====【需求/字体粗细】旧 JSON 缺该字段时用默认值 700（整体粗细），向后兼容 =====
      fontWeight: (json['fontWeight'] as num?)?.toInt() ?? 700,
    );
  }

  // ====【需求/字体粗细】====
  /// 歌词整体字重：由持久化 [fontWeight]（400~900）映射到 FontWeight。
  /// FontWeight.values 索引顺序即 w100(i0)…w900(i8)，换算 i = (w~100)-1，clamp 到 0..8 兜底。
  FontWeight lyricFontWeight() {
    final index = ((fontWeight ~/ 100) - 1).clamp(0, 8);
    return FontWeight.values[index];
  }

  /// 供渲染使用的当前行/高光透明度：
  ///   * 统一歌词透明度开启 → 返回 [opacity]（全部歌词一致）；
  ///   * 关闭 → 返回独立的高光透明度 [highlightOpacity]。
  /// ====【需求/拆分透明度】====
  double highlightAlpha() =>
      unifiedOpacity ? opacity : highlightOpacity;

  // ====【需求/颜色统一·当前行随底色透明度】====
  /// 当前行最终 alpha：`opacity × (unifiedOpacity ? 1.0 : highlightOpacity)`，clamp 到 [0.0, 1.0]。
  ///   * 统一歌词透明度 → 与底色同为 [opacity]（随"底色透明度"变淡，保持更早效果）；
  ///   * 关闭统一（单独调高光）→ 仍受 [opacity] 影响，另乘独立高光倍率 [highlightOpacity]。
  /// 供渲染当前行/高光及当前行翻译色使用。
  // ====【修复/当前行高亮透明度】统一→跟随 opacity；关闭统一→独立用 highlightOpacity ====
  // 说明：此前非统一分支写为 opacity×highlightOpacity，会让"高光透明度"仍被"底色透明度"
  // 波及（调底色透明度会连动高亮）。现改为二者彻底独立：
  //   统一(open)   → 当前行高亮透明度 = opacity（与底色一致，保持统一观感）；
  //   关闭统一     → 当前行高亮透明度 = highlightOpacity（只受"高光透明度"控制）。
  // 当前行"底色层"/非当前行始终只受 opacity（底色透明度）控制（见各渲染点）。
  double currentLineAlpha() =>
      (unifiedOpacity ? opacity : highlightOpacity).clamp(0.0, 1.0);

  // ====【需求/颜色统一】====
  /// 非当前行（底色）实际颜色 ARGB int：
  ///   * 统一歌词颜色（[unifiedColor]）→ 与高亮同色 [highlightColor]（保持现状观感）；
  ///   * 关闭统一 → 用独立底色 [baseColor]。
  /// 供渲染"非当前行/底色/翻译非当前行"色使用。
  int baseColorValue() => unifiedColor ? highlightColor : baseColor;
}

/// [歌词调整] 集中配置读写（静态工具类 + 内存缓存 + 变更通知）。
class LyricAdjustments {
  LyricAdjustments._();

  static const _globalKey = 'settings.lyric_adjustments';
  static const _scaleKey = 'settings.lyric_scale';
  static const _offsetMapKey = 'settings.lyric_offset_map';

  // ====【修复/切歌后小卡顿·歌词调整写盘异步化】====
  // 原实现全部经 SharedPreferences 读写：桌面端 `prefs.setString` 同步整写整个 prefs 文件，
  // 切歌后自适应提色完成时 setGlobal 正是"画面稳定后小卡顿"的来源之一。
  // 现改为【独立小文件 + File 异步写】：写入时内存 + notifier 立即生效（渲染即时刷新），
  // 磁盘写走 File.writeAsString（不阻塞主线程）；读取优先独立文件、回退旧 prefs 值并当场迁移。
  static const _globalFileName = 'lyric_adjustments';
  static const _scaleFileName = 'lyric_scale';
  static const _offsetMapFileName = 'lyric_offset_map';

  /// 歌词调整独立小文件（应用支持目录）。
  static Future<File> _fileFor(String name) async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  /// 读取原始文本（独立文件优先；无则回退旧 prefs 并当场迁移写文件）。
  /// [legacyRead]：旧 prefs 的读取器（global/offset 用 getString；scale 用 getDouble）。
  static Future<String?> _readRaw(
    String name,
    String legacyKey,
    String? Function(SharedPreferences prefs) legacyRead,
  ) async {
    try {
      final f = await _fileFor(name);
      if (f.existsSync()) {
        final s = await f.readAsString();
        if (s.isNotEmpty) return s;
      }
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = legacyRead(prefs);
      if (raw != null) {
        try {
          await _writeRaw(name, raw);
          await prefs.remove(legacyKey);
        } catch (_) {}
        return raw;
      }
    } catch (_) {}
    return null;
  }

  /// 写入原始文本（File 异步写，不阻塞主线程）。
  static Future<void> _writeRaw(String name, String data) async {
    try {
      final f = await _fileFor(name);
      await f.writeAsString(data);
    } catch (_) {}
  }

  static const _defaultGlobal = LyricAdjustmentConfig();

  /// 配置变化通知（歌词调整页写入 / 启动加载后触发，渲染处监听以实时刷新）。
  /// 用 ValueNotifier 自增数值作为"变更信号"，避免在静态工具类中调用受保护的 notifyListeners。
  static final ValueNotifier<int> notifier = ValueNotifier<int>(0);

  // ---- 内存缓存（渲染热路径只走缓存，不再读磁盘）----
  static LyricAdjustmentConfig _cachedGlobal = _defaultGlobal;
  static double _cachedScale = 1.0;
  static final Map<String, double> _cachedOffsets = {};
  static bool _loadedGlobal = false;

  /// 重新加载全部配置到内存缓存（首页/进入时调用一次即可）。
  /// ====【修复/切歌后小卡顿】改为读独立小文件（回退旧 prefs 并迁移），不再整读 prefs。====
  static Future<void> reload() async {
    _loadedGlobal = true;
    // 全局配置
    try {
      final raw = await _readRaw(
        _globalFileName,
        _globalKey,
        (prefs) => prefs.getString(_globalKey),
      );
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _cachedGlobal =
              LyricAdjustmentConfig.fromJson(decoded.cast<String, dynamic>());
        }
      } else {
        _cachedGlobal = _defaultGlobal;
      }
    } catch (_) {
      _cachedGlobal = _defaultGlobal;
    }
    // 字体缩放（旧 prefs 存 double，用 getDouble 迁移）
    try {
      final raw = await _readRaw(
        _scaleFileName,
        _scaleKey,
        (prefs) {
          final v = prefs.getDouble(_scaleKey);
          return v == null ? null : '$v';
        },
      );
      _cachedScale = double.tryParse(raw ?? '') ?? 1.0;
    } catch (_) {
      _cachedScale = 1.0;
    }
    // 进度偏移表
    _cachedOffsets.clear();
    try {
      final raw = await _readRaw(
        _offsetMapFileName,
        _offsetMapKey,
        (prefs) => prefs.getString(_offsetMapKey),
      );
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          (decoded).forEach((k, v) {
            _cachedOffsets[k.toString()] =
                (v as num?)?.toDouble() ?? 0.0;
          });
        }
      }
    } catch (_) {
      _cachedOffsets.clear();
    }
    notifier.value++;
  }

  // ---- 同步读取（渲染热路径用）----

  /// 当前全局外观配置（未加载完时返回默认值）。
  static LyricAdjustmentConfig getGlobal() =>
      _loadedGlobal ? _cachedGlobal : _defaultGlobal;

  /// 当前字体缩放（settings.lyric_scale）。
  static double scale() => _cachedScale;

  // ====【需求/拆分透明度】供渲染使用的当前行/高光透明度（统一→opacity，否则 highlightOpacity）====
  /// 直接读取缓存配置的当前行高光透明度，渲染热路径无需先取 config。
  static double highlightAlpha() => getGlobal().highlightAlpha();

  // ====【需求/中心区域取色可选项】便捷 getter（仿 highlightAlpha 用缓存 getGlobal 先例）====
  /// 直接读取缓存配置的"仅中心区域取色"开关，调用方无需先取 config。
  static bool centerCrop() => getGlobal().centerCrop;

  /// 指定歌曲（songKey）的进度偏移（秒），默认 0。
  static double offsetFor(String key) => _cachedOffsets[key] ?? 0.0;

  /// 行距换算系数：把配置的 lineSpacing（默认 1.3）换算为相对"当前观感(=1.3)"的比例。
  /// 原版 textStyle height=1.24/1.3、lineGap、contentPadding 垂直向均按此系数缩放。
  static double lineSpacingFactor() => getGlobal().lineSpacing / 1.3;

  /// 解析"按歌曲进度偏移"的存储键（与 PlayerController 的歌曲标识一致：hash 优先）。
  static String resolveOffsetKey({
    required String hash,
    required String id,
  }) =>
      hash.isNotEmpty ? hash : id;

  // ---- 写入（含持久化 + 通知）----

  static Future<void> setGlobal(LyricAdjustmentConfig cfg) async {
    _cachedGlobal = cfg;
    _loadedGlobal = true;
    // ====【修复/切歌后小卡顿】内存+notifier 立即生效（歌词颜色即时刷新）；
    // 磁盘写独立小文件（File 异步写，不再 SharedPreferences 同步整写 prefs JSON 卡顿）。====
    unawaited(_writeRaw(_globalFileName, jsonEncode(cfg.toJson())));
    notifier.value++;
  }

  /// 写入字体缩放（复用 settings.lyric_scale，让歌词调整页与原有 +/- 按钮共用同一 key）。
  static Future<void> setScale(double v) async {
    _cachedScale = v;
    unawaited(_writeRaw(_scaleFileName, '$v'));
    notifier.value++;
  }

  /// 写入指定歌曲的进度偏移（秒）。
  static Future<void> setOffsetFor(String key, double seconds) async {
    _cachedOffsets[key] = seconds;
    final map = <String, dynamic>{
      for (final e in _cachedOffsets.entries) e.key: e.value,
    };
    unawaited(_writeRaw(_offsetMapFileName, jsonEncode(map)));
    notifier.value++;
  }
}