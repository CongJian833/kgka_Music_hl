// ====【需求/自适应歌词颜色】封面主色提取工具 =====
//
// 说明：
//   * 输入：封面 URL 字符串（可为空）。
//   * 输出：`ExtractedColors`（高亮色 + 配套底色色）或 null。
//   * 下载封面字节（HttpClient 带超时）→ `dart:ui` 解码 → 按 ~64x64 网格采样（控制成本）→
//     主色提取：去掉过黑/过白/过低饱和像素后做量化直方图，取"频率高 + 亮度较高 + 饱和较好"
//     的主色作为高亮色；底色色用高亮色做"降饱和 + 适度压暗"的成套版本（同色相、非纯黑）。
//   * URL 为空 / 下载失败 / 解码失败 / 无有效样本 → 返回 null（调用方回退默认色）。
//   * 不依赖第三方库；仅在"切歌 / 封面变化 / 用户手动触发"时调用，避免每次 build 高频跑。
// ====【需求/提色诊断·明亮主色】====
// 本次改动新增两件事：
//   1) 取色过程诊断日志：追加写入 %TEMP%\ka_cover_color.log（仅诊断用，全部 try-catch 静默，
//      绝不因日志问题影响功能/崩溃）。会记录：封面 URL、下载(成功/失败)、解码尺寸、
//      样本量、平均亮度判定是否明亮、最终 high/base 结果或"回退默认"。
//   2) 让"明亮暖色主色"真正胜出（防灰）：解码后先算整张封面平均亮度，若封面偏明亮(>160)，
//      则在主色打分时大幅提高亮度权重，并额外优先"亮度>200、饱和 0.18~0.7、暖色相(R>B)"的桶，
//      使暖白/浅米/肤色这类封面主体色压制中性灰/暗部而胜出；若封面本身偏暗则不硬拉。
// ====【需求/对比度导向取色】====
// 自适应歌词颜色的取色矫正由"单纯抬亮"改为"对比度导向"：歌词被盖在"封面模糊后的全屏背景"上，
// 因此应与【背景亮暗】成反向对比 —— 背景暗→取亮档、背景亮→取深档（详见 _readabilityCorrectHighlight）。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// 提色结果：高亮色 + 配套底色色。
class ExtractedColors {
  const ExtractedColors({required this.highlight, required this.base});

  /// 高亮色（供当前行 / 统一歌词颜色使用）。
  final Color highlight;

  /// 配套底色色（供非当前行 / 底色使用，为其高亮色"降饱和 + 压暗"的成套版本）。
  final Color base;
}

/// 封面主色提取工具（静态方法，无状态；调用方负责按需触发）。
class CoverColorExtractor {
  CoverColorExtractor._();

  /// 下载超时。
  static const _timeout = Duration(seconds: 8);

  /// 提色采样网格上限（边长）；控制成本：最多采样 ~64x64 = 4096 个像素。
  static const _sampleMax = 64;

  /// 量化位数：每通道取高 [bits] 位建桶（5 位 → 32x32x32 个桶，足够区分主色又抗噪）。
  static const _quantBits = 5;

  static const _quantShift = 8 - _quantBits;

  // ====【需求/提色诊断·明亮主色】诊断日志工具 ====
  /// 写入一句诊断日志到 %TEMP%\ka_cover_color.log；全部 try-catch 静默，绝不因日志影响功能。
  static void _log(String msg) {
    try {
      final tmp = Platform.environment['TEMP'];
      if (tmp == null || tmp.isEmpty) return;
      final f = File('$tmp\\ka_cover_color.log');
      f.writeAsStringSync('[${DateTime.now().toIso8601String()}] $msg\n',
          mode: FileMode.append);
    } catch (_) {
      // 静默：日志失败不影响提色。
    }
  }

  /// 供 compute 后台 isolate 调用的封面字节下载（静态方法可作 compute 回调）。
  /// ====【修复/切歌自动提色·isolate 解码不可用】====
  // compute 后台 isolate 中 ui.instantiateImageCodec 无法解码封面（Windows/各平台一致），
  // 此前全局切歌自动提色日志全为"下载成功→解码失败或无有效样本"，功能静默失效、歌词停在旧色。
  // 方案：网络下载封面字节放后台 isolate（dart:io 可用、不阻塞主线程）；解码+采样+量化回主
  // isolate（[extractFromBytes]，400x400 解码+4096 像素采样仅数毫秒）。
  /// [coverUrl] 可为空/空字符串（视为缺失，返回 null）；仅网络下载，不做任何 dart:ui 解码。
  static Future<Uint8List?> downloadCoverBytesForExtract(String? coverUrl) {
    if (coverUrl == null || coverUrl.isEmpty) {
      return Future.value(null);
    }
    return _downloadBytes(coverUrl);
  }

  /// 提取封面主色。失败/无有效样本返回 null。
  ///
  /// [coverUrl] 可为空（空字符串视为缺失）。
  /// ====【需求/中心区域取色可选项】====
  /// [centerOnly]：为 true 时仅对封面中心约 70%（中心 crop=0.15 矩形）区域采样，
  /// 避免四周边缘色干扰主导色；为 false（默认）时按【全图】采样，行为与旧版一致。
  static Future<ExtractedColors?> extract(String? coverUrl,
      {bool centerOnly = false}) async {
    // 旧签名备份：static Future<ExtractedColors?> extract(String? coverUrl) async {
    // ====【需求/提色诊断·明亮主色】触发日志：封面 URL 是否为空 ====
    _log('触发提取 coverUrl=${coverUrl == null ? 'null' : (coverUrl.isEmpty ? '(空)' : coverUrl)}'
        ' centerOnly=$centerOnly');
    if (coverUrl == null || coverUrl.isEmpty) {
      _log('回退默认：封面 URL 为空');
      return null;
    }
    if (coverUrl.startsWith('content://')) {
      // 本地封面（content URI）无法用 HTTP 下载，暂视为缺失 → 回退默认。
      _log('回退默认：本地 content:// 封面无法 HTTP 下载');
      return null;
    }

    final bytes = await _downloadBytes(coverUrl);
    if (bytes == null || bytes.isEmpty) {
      _log('回退默认：下载失败或空字节');
      return null;
    }
    _log('下载成功：${bytes.length} 字节');
    return _extractFromBytes(bytes, centerOnly: centerOnly);
  }

  /// 从已下载的封面字节提取主色（解码+采样+量化）。
  /// ====【修复/切歌自动提色·isolate 解码不可用】====
  // 页面路径（主 isolate）直接走 [extract]；全局切歌自动提色（AdaptiveLyricColor）
  // 改为 compute 后台 isolate 只下载字节、解码采样回主 isolate 后走本方法。
  /// [bytes] 封面图像字节；[centerOnly] 同 [extract]。
  static Future<ExtractedColors?> extractFromBytes(Uint8List bytes,
          {bool centerOnly = false}) =>
      _extractFromBytes(bytes, centerOnly: centerOnly);

  /// 解码+采样+量化提色核心（[extract] / [extractFromBytes] 共用）。
  static Future<ExtractedColors?> _extractFromBytes(Uint8List bytes,
      {bool centerOnly = false}) async {
    final samples = await _samplePixels(bytes, centerOnly: centerOnly);
    if (samples == null || samples.isEmpty) {
      _log('回退默认：解码失败或无有效样本');
      return null;
    }
    _log('解码成功：样本量=${samples.length}');

    // ====【需求/提色诊断·明亮主色】计算封面平均亮度（仅日志参考；不再作为取色开关）====
    var sumLum = 0.0;
    for (final p in samples) {
      sumLum += 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2];
    }
    final avgLum = sumLum / samples.length;
    _log('封面平均亮度=${avgLum.toStringAsFixed(1)}');
    // ====【需求/主色强偏亮】==== 已移除"平均亮度>160 才高亮权重"的 isBright 闸门：
    // 即便封面整体偏暗，也会从相对较亮、带色彩、偏暖的样本取主色，不再回落高频暗色。
    final colors = _extractFromSamples(samples, avgLum);
    // ====【需求/提色诊断·明亮主色】最终结果日志 ====
    final finalHigh = colors.highlight;
    final finalBase = colors.base;
    _log('最终: high=(r:${(finalHigh.r * 255).round()},'
        'g:${(finalHigh.g * 255).round()},'
        'b:${(finalHigh.b * 255).round()}) '
        'base=(r:${(finalBase.r * 255).round()},'
        'g:${(finalBase.g * 255).round()},'
        'b:${(finalBase.b * 255).round()})');
    return colors;
  }

  /// 下载封面字节（带超时，失败返回 null）。
  static Future<Uint8List?> _downloadBytes(String url) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = _timeout;
      final req = await client.getUrl(Uri.parse(url)).timeout(_timeout);
      final res = await req.close().timeout(_timeout);
      if (res.statusCode != 200) {
        return null;
      }
      final builder = BytesBuilder(copy: false);
      await res.timeout(_timeout).forEach(builder.add);
      return builder.takeBytes();
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  /// 解码封面并按 ~[64x64] 网格采样像素。返回样本列表 `(r,g,b)`。解码失败/全透明返回 null。
  // ====【需求/中心区域取色可选项】====
  // 新增 [centerOnly]：为 true → 仅对封面中心 crop=0.15 矩形（约中心 70%）采样；
  // 为 false（默认）→ 按全图采样（旧版行为）。两分支均保留"空样本退化为全图采样"兜底，
  // 保证透明/过小平区封面仍能取色。
  static Future<List<List<int>>?> _samplePixels(Uint8List bytes,
      {bool centerOnly = false}) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final w = image.width;
      final h = image.height;
      if (w <= 0 || h <= 0) return null;
      // ====【需求/提色诊断·明亮主色】记录解码尺寸 ====
      _log('解码成功：尺寸=${w}x$h');
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      // ====【性能】解码后立即释放图像资源，避免内存驻留 ====
      image.dispose();

      if (data == null) return null;

      final minLen = math.min(w, h);
      final step = math.max(1, (minLen / _sampleMax).ceil());
      final samples = <List<int>>[];
      final rows = data.lengthInBytes ~/ (w * 4);
      final rowCount = rows > 0 ? rows : h;

      final int xFrom;
      final int xTo;
      final int yFrom;
      final int yTo;
      if (centerOnly) {
        // 【中心区域采样·贴合实际背景】歌词盖住的"背景"并不总是整张封面，而可能是封面
        // 【中心区域】被放大+高斯模糊+压暗后的画面（如封面四周黄边，背景只取了中间部分）。
        // 取中心 [crop, 1-crop] 矩形（约中心 70% 面积），四周边缘色不再主导取色。
        const double crop = 0.15;
        xFrom = (w * crop).floor();
        xTo = (w * (1 - crop)).round();
        yFrom = (rowCount * crop).floor();
        yTo = (rowCount * (1 - crop)).round();
      } else {
        // 【全图采样】默认：对整张封面均匀采样（旧版默认行为）。
        xFrom = 0;
        xTo = w;
        yFrom = 0;
        yTo = rowCount;
      }
      for (var y = yFrom; y < yTo; y += step) {
        for (var x = xFrom; x < xTo; x += step) {
          final offset = (y * w + x) * 4;
          if (offset + 3 >= data.lengthInBytes) continue;
          final a = data.getUint8(offset + 3);
          if (a < 128) continue; // 跳过透明像素
          final r = data.getUint8(offset);
          final g = data.getUint8(offset + 1);
          final b = data.getUint8(offset + 2);
          samples.add([r, g, b]);
        }
      }
      // 若采样区域（中心或整体）因透明/太小无样本，退化为全图采样兜底。
      if (samples.isEmpty) {
        for (var y = 0; y < rowCount; y += step) {
          for (var x = 0; x < w; x += step) {
            final offset = (y * w + x) * 4;
            if (offset + 3 >= data.lengthInBytes) continue;
            final a = data.getUint8(offset + 3);
            if (a < 128) continue;
            samples.add([
              data.getUint8(offset),
              data.getUint8(offset + 1),
              data.getUint8(offset + 2),
            ]);
          }
        }
      }
      return samples.isEmpty ? null : samples;
    } catch (_) {
      return null;
    }
  }

  /// 从采样像素中提取高亮色 + 配套底色色。
  // ====【需求/主色强偏亮】====
  // 本轮改动：
  //   1) 移除"平均亮度 >160 才给亮度权重"的 [isBright] 闸门：即使封面整体偏暗(如平均亮度 143)，
  //      也坚持从"相对较亮、带色彩、偏暖"的样本取主色，避免落到高频暗部(如 (50,44,42) 暗灰褐)。
  //   2) 先筛出一个"高亮候选池"(较亮且非死白、饱和适中、偏暖 R>B)；候选太少则逐级降亮度门槛，
  //      保证总能凑出"封面中最亮、不近死白"的一批像素作为主色来源。
  //   3) 量化打分按"频数 + 高亮度权重 + 饱和度 + 暖色相奖励"取主色，结果显著更亮更暖、有色彩感。
  //   4) 底色沿用"同色相、降饱和少、中等偏亮"版本。
  static ExtractedColors _extractFromSamples(List<List<int>> samples, double avgLum) {
    // ====【需求/主导色面积优先】====
    // 主导主色改为"覆盖面积最大"为导向：
    //   * 直接对【全部采样】(而非旧的"高亮暖色子池")做量化桶，取"覆盖面积(像素频数)最大"的簇代表色，
    //     避免"面积小但亮/暖的次要色块(如晚霞粉)在与面积大的主导色块(如大片蓝)竞争时胜出"而带偏整体色系。
    //   * 分工：主导色只负责"是哪种色系"(色相)；亮/深档继续交给 `_finalizeForReadability` 的对比度矫正。
    final highlight = _dominantByArea(samples);
    if (highlight != null) {
      return _finalizeForReadability(highlight, avgLum);
    }
    // [备份] 旧"构造高亮候选池(brightPool)→量化强偏亮/暖打分取主色"逻辑已整体移除，见函数备份注释块。

    // 3) 退化兜底：从全部样本里挑"高亮度 + 较饱和 + 偏暖"的代表色，绝不取到暗灰褐/死白。
    Color? best;
    double bestScore = -1;
    for (final p in samples) {
      final r = p[0], g = p[1], b = p[2];
      final mx = math.max(r, math.max(g, b));
      final mn = math.min(r, math.min(g, b));
      final luminance = 0.299 * r + 0.587 * g + 0.114 * b;
      final saturation = mx == 0 ? 0.0 : (mx - mn) / mx;
      if (luminance >= 250) continue; // 兜底也排除近死白
      // ----【原兜底(含 isBright 加强)备份】----
      // final score = 0.85 * (luminance / 255) + 0.15 * saturation;
      // if (isBright && luminance > 200 && r > b && saturation >= 0.18) score += 0.5;
      // ====【需求/主色强偏亮】==== 兜底同样强偏亮 + 带饱和 + 暖色相加分
      var score = 0.75 * (luminance / 255) + 0.25 * saturation;
      if (r > b && saturation >= 0.12) score += 0.5;
      if (score > bestScore) {
        bestScore = score;
        best = Color.fromARGB(255, r, g, b);
      }
    }
    final h = best ?? const Color(0xFFFFFFFF);
    return _finalizeForReadability(h, avgLum);
  }

  // #################### 【需求/主导色面积优先】 ####################
  // ————— 新主导主色选择：`_dominantByArea`（按覆盖面积最大选取） —————
  //   旧逻辑 `_collectBrightPool` + `_dominantHighlight` 有两个根因被本次替换：
  //   1) 旧逻辑先从全样本筛"较亮+带色+偏暖(R>B)"的 `brightPool` 子池，再丢给打分函数；
  //      这一步会【把大面积冷色主导块(如大片蓝，R≤B)挡在池外】，同时把小而暖的晚霞粉筛进来。
  //   2) 旧打分“对数频数×1.6 + 高亮度权重×6.0 + 饱和×1.2 + 暖色奖励+1.5 + 既亮又好看+1.2”，
  //      亮度/暖色加成权重远大于面积 → 面积小但亮/暖的小块(晚霞粉)能与大面积的普通主导色(大片蓝)
  //      竞争并胜出，导致主导色调被带偏为晚霞粉，与“蓝调封面”整体不协调。
  //   新逻辑：直接对【全部采样】做量化桶，评分以【覆盖面积(像素频数)占比】为主导(权重大)，
  //      亮度/饱和/暖色仅作“面积相近时”的次要微调(权重小得多) → 占面积大的颜色必胜出。
  //   分工：主导色只决定“是哪种色系”(色相)；亮/深档由 _finalizeForReadability 的对比度矫正负责，互不覆盖。
  /// 主导主色：按“覆盖面积最大”为主导选代表色，并做死白背景保护。
  static Color? _dominantByArea(List<List<int>> samples) {
    final buckets = <int, List<List<int>>>{};
    for (final p in samples) {
      final key = _quantize(p);
      (buckets[key] ??= <List<int>>[]).add(p);
    }
    final total = samples.length;

    // 桶内平均色 + 覆盖像素数（面积）。面积 = 频数，是主导判定的核心。
    final groups = <({int count, int r, int g, int b})>[];
    for (final group in buckets.values) {
      if (group.length < 2) continue;
      var r = 0, g = 0, b = 0;
      for (final p in group) {
        r += p[0];
        g += p[1];
        b += p[2];
      }
      r ~/= group.length;
      g ~/= group.length;
      b ~/= group.length;
      groups.add((count: group.length, r: r, g: g, b: b));
    }
    if (groups.isEmpty) return null;

    // 近死白判定(按桶平均色)：l≈>0.93 且 饱和极低。
    bool nearDeadWhite(({int count, int r, int g, int b}) grp) {
      final mx = math.max(grp.r, math.max(grp.g, grp.b));
      final mn = math.min(grp.r, math.min(grp.g, grp.b));
      final lum = 0.299 * grp.r + 0.587 * grp.g + 0.114 * grp.b;
      final sat = mx == 0 ? 0.0 : (mx - mn) / mx;
      return lum >= 236 && sat < 0.12;
    }

    // 死白保护：先剔除近死白簇，仅在“几乎所有像素都近死白(剔除后为空，如整面大白墙)”时才保留之，
    // 交由对比度矫正转成深档/深灰，避免“大白墙 → 整屏白字”。典型“蓝调+晚霞粉”封面的白/亮死白小块
    // 会被剔除，主导落在蓝色簇。
    final viable = groups.where((g) => !nearDeadWhite(g)).toList();
    final considered = viable.isEmpty ? groups : viable;

    // 面积优先评分：面积占比权重(100)显著大于亮度(2)/饱和(1)/暖色微调(0.5) → 面积主导。
    double scoreOf(({int count, int r, int g, int b}) grp) {
      final areaShare = grp.count / total; // 0..1
      final mx = math.max(grp.r, math.max(grp.g, grp.b));
      final mn = math.min(grp.r, math.min(grp.g, grp.b));
      final lum = 0.299 * grp.r + 0.587 * grp.g + 0.114 * grp.b;
      final sat = mx == 0 ? 0.0 : (mx - mn) / mx;
      var s = areaShare * 100.0; // 面积主导（权重很大 → “占面积大”的颜色胜出）
      s += (lum / 255) * 2.0; // 面积相近时才轻微偏好较亮（不改变色系）
      s += sat * 1.0; // 轻微偏好有彩
      if (grp.r > grp.b) s += 0.5; // 极弱的暖色微调，不再能盖过面积差
      return s;
    }

    var best = groups.first;
    var bestScore = -1.0;
    for (final grp in considered) {
      final s = scoreOf(grp);
      if (s > bestScore) {
        bestScore = s;
        best = grp;
      }
    }
    return Color.fromARGB(255, best.r, best.g, best.b);
  }

  // #################### 【备份】旧主导主色逻辑(已不再使用，仅存档比对) ####################
  // //// `_collectBrightPool`：高亮暖色候选池 ————
  // // 从全样本筛"相对较亮、带色彩、偏暖且非死白"的高亮候选池；被 _dominantByArea 取代，
  // // 因其按 R>B 强筛选会把大面积冷色主导块(大片蓝)排除、却把小而暖的晚霞粉筛入，是 bug 根因之一。
  // static List<List<int>> _collectBrightPool(List<List<int>> samples) {
  //   final pool = <List<int>>[];
  //   var lumThr = 128.0;
  //   var satMin = 0.15;
  //   var requireWarm = true;
  //   for (var round = 0; round < 4; round++) {
  //     pool.clear();
  //     for (final p in samples) {
  //       final r = p[0], g = p[1], b = p[2];
  //       final mx = math.max(r, math.max(g, b));
  //       final mn = math.min(r, math.min(g, b));
  //       final lum = 0.299 * r + 0.587 * g + 0.114 * b;
  //       final sat = mx == 0 ? 0.0 : (mx - mn) / mx;
  //       if (lum < lumThr) continue;
  //       if (lum >= 252) continue;
  //       if (sat < satMin || sat > 0.8) continue;
  //       if (requireWarm && r <= b) continue; // 强偏暖 R>B
  //       pool.add(p);
  //     }
  //     if (pool.length >= math.max(4, samples.length * 0.01)) break;
  //     if (round == 0) { lumThr = 100; satMin = 0.12; }
  //     else if (round == 1) { lumThr = 78; satMin = 0.10; }
  //     else { lumThr = 55; satMin = 0.08; requireWarm = false; }
  //   }
  //   return pool;
  // }
  // //// `_dominantHighlight`：量化强偏亮/暖打分取主色 ————
  // // 评分 = 对数频数×1.6 + 亮度×6.0 + 饱和×1.2 + 暖色+1.5 + 既亮又好看+1.2；
  // // 亮度/暖权重过高致“面积小队亮/暖小块”能盖过“面积大的普通主导色”，是 bug 根因之二。
  // static Color? _dominantHighlight(List<List<int>> candidates) {
  //   final buckets = <int, List<List<int>>>{};
  //   for (final p in candidates) { (buckets[_quantize(p)] ??= <List<int>>[]).add(p); }
  //   Color? best; double bestScore = -1;
  //   for (final group in buckets.values) {
  //     if (group.length < 2) continue;
  //     var r = 0, g = 0, b = 0;
  //     for (final p in group) { r += p[0]; g += p[1]; b += p[2]; }
  //     r ~/= group.length; g ~/= group.length; b ~/= group.length;
  //     final mx = math.max(r, math.max(g, b));
  //     final mn = math.min(r, math.min(g, b));
  //     final luminance = 0.299 * r + 0.587 * g + 0.114 * b;
  //     final saturation = mx == 0 ? 0.0 : (mx - mn) / mx;
  //     if (saturation < 0.12) continue;
  //     var score = math.log(group.length) * 1.6 + (luminance / 255) * 6.0 + saturation * 1.2;
  //     if (r > b) score += 1.5;
  //     if (luminance >= 170 && luminance < 250 && saturation >= 0.18) score += 1.2;
  //     if (score > bestScore) { bestScore = score; best = Color.fromARGB(255, r, g, b); }
  //   }
  //   return best;
  // }

  /// 把 RGB 量化为桶键（每通道取高 [_quantBits] 位）。
  static int _quantize(List<int> p) {
    final r = p[0] >> _quantShift;
    final g = p[1] >> _quantShift;
    final b = p[2] >> _quantShift;
    return (r << (_quantBits * 2)) | (g << _quantBits) | b;
  }

  static double _clampD(double v, double lo, double hi) =>
      v < lo ? lo : (v > hi ? hi : v);

  static Color _makeHslColor(double h, double s, double l) {
    final c = _hslToRgb(h, s, l);
    return Color.fromARGB(255, c[0], c[1], c[2]);
  }

  /// 由高亮色派生配套底色色。==== 对比度导向 ====：底色与背景保持同一亮暗对比方向。
  // ====【需求/对比度导向取色】====
  // 底色仍由【矫正后的】high 派生（同色相、降饱和、略作 current / 非 current 区分），
  // 但方向跟随背景亮暗，避免歌词整行溶进背景：
  //   * 暗背景(avgLum<128)：歌词取亮档 → 底色比 high 稍深稍灰、仍处亮侧(0.55~0.7)，
  //     在暗底上可见（亮于背景）并与当前行 high 有区分。
  //   * 亮背景：歌词取深档 → 底色取更深的深色系(0.28~0.40)并更灰，深于亮背景、比 high 略灰略深。
  // 旧实现（备份）：降饱和(s*0.8)+压暗(l*0.9).clamp(0.55,0.7)，不考虑背景亮暗，亮背景会溶进亮底。
  static Color _deriveBase(Color highlight, double avgLum) {
    final rgb = _rgbToHsl(highlight);
    final isDarkBg = avgLum < 128.0;
    final double baseS;
    final double baseL;
    if (isDarkBg) {
      baseS = (rgb.s * 0.8).clamp(0.0, 1.0).toDouble();
      baseL = (rgb.l * 0.9).clamp(0.55, 0.7).toDouble();
    } else {
      baseS = (rgb.s * 0.7).clamp(0.0, 1.0).toDouble();
      baseL = (rgb.l * 0.8).clamp(0.28, 0.40).toDouble();
    }
    return _makeHslColor(rgb.h, baseS, baseL);
  }

  // ---- HSL 转换辅助（用于派生成套底色色，就地实现，不引第三方库） ----

  // ====【需求/深色封面可读性矫正】====
  // 背景：当封面是纯黑、深色、或低饱和(灰)时，提取出的主色也是黑色/暗灰，歌词文字在深色背景上
  //       看不清。本环节在【最终输出颜色】上做一道"可读性矫正"，不推翻已有的强偏亮主色提取：
  //   * high 永远足够亮：用 HSL 亮度 L 判定。若 high 过暗(L<0.50) 或几乎无彩色(S<0.18)，
  //       则把它抬到明亮档并保留色相；若色相抬亮后仍接近灰，再增强饱和或转入明快暖色。
  //   * 低饱和(接近灰/黑、没色可提)封面：不输出灰糊糊的颜色，直接落到"清晰可读的中性明快暖色"
  //       （奶油/浅暖米 H≈42°），保证歌词清楚且观感协调。
  //   * 底色 base 仍由【矫正后的】high 走 `_deriveBase` 推出：同色相、降饱和、压暗到 0.55~0.7，
  //       天然避免纯黑/不可见极暗色，并与 high 成套。
  //   * 正常亮色/彩饰封面：brightPool 取出的 high 已够亮够彩(L≥0.50 且 S≥0.18)，零折损原样通过。

  /// 选取最终的可读性套装色：先矫正 high，再由矫正后的 high 派生 base；并输出矫正前后亮度日志。
  static ExtractedColors _finalizeForReadability(Color originalHighlight, double avgLum) {
    final before = _rgbToHsl(originalHighlight);
    final corrected = _readabilityCorrectHighlight(originalHighlight, avgLum);
    final after = _rgbToHsl(corrected);
    final base = _deriveBase(corrected, avgLum);
    final baseHsl = _rgbToHsl(base);
    _log('对比度矫正(avgLum=${avgLum.toStringAsFixed(0)}): '
        'high(L=${before.l.toStringAsFixed(2)},S=${before.s.toStringAsFixed(2)})'
        ' -> high(L=${after.l.toStringAsFixed(2)},S=${after.s.toStringAsFixed(2)})'
        ' base(L=${baseHsl.l.toStringAsFixed(2)},S=${baseHsl.s.toStringAsFixed(2)})');
    return ExtractedColors(highlight: corrected, base: base);
  }

  /// 对 high 做**对比度导向**的可读性矫正。
  // ====【需求/对比度导向取色】====
  // 新理念（用户明确的正确方向）：歌词不简单复制封面主色，而是被盖在"全屏模糊封面背景"上，
  // 因此要与【背景亮暗】形成反向对比 —— 背景暗→歌词亮、背景亮→歌词深。
  // 背景亮暗由封面平均亮度 [avgLum](0-255) 分档判定：
  //   * avgLum<45    近全黑背景 → 近白歌词。
  //   * avgLum>200   整体很亮背景 → 深色高对比歌词。
  //   * 中间以阈值 128 区分"偏暗(取亮档) / 偏亮(取深档)"。
  // 旧实现（备份，纯单向抬亮，导致亮背景给浅字看不清）：仅当 high 过暗(L<0.50)或近灰(S<0.18)
  //   才抬亮——暗背景给亮档、avgLum<45 给近白、其余抬到 L0.68；亮背景下浅歌词与亮底对比不足、
  //   且与背景不协调（正是"白/蓝封面却给米色"的根因）。本次重写为双向对比。
  static Color _readabilityCorrectHighlight(Color highlight, double avgLum) {
    final hsl = _rgbToHsl(highlight);
    final double h = hsl.h;
    final double s = hsl.s;
    final double l = hsl.l;

    // 【近全黑背景】黑底白词，最清晰协调。
    if (avgLum < 45.0) return _makeHslColor(h, 0.08, 0.92);
    // ====【需求/白封面取亮字·移除按封面亮暗上深字】====
    // 背景始终含压暗遮罩：白封面 avgLum 很高，但其【实际背景】经压暗后是暗青/暗灰，
    // 若按封面亮就取深字(如 69,76,84 深灰蓝)会与暗背景同色看不清(孙燕姿/九张机/酸欠少女复现)。
    // 故不再因封面"整体亮"就取深字；白封面改走下面的"主导色高亮档/近白"，与压暗背景形成清晰对比。
    // 仅保留"整图极端纯白且主导近白"(avgLum>240)的极小概率保险，用深字防"白字白底"。
    if (avgLum > 240.0 && l > 0.90) {
      return _makeHslColor(h, 0.10, 0.30); // 极端纯白大背景 → 深字保险
    }

    // ====【需求/主导色亮档优先(中等及偏亮背景)】====
    // 背景为"中等/偏亮"(如白、浅蓝封面压暗成灰褐)时，若按旧逻辑取"深档"会把歌词做成深灰，
    // 与相同明度的灰褐背景低对比、看不清(孙燕姿《完美的一天》复现)。改为默认取"主导色提亮/近白"：
    // 浅蓝→浅蓝亮版、白→近白，正如顶部标题白字在同一背景清晰可读，也贴合"蓝封面压暗成背景、
    // 歌词取高蓝"的协调审美。当背景经上分支判定为“真正很亮”时才取深字。
    if (l > 0.90) return _makeHslColor(h, 0.05, 0.95); // 主导色近白 → 近白
    if (s < 0.18) return _makeHslColor(h, 0.08, 0.90); // 主导色近灰 → 亮中性
    return _makeHslColor(h, math.max(s, 0.45), _clampD(l * 0.25 + 0.62, 0.78, 0.85));
  }

  /// RGB(0-255 Color) → HSL（h∈[0,360)，s,l∈[0,1]）。
  static ({double h, double s, double l}) _rgbToHsl(Color color) {
    final r = color.r;
    final g = color.g;
    final b = color.b;
    final mx = math.max(r, math.max(g, b));
    final mn = math.min(r, math.min(g, b));
    final l = (mx + mn) / 2;
    if (mx == mn) {
      return (h: 0, s: 0, l: l);
    }
    final d = mx - mn;
    final s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
    double h;
    if (mx == r) {
      h = ((g - b) / d + (g < b ? 6 : 0)) / 6;
    } else if (mx == g) {
      h = ((b - r) / d + 2) / 6;
    } else {
      h = ((r - g) / d + 4) / 6;
    }
    return (h: h * 360, s: s.clamp(0.0, 1.0), l: l.clamp(0.0, 1.0));
  }

  /// HSL → RGB [r,g,b] int(0-255)。
  static List<int> _hslToRgb(double h, double s, double l) {
    final c = (1 - (2 * l - 1).abs()) * s;
    final hp = (h >= 360 ? 0.0 : h) / 60;
    final x = c * (1 - (hp % 2 - 1).abs());
    double r, g, b;
    switch (hp.floor() % 6) {
      case 0:
        r = c;
        g = x;
        b = 0;
        break;
      case 1:
        r = x;
        g = c;
        b = 0;
        break;
      case 2:
        r = 0;
        g = c;
        b = x;
        break;
      case 3:
        r = 0;
        g = x;
        b = c;
        break;
      case 4:
        r = x;
        g = 0;
        b = c;
        break;
      default:
        r = c;
        g = 0;
        b = x;
    }
    final m = l - c / 2;
    return [
      ((r + m) * 255).round().clamp(0, 255).toInt(),
      ((g + m) * 255).round().clamp(0, 255).toInt(),
      ((b + m) * 255).round().clamp(0, 255).toInt(),
    ];
  }
}