import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/services/startup_diag_logger.dart';

/// ====【诊断/冷启动】==== 启动日志器冒烟测试（诊断期临时文件，验证完可删）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('startFrameMonitor 写文件并产出 startup./native./win.play 行', () async {
    StartupDiagLogger.markAppStart();
    StartupDiagLogger.phase('smokePhase', ms: 12, note: '中文备注');
    StartupDiagLogger.native('createEqualizer', ms: 7, note: 'sessionId=1');
    StartupDiagLogger.play('PLAY_CALL levelAtCall=0 stateAtCall=playing', ms: 3);
    await StartupDiagLogger.flush();

    final path = await StartupDiagLogger.resolveLogPath();
    expect(path, isNotNull, reason: '应解析出日志路径');
    final text = File(path!).readAsStringSync();
    print('---- 启动日志 ----');
    print(text);
    print('---- 结束 ----');

    expect(text, contains('STARTUP DIAG'));
    expect(text, contains('region=startup.smokePhase'));
    expect(text, contains('ms=12'));
    expect(text, contains('中文备注'));
    expect(text, contains('region=native.createEqualizer'));
    expect(text, contains('region=win.play'));
  });
}
