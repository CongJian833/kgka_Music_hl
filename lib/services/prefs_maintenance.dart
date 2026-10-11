// ====【修复/切歌卡顿·prefs 瘦身】====
//
// 背景：SharedPreferences 每次 `setX` 都会同步重写整个 JSON 文件（本机实测 8.67MB 文件
// 单次约 430ms），经打点确认为切歌两处小卡顿的唯一根因。切歌路径上的写入已全部迁到独立
// 小文件（见 player_controller / download_controller），但 prefs 里仍残留大量"迁移后的死键"：
//   * `cache_*`（歌词/歌单/专辑/歌手等缓存）386 个键占 6.37MB —— 缓存已改存
//     `cache_files/*.json`，读取走"文件优先"，永远不触发旧 prefs 的回退迁移，于是永久滞留；
//   * `playback.queue` 单键 682KB 等 —— 队列/当前歌曲/位置/播放模式均已改存独立小文件。
//
// 做法：一次性"快照 → clear → 回写"，把死键清掉、只保留有效键。
// 为什么不用逐个 `prefs.remove`：每次 remove 同样会同步整写整个文件（430ms），386 个键约需
// 166 秒并持续造成主线程卡顿，比不清理更糟（已实测确认：逐个删只从 8672KB 降到 8143KB）。
//
// 安全性：
//   1) 只删"可再生的派生数据"（`cache_*`）与"已确认迁移完成"的 playback 旧键（由调用方
//      判断对应小文件存在且非空后才传入，未升级用户的数据仍在 prefs 中，不会误删）；
//   2) 清理前先把要保留的键写入备份文件；若清理中途崩溃，下次启动由 [recoverIfNeeded]
//      先恢复设置再重试，不会丢登录态等用户数据；
//   3) 任一保留键的类型无法识别时直接放弃清理（fail-safe，绝不冒险丢设置）。
//
// 调用时机：`recoverIfNeeded` 在 main() 最早期（任何 prefs 消费者之前）调用；
//          `purge` 在播放状态恢复（含旧值迁移）完成之后调用一次。
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PrefsMaintenance {
  PrefsMaintenance._();

  static const _backupFileName = 'prefs_purge_backup.json';

  /// ====【修复/安卓冷启动重复开销】==== 「已瘦身完成」标记键。
  /// 原实现每次冷启动都要把整个 prefs 读出来逐键判断死键（TV 上实测 50~170ms，
  /// 因为读取本身就要解析并可能回写整份文件）。瘦身是一次性迁移，完成后立标记即可跳过。
  static const _purgeDoneKey = 'ka_music_prefs_purged_v1';

  /// 可安全整段丢弃的 key 前缀（派生缓存；清了只会导致下次重新拉取）。
  /// 注：只收 `cache_`（首页/歌单/专辑/歌手/用户/歌词等缓存，实测占 6.37MB）。
  /// `ka_music_cached_playlists_{userId}` 体积很小、且被清掉会让"我的歌单"短暂空白，
  /// 故不纳入清理范围。
  static const _disposablePrefixes = <String>[
    'cache_',
  ];

  static Future<File> _backupFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_backupFileName');
  }

  /// 清理中断后的恢复：把备份文件里的键写回 prefs，然后删除备份。
  /// 必须在任何 prefs 消费者之前调用（main() 最早期）。
  static Future<void> recoverIfNeeded() async {
    try {
      final backup = await _backupFile();
      if (!backup.existsSync()) return;
      final raw = await backup.readAsString();
      if (raw.isEmpty) {
        await backup.delete();
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        await backup.delete();
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      for (final entry in decoded.entries) {
        final v = entry.value;
        if (v == null) continue;
        await _writeAny(prefs, entry.key.toString(), v);
      }
      await backup.delete();
    } catch (_) {
      // 静默：恢复失败不影响启动（下次再试）。
    }
  }

  /// 一次性瘦身 prefs：删除 `cache_*` 死键，只保留有效键。
  ///
  /// 必须在 [recoverIfNeeded] 之后、**任何其它 prefs 消费者之前**调用（见 main() 最早期）：
  /// 本方法内部会 `clear()` 后回写，若与其它协作者（token 刷新等）并发，落在"快照→clear"
  /// 之间的写入会被回滚，故放在启动最早、无任何并发的时刻执行。
  ///
  /// 返回是否执行成功（false 表示因类型不可识别等原因放弃，未做任何修改）。
  static Future<bool> purge() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // ====【修复/安卓冷启动重复开销】==== 已瘦身过则直接返回，避免每次全量扫描。
      var alreadyPurged = false;
      try {
        alreadyPurged = prefs.getBool(_purgeDoneKey) ?? false;
      } catch (_) {}
      if (alreadyPurged) return true;
      final keys = prefs.getKeys().toList();

      final keep = <String, Object>{};
      var hasDisposable = false;
      for (final key in keys) {
        if (_isDisposable(key)) {
          hasDisposable = true;
          continue;
        }
        final value = _readAny(prefs, key);
        if (value == null) {
          // 存在无法识别的类型：放弃清理，避免回写时丢失该设置（fail-safe）。
          return false;
        }
        keep[key] = value;
      }
      if (!hasDisposable) {
        // 已经没有死键：落标记，下次启动直接跳过。
        try {
          await prefs.setBool(_purgeDoneKey, true);
        } catch (_) {}
        return true;
      }

      // 1) 备份要保留的键（崩溃可恢复）
      final backup = await _backupFile();
      await backup.writeAsString(jsonEncode(keep));

      // 2) 一次性清空（此处一次整写清空，随后文件变小，回写为毫秒级）
      await prefs.clear();

      // 3) 回写保留键
      for (final entry in keep.entries) {
        await _writeAny(prefs, entry.key, entry.value);
      }

      // 4) 清理成功，删除备份
      try {
        if (backup.existsSync()) await backup.delete();
      } catch (_) {}
      // 5) 落「已瘦身」标记：后续启动不再全量扫描 prefs。
      try {
        await prefs.setBool(_purgeDoneKey, true);
      } catch (_) {}
      return true;
    } catch (_) {
      return false;
    }
  }

  static bool _isDisposable(String key) {
    for (final p in _disposablePrefixes) {
      if (key.startsWith(p)) return true;
    }
    return false;
  }

  /// 读取任意类型的值（经典 API 无泛型 get，只能按类型逐个尝试，类型不符会抛错）。
  /// 全部类型均不匹配时返回 null（调用方据此放弃清理）。
  static Object? _readAny(SharedPreferences prefs, String key) {
    try {
      final v = prefs.getString(key);
      if (v != null) return v;
    } catch (_) {}
    try {
      final v = prefs.getBool(key);
      if (v != null) return v;
    } catch (_) {}
    try {
      final v = prefs.getInt(key);
      if (v != null) return v;
    } catch (_) {}
    try {
      final v = prefs.getDouble(key);
      if (v != null) return v;
    } catch (_) {}
    try {
      final v = prefs.getStringList(key);
      if (v != null) return v;
    } catch (_) {}
    return null;
  }

  static Future<void> _writeAny(
    SharedPreferences prefs,
    String key,
    Object value,
  ) async {
    if (value is String) {
      await prefs.setString(key, value);
    } else if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is int) {
      await prefs.setInt(key, value);
    } else if (value is double) {
      await prefs.setDouble(key, value);
    } else if (value is List) {
      await prefs.setStringList(key, value.map((e) => '$e').toList());
    }
  }
}
