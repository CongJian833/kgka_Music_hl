import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/music_models.dart';
import '../services/cache_diag_logger.dart'; // ====【诊断/缓存清理卡顿】====
import '../services/download_service.dart';
import '../services/music_api.dart';

/// 下载状态枚举。
enum DownloadStatus { notDownloaded, downloading, downloaded, failed }

/// 批量下载结果统计。
class BatchDownloadResult {
  const BatchDownloadResult({
    required this.enqueued,
    required this.skipped,
    required this.failed,
  });

  /// 成功加入下载队列的歌曲数。
  final int enqueued;

  /// 跳过的歌曲数（已下载或已在下载中）。
  final int skipped;

  /// 加入队列失败（无播放地址/网络错误）的歌曲数。
  final int failed;

  /// 已加入队列（含已下载与失败）的总处理数量。
  int get total => enqueued + skipped + failed;
}

/// 下载条目。
class DownloadEntry {
  const DownloadEntry({
    required this.song,
    required this.quality,
    required this.status,
    this.progress = 0,
    this.filePath,
    this.error,
    this.downloadedAt,
  });

  final Song song;
  final AudioQuality quality;
  final DownloadStatus status;
  final double progress;
  final String? filePath;
  final String? error;
  final DateTime? downloadedAt;

  DownloadEntry copyWith({
    DownloadStatus? status,
    double? progress,
    String? filePath,
    String? error,
    DateTime? downloadedAt,
  }) {
    return DownloadEntry(
      song: song,
      quality: quality,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      filePath: filePath ?? this.filePath,
      error: error,
      downloadedAt: downloadedAt ?? this.downloadedAt,
    );
  }
}

/// 播放缓存条目。
class PlayCacheEntry {
  const PlayCacheEntry({
    required this.cacheKey,
    required this.song,
    required this.quality,
    required this.filePath,
    required this.size,
    required this.cachedAt,
  });

  final String cacheKey;
  final Song song;
  final AudioQuality quality;
  final String filePath;
  final int size;
  final DateTime cachedAt;
}

/// 下载与播放缓存控制器。
///
/// 管理用户主动下载（持久目录）和播放缓存（临时目录）。
/// 下载状态通过 [DownloadStatus] + [entryFor] 查询，UI 用 AnimatedBuilder 监听。
class DownloadController extends ChangeNotifier {
  DownloadController(this._service, this._api);

  final DownloadService _service;
  final MusicApi _api;

  static const _downloadsIndexKey = 'ka_music_downloads_index';
  static const _playCacheIndexKey = 'ka_music_play_cache_index';
  static const _playCacheLimitKey = 'settings.play_cache_limit';

  final Map<String, DownloadEntry> _downloads = {}; // key = hash
  final Map<String, PlayCacheEntry> _playCache = {}; // key = hash_quality
  bool _initialized = false;

  int _playCacheLimit = 300 * 1024 * 1024; // 默认 300MB
  int get playCacheLimit => _playCacheLimit;

  Future<void> setPlayCacheLimit(int limitInBytes) async {
    // ====【诊断/缓存清理卡顿】==== 触发点3：用户在设置页改播放缓存上限。
    final sw = Stopwatch()..start();
    _playCacheLimit = limitInBytes;
    final prefs = await SharedPreferences.getInstance();
    final prefsWriteSw = Stopwatch()..start();
    await prefs.setInt(_playCacheLimitKey, limitInBytes);
    prefsWriteSw.stop();
    notifyListeners();
    await _prunePlayCache(excludePaths: const {}, origin: 'setLimit');
    sw.stop();
    CacheDiagLogger.log(
      'ui.setPlayCacheLimit',
      'newLimit=${(limitInBytes / (1024 * 1024)).toStringAsFixed(0)}MB '
      'prefsSetInt=${prefsWriteSw.elapsedMilliseconds}ms',
      ms: sw.elapsedMilliseconds,
    );
  }

  /// 启动时加载索引并校验文件存在性。
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    // ====【诊断/缓存清理卡顿】==== 触发点1：应用启动。逐阶段计时。
    final sw = Stopwatch()..start();
    final prefsSw = Stopwatch()..start();
    final prefs = await SharedPreferences.getInstance();
    _playCacheLimit = prefs.getInt(_playCacheLimitKey) ?? (300 * 1024 * 1024);
    prefsSw.stop();
    final dlSw = Stopwatch()..start();
    await _loadDownloads();
    dlSw.stop();
    final pcSw = Stopwatch()..start();
    await _loadPlayCache();
    pcSw.stop();
    final pruneSw = Stopwatch()..start();
    // 启动时 LRU 清理播放缓存
    await _prunePlayCache(excludePaths: const {}, origin: 'startup');
    pruneSw.stop();
    sw.stop();
    CacheDiagLogger.log(
      'init.initialize',
      'limit=${(_playCacheLimit / (1024 * 1024)).toStringAsFixed(0)}MB '
      'indexEntries=${_playCache.length} downloads=${_downloads.length} '
      'prefs=${prefsSw.elapsedMilliseconds}ms '
      'loadDownloads=${dlSw.elapsedMilliseconds}ms '
      'loadPlayCache=${pcSw.elapsedMilliseconds}ms '
      'prune=${pruneSw.elapsedMilliseconds}ms',
      ms: sw.elapsedMilliseconds,
    );
  }

  Future<void> _loadDownloads() async {
    // ====【修复/切歌卡顿·索引移出 prefs】优先独立文件；无则回退旧 prefs 并迁移。====
    // ====【诊断/缓存清理卡顿】==== 加载下载索引时逐条 fileSize 校验，启动阶段一并计时。
    final sw = Stopwatch()..start();
    final raw = await _readIndexFile(_downloadsIndexFileName, _downloadsIndexKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw);
      if (list is! List) return;
      for (final item in list.whereType<Map<String, dynamic>>()) {
        final song = Song.fromCache(
          (item['song'] as Map).cast<String, dynamic>(),
        );
        final quality = AudioQuality.fromApiValue(item['quality'] as String?);
        final filePath = item['filePath'] as String?;
        if (filePath == null) continue;
        // 校验文件存在性
        if (!await _service.fileSize(filePath).then((s) => s > 0)) continue;
        final downloadedAtStr = item['downloadedAt'] as String?;
        _downloads[song.hash] = DownloadEntry(
          song: song,
          quality: quality,
          status: DownloadStatus.downloaded,
          filePath: filePath,
          downloadedAt: downloadedAtStr != null
              ? DateTime.tryParse(downloadedAtStr)
              : null,
        );
      }
    } catch (_) {}
    sw.stop();
    CacheDiagLogger.log(
      'load.downloadsIndex',
      'valid=${_downloads.length}',
      ms: sw.elapsedMilliseconds,
    );
  }

  Future<void> _loadPlayCache() async {
    // ====【修复/切歌卡顿·索引移出 prefs】优先独立文件；无则回退旧 prefs 并迁移。====
    // ====【诊断/v2】==== 把「读索引文件」与「逐条 fileSize 校验」分开计时：
    // RUN1 显示 validate=217ms 但同批文件后续 stat 只要几 ms，需定位真凶。
    final sw = Stopwatch()..start();
    final readSw = Stopwatch()..start();
    final raw = await _readIndexFile(_playCacheIndexFileName, _playCacheIndexKey);
    readSw.stop();
    if (raw == null || raw.isEmpty) {
      sw.stop();
      CacheDiagLogger.log(
        'load.playCacheIndex',
        'raw=empty readIndex=${readSw.elapsedMilliseconds}ms',
        ms: sw.elapsedMilliseconds,
      );
      return;
    }
    final validateSw = Stopwatch()..start();
    try {
      final list = jsonDecode(raw);
      if (list is! List) return;
      for (final item in list.whereType<Map<String, dynamic>>()) {
        final cacheKey = item['cacheKey'] as String? ?? '';
        final filePath = item['filePath'] as String?;
        if (filePath == null) continue;
        // 校验文件存在性
        final size = await _service.fileSize(filePath);
        if (size == 0) continue;
        final song = Song.fromCache(
          (item['song'] as Map).cast<String, dynamic>(),
        );
        final quality = AudioQuality.fromApiValue(item['quality'] as String?);
        final cachedAtStr = item['cachedAt'] as String?;
        _playCache[cacheKey] = PlayCacheEntry(
          cacheKey: cacheKey,
          song: song,
          quality: quality,
          filePath: filePath,
          size: size,
          cachedAt: cachedAtStr != null
              ? DateTime.tryParse(cachedAtStr) ?? DateTime.now()
              : DateTime.now(),
        );
      }
    } catch (_) {}
    validateSw.stop();
    sw.stop();
    CacheDiagLogger.log(
      'load.playCacheIndex',
      'valid=${_playCache.length} bytes=${raw.length} '
      'readIndex=${readSw.elapsedMilliseconds}ms '
      'validate=${validateSw.elapsedMilliseconds}ms',
      ms: sw.elapsedMilliseconds,
    );
  }

  /// 带诊断计时的 [DownloadService.fileSize] 包装（每个条目一次同步 stat）。
  Future<int> _fileSize(String path) async {
    final sw = Stopwatch()..start();
    final size = await _service.fileSize(path);
    sw.stop();
    CacheDiagLogger.log(
      'fileSize',
      'path=${path.split(Platform.pathSeparator).last} size=$size',
      ms: sw.elapsedMilliseconds,
    );
    return size;
  }

  Future<void> _persistDownloads() async {
    final list = _downloads.values
        .where((e) => e.status == DownloadStatus.downloaded)
        .map((e) => {
              'song': e.song.toCache(),
              'quality': e.quality.apiValue,
              'filePath': e.filePath,
              'downloadedAt': e.downloadedAt?.toIso8601String(),
            })
        .toList();
    // ====【修复/切歌卡顿·索引移出 prefs】原实现 prefs.setString 同步整写整个 prefs 文件
    // （实测 430ms 级阻塞）。改独立小文件 + File 异步写。====
    await _writeIndexFile(_downloadsIndexFileName, jsonEncode(list));
  }

  Future<void> _persistPlayCache() async {
    // ====【诊断/缓存清理卡顿】==== 索引 JSON 编码 + 异步写盘各计时（写盘在主 isolate 上）。
    final sw = Stopwatch()..start();
    final list = _playCache.values
        .map((e) => {
              'cacheKey': e.cacheKey,
              'song': e.song.toCache(),
              'quality': e.quality.apiValue,
              'filePath': e.filePath,
              'size': e.size,
              'cachedAt': e.cachedAt.toIso8601String(),
            })
        .toList();
    // ====【修复/切歌卡顿·索引移出 prefs】原实现 prefs.setString 同步整写（实测 ~430ms），
    // 且发生在"无缓存歌曲"的 cacheForPlayback 完成后 2~6 秒 —— 正是第二处小卡顿的来源。
    // 改独立小文件 + File 异步写。====
    final encodeSw = Stopwatch()..start();
    final json = jsonEncode(list);
    encodeSw.stop();
    final writeSw = Stopwatch()..start();
    await _writeIndexFile(_playCacheIndexFileName, json);
    writeSw.stop();
    sw.stop();
    CacheDiagLogger.log(
      'persist.playCacheIndex',
      'entries=${list.length} bytes=${json.length} '
      'encode=${encodeSw.elapsedMilliseconds}ms '
      'write=${writeSw.elapsedMilliseconds}ms',
      ms: sw.elapsedMilliseconds,
    );
  }

  // ====【修复/切歌卡顿·索引移出 prefs】索引文件读写（读取时兼容旧 prefs 并迁移）====
  static const _downloadsIndexFileName = 'downloads_index';
  static const _playCacheIndexFileName = 'play_cache_index';

  Future<File> _indexFile(String name) async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  Future<void> _writeIndexFile(String name, String data) async {
    try {
      final f = await _indexFile(name);
      await f.writeAsString(data);
    } catch (_) {}
  }

  /// 读取索引原始 JSON：独立文件优先；无则回退旧 prefs 值并当场迁移。
  ///
  /// ====【诊断/v2】==== RUN1 里 load.playCacheIndex=217ms、load.downloadsIndex=103ms，
  /// 但同批文件之后的 stat 只要几 ms，说明耗时不在校验循环。这里把
  /// 「定位文件 / 同步 existsSync / 异步 readAsString」三段拆开计时以定位真凶。
  Future<String?> _readIndexFile(String name, String legacyKey) async {
    final sw = Stopwatch()..start();
    var locateMs = 0;
    try {
      final locateSw = Stopwatch()..start();
      final f = await _indexFile(name);
      locateSw.stop();
      locateMs = locateSw.elapsedMilliseconds;
      final existsSw = Stopwatch()..start();
      final exists = f.existsSync();
      existsSw.stop();
      if (exists) {
        final readSw = Stopwatch()..start();
        final s = await f.readAsString();
        readSw.stop();
        CacheDiagLogger.log(
          'readIndexFile',
          'name=$name bytes=${s.length} locate=${locateMs}ms '
          'existsSync=${existsSw.elapsedMilliseconds}ms '
          'readAsString=${readSw.elapsedMilliseconds}ms',
          ms: sw.elapsedMilliseconds,
        );
        if (s.isNotEmpty) return s;
      } else {
        CacheDiagLogger.log(
          'readIndexFile',
          'name=$name exists=false（走 prefs 回退）',
          ms: sw.elapsedMilliseconds,
        );
      }
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      final old = prefs.getString(legacyKey);
      if (old != null && old.isNotEmpty) {
        try {
          await _writeIndexFile(name, old);
          await prefs.remove(legacyKey); // 迁移后清 prefs 旧值
        } catch (_) {}
        return old;
      }
    } catch (_) {}
    return null;
  }

  // ===== 查询 =====

  /// 返回本地文件路径：优先已下载 > 播放缓存（按当前音质）。无则 null。
  String? localPathFor(Song song, AudioQuality quality) {
    final key = _service.cacheKeyFor(song, quality);
    // 优先已下载（同音质）
    final download = _downloads[song.hash];
    if (download?.status == DownloadStatus.downloaded &&
        download?.filePath != null &&
        _service.cacheKeyFor(download!.song, download.quality) == key) {
      return download.filePath;
    }
    // 其次播放缓存
    final cache = _playCache[key];
    if (cache != null) {
      return cache.filePath;
    }
    return null;
  }

  bool isDownloaded(Song song) =>
      _downloads[song.hash]?.status == DownloadStatus.downloaded;

  DownloadEntry? entryFor(Song song) => _downloads[song.hash];

  List<Song> get downloadedSongs => _downloads.values
      .where((e) => e.status == DownloadStatus.downloaded)
      .map((e) => e.song)
      .toList();

  List<DownloadEntry> get downloadEntries =>
      _downloads.values.toList();

  List<PlayCacheEntry> get playCacheEntries => _playCache.values.toList();

  /// 获取下载目录大小（字节）。
  Future<int> getDownloadDirSize() => _service.getDownloadDirSize();

  /// 获取播放缓存目录大小（字节）。
  Future<int> getPlayCacheDirSize() => _service.getPlayCacheDirSize();

  // ===== 下载操作 =====

  /// 用户主动下载歌曲。
  Future<void> download(Song song, AudioQuality quality) async {
    final hash = song.hash;
    final existing = _downloads[hash];
    if (existing?.status == DownloadStatus.downloading) return;
    if (existing?.status == DownloadStatus.downloaded) return;

    _downloads[hash] = DownloadEntry(
      song: song,
      quality: quality,
      status: DownloadStatus.downloading,
      progress: 0,
    );
    notifyListeners();

    try {
      final playUrl = await _api.songUrl(song, quality: quality);
      if (playUrl.url.isEmpty) {
        throw Exception('这首歌暂时没有可播放地址');
      }
      await _transfer(song, quality, playUrl.url);
    } catch (error) {
      _downloads[hash] = DownloadEntry(
        song: song,
        quality: quality,
        status: DownloadStatus.failed,
        error: error.toString(),
      );
      notifyListeners();
    }
  }

  /// 批量下载：把一组歌曲一次性加入现有下载队列。
  ///
  /// - 已下载、正在下载的歌曲自动跳过；
  /// - 播放地址解析失败或无地址的歌曲进入失败列表，可单独重试；
  /// - 地址解析采用有限并发（4 路），避免一次性发起大量请求；
  /// - 文件传输复用 [DownloadService] 的并发队列（上限
  ///   [AppConfig.maxConcurrentDownloads]），支持进度与断点续传。
  Future<BatchDownloadResult> enqueueBatch(
    List<Song> songs,
    AudioQuality quality,
  ) async {
    const urlConcurrency = 4;
    var enqueued = 0;
    var skipped = 0;
    var failed = 0;
    var cursor = 0;

    Future<void> worker() async {
      while (cursor < songs.length) {
        final song = songs[cursor++];
        final hash = song.hash;
        final existing = _downloads[hash];
        if (existing?.status == DownloadStatus.downloading ||
            existing?.status == DownloadStatus.downloaded) {
          skipped++;
          continue;
        }

        _downloads[hash] = DownloadEntry(
          song: song,
          quality: quality,
          status: DownloadStatus.downloading,
          progress: 0,
        );
        notifyListeners();

        try {
          final playUrl = await _api.songUrl(song, quality: quality);
          if (playUrl.url.isEmpty) {
            _downloads[hash] = DownloadEntry(
              song: song,
              quality: quality,
              status: DownloadStatus.failed,
              error: '这首歌暂时没有可播放地址',
            );
            notifyListeners();
            failed++;
            continue;
          }
          enqueued++;
          unawaited(_transfer(song, quality, playUrl.url));
        } catch (error) {
          _downloads[hash] = DownloadEntry(
            song: song,
            quality: quality,
            status: DownloadStatus.failed,
            error: error.toString(),
          );
          notifyListeners();
          failed++;
        }
      }
    }

    final workerCount = songs.length < urlConcurrency
        ? songs.length
        : urlConcurrency;
    await Future.wait(
      [for (var i = 0; i < workerCount; i++) worker()],
    );
    return BatchDownloadResult(
      enqueued: enqueued,
      skipped: skipped,
      failed: failed,
    );
  }

  /// 文件传输（播放地址已解析）。成功后写入已下载索引，失败进入失败列表。
  Future<void> _transfer(Song song, AudioQuality quality, String url) async {
    final hash = song.hash;
    try {
      final path = await _service.download(
        song: song,
        quality: quality,
        url: url,
        onProgress: (received, total) {
          final progress = total > 0 ? received / total : 0.0;
          final entry = _downloads[hash];
          if (entry?.status == DownloadStatus.downloading) {
            _downloads[hash] = entry!.copyWith(progress: progress);
            notifyListeners();
          }
        },
      );
      _downloads[hash] = DownloadEntry(
        song: song,
        quality: quality,
        status: DownloadStatus.downloaded,
        progress: 1,
        filePath: path,
        downloadedAt: DateTime.now(),
      );
      notifyListeners();
      await _persistDownloads();
    } catch (error) {
      _downloads[hash] = DownloadEntry(
        song: song,
        quality: quality,
        status: DownloadStatus.failed,
        error: error.toString(),
      );
      notifyListeners();
    }
  }

  /// 移除一条失败记录（从失败列表清除）。
  void removeFailed(Song song) {
    final entry = _downloads[song.hash];
    if (entry?.status != DownloadStatus.failed) return;
    _downloads.remove(song.hash);
    notifyListeners();
  }

  /// 取消下载。
  Future<void> cancelDownload(Song song) async {
    final hash = song.hash;
    final entry = _downloads[hash];
    if (entry?.status != DownloadStatus.downloading) return;
    final key = _service.cacheKeyFor(song, entry!.quality);
    await _service.cancel(key);
    _downloads.remove(hash);
    notifyListeners();
  }

  /// 删除单个已下载歌曲。
  Future<void> deleteDownload(Song song) async {
    final hash = song.hash;
    final entry = _downloads[hash];
    if (entry?.filePath != null) {
      await _service.deleteFile(entry!.filePath!);
    }
    _downloads.remove(hash);
    notifyListeners();
    await _persistDownloads();
  }

  /// 清空所有已下载歌曲。
  Future<void> clearAllDownloads() async {
    for (final entry in _downloads.values) {
      if (entry.filePath != null) {
        await _service.deleteFile(entry.filePath!);
      }
    }
    _downloads.clear();
    notifyListeners();
    await _persistDownloads();
  }

  // ===== 播放缓存 =====

  /// 后台缓存当前播放歌曲（首播后调用）。url 来自 songUrl 结果。
  Future<void> cacheForPlayback(
    Song song,
    AudioQuality quality,
    String url,
  ) async {
    final key = _service.cacheKeyFor(song, quality);
    // 已有缓存或已在下载则跳过
    if (_playCache[key] != null) return;
    if (_downloads[song.hash]?.status == DownloadStatus.downloading) return;

    // ====【诊断/缓存清理卡顿】==== 触发点2：一首歌首播落盘后的整条链路。
    // 关键观察点：本方法结束时刻 = 切歌后 UI 正在恢复播放的时段，
    // 若此时 FRAME 行出现卡顿，即由下面的 prune/persist 造成。
    final sw = Stopwatch()..start();
    var stage = 'download';
    try {
      // 阶段A：下载 + 落盘校验（含同步文件头读取）
      final dlSw = Stopwatch()..start();
      final path = await _service.cacheForPlayback(
        song: song,
        quality: quality,
        url: url,
      );
      dlSw.stop();
      // 阶段B：落盘后取大小（同步 stat，走诊断包装）
      stage = 'fileSize';
      final sizeSw = Stopwatch()..start();
      final size = await _fileSize(path);
      sizeSw.stop();
      // 阶段C：更新索引 + 通知 UI
      stage = 'persist';
      _playCache[key] = PlayCacheEntry(
        cacheKey: key,
        song: song,
        quality: quality,
        filePath: path,
        size: size,
        cachedAt: DateTime.now(),
      );
      final notifySw = Stopwatch()..start();
      notifyListeners();
      notifySw.stop();
      final persistSw = Stopwatch()..start();
      await _persistPlayCache();
      persistSw.stop();
      // 阶段D：LRU 清理（本次新增文件本身被排除）
      stage = 'prune';
      final pruneSw = Stopwatch()..start();
      await _prunePlayCache(excludePaths: {path}, origin: 'cacheForPlayback');
      pruneSw.stop();
      sw.stop();
      CacheDiagLogger.log(
        'cacheForPlayback',
        'song=${song.title} hash=${song.hash} quality=${quality.apiValue} '
        'size=${(size / (1024 * 1024)).toStringAsFixed(1)}MB '
        'download=${dlSw.elapsedMilliseconds}ms '
        'sizeQuery=${sizeSw.elapsedMilliseconds}ms '
        'notify=${notifySw.elapsedMilliseconds}ms '
        'persist=${persistSw.elapsedMilliseconds}ms '
        'prune=${pruneSw.elapsedMilliseconds}ms',
        ms: sw.elapsedMilliseconds,
      );
    } catch (error) {
      sw.stop();
      // 播放缓存失败静默忽略（仅记录诊断）
      CacheDiagLogger.log(
        'cacheForPlayback',
        'failed stage=$stage song=${song.title} hash=${song.hash} '
        'error=${error.toString().split('\n').first}',
        ms: sw.elapsedMilliseconds,
      );
    }
  }

  /// 清空所有播放缓存。
  Future<void> clearPlayCache() async {
    // ====【诊断/缓存清理卡顿】==== 触发点4a：设置页/缓存管理"清空播放缓存"。
    final sw = Stopwatch()..start();
    final deleted = _playCache.length;
    await _service.clearPlayCacheDir();
    _playCache.clear();
    notifyListeners();
    await _persistPlayCache();
    sw.stop();
    CacheDiagLogger.log(
      'ui.clearPlayCache',
      'indexEntriesCleared=$deleted',
      ms: sw.elapsedMilliseconds,
    );
  }

  /// 删除单首播放缓存。
  Future<void> deletePlayCache(Song song, AudioQuality quality) async {
    final key = _service.cacheKeyFor(song, quality);
    final entry = _playCache[key];
    if (entry != null) {
      // ====【诊断/缓存清理卡顿】==== 触发点4b：单首删除（歌曲页/换源自愈会调用）。
      final sw = Stopwatch()..start();
      await _service.deleteFile(entry.filePath);
      _playCache.remove(key);
      notifyListeners();
      await _persistPlayCache();
      sw.stop();
      CacheDiagLogger.log(
        'ui.deletePlayCache',
        'song=${song.title} hash=${song.hash}',
        ms: sw.elapsedMilliseconds,
      );
    }
  }

  Future<void> _prunePlayCache({
    Set<String> excludePaths = const {},
    String origin = 'unknown',
  }) async {
    // ====【诊断/缓存清理卡顿】==== 一次清理共三段主 isolate 工作：
    //   ①构造+排序索引（内存）②service.prunePlayCache（全量同步 stat + 删除）
    //   ③清理后逐条再校验一遍（又一次全量同步 stat）—— ③ 是最容易被忽略的第二遍扫描。
    final totalSw = Stopwatch()..start();
    final buildSw = Stopwatch()..start();
    final entries = _playCache.values
        .map((e) => (
              cacheKey: e.cacheKey,
              filePath: e.filePath,
              cachedAt: e.cachedAt,
            ))
        .toList()
      ..sort((a, b) => a.cachedAt.compareTo(b.cachedAt));
    buildSw.stop();

    final serviceSw = Stopwatch()..start();
    final result = await _service.prunePlayCache(
      entries,
      maxBytes: _playCacheLimit,
      excludePaths: excludePaths,
      origin: origin,
    );
    serviceSw.stop();

    final verifySw = Stopwatch()..start();
    // 清理后校验索引，移除已删除的条目
    final toRemove = <String>[];
    for (final entry in _playCache.values) {
      final size = await _service.fileSize(entry.filePath);
      if (size == 0 && !excludePaths.contains(entry.filePath)) {
        toRemove.add(entry.cacheKey);
      }
    }
    verifySw.stop();

    final persistSw = Stopwatch()..start();
    if (toRemove.isNotEmpty) {
      for (final key in toRemove) {
        _playCache.remove(key);
      }
      notifyListeners();
      await _persistPlayCache();
    }
    persistSw.stop();
    totalSw.stop();

    CacheDiagLogger.log(
      'prune.controller',
      'origin=$origin entries=${entries.length} '
      'serviceScanned=${result.scannedEntries} '
      'deleted=${result.deletedCount} removedFromIndex=${toRemove.length} '
      'excludedSkip=${result.skippedExcluded} '
      'buildIndex=${buildSw.elapsedMilliseconds}ms '
      'service=${serviceSw.elapsedMilliseconds}ms '
      'verifySweep=${verifySw.elapsedMilliseconds}ms(第二遍全量 stat, '
      '${_playCache.length} 条) '
      'persist=${persistSw.elapsedMilliseconds}ms',
      ms: totalSw.elapsedMilliseconds,
    );
  }
}
