// ====【修复/切歌自动刷新·自适应歌词颜色】全局提色编排 =====
//
// 背景（根因）：
//   原先"自适应歌词颜色"的提色触发（_onPlayerChanged → _runAdaptiveExtract）只写在
//   LyricAdjustmentsPage（一个"更多菜单→歌词调整"的临时路由页）内部。该页被 push 打开时
//   才会监听播放器切歌；页面关闭后（正常播放状态）再切歌，就再没有任何代码触发提色，
//   → 全局缓存 highlightColor/baseColor 不会更新，歌词颜色停在上一次的颜色。
//   与此同时，player_page 的三处歌词渲染（全屏 _LyricViewport / 轻量 _PerfLyricList /
//   车机 _LandscapeLyricPanel）其实都已在正确监听 LyricAdjustments.notifier 并重读
//   getGlobal()（渲染层本身没有问题）。缺的正是"正常播放时的自动触发"这一环。
//
// 解决：本类在应用启动时挂到一个 PlayerController 上，全局、常驻监听切歌；
//   开关开启且歌曲变化时对新歌封面提色并 LyricAdjustments.setGlobal(...)
//   （与调整页走同一份缓存与 ValueNotifier 通知机制），让渲染层即时拿到新颜色。
//   与 LyricAdjustmentsPage 自身的触发并存时结果一致（同一配来源、可重入），重复触发无害。
import 'dart:async';

import 'package:flutter/foundation.dart' show compute; // ====【修复/切歌卡顿·提色移 isolate】====

import '../controllers/player_controller.dart';
import 'cover_color_extractor.dart';
import 'lyric_adjustments.dart';
import 'startup_diag_logger.dart'; // ====【诊断/安卓渲染卡顿】====

// ====【修复/切歌自动提色·isolate 解码不可用】====
// compute 后台 isolate 中 ui.instantiateImageCodec 无法解码封面（此前切歌自动提色
// 日志全为"下载成功→解码失败或无有效样本"，功能静默失效、歌词颜色停在上一首）。
// 方案：1) compute 后台 isolate 只做【网络下载封面字节】（dart:io 可用、不阻塞主线程）；
//       2) 解码+采样+量化回主 isolate（CoverColorExtractor.extractFromBytes，
//          400x400 封面解码+4096 像素采样仅数毫秒，不构成切歌卡顿来源）。
// 注：compute 参数直接用静态方法引用（CoverColorExtractor.downloadCoverBytesForExtract）。====

/// [自适应歌词颜色] 全局切歌自动提色编排（静态单例，应用启动时 attach 一次）。
class AdaptiveLyricColor {
  AdaptiveLyricColor._();

  static PlayerController? _player;
  /// 上一次"真实触发提色"的歌曲 key（用于切歌门禁，避免播放中每帧 notify 反复提）。
  static String _lastKey = '';
  /// 提色请求序号：仅最后一次请求生效，避免切歌竞态把旧歌颜色写入新歌（防串色）。
  static int _serial = 0;
  static bool _attached = false;

  /// 挂载：应用启动构建 PlayerController 后调用一次。重复调用安全（幂等）。
  static void attach(PlayerController player) {
    if (_attached) {
      return;
    }
    _attached = true;
    _player = player;
    _lastKey = _resolveKey(player);
    player.addListener(_onSongChanged);
  }

  /// 卸载：应用退出时调用，移除监听释放引用。
  static void detach(PlayerController player) {
    if (!_attached) {
      return;
    }
    player.removeListener(_onSongChanged);
    _attached = false;
    _player = null;
    _serial = 0;
  }

  static String _resolveKey(PlayerController player) {
    final s = player.currentSong;
    if (s == null) {
      return '';
    }
    return LyricAdjustments.resolveOffsetKey(hash: s.hash, id: s.id);
  }

  /// player 每帧 notify（位置流）等，这里仅做"歌曲 key 是否变化"的轻量比对。
  static void _onSongChanged() {
    final player = _player;
    if (player == null) {
      return;
    }
    if (!LyricAdjustments.getGlobal().adaptiveColor) {
      return;
    }
    final key = _resolveKey(player);
    if (key.isEmpty || key == _lastKey) {
      return;
    }
    // 确要提这一首：先同步记录，避免本次异步提炼取完成前被同一首重复触发。
    _lastKey = key;
    unawaited(_extract(player, key));
  }

  /// 对新歌封面提色并写入全局配置；失败跳过（保留旧色，避免切歌瞬间闪白），
  /// 成功则按 unifiedColor 写高亮（+底色）→ setGlobal 触发 notifier → 渲染层即时刷新。
  static Future<void> _extract(PlayerController player, String key) async {
    final serial = ++_serial;
    final song = player.currentSong;
    if (song == null) {
      return;
    }
    // ====【修复/无封面歌曲歌词色】====
    // 无封面（coverUrl 为空）或本地 content:// 封面（无法 HTTP 下载提取）时，使用【默认白色】，
    // 不再沿用上一首提取出的颜色 —— 上一首的颜色与当前歌无关，观感错误（用户反馈）。
    final coverUrl = song.coverUrl;
    if (coverUrl == null ||
        coverUrl.isEmpty ||
        coverUrl.startsWith('content://')) {
      if (serial != _serial) {
        return; // 已被更新的切换/触发覆盖
      }
      final cfg = LyricAdjustments.getGlobal();
      if (!cfg.adaptiveColor) {
        return;
      }
      if (cfg.highlightColor == 0xFFFFFFFF && cfg.baseColor == 0xFFFFFFFF) {
        return; // 已是默认白，无需重复写盘
      }
      await LyricAdjustments.setGlobal(
        cfg.copyWith(highlightColor: 0xFFFFFFFF, baseColor: 0xFFFFFFFF),
      );
      return;
    }
    // ====【需求/中心区域取色可选项】把配置的"仅中心取色"开关作为 centerOnly 传入
    //（关闭→false=全图=现状；开启→true=中心 crop=0.15）====
    final centerOnly = LyricAdjustments.centerCrop();
    try {
      // ====【修复/切歌自动提色·isolate 解码不可用】1) 后台 isolate 下载封面字节 ====
      final bytes = await compute(
        CoverColorExtractor.downloadCoverBytesForExtract,
        song.coverUrl,
      );
      if (serial != _serial || bytes == null || bytes.isEmpty) {
        return; // 已被更新的切换/触发覆盖，或下载失败（保留旧色）
      }
      // ==== 2) 主 isolate 解码+采样+提色（dart:ui 解码仅主 isolate 可靠）====
      // ====【诊断/安卓渲染卡顿】==== 量出"主 isolate 解码+取像素+提色"的真实耗时。
      final extractSw = Stopwatch()..start();
      final result = await CoverColorExtractor.extractFromBytes(
        bytes,
        centerOnly: centerOnly,
      );
      extractSw.stop();
      StartupDiagLogger.phase(
        'coverExtract',
        ms: extractSw.elapsedMilliseconds,
        note: 'song=${song.title} coverBytes=${bytes.length} '
            'centerOnly=$centerOnly',
      );
      if (serial != _serial) {
        return; // 已被更新的切换/触发覆盖，丢弃（防串色）
      }
      final cfg = LyricAdjustments.getGlobal();
      if (!cfg.adaptiveColor) {
        return;
      }
      if (result == null) {
        return; // 提色失败/封面未就绪：本轮保留上一次的颜色，避免闪白
      }
      final next = cfg.copyWith(
        highlightColor: result.highlight.toARGB32(),
        baseColor: cfg.unifiedColor
            ? result.highlight.toARGB32()
            : result.base.toARGB32(),
      );
      await LyricAdjustments.setGlobal(next);
    } catch (_) {
      // 静默：提色异常不影响播放（保留旧色，避免闪白）。
    }
  }
}