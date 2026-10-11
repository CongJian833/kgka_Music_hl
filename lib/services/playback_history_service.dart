import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/music_models.dart';

/// 播放历史记录服务。
///
/// 将最近播放过的歌曲按时间倒序持久化，同一首歌重复播放时会移动到列表头部，
/// 最多保留 [_maxRecords] 条。
/// ====【修复/切歌后小卡顿·历史迁文件】====
// 原实现存 SharedPreferences（最多 500 条大 JSON），record 每次 `prefs.setString`
// 同步整写整个 prefs 文件（桌面端实锤卡顿源），是"画面稳定后小卡顿"的来源之一。
// 现改为【独立小文件 + File 异步读写】；读取优先独立文件、回退旧 prefs 值并当场迁移
// （兼容升级前数据）。全部文件读写 try-catch 静默，绝不因存储问题影响功能。
class PlaybackHistoryService {
  static const _key = 'playback_history';
  static const _maxRecords = 500;

  /// 播放历史独立小文件（应用支持目录）。
  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}playback_history');
  }

  /// 读取历史原始列表（独立文件优先；无则回退旧 prefs 并当场迁移）。
  Future<List<dynamic>> _readList() async {
    try {
      final f = await _file();
      if (f.existsSync()) {
        final raw = await f.readAsString();
        if (raw.isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is List) return decoded;
        }
      }
    } catch (_) {}
    // 旧数据（升级前存 prefs）回退 + 迁移
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is List) {
            await _writeList(decoded);
            await prefs.remove(_key); // 迁移后清 prefs 旧值（一次性整写，可接受）
            return decoded;
          }
        } catch (_) {}
      }
    } catch (_) {}
    return [];
  }

  /// 写入历史（File 异步写，不阻塞主线程）。
  Future<void> _writeList(List<dynamic> list) async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(list));
    } catch (_) {}
  }

  /// 记录一次播放：去重后插入到头部，超出上限时截断。
  Future<void> record(Song song) async {
    if (song.hash.isEmpty) return;
    final list = await _readList();
    // 去重：移除同 hash 的旧记录
    list.removeWhere((item) {
      if (item is! Map) return false;
      return item['hash'] == song.hash;
    });
    // 插入到头部
    list.insert(0, song.toCache());
    // 限制数量
    if (list.length > _maxRecords) {
      list.removeRange(_maxRecords, list.length);
    }
    await _writeList(list);
  }

  /// 读取播放历史，最多返回 [limit] 条。
  Future<List<Song>> getHistory({int limit = 100}) async {
    final list = await _readList();
    return list
        .whereType<Map<String, dynamic>>()
        .map(Song.fromCache)
        .where((s) => s.hash.isNotEmpty)
        .take(limit)
        .toList();
  }

  /// 读取历史记录总数（仅解析 JSON 长度，不反序列化 Song 对象）。
  ///
  /// 用于 UI 上的计数展示，避免为了取 length 而反序列化全部 Song。
  /// 返回值受 [_maxRecords] 上限约束。
  Future<int> count() async {
    return (await _readList()).length;
  }

  /// 清空播放历史（文件 + 旧 prefs 双清）。
  Future<void> clear() async {
    try {
      final f = await _file();
      if (f.existsSync()) await f.delete();
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {}
  }
}
