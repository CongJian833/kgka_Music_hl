import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../controllers/auth_controller.dart';
import '../controllers/player_controller.dart';

/// 关闭窗口时的行为。
enum CloseBehavior { hideToTray, quit }

/// 桌面集成控制器（Windows 平台）。
///
/// 负责：
/// - 系统托盘图标 + 右键菜单（播放/暂停、上/下曲、收藏、显示窗口、退出）
/// - 关闭窗口行为（收托盘 / 直接退出，可配置）
/// - 开机自启动（写入 HKCU Run 键；F11/Esc 由 ShortcutHandler 处理）
/// - 仅 Windows 启用；Android/其他平台 isSupported=false，attach 不生效。
class DesktopController extends ChangeNotifier with WindowListener, TrayListener {
  DesktopController._();

  static DesktopController? _instance;
  static DesktopController get instance => _instance ??= DesktopController._();

  static const _closeBehaviorKey = 'desktop.close_behavior';
  static const _launchAtStartupKey = 'desktop.launch_at_startup';
  static const _trayAssetPath = 'lib/assets/tray_icon.ico';

  // ===== 试用开关：是否用官方 AppLifecycleListener.onExitRequested 接管"窗口关闭退出" =====
// 【Windows 实测结论】onExitRequested 在此的 window_manager + setPreventClose(false)
// 组合下未能可靠让进程退出（窗口关了、音乐继续、后台进程残留），故已回退为 false，
// 走原 window_manager 的 onWindowClose + _quit 流程（完整保留在下）。相关 onExitRequested
// 代码一并保留，待将来需要/平台支持再试；只要改回 true 重建即可。
// true  → 用 onExitRequested 统一处理（当前 Windows 下不推荐，见上）。
// false → 回退到原 onWindowClose + _quit，并在 _quit 末尾用 exit(0) 兜底强制进程退出。
static const bool _useOnExitRequested = false;

  PlayerController? _player;
  AuthController? _auth;
  bool _attached = false;
  bool _isQuitting = false;
  String? _lastMenuFingerprint;
  AppLifecycleListener? _lifecycle;

  /// 托盘菜单是否正在跟踪中（已弹出且未关闭），用于抑制重复弹出。
  bool _trayMenuOpen = false;

  CloseBehavior _closeBehavior = CloseBehavior.hideToTray;
  bool _launchAtStartup = false;

  CloseBehavior get closeBehavior => _closeBehavior;
  bool get launchAtStartup => _launchAtStartup;
  /// 仅 Windows 平台启用托盘能力。
  bool get isSupported => Platform.isWindows;

  PlayerController? get player => _player;

  /// 初始化桌面能力。应在 ensureInitialized 后、runApp 前调用一次。
  /// 非 Windows 平台直接返回，不影响 Android 等。
  Future<void> attach(PlayerController? player, AuthController? auth) async {
    if (!Platform.isWindows || _attached) return;
    _player = player;
    _auth = auth;
    _attached = true;

    final prefs = await SharedPreferences.getInstance();
    final closeVal = prefs.getInt(_closeBehaviorKey);
    _closeBehavior = closeVal == CloseBehavior.quit.index
        ? CloseBehavior.quit
        : CloseBehavior.hideToTray;
    _launchAtStartup = prefs.getBool(_launchAtStartupKey) ?? false;

    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    if (_useOnExitRequested) {
      // onExitRequested 试用：不再用 window_manager 手动拦截关闭，把关闭交给 Flutter
      // 框架的退出请求(onExitRequested)统一处理（见 _onExitRequested）。
      await windowManager.setPreventClose(false);
      _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);
    } else {
      // 原方案：拦截关闭，由本控制器根据设置决定收托盘或退出。
      await windowManager.setPreventClose(true);
    }
    await windowManager.waitUntilReadyToShow();
    // ===== 沉浸式窗口：隐藏系统标题栏，改用自绘 WindowTitleBar（窗口控制按钮）=====
    // 隐藏后需由 Flutter 侧自绘顶栏承载最小化/最大化/关闭（见 lib/ui/widgets/window_title_bar.dart
    // 与 main.dart 的 MaterialApp.builder 挂载），并用 DragToMoveArea 提供拖拽移动。
    try {
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: true,
      );
    } catch (_) {}
    // window_manager 在 waitUntilReadyToShow 后默认不显示窗口，
    // 需显式 show() 主窗口才会出现在桌面上（否则只有托盘图标、无主界面）。
    await windowManager.show();

    await _initTray();

    _player?.addListener(_onPlayerChanged);
    _auth?.addListener(_onAuthChanged);
  }

  /// Windows 端托盘图标仅支持文件系统路径，因此先把 assets 里的图标落到临时目录。
  Future<String?> _resolveTrayIconPath() async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}ka_music_tray.ico');
      if (!await file.exists()) {
        final data = await rootBundle.load(_trayAssetPath);
        await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      }
      return file.path;
    } catch (_) {
      return null;
    }
  }

  Future<void> _initTray() async {
    TrayManager.instance.addListener(this);
    final iconPath = await _resolveTrayIconPath();
    if (iconPath != null) {
      await TrayManager.instance.setIcon(iconPath);
    }
    await TrayManager.instance.setToolTip('KA Music');
    await _refreshTrayMenu();
  }

  Future<void> _refreshTrayMenu() async {
    if (!_attached) return;
    final player = _player;
    final hasSong = player?.currentSong != null;
    final hasQueue = (player?.queue.length ?? 0) >= 2;
    final playing = player?.isPlaying ?? false;
    final liked = hasSong && (_auth?.isLiked(player!.currentSong!) ?? false);

    // 指纹缓存：仅当菜单动态显示内容变化时才重建托盘菜单，避免右键菜单跟踪期间被反复重建产生闪烁。
    final fingerprint = '$playing|$hasSong|$hasQueue|$liked';
    if (fingerprint == _lastMenuFingerprint) return;
    _lastMenuFingerprint = fingerprint;

    final menu = Menu(items: [
      MenuItem(key: 'show', label: '显示主界面'),
      MenuItem.separator(),
      MenuItem(key: 'play', label: '播放'),
      MenuItem(key: 'prev', label: '上一曲'),
      MenuItem(key: 'next', label: '下一曲'),
      MenuItem(key: 'like', label: '收藏'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: '退出'),
    ]);

    _applyDynamicMenuState(menu, hasSong: hasSong, hasQueue: hasQueue,
        playing: playing, liked: liked);

    await TrayManager.instance.setContextMenu(menu);
  }

  /// 根据播放器当前状态更新菜单项的 disabled 与 label（播放/暂停、收藏/取消收藏等）。
  void _applyDynamicMenuState(Menu menu,
      {required bool hasSong,
      required bool hasQueue,
      required bool playing,
      required bool liked}) {
    final play = menu.getMenuItem('play');
    if (play != null) {
      play.disabled = !hasSong;
      play.label = playing ? '暂停' : '播放';
    }
    final prev = menu.getMenuItem('prev');
    if (prev != null) prev.disabled = !hasQueue;
    final next = menu.getMenuItem('next');
    if (next != null) next.disabled = !hasQueue;
    final like = menu.getMenuItem('like');
    if (like != null) {
      like.disabled = !hasSong;
      like.label = liked ? '取消收藏' : '收藏';
    }
  }

  /// 执行一个菜单操作：先清理"菜单跟踪中"标记，操作完成后刷新菜单保持数据同步。
  Future<void> _runMenuAction(Future<void> Function() action) async {
    _trayMenuOpen = false;
    try {
      await action();
    } catch (_) {
      // 菜单操作异常（如网络）静默忽略，避免弹错。
    } finally {
      await _refreshTrayMenu();
    }
  }

  /// 托盘菜单项点击派发：通过 key 定位操作，执行后刷新菜单状态。
  void _onMenuItemClick(String key) {
    if (_isQuitting) return;
    final player = _player;
    switch (key) {
      case 'show':
        unawaited(_runMenuAction(_showWindow));
        break;
      case 'play':
        if (player != null) {
          unawaited(_runMenuAction(() => player.togglePlay()));
        }
        break;
      case 'prev':
        if (player != null) {
          unawaited(_runMenuAction(() => player.skipToPrevious()));
        }
        break;
      case 'next':
        if (player != null) {
          unawaited(_runMenuAction(() => player.skipToNext()));
        }
        break;
      case 'like':
        unawaited(_runMenuAction(_toggleLike));
        break;
      case 'quit':
        unawaited(_quit());
        break;
      default:
        break;
    }
  }

  void _onPlayerChanged() => unawaited(_refreshTrayMenu());
  void _onAuthChanged() => unawaited(_refreshTrayMenu());

  Future<void> _toggleLike() async {
    final auth = _auth;
    final song = _player?.currentSong;
    if (auth == null || song == null) return;
    try {
      await auth.toggleLike(song);
    } catch (_) {} // 网络失败等，保持原菜单状态。
  }

  // ====== WindowListener ======
  @override
  void onWindowClose() {
    if (_useOnExitRequested) {
      // onExitRequested 试用：交由 AppLifecycleListener.onExitRequested 统一处理，
      // 这里不再手动接管关闭（否则会与框架退出请求重复）。
      return;
    }
    if (_closeBehavior == CloseBehavior.quit) {
      unawaited(_quit());
    } else {
      unawaited(_hideToTray());
    }
  }

  /// ===== 试用方案：官方 AppLifecycleListener.onExitRequested =====
  /// Flutter 在"可取消的退出请求"（如关闭窗口）时回调此函数。据此统一处理：
  ///   * hideToTray：返回 cancel（不退出），并把窗口隐藏到托盘；
  ///   * quit：先 await 做持久化/暂停/托盘清理，再返回 exit，由框架退出、窗口随之关闭。
  /// 相比原 window_manager 手动 onWindowClose 流程，这是官方标准的"退出前清理"接入。
  Future<AppExitResponse> _onExitRequested() async {
    if (_isQuitting) return AppExitResponse.exit;
    if (_closeBehavior == CloseBehavior.hideToTray) {
      unawaited(_hideToTray());
      return AppExitResponse.cancel;
    }
    await _cleanupForExit();
    return AppExitResponse.exit;
  }

  /// 退出前的公共清理：持久化状态 + 暂停(不等待) + 销毁托盘。
  /// 返回后由调用方决定 exit（框架退出）或由旧 _quit 继续销毁窗口。
  Future<void> _cleanupForExit() async {
    _isQuitting = true;
    // 1) 持久化（fire-and-forget）。
    _player?.persistCurrentStateSync();
    // 2) 发起暂停、不等待（WinRT audio 可能阻塞，不阻塞销毁/退出）。
    try {
      final pf = _player?.pause();
      if (pf != null) unawaited(pf.catchError((_) {}));
    } catch (_) {}
    // 3) 等待托盘销毁完成（保证托盘/后台退干净；此等待发生在窗口销毁/引擎退出之前，
    //    因此能真正执行完，不会残留）。
    try {
      await TrayManager.instance.destroy();
    } catch (_) {}
  }

  // ====== TrayListener ======
  /// 右键：弹出托盘菜单。
  ///
  /// bringAppToFront:false 表示弹出菜单时不把我们的主窗口带到前台，
  /// 这样窗口仍保持在托盘不可见状态；同时菜单将自身获取系统焦点，
  /// 点击外部区域/菜单项后由系统自动关闭并触发对应回调。
  @override
  void onTrayIconRightMouseDown() {
    if (_isQuitting) return;
    _trayMenuOpen = true;
    // ignore: deprecated_member_use (bringAppToFront 仅 Windows 有效，属既有用法)
    unawaited(TrayManager.instance.popUpContextMenu(bringAppToFront: false));
  }

  /// 左键单击：切换窗口显示/隐藏。
  @override
  void onTrayIconMouseDown() {
    if (_isQuitting || _trayMenuOpen) return;
    windowManager.isVisible().then((visible) {
      if (visible) {
        // 通过 _hideToTray 隐藏，以同步通知 isUIVisible=false（停掉窗口内 UI Ticker）。
        unawaited(_hideToTray());
        // ===== 原实现（备份，供回退）=====
        // unawaited(windowManager.hide());
      } else {
        unawaited(_showWindow());
      }
    });
  }

  /// 菜单项点击：key 已在菜单构建时唯一，统一在此派发。
  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    _trayMenuOpen = false;
    final key = menuItem.key;
    if (key != null) _onMenuItemClick(key);
  }

  Future<void> _hideToTray() async {
    if (!_attached) return;
    await windowManager.hide();
    // ===== 【修复】收进托盘后停掉窗口内持续请求帧的 UI Ticker，降低隐藏态 GPU 占用 =====
    // 原因：Flutter 窗口隐藏后渲染循环仍在跑，加上窗口内活跃 Ticker（歌词滚动等）
    // 仍在每帧请求提交，导致 GPU 满载。这里通知 PlayerController 置 isUIVisible=false，
    // 歌词页 Ticker 据此停止；**不暂停音频**——收进托盘后音乐应继续播放。
    _player?.setUIVisible(false);
  }

  Future<void> _showWindow() async {
    if (!_attached) return;
    await windowManager.show();
    await windowManager.focus();
    // ===== 【修复】恢复显示时重新启用窗口内 UI Ticker（与 _hideToTray 对称）=====
    _player?.setUIVisible(true);
  }

  Future<void> _quit() async {
    if (_isQuitting) return;
    _isQuitting = true;
    // ===== 【修复】退出时序优化：先持久化→先停音频→再毁托盘→最后毁窗 =====
    // 原因：原实现先销毁托盘图标（瞬间消失）、再销毁窗口，且未先停音频，
    // 关闭期间音频/进度 ticker 仍在发声，导致"托盘先消失、窗口后消失、音频顿挫"。
    // 新顺序让"托盘图标+关闭动画更一致、音频先停再关"。
    //
    // ===== 优化失败记录：托盘 destroy 改 fire-and-forget 会"后台没退干净"；
    //     更正为 hide 先藏窗、再 await 清托盘、最后 destroy，快与干净兼顾 =====
    //
    // 1) 先触发状态持久化（persistCurrentStateSync 现返回 Future）。
    //    ===== 【方案A优化】原本 fire-and-forget（不阻塞），退出竞态下可能未落盘即 exit；
    //    现改为 await 同步落盘（队列/歌曲+进度），保证退出零丢失。=====
    try {
      await _player?.persistCurrentStateSync();
    } catch (_) {}
    // 2) 发起暂停播放但【不等待】返回。
    //    原因：pause() 在 WinRT 上可能阻塞片刻，会让主线程停在"销毁窗口"之前。
    //    这里只发起暂停、不等待；音频随引擎销毁而自然停止。
    try {
      final pauseFuture = _player?.pause();
      if (pauseFuture != null) {
        unawaited(pauseFuture.catchError((_) {}));
      }
    } catch (_) {}
    // 3) 先隐藏窗口（瞬间消失，用户感知"已退出"），再做后台清理。
    //    【退出既要快又要干净】窗口若直接 destroy，进程随之退出，后续 await 清理
    //    来不及执行 → 后台/托盘残留（此前用 fire-and-forget 引发的 bug）。所以：
    //      a) windowManager.hide() 几乎立即藏起窗口 → 退出感知即时装成；
    //      b) await 托盘销毁（此时窗口已不可见，等待不再"堵在用户眼前"）→ 保证干净；
    //      c) 最后强制退出进程。
    //
    // 【兜底加固 · 实测根因】：清理包进 try / finally，用 exit(0) 兜底强制进程退出，
    // **不再调用 windowManager.setPreventClose(false) + windowManager.destroy()**。
    // 原因：window_manager 会把 SetQuitOnClose 设为 false，手动 destroy 后进程并不自行退出；
    // 且本应用在 Flutter 引擎尚未停止时手动销毁窗口，会在原生层触发访问违例(c0000005)/
    // fail-fast(c0000409) 崩溃，被 Windows 错误报告(WerFault)捕获后"自重启"，每次退出都
    // 派生新的无窗口 kgka_music_hl 进程并累积成残留。改为隐藏窗口 + 清理托盘后直接
    // exit(0) 终止进程、由 OS 一并收回窗口，避免该原生竞态崩溃。finally 保证 exit(0)
    // 无论异常与否都执行。
    // ===== NEW 尝试（已实测失败并回退）：优雅退出 =====
    // 曾尝试改为：经 'ka_music/window_state' 通道调原生 PostQuitMessage(0) 让引擎优雅析构，
    // 以此绕过 exit(0) 强杀引发的 teardown 崩溃。实测结果：主进程仍悬挂不退出(exited=False)、
    // 继续触发 ucrtbase/DEP fail-fast(c0000409/BEX64) 崩溃并被 WerFault 自动恢复重启。
    // 结论：该崩溃源自 Flutter 引擎/某插件在"窗口关闭/进程结束"时的原生 teardown，与退出
    // 的 Dart 实现方式基本无关——exit(0)/windowManager.destroy()/PostQuitMessage 均无法避免。
    // 因此回退到下方可用的"隐藏窗口 + 清理托盘 + exit(0) 兜底"（保证进程必定退出）。
    try {
      try {
        await windowManager.hide();
      } catch (_) {}
      try {
        await TrayManager.instance.destroy();
      } catch (_) {}
    } finally {
      // exit() 不会返回，需放在所有 await 清理之后。
      exit(0);
    }

    // ===== 优化失败记录：托盘 destroy 改 fire-and-forget 会"后台没退干净"；
    //     更正为 hide 先藏窗、再 await 清托盘、最后 destroy，快与干净兼顾 =====
    // ===== 原实现（备份，供回退）=====
    // Future<void> _quit() async {
    //   if (_isQuitting) return;
    //   _isQuitting = true;
    //   _player?.persistCurrentStateSync();
    //   try {
    //     await TrayManager.instance.destroy();
    //   } catch (_) {}
    //   await windowManager.setPreventClose(false);
    //   await windowManager.destroy();
    // }
  }

  // ====== 设置持久化 ======
  Future<void> setCloseBehavior(CloseBehavior value) async {
    if (_closeBehavior == value) return;
    _closeBehavior = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_closeBehaviorKey, value.index);
  }

  Future<void> setLaunchAtStartup(bool enabled) async {
    if (_launchAtStartup == enabled) return;
    _launchAtStartup = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_launchAtStartupKey, enabled);
    await _applyLaunchAtStartup(enabled);
  }

  Future<bool> _applyLaunchAtStartup(bool enabled) async {
    if (!Platform.isWindows || Platform.resolvedExecutable.isEmpty) return false;
    const runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
    const name = 'KA Music';
    try {
      final List<String> args;
      if (enabled) {
        args = ['add', runKey, '/v', name, '/t', 'REG_SZ', '/d', '"${Platform.resolvedExecutable}"', '/f'];
      } else {
        args = ['delete', runKey, '/v', name, '/f'];
      }
      final result = await Process.run('reg', args);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// 供设置页强化显示时刷新托盘菜单。
  Future<void> refresh() => _refreshTrayMenu();

  @override
  void dispose() {
    _player?.removeListener(_onPlayerChanged);
    _auth?.removeListener(_onAuthChanged);
    _lifecycle?.dispose();
    _lifecycle = null;
    if (_attached) TrayManager.instance.removeListener(this);
    super.dispose();
  }
}