import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../config/app_config.dart';
import '../models/music_models.dart';
import 'cache_diag_logger.dart'; // ====【诊断/缓存清理卡顿】====

/// 下载任务类型。
enum DownloadTaskKind { download, playCache }

/// ====【诊断/缓存清理卡顿】==== 一次 LRU 清理的结果快照。
///
/// 仅用于把"扫了多少 / 删了多少 / 删完还剩多少"回传给调用方写日志，
/// 不参与任何业务判定（业务仍以索引 + 磁盘实际状态为准）。
class PruneResult {
  const PruneResult({
    required this.scannedBytes,
    required this.scannedEntries,
    required this.deletedCount,
    required this.deletedBytes,
    required this.remainingBytes,
    required this.skippedExcluded,
    required this.unlimited,
  });

  /// 扫描时统计到的总字节数。
  final int scannedBytes;

  /// 参与扫描的索引条目数。
  final int scannedEntries;

  /// 实际删除的文件数。
  final int deletedCount;

  /// 实际删除的字节数。
  final int deletedBytes;

  /// 清理结束后的剩余字节数。
  final int remainingBytes;

  /// 因"正在播放/excludePaths"被跳过的条目数。
  final int skippedExcluded;

  /// 是否配置为"无限制"。
  final bool unlimited;
}

/// 内部待执行任务。
class _PendingTask {
  _PendingTask({
    required this.kind,
    required this.song,
    required this.quality,
    required this.url,
    required this.completer,
    this.onProgress,
  });

  final DownloadTaskKind kind;
  final Song song;
  final AudioQuality quality;
  final String url;
  final Completer<String> completer;
  final void Function(int received, int total)? onProgress;
}

/// 歌曲下载服务（IO 层 + dio 下载 + 并发管理）。
///
/// 下载到持久目录（用户主动下载），播放缓存到临时目录（系统可清理）。
/// 两者共享并发上限，用户主动下载优先。
class DownloadService {
  DownloadService();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(minutes: 10),
  ));
  final Map<String, CancelToken> _cancelTokens = {};
  final int _maxConcurrent = AppConfig.maxConcurrentDownloads;
  int _running = 0;
  final List<_PendingTask> _queue = [];

  /// 持久下载目录。
  ///
  /// Android 优先使用系统公共下载目录（/storage/emulated/0/Download/KA Music），
  /// 需要存储权限；其他平台或获取失败时回退到应用文档目录。
  Future<Directory> downloadDir() async {
    if (Platform.isAndroid) {
      try {
        // Android 11+ 需要 MANAGE_EXTERNAL_STORAGE 权限才能写入公共目录
        // Android 10 及以下需要 WRITE_EXTERNAL_STORAGE
        final hasPermission = await _requestStoragePermission();
        if (hasPermission) {
          final dir = Directory('/storage/emulated/0/Download/${AppConfig.downloadDirName}');
          if (!dir.existsSync()) {
            await dir.create(recursive: true);
          }
          return dir;
        }
      } catch (e) {
        debugPrint('[KA Music] Failed to access public Download dir: $e');
      }
    }
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/${AppConfig.downloadDirName}');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 请求存储写入权限。
  Future<bool> _requestStoragePermission() async {
    if (Platform.isAndroid) {
      // Android 11+ (API 30+): 需要 MANAGE_EXTERNAL_STORAGE
      if (await Permission.manageExternalStorage.isGranted) {
        return true;
      }
      // 先尝试请求普通写入权限（Android 10 及以下）
      if (await Permission.storage.isGranted) {
        return true;
      }
      // 请求 manageExternalStorage（Android 11+）
      final status = await Permission.manageExternalStorage.request();
      if (status.isGranted) return true;
      // 回退请求普通存储权限
      final storageStatus = await Permission.storage.request();
      return storageStatus.isGranted;
    }
    return true;
  }

  /// 临时播放缓存目录。
  Future<Directory> playCacheDir() async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/${AppConfig.playCacheDirName}');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 文件命名：{歌手}-{歌曲名}.{ext}
  String fileNameFor(Song song, AudioQuality quality) {
    final ext = quality == AudioQuality.lossless ? 'flac' : 'mp3';
    final safeArtist = _sanitizeFileName(song.artist);
    final safeTitle = _sanitizeFileName(song.title);
    final name = (safeArtist.isNotEmpty && safeTitle.isNotEmpty)
        ? '$safeArtist-$safeTitle'
        : song.hash.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    return '$name.$ext';
  }

  /// 移除文件名中不合法的字符。
  String _sanitizeFileName(String name) {
    // 替换文件系统不允许的字符：\ / : * ? " < > |
    return name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceFirst(RegExp(r'^_+'), '')
        .replaceFirst(RegExp(r'_+$'), '')
        .trim();
  }

  /// 缓存 key：{hash}_{quality.apiValue}
  String cacheKeyFor(Song song, AudioQuality quality) {
    final safeHash = song.hash.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    return '${safeHash}_${quality.apiValue}';
  }

  /// 下载到持久目录（用户下载）。支持断点续传。
  ///
  /// [onProgress] 回调 (received, total)。返回最终文件路径。
  Future<String> download({
    required Song song,
    required AudioQuality quality,
    required String url,
    required void Function(int received, int total) onProgress,
  }) async {
    final completer = Completer<String>();
    final task = _PendingTask(
      kind: DownloadTaskKind.download,
      song: song,
      quality: quality,
      url: url,
      completer: completer,
      onProgress: onProgress,
    );
    _enqueue(task);
    return completer.future;
  }

  /// 下载到临时缓存目录（播放缓存）。无进度上报（静默）。
  Future<String> cacheForPlayback({
    required Song song,
    required AudioQuality quality,
    required String url,
  }) async {
    final completer = Completer<String>();
    final task = _PendingTask(
      kind: DownloadTaskKind.playCache,
      song: song,
      quality: quality,
      url: url,
      completer: completer,
    );
    _enqueue(task);
    return completer.future;
  }

  void _enqueue(_PendingTask task) {
    // 用户下载优先：插入队列头部之后（在其它下载任务之后、播放缓存之前）
    if (task.kind == DownloadTaskKind.download) {
      // 插入到第一个 playCache 任务之前
      final firstPlayCache = _queue
          .indexWhere((t) => t.kind == DownloadTaskKind.playCache);
      if (firstPlayCache >= 0) {
        _queue.insert(firstPlayCache, task);
      } else {
        _queue.add(task);
      }
    } else {
      _queue.add(task);
    }
    _processQueue();
  }

  Future<void> _processQueue() async {
    if (_running >= _maxConcurrent) return;
    if (_queue.isEmpty) return;

    final task = _queue.removeAt(0);
    _running++;

    try {
      final path = await _executeTask(task);
      task.completer.complete(path);
    } catch (error) {
      task.completer.completeError(error);
    } finally {
      _running--;
      _processQueue();
    }
  }

  Future<String> _executeTask(_PendingTask task) async {
    final key = cacheKeyFor(task.song, task.quality);
    final fileName = fileNameFor(task.song, task.quality);
    final dir = task.kind == DownloadTaskKind.download
        ? await downloadDir()
        : await playCacheDir();
    final targetPath = '${dir.path}/$fileName';
    final partPath = '$targetPath.part';
    final cancelToken = CancelToken();
    _cancelTokens[key] = cancelToken;

    try {
      // 断点续传：检查已有 .part 文件大小
      int startOffset = 0;
      final partFile = File(partPath);
      if (partFile.existsSync()) {
        startOffset = await partFile.length();
      }

      final headers = <String, dynamic>{};
      if (startOffset > 0) {
        headers[HttpHeaders.rangeHeader] = 'bytes=$startOffset-';
      }

      await _dio.download(
        task.url,
        partPath,
        onReceiveProgress: (received, total) {
          final actualTotal = startOffset + total;
          final actualReceived = startOffset + received;
          task.onProgress?.call(actualReceived, actualTotal);
        },
        options: Options(headers: headers),
        cancelToken: cancelToken,
        deleteOnError: false,
      );

      // 下载完成，重命名 .part 为最终文件
      if (partFile.existsSync()) {
        await partFile.rename(targetPath);
      }

      // ===== 【自愈】播放缓存音频有效性校验（防污染） =====
      // 某些在线源(如失效的网易云外链)实际返回的是网页(HTML)而非音频，若被
      // 缓存成 .flac 会永久导致该歌解码失败、播放卡死。落盘后校验文件头是否为
      // 有效音频；非音频则删除缓存抛错，避免污染播放缓存（用户下载不受影响）。
      // ====【诊断/缓存清理卡顿】==== 落盘校验是同步文件头读取，单独计时。
      final audioCheckSw = Stopwatch()..start();
      final audioValid = task.kind == DownloadTaskKind.playCache
          ? _isAudioFile(targetPath)
          : true;
      audioCheckSw.stop();
      if (task.kind == DownloadTaskKind.playCache) {
        CacheDiagLogger.log(
          'audioCheck',
          'path=${targetPath.split(Platform.pathSeparator).last} valid=$audioValid',
          ms: audioCheckSw.elapsedMilliseconds,
        );
      }
      if (task.kind == DownloadTaskKind.playCache && !audioValid) {
        final bad = File(targetPath);
        if (bad.existsSync()) {
          await bad.delete();
        }
        throw Exception('播放缓存非有效音频，已丢弃：${task.url}');
      }

      return targetPath;
    } finally {
      _cancelTokens.remove(key);
    }
  }

  /// 判断文件头是否为常见音频格式（FLAC / M4A / MP3(含 ID3) / ADTS AAC）。
  /// 用于拦截把网页(HTML)等非音频内容误当成音频缓存的情况。
  bool _isAudioFile(String path) {
    try {
      final raf = File(path).openSync();
      List<int> head;
      try {
        head = raf.readSync(8);
      } finally {
        try {
          raf.closeSync();
        } catch (_) {}
      }
      if (head.length < 4) return false;
      final isFlac = head[0] == 0x66 && head[1] == 0x4c && head[2] == 0x61 &&
          head[3] == 0x43; // "fLaC"
      final isM4a = head.length >= 8 && head[4] == 0x66 && head[5] == 0x74 &&
          head[6] == 0x79 && head[7] == 0x70; // "ftyp"
      final isId3 = head[0] == 0x49 && head[1] == 0x44 &&
          head[2] == 0x33; // "ID3"
      final isMp3 = head[0] == 0xff && (head[1] & 0xe0) == 0xe0;
      final isAac = head[0] == 0xff && (head[1] & 0xf0) == 0xf0;
      return isFlac || isM4a || isId3 || isMp3 || isAac;
    } catch (_) {
      return false;
    }
  }

  /// 取消下载/缓存任务。
  Future<void> cancel(String cacheKey) async {
    final token = _cancelTokens[cacheKey];
    if (token != null && !token.isCancelled) {
      token.cancel();
    }
  }

  /// 删除文件（若存在）。
  Future<void> deleteFile(String path) async {
    final sw = Stopwatch()..start();
    try {
      final file = File(path);
      if (file.existsSync()) {
        await file.delete();
      }
    } catch (_) {
    } finally {
      // ====【诊断/缓存清理卡顿】==== 删除是同步阻塞点，单次耗时全量记录（便于统计）。
      sw.stop();
      CacheDiagLogger.log(
        'deleteFile',
        'path=${path.split(Platform.pathSeparator).last}',
        ms: sw.elapsedMilliseconds,
      );
    }
  }

  /// 获取文件大小（字节），不存在返回 0。
  Future<int> fileSize(String path) async {
    final file = File(path);
    if (file.existsSync()) {
      return await file.length();
    }
    return 0;
  }

  /// 获取下载目录的总大小（字节）。
  Future<int> getDownloadDirSize() async {
    final sw = Stopwatch()..start();
    var files = 0;
    try {
      final dir = await downloadDir();
      if (!dir.existsSync()) return 0;
      var total = 0;
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is File) {
          total += entity.lengthSync();
          files++;
        }
      }
      return total;
    } catch (_) {
      return 0;
    } finally {
      // ====【诊断/缓存清理卡顿】==== listSync(recursive)+lengthSync 全程同步，务必计时。
      sw.stop();
      CacheDiagLogger.log(
        'getDownloadDirSize',
        'files=$files（同步 listSync+lengthSync）',
        ms: sw.elapsedMilliseconds,
      );
    }
  }

  /// 获取播放缓存目录的总大小（字节）。
  Future<int> getPlayCacheDirSize() async {
    final sw = Stopwatch()..start();
    var files = 0;
    try {
      final dir = await playCacheDir();
      if (!dir.existsSync()) return 0;
      var total = 0;
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is File) {
          total += entity.lengthSync();
          files++;
        }
      }
      return total;
    } catch (_) {
      return 0;
    } finally {
      // ====【诊断/缓存清理卡顿】==== 打开设置页「缓存管理」时会走这里，全程同步。
      sw.stop();
      CacheDiagLogger.log(
        'getPlayCacheDirSize',
        'files=$files（同步 listSync+lengthSync）',
        ms: sw.elapsedMilliseconds,
      );
    }
  }

  /// 清空整个播放缓存目录。
  Future<void> clearPlayCacheDir() async {
    // ====【诊断/缓存清理卡顿】==== 手动"清空播放缓存"整段计时。
    final sw = Stopwatch()..start();
    var files = 0;
    try {
      final dir = await playCacheDir();
      if (dir.existsSync()) {
        await for (final entity in dir.list()) {
          if (entity is File) {
            await entity.delete();
            files++;
          }
        }
      }
    } finally {
      sw.stop();
      CacheDiagLogger.log(
        'clearPlayCacheDir',
        'deleted=$files',
        ms: sw.elapsedMilliseconds,
      );
    }
  }

  /// LRU 清理播放缓存至 [maxBytes]（默认 [AppConfig.playCacheMaxBytes]）以下。
  ///
  /// [entries] 为当前缓存索引（按 cachedAt 升序排列）。
  /// [excludePaths] 中的文件跳过清理（如正在播放的文件）。
  ///
  /// ====【诊断/缓存清理卡顿】==== 返回值用于把"清理到底做了什么"回传给控制器，
  /// 便于日志区分"只扫描不删除"与"真的删了文件"两种情形。
  Future<PruneResult> prunePlayCache(
    List<({String cacheKey, String filePath, DateTime cachedAt})> entries, {
    int? maxBytes,
    Set<String> excludePaths = const {},
    String origin = 'unknown',
  }) async {
    final totalSw = Stopwatch()..start();

    // ===== 阶段1：全量 stat（每条一次 existsSync + lengthSync）=====
    final scanSw = Stopwatch()..start();
    int totalSize = 0;
    final fileSizes = <String, int>{};
    for (final entry in entries) {
      final size = await fileSize(entry.filePath);
      fileSizes[entry.filePath] = size;
      totalSize += size;
    }
    scanSw.stop();
    // 扫描完成时的总字节（删除过程中 totalSize 会递减，这里留一份原始值供日志/返回用）。
    final scannedBytes = totalSize;

    final limit = maxBytes ?? AppConfig.playCacheMaxBytes;
    // 小于 0 代表无限制
    if (limit < 0) {
      totalSw.stop();
      CacheDiagLogger.log(
        'prune.total',
        'origin=$origin result=unlimited entries=${entries.length} '
        'scanned=${fileSizes.length} totalBytes=$totalSize',
        ms: totalSw.elapsedMilliseconds,
      );
      CacheDiagLogger.log(
        'prune.scan',
        'origin=$origin entries=${entries.length} totalBytes=$totalSize',
        ms: scanSw.elapsedMilliseconds,
      );
      return PruneResult(
        scannedBytes: totalSize,
        scannedEntries: entries.length,
        deletedCount: 0,
        deletedBytes: 0,
        remainingBytes: totalSize,
        skippedExcluded: 0,
        unlimited: true,
      );
    }

    final needDelete = totalSize > limit;
    final deleteSw = Stopwatch()..start();
    var deletedCount = 0;
    var deletedBytes = 0;
    var skippedExcluded = 0;
    if (needDelete) {
      // 按 cachedAt 升序删除最旧条目
      final sorted = List.of(entries)
        ..sort((a, b) => a.cachedAt.compareTo(b.cachedAt));

      for (final entry in sorted) {
        if (totalSize <= limit) break;
        if (excludePaths.contains(entry.filePath)) {
          skippedExcluded++;
          continue;
        }
        final size = fileSizes[entry.filePath] ?? 0;
        await deleteFile(entry.filePath);
        totalSize -= size;
        deletedCount++;
        deletedBytes += size;
      }
    }
    deleteSw.stop();
    if (needDelete) {
      // 阶段2：删除（每条一次同步 existsSync+delete），单独记一行便于定位卡顿归属。
      CacheDiagLogger.log(
        'prune.delete',
        'origin=$origin deleted=$deletedCount '
        'deletedBytes=${_mb(deletedBytes)} excludedSkip=$skippedExcluded',
        ms: deleteSw.elapsedMilliseconds,
      );
    }
    totalSw.stop();

    // ===== 每个触发点一条总账，便于和 FRAME 卡顿行按 t= 对齐 =====
    CacheDiagLogger.log(
      'prune.total',
      'origin=$origin needDelete=$needDelete entries=${entries.length} '
      'scannedBytes=${_mb(scannedBytes)} limit=${_mb(limit)} '
      'deleted=$deletedCount deletedBytes=${_mb(deletedBytes)} '
      'remaining=${_mb(scannedBytes - deletedBytes)} '
      'excludedSkip=$skippedExcluded',
      ms: totalSw.elapsedMilliseconds,
    );
    return PruneResult(
      scannedBytes: scannedBytes,
      scannedEntries: entries.length,
      deletedCount: deletedCount,
      deletedBytes: deletedBytes,
      remainingBytes: scannedBytes - deletedBytes,
      skippedExcluded: skippedExcluded,
      unlimited: false,
    );
  }

  /// 字节转 MB 字符串（诊断日志用，保留 1 位小数）。
  String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

  /// 关闭 Dio（应用退出时调用）。
  void dispose() {
    _dio.close();
  }
}
