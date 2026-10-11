import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cache_diag_logger.dart'; // ====【诊断/缓存清理卡顿】====

/// 缓存读取结果。
class CacheResult<T> {
  const CacheResult({required this.data, required this.isStale});

  final T data;

  /// 是否已超过 TTL（过期）。
  final bool isStale;
}

/// 统一数据缓存服务。
///
/// 缓存载体为【独立小文件 + JSON】（决策2，2026-09-25）：
/// 每条缓存一个文件 `cache_files/{key}.json`，内容同原结构
/// `{ "savedAt": <毫秒时间戳>, "payload": <任意 JSON> }`。
/// ====【修复/切歌卡顿·缓存移文件】原决策1用 SharedPreferences 存所有缓存（含歌词等
/// 大 JSON），每次 setString 同步整写整个 prefs JSON，切歌时歌词缓存写入是卡顿来源。
/// 现缓存写独立文件 + File 异步写；读取优先文件、回退旧 prefs 值并当场迁移（兼容升级前
/// 数据）。prefs 只保留其它小配置。全部文件读写 try-catch 静默，绝不因缓存问题影响功能。
///
/// 核心方法 [swr] 封装 stale-while-revalidate 模式：先返回缓存立即显示，
/// 后台静默刷新，失败时降级到缓存。该模式推广自 AuthController 已有的
/// 「先缓存后刷新 + 失败降级」逻辑。
class CacheService {
  CacheService();

  static const _savedAtKey = 'savedAt';
  static const _payloadKey = 'payload';

  // ===== key 命名规范 =====
  // 首页（匿名可访问，登出不清理）：cache_home
  // 歌单详情：cache_playlist_{playlistId}
  // 专辑详情：cache_album_{albumId}
  // 歌手详情：cache_artist_{artistId}
  // 用户信息：cache_user_{userId}
  // 用户歌单列表：cache_user_playlists_{userId}
  // 歌词：cache_lyric_{hash} 等

  /// 响度分析缓存的 key 前缀。
  ///
  /// ====【响应"响度缓存改为手动清理"】====
  /// 该前缀的缓存不参与 clearAllCache（避免误清算力换来的结果），
  /// 由设置页「缓存管理」的独立条目手动清理（prefixStats / removeByPrefix）。
  /// 须与 loudness_normalization.dart 的 _loudnessCachePrefix 保持一致。
  static const String loudnessCachePrefix = 'cache_loudness_v';

  /// 用户相关缓存 key 前缀，登出时按前缀清理。
  static const _userCachePrefixes = <String>[
    'cache_user_',
    'cache_playlist_',
    'cache_album_',
    'cache_artist_',
  ];

  /// 读取缓存。无缓存返回 null。
  /// ====【缓存移文件】优先读独立文件；无则回退旧 prefs key 并当场迁移（写文件+清 prefs）。====
  Future<CacheResult<T>?> read<T>(
    String key, {
    required T Function(Map<String, dynamic> json) decode,
    Duration ttl = const Duration(hours: 24),
  }) async {
    String? raw;
    try {
      final f = await _cacheFile(key);
      if (f.existsSync()) {
        final s = await f.readAsString();
        if (s.isNotEmpty) raw = s;
      }
    } catch (_) {}
    if (raw == null) {
      // 旧数据（升级前存 prefs）回退 + 迁移
      try {
        final prefs = await SharedPreferences.getInstance();
        raw = prefs.getString(key);
        if (raw != null) {
          try {
            await _cacheFile(key).then((f) => f.writeAsString(raw!));
            await prefs.remove(key); // 迁移后清 prefs 旧值（一次性整写，可接受）
          } catch (_) {}
        }
      } catch (_) {}
    }
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final payload = decoded[_payloadKey];
      if (payload is! Map<String, dynamic>) return null;
      final savedAt = decoded[_savedAtKey];
      final isStale = savedAt is! num ||
          DateTime.now().millisecondsSinceEpoch - savedAt.toInt() >
              ttl.inMilliseconds;
      return CacheResult<T>(data: decode(payload), isStale: isStale);
    } catch (_) {
      return null;
    }
  }

  /// 写入缓存（记录 savedAt = 当前时间）。
  /// ====【缓存移文件】写独立文件（File 异步写，不再触发 prefs 同步整写 JSON）。====
  Future<void> write(String key, Map<String, dynamic> payload) async {
    final wrapper = jsonEncode({
      _savedAtKey: DateTime.now().millisecondsSinceEpoch,
      _payloadKey: payload,
    });
    try {
      final f = await _cacheFile(key);
      await f.writeAsString(wrapper);
    } catch (_) {
      // 静默：缓存写失败不影响功能（下次 swr 重新拉取）。
    }
  }

  /// 移除单条缓存（文件 + 旧 prefs 双清）。
  Future<void> remove(String key) async {
    try {
      final f = await _cacheFile(key);
      if (f.existsSync()) await f.delete();
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    } catch (_) {}
  }

  /// 登出清理：清除用户相关缓存，保留匿名可访问内容（首页 cache_home）。
  Future<void> clearUserCache(String? userId) async {
    await _removeByPrefix(_userCachePrefixes);
  }

  /// 按前缀统计缓存占用（条目数 + 字节数），供"缓存管理"展示单项缓存的体积。
  ///
  /// ====【新增/缓存管理可手动清理】====
  /// 用于在设置页「缓存管理」里单独展示某项缓存（如响度分析结果）并允许手动清理；
  /// 清理与否完全交给用户，不做自动裁剪。全部 try-catch 静默。
  Future<({int count, int bytes})> prefixStats(String prefix) async {
    // ====【诊断/v2】==== 与 getCacheSize 同为「缓存管理」面板内的目录遍历。
    final sw = Stopwatch()..start();
    var count = 0;
    var bytes = 0;
    try {
      final dir = await _cacheDir();
      if (await dir.exists()) {
        await for (final entity in dir.list()) {
          if (entity is! File) continue;
          final segments = entity.uri.pathSegments;
          final name = segments.isEmpty ? '' : segments.last;
          if (!name.startsWith(prefix)) continue;
          count++;
          try {
            bytes += await entity.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    sw.stop();
    CacheDiagLogger.log(
      'prefixStats',
      'prefix=$prefix count=$count',
      ms: sw.elapsedMilliseconds,
    );
    return (count: count, bytes: bytes);
  }

  /// 按前缀删除缓存（文件 + 旧 prefs 双清）。公开版本，供缓存管理手动清理单项缓存。
  Future<void> removeByPrefix(String prefix) => _removeByPrefix([prefix]);

  /// 按前缀删除缓存（文件 + prefs 双清）。
  Future<void> _removeByPrefix(List<String> prefixes) async {
    // 文件侧：删除 cache_files 下前缀匹配的文件
    try {
      final dir = await _cacheDir();
      if (await dir.exists()) {
        await for (final f in dir.list()) {
          final name = f.uri.pathSegments.isEmpty
              ? ''
              : f.uri.pathSegments.last;
          for (final p in prefixes) {
            if (name.startsWith(p)) {
              try {
                await f.delete();
              } catch (_) {}
              break;
            }
          }
        }
      }
    } catch (_) {}
    // prefs 侧
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().toList();
      for (final key in keys) {
        for (final prefix in prefixes) {
          if (key.startsWith(prefix)) {
            await prefs.remove(key);
            break;
          }
        }
      }
    } catch (_) {}
  }

  /// 获取所有数据缓存的总大小（字节，文件 + 旧 prefs）。
  ///
  /// ====【响度缓存改手动清理】==== 统计时排除 [loudnessCachePrefix]：
  /// 该部分在「缓存管理」里是独立条目，若计入总量会出现"清理后大小不变"的困惑。
  Future<int> getCacheSize() async {
    // ====【诊断/v2】==== RUN1 实测：打开「缓存管理」时 dataCache=52~128ms，
    // 这里拆出「目录列举 list」与「逐文件 length stat」两段以定位。
    final sw = Stopwatch()..start();
    var files = 0;
    var listMs = 0;
    var statMs = 0;
    var dirExistsMs = 0;
    var total = 0;
    try {
      final dirSw = Stopwatch()..start();
      final dir = await _cacheDir();
      final exists = await dir.exists();
      dirSw.stop();
      dirExistsMs = dirSw.elapsedMilliseconds;
      if (exists) {
        final listSw = Stopwatch()..start();
        await for (final entity in dir.list()) {
          if (entity is! File) continue;
          final segments = entity.uri.pathSegments;
          final name = segments.isEmpty ? '' : segments.last;
          if (name.startsWith(loudnessCachePrefix)) continue; // 独立条目，不计入
          files++;
          try {
            final s = Stopwatch()..start();
            total += await entity.length();
            s.stop();
            statMs += s.elapsedMilliseconds;
          } catch (_) {}
        }
        listSw.stop();
        listMs = listSw.elapsedMilliseconds;
      }
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        if (key.startsWith(loudnessCachePrefix)) continue; // 独立条目，不计入
        if (key.startsWith('cache_') ||
            key.startsWith('ka_music_cached_playlists')) {
          final value = prefs.getString(key);
          if (value != null) total += value.length * 2;
        }
      }
    } catch (_) {}
    sw.stop();
    CacheDiagLogger.log(
      'getCacheSize',
      'files=$files bytes=${(total / 1024 / 1024).toStringAsFixed(2)}MB '
      'dirExists=${dirExistsMs}ms dirList=${listMs}ms statTotal=${statMs}ms',
      ms: sw.elapsedMilliseconds,
    );
    return total;
  }

  /// 获取缓存条目数量（文件 + 旧 prefs）。同样排除响度缓存（见 [getCacheSize]）。
  Future<int> getCacheCount() async {
    var count = 0;
    try {
      final dir = await _cacheDir();
      if (await dir.exists()) {
        await for (final entity in dir.list()) {
          final segments = entity.uri.pathSegments;
          final name = segments.isEmpty ? '' : segments.last;
          if (name.startsWith(loudnessCachePrefix)) continue;
          count++;
        }
      }
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      count += prefs
          .getKeys()
          .where(
            (key) =>
                key.startsWith('cache_') &&
                !key.startsWith(loudnessCachePrefix),
          )
          .length;
    } catch (_) {}
    return count;
  }

  /// 清除所有数据缓存（保留用户歌单索引等必要数据；文件 + 旧 prefs）。
  ///
  /// ====【响度缓存改为手动清理】==== 响度分析结果（cache_loudness_*）不在本方法内清除：
  /// 它是"算力换来的结果"，误清会导致所有歌重新分析；数据量也极小（每首约 200 字节）。
  /// 如需清理，走设置页「缓存管理」中的独立条目（CacheService.removeByPrefix）。
  Future<void> clearAllCache() async {
    try {
      final dir = await _cacheDir();
      if (await dir.exists()) {
        await for (final f in dir.list()) {
          final segments = f.uri.pathSegments;
          final name = segments.isEmpty ? '' : segments.last;
          if (name.startsWith(loudnessCachePrefix)) continue; // 跳过响度缓存
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().toList();
      for (final key in keys) {
        if (key.startsWith(loudnessCachePrefix)) continue; // 跳过响度缓存
        if (key.startsWith('cache_')) {
          await prefs.remove(key);
        }
      }
    } catch (_) {}
  }

  /// 缓存文件目录（应用支持目录/cache_files）。
  Future<Directory> _cacheDir() async {
    final dir = await getApplicationSupportDirectory();
    final sub = Directory('${dir.path}${Platform.pathSeparator}cache_files');
    if (!await sub.exists()) {
      try {
        await sub.create(recursive: true);
      } catch (_) {}
    }
    return sub;
  }

  /// 由 key 生成缓存文件（非法字符替换为下划线，避免路径问题）。
  Future<File> _cacheFile(String key) async {
    final dir = await _cacheDir();
    final safe = key.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return File('${dir.path}${Platform.pathSeparator}$safe.json');
  }

  /// stale-while-revalidate 封装。
  ///
  /// 流程：
  /// 1. 读取缓存 → 若命中，立即 [onData](cached)（首屏优先显示，无感）。
  /// 2. 后台执行 [fetch]：
  ///    - 成功 → [write] 缓存 → [onData](fresh)（静默刷新界面）。
  ///    - 失败 → 若缓存存在（哪怕过期）则保持不报错（降级）；
  ///      若完全无缓存则调用 [onError]。
  /// 3. [forceRefresh] = true（下拉刷新）时跳过第 1 步的立即返回，
  ///    优先走 fetch，失败再回退缓存。
  Future<void> swr<T>({
    required String key,
    required Duration ttl,
    required Future<T> Function() fetch,
    required T Function(Map<String, dynamic> json) decode,
    required Map<String, dynamic> Function(T data) encode,
    required void Function(T data) onData,
    void Function(Object error)? onError,
    bool forceRefresh = false,
  }) async {
    // 1. 先读缓存（非强制刷新时立即返回显示）
    CacheResult<T>? cached;
    if (!forceRefresh) {
      cached = await read<T>(key, decode: decode, ttl: ttl);
      if (cached != null) {
        onData(cached.data);
      }
    } else {
      // 强制刷新也先读缓存作为降级兜底，但不立即显示
      cached = await read<T>(key, decode: decode, ttl: ttl);
    }

    // 2. 后台静默刷新
    try {
      final fresh = await fetch();
      await write(key, encode(fresh));
      onData(fresh);
    } catch (error) {
      if (cached != null) {
        // 有缓存（哪怕过期）则降级，不报错
        if (forceRefresh) {
          // 强制刷新模式下前面没有立即显示，这里补显示缓存
          onData(cached.data);
        }
      } else {
        // 完全无缓存，回调错误
        onError?.call(error);
      }
    }
  }
}
