import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/services/cache_diag_logger.dart';

/// ====【诊断/缓存清理卡顿】==== 日志器冒烟测试。
///
/// 目的只有一个：确认日志文件真的会生成、行格式与埋点调用处一致，
/// 免得实机测完才发现日志是空的或字段对不上。
/// 该文件是诊断期临时产物，功能验证完成后可删除。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('startFrameMonitor 生成日志文件并写入 HEADER/LOGPATH', () async {
    final path = await CacheDiagLogger.startFrameMonitor();
    expect(path, isNotNull, reason: '应返回日志文件路径');

    final f = File(path!);
    expect(f.existsSync(), isTrue, reason: '日志文件应已创建');

    CacheDiagLogger.log('smoke', 'hello 中文', ms: 7);
    await CacheDiagLogger.flushSummary();

    final text = f.readAsStringSync();
    print('---- 日志内容 ----');
    print(text);
    print('---- 结束 ----');

    expect(text, contains('HEADER'), reason: '缺少启动头');
    expect(text, contains('LOGPATH='), reason: '缺少 LOGPATH 便于定位');
    expect(text, contains('region=smoke'), reason: '缺少 region 字段');
    expect(text, contains('ms=7'), reason: '缺少 ms 字段');
    expect(text, contains('hello 中文'), reason: '中文 note 应原样落盘');
    expect(text, contains('SUMMARY region=smoke count=1'), reason: '缺少汇总聚合');
    expect(
      text,
      matches(RegExp(r'\[CACHE_DIAG\] t=\d+ms run=\d+ region=smoke ms=7')),
      reason: 'CACHE_DIAG 行格式不符合预期',
    );
  });

  test('二次启动会轮转上一次日志为 .1.log', () async {
    final first = await CacheDiagLogger.startFrameMonitor();
    expect(first, isNotNull);
    CacheDiagLogger.log('rotate', 'first-run');
    await CacheDiagLogger.flushSummary();

    final second = await CacheDiagLogger.startFrameMonitor();
    expect(second, isNotNull);

    final rotated = File('${first!}.1.log');
    // 轮转目标名是固定后缀，这里按目录重新定位更稳妥。
    final dir = File(first).parent;
    final rotatedName = '${dir.path}${Platform.pathSeparator}'
        'ka_music_cache_diag.1.log';
    final candidates = [File(rotatedName), rotated];
    final exists = candidates.any((c) => c.existsSync());
    expect(exists, isTrue, reason: '上一次日志应被轮转为 .1.log');
    if (File(rotatedName).existsSync()) {
      expect(File(rotatedName).readAsStringSync(), contains('first-run'));
    }
  });
}
