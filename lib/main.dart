import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';

import 'config/app_config.dart';
import 'controllers/auth_controller.dart';
import 'controllers/download_controller.dart';
import 'controllers/player_controller.dart';
import 'controllers/local_music_controller.dart';
import 'controllers/theme_controller.dart';
import 'core/api_client.dart';
import 'services/cache_diag_logger.dart'; // ====【诊断/缓存清理卡顿】====
import 'services/cache_service.dart';
import 'services/device_info_service.dart';
import 'services/frame_diag_logger.dart'; // ====【诊断/安卓渲染卡顿】====
import 'services/main_thread_lag_monitor.dart'; // ====【诊断/主线程阻塞全景】====
import 'services/download_service.dart';
import 'services/music_audio_handler.dart';
import 'services/music_api.dart';
import 'services/adaptive_lyric_color.dart';
import 'services/desktop_controller.dart';
import 'services/loudness_normalization.dart'; // ====【新增/响度归一化】全局编排 ====
import 'services/prefs_maintenance.dart';
import 'services/startup_diag_logger.dart'; // ====【诊断/冷启动有效性问题】====
import 'ui/adaptive_layout.dart';
import 'ui/app_theme.dart';
import 'ui/pages/app_shell.dart';
import 'ui/pages/login_page.dart';
import 'ui/widgets/shortcut_handler.dart';
import 'ui/widgets/tv_focus.dart'; // ====【新增/Android TV 遥控器适配】====
import 'ui/widgets/tv_navigation_scope.dart'; // ====【新增/Android TV 遥控器适配】====
import 'ui/widgets/toast.dart';
import 'ui/widgets/window_title_bar.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // ====【诊断/缓存清理卡顿】==== 尽早启动日志 + 帧监控：
  // 必须早于 DownloadController.initialize()，否则启动阶段的清理日志会丢。
  // 日志：%TEMP%\ka_music_cache_diag.log（每次启动轮转旧文件为 .1.log）。
  unawaited(CacheDiagLogger.startFrameMonitor());
  // ====【诊断/冷启动有效性问题】==== 记下启动零点，并登记"首帧上屏"时刻。
  final bootSw = Stopwatch()..start();
  StartupDiagLogger.markAppStart();
  StartupDiagLogger.markFirstFrame();
  // ====【新增/Android TV 遥控器适配】==== TV 焦点高亮只在"遥控器/键盘"场景需要；
  // 桌面端保持关闭，避免鼠标点击后出现刺眼焦点框（桌面端已有 F11/Esc 等快捷键）。
  // Android（TV / 车机 / 盒子）默认开启：方向键遍历 + 确定键激活 + 高亮。
  TvFocusMode.enabled = Platform.isAndroid;
  TvFocusMode.directionalTraversal = true;
  // ====【诊断/TV 焦点】==== 把焦点变化打到日志，便于确认遥控器导航真的生效。
  // 排查期置 true；正式发版关闭（release 下 debugPrint 本就会被剥离）。
  TvFocusMode.debugLogFocus = false;
  StartupDiagLogger.phase('binding', ms: bootSw.elapsedMilliseconds);
  // ====【修复/切歌卡顿·prefs 瘦身】==== 必须最先执行、且早于任何其它 prefs 消费者：
  // 1) 若上次清理中途崩溃，先用备份恢复设置，避免丢登录态等数据；
  // 2) 再一次性清掉已迁到独立文件的 `cache_*` 死键（实测 386 个键占 6.37MB、使 prefs 达
  //    8.67MB，每次 setX 同步整写约 430ms，是切歌两处卡顿的根因）。
  // 放在此处可保证清理期间没有任何并发 prefs 写入（purge 内含 clear，怕被并发写入回滚）。
  final prefsSw = Stopwatch()..start();
  await PrefsMaintenance.recoverIfNeeded();
  final recoverMs = prefsSw.elapsedMilliseconds;
  final purgeSw = Stopwatch()..start();
  await PrefsMaintenance.purge();
  purgeSw.stop();
  StartupDiagLogger.phase(
    'prefsMaintenance',
    note: 'recover=${recoverMs}ms purge=${purgeSw.elapsedMilliseconds}ms',
    ms: prefsSw.elapsedMilliseconds,
  );
  await AppConfig.loadCustomBaseUrl();
  StartupDiagLogger.phase('prefsBlock', ms: bootSw.elapsedMilliseconds);

  final client = ApiClient();
  final api = MusicApi(client);
  // ---- Windows 桌面适配 ----
  // audio_service 在 Windows 上无原生实现：Windows 构建中 plugin 矩阵不包含
  // audio_service（无系统媒体集成/通知栏需求），此时 `AudioService.init` 会抛
  // MissingPluginException 导致启动崩溃。因此桌面端改用纯 Dart 的
  // MusicAudioHandler（构造不访问原生通道），播放能力仍由 just_audio
  // （just_audio_windows）提供，仅跳过原生后台服务注册。
  // 如需恢复 Android/iOS/macOS 的原始启动逻辑，改回下面被注释的原始代码即可。
  // ====【诊断/冷启动】==== AudioService.init 会注册原生前台服务/通知，安卓上可能是耗时点。
  final audioInitSw = Stopwatch()..start();
  final audioHandler = Platform.isWindows
      ? MusicAudioHandler()
      : await AudioService.init(
          builder: MusicAudioHandler.new,
          config: const AudioServiceConfig(
            androidNotificationChannelId: 'kgka_music_hl.playback',
            androidNotificationChannelName: 'KA Music 播放控制',
            androidStopForegroundOnPause: false,
          ),
        );
  audioInitSw.stop();
  StartupDiagLogger.phase(
    'audioServiceInit',
    ms: audioInitSw.elapsedMilliseconds,
    note: 'sinceBoot=${bootSw.elapsedMilliseconds}ms',
  );
  // ============ 原始代码（保留备用，勿在 Windows 启用） ============
  // final audioHandler = await AudioService.init(
  //   builder: MusicAudioHandler.new,
  //   config: const AudioServiceConfig(
  //     androidNotificationChannelId: 'kgka_music_hl.playback',
  //     androidNotificationChannelName: 'KA Music 播放控制',
  //     androidStopForegroundOnPause: false,
  //   ),
  // );

  final themeController = ThemeController();
  // 先检测车机，再加载设置：首次安装时据检测结果决定车机模式默认值。
  final automotiveSw = Stopwatch()..start();
  await themeController.detectAutomotive(const DeviceInfoService());
  automotiveSw.stop();
  final themeLoadSw = Stopwatch()..start();
  await themeController.load();
  themeLoadSw.stop();
  StartupDiagLogger.phase(
    'theme',
    ms: automotiveSw.elapsedMilliseconds + themeLoadSw.elapsedMilliseconds,
    note: 'detectAutomotive=${automotiveSw.elapsedMilliseconds}ms '
        'load=${themeLoadSw.elapsedMilliseconds}ms',
  );

  StartupDiagLogger.phase('beforeRunApp', ms: bootSw.elapsedMilliseconds);
  // ====【诊断/安卓渲染卡顿】==== 帧耗时监控需在绑定就绪后挂载。
  FrameDiagLogger.attach();
  // ====【诊断/主线程阻塞全景】==== 捕获所有未打点的同步阻塞来源。
  MainThreadLagMonitor.start();
  runApp(ShortcutHandler(
    child: KaMusicApp(
      client: client,
      api: api,
      audioHandler: audioHandler,
      themeController: themeController,
    ),
  ));
}

class KaMusicApp extends StatefulWidget {
  const KaMusicApp({
    super.key,
    required this.client,
    required this.api,
    required this.audioHandler,
    required this.themeController,
  });

  final ApiClient client;
  final MusicApi api;
  final MusicAudioHandler audioHandler;
  final ThemeController themeController;

  @override
  State<KaMusicApp> createState() => _KaMusicAppState();
}

class _KaMusicAppState extends State<KaMusicApp> with WidgetsBindingObserver {
  late final ApiClient _client;
  late final MusicApi _api;
  late final CacheService _cacheService;
  late final DownloadService _downloadService;
  late final DownloadController _downloads;
  late final AuthController _auth;
  late final PlayerController _player;
  late final ThemeController _theme;
  late final LocalMusicController _localMusic;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _client = widget.client;
    _api = widget.api;
    _cacheService = CacheService();
    _downloadService = DownloadService();
    _downloads = DownloadController(_downloadService, _api);
    _auth = AuthController(_api, _cacheService);
    _localMusic = LocalMusicController();
    _player = PlayerController(_api, widget.audioHandler)
      ..downloadController = _downloads
      ..cacheService = _cacheService
      ..localMusic = _localMusic;
    _theme = widget.themeController;
    // ====【诊断/冷启动】==== 记录 initState 构建耗时（构造同步部分）。
    StartupDiagLogger.phase(
      'initStateBuild',
      note: '含 PlayerController/AuthController/DownloadController 构造',
    );
    final authSw = Stopwatch()..start();
    MainThreadLagMonitor.crumb('initState:auth.restore');
    _auth.restore();
    StartupDiagLogger.phase('authRestoreCall', ms: authSw.elapsedMilliseconds);
    final dlSw = Stopwatch()..start();
    MainThreadLagMonitor.crumb('initState:downloads.initialize');
    _downloads.initialize();
    StartupDiagLogger.phase('downloadsInitCall', ms: dlSw.elapsedMilliseconds);
    final restoreSw = Stopwatch()..start();
    MainThreadLagMonitor.crumb('initState:restorePlaybackState');
    _restorePlaybackState();
    StartupDiagLogger.phase('restorePlaybackCall', ms: restoreSw.elapsedMilliseconds);

    // Windows 桌面集成（托盘/关窗/全屏/开机自启）。
    // 非 Windows 平台（Android 等）DesktopController.isSupported=false 自动跳过。
    unawaited(DesktopController.instance.attach(_player, _auth));
    // ====【修复/切歌自动刷新·自适应歌词颜色】====：应用启动即挂载全局切歌触发，
    // 让"正常播放（歌词调整页未打开）时切歌"也能自动对新封面提色并 setGlobal，
    // 渲染层（已监听 notifier）随之即时刷新歌词颜色。由 AdaptiveLyricColor.detach 对应卸载。
    MainThreadLagMonitor.crumb('initState:adaptiveColorAttach');
    AdaptiveLyricColor.attach(_player);
    // ====【新增/响度归一化】==== 应用启动即挂载全局编排：
    // 监听换源（handler.onSourceLoaded）→ 查缓存/排队分析每首歌的 integrated LUFS
    // → 施加单一固定增益偏移（完整保留动态，双端生效）。
    // 与"音量均衡"开关联动；关闭时不施加任何增益。由 LoudnessNormalization.detach 卸载。
    MainThreadLagMonitor.crumb('initState:loudnessAttach');
    LoudnessNormalization.attach(
      _player,
      widget.audioHandler,
      cache: _cacheService,
    );
  }

  // ====【已撤回】==== 曾尝试把"恢复播放准备"延后到首帧之后（仅安卓），
  // 但实机 A/B 显示 `prepareRestoredSong` 总耗时仍为 ~10 秒（只是把等待挪了位置），
  // 而首播会被推迟约 1.8 秒 —— 收益不明确且有行为风险，故撤回，保持原语义。

  /// 恢复上次的播放队列和进度。
  Future<void> _restorePlaybackState() async {
    // ====【诊断/冷启动】==== 恢复链路逐段计时（网络请求是最可疑的一段）。
    final totalSw = Stopwatch()..start();
    final queueSw = Stopwatch()..start();
    MainThreadLagMonitor.crumb('restore:restoreQueueState');
    await _player.restoreQueueState();
    queueSw.stop();
    StartupDiagLogger.phase(
      'restoreQueueState',
      ms: queueSw.elapsedMilliseconds,
      note:
          'queueLen=${_player.queue.length} hasCurrent=${_player.currentSong != null}',
    );
    if (_player.currentSong != null) {
      unawaited(_player.prepareRestoredSong());
      StartupDiagLogger.phase(
        'restorePlaybackState',
        ms: totalSw.elapsedMilliseconds,
      );
      return;
    }
    // 本地无播放记录时，尝试用服务端「继续播放」信息恢复。
    try {
      final apiSw = Stopwatch()..start();
      MainThreadLagMonitor.crumb('restore:latestListenSongs');
      final latest = await _api.latestListenSongs();
      apiSw.stop();
      StartupDiagLogger.phase(
        'latestListenSongs',
        ms: apiSw.elapsedMilliseconds,
        note: 'songs=${latest.songs.length}',
      );
      if (_player.currentSong != null || latest.songs.isEmpty) {
        StartupDiagLogger.phase(
          'restorePlaybackState',
          ms: totalSw.elapsedMilliseconds,
        );
        return;
      }
      _player.restoreFromServerQueue(latest.songs);
      unawaited(_player.prepareRestoredSong());
    } catch (_) {
      // 服务端恢复失败静默忽略，保持空状态。
    }
    StartupDiagLogger.phase(
      'restorePlaybackState',
      ms: totalSw.elapsedMilliseconds,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AdaptiveLyricColor.detach(_player); // ====【修复/切歌自动刷新】==== 卸载全局切歌提色监听
    LoudnessNormalization.detach(); // ====【新增/响度归一化】==== 卸载全局编排
    _auth.dispose();
    // 退出前保存播放状态
    _player.persistCurrentStateSync();
    _player.dispose();
    _downloads.dispose();
    _localMusic.dispose();
    _downloadService.dispose();
    // ====【诊断/缓存清理卡顿】==== 收尾：写各区域 count/avg/max 汇总后再落盘。
    unawaited(CacheDiagLogger.flushSummary());
    CacheDiagLogger.log('app', 'dispose 退出');
    _client.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // ====【响度归一化·预分析】应用前后台联动 ====
    // 必须放在下方 desktopLyricsEnabled 提前 return 之前，否则桌面歌词未开启时
    // 这段逻辑永远不会执行。作用：应用进入后台时立即停止预扫描，
    // 避免后台持续下载歌曲（Android 上尤其重要：会消耗移动流量与电量）。
    LoudnessNormalization.setAppActive(state == AppLifecycleState.resumed);
    // ====【诊断/缓存清理卡顿】==== 最小化/后台时暂停帧采样，避免假尖峰污染日志。
    CacheDiagLogger.setAppActive(state == AppLifecycleState.resumed);
    if (!_player.desktopLyricsEnabled) return;
    switch (state) {
      case AppLifecycleState.resumed:
        _player.setAppForeground(true);
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _player.setAppForeground(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    _theme.applyOrientations(AdaptiveLayout.isTablet(context));
    return AnimatedBuilder(
      animation: _theme,
      builder: (context, _) {
        return MaterialApp(
          title: AppConfig.appName,
          debugShowCheckedModeBanner: false,
          navigatorKey: Toast.navigatorKey,
          // ====【诊断/安卓渲染卡顿】==== 记录页面切换，便于把卡顿帧归因到页面。
          navigatorObservers: [FrameDiagObserver()],
          themeMode: ThemeMode.system,
          theme: AppTheme.light(
            seedColor: _theme.seedColor,
            transparentBackground: _theme.backgroundEnabled,
          ),
          darkTheme: AppTheme.dark(
            seedColor: _theme.seedColor,
            transparentBackground: _theme.backgroundEnabled,
          ),
          builder: (context, child) {
            // 全局字体大小（保留系统无障碍缩放）。
            final baseScale = MediaQuery.textScalerOf(context).scale(1.0);
            final textScaler = TextScaler.linear(baseScale * _theme.fontScale);
            // ====【新增/Android TV 遥控器适配】==== 包住所有页面（含弹窗/底部弹窗，
            // 它们也走 Navigator 的 builder，因此焦点与媒体键在其中同样生效）。
            final themed = MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              // ===== 沉浸式窗口：Windows 已隐藏系统标题栏（见 DesktopController）。
              // 页面内容直接贴窗口顶部铺满（不额外让出顶栏高度），右上角窗口控制按钮
              // 作为覆盖层始终显示在页面内容之上；顶栏/按钮透明、无底色，从而与任意
              // 页面（含播放器浅色背景）融入。其它平台保持原布局。=====
              child: _AppBackground(
                themeController: _theme,
                child: Platform.isWindows
                    ? Stack(
                        children: [
                          Positioned.fill(
                            child: _SystemUiOverlay(
                              child: child ?? const SizedBox.shrink(),
                            ),
                          ),
                          const Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: WindowTitleBar(),
                          ),
                        ],
                      )
                    : _SystemUiOverlay(child: child ?? const SizedBox.shrink()),
              ),
            );
            // ====【新增/Android TV 遥控器适配】==== 全局几何遍历：
            // 所有页面默认按"上→下、左→右"的就近顺序移动焦点（WidgetOrderTraversalPolicy），
            // 避免阅读顺序策略在列表/网格里出现"按右键跳很远"的问题。
            return TvNavigationScope(
              player: _player,
              child: FocusTraversalGroup(
                policy: WidgetOrderTraversalPolicy(),
                child: themed,
              ),
            );
          },          home: AnimatedBuilder(
            animation: _auth,
            builder: (context, _) {
              if (!_auth.isRestoring && !_auth.isLoggedIn) {
                return LoginPage(auth: _auth, api: _api);
              }

              return AppShell(
                api: _api,
                auth: _auth,
                player: _player,
                cache: _cacheService,
                downloads: _downloads,
                theme: _theme,
                localMusic: _localMusic,
              );
            },
          ),
        );
      },
    );
  }
}

/// 全局背景图层。
///
/// 当用户启用了自定义背景图时，在所有页面内容下方显示背景图，
/// 并叠加半透明遮罩（由 [ThemeController.backgroundOpacity] 控制）。
class _AppBackground extends StatefulWidget {
  const _AppBackground({required this.themeController, required this.child});

  final ThemeController themeController;
  final Widget child;

  @override
  State<_AppBackground> createState() => _AppBackgroundState();
}

class _AppBackgroundState extends State<_AppBackground> {
  FileImage? _imageProvider;
  String? _cachedPath;

  @override
  void initState() {
    super.initState();
    widget.themeController.addListener(_onThemeChanged);
    _updateProvider();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _precacheBackground();
  }

  @override
  void didUpdateWidget(covariant _AppBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.themeController != widget.themeController) {
      oldWidget.themeController.removeListener(_onThemeChanged);
      widget.themeController.addListener(_onThemeChanged);
      _updateProvider();
      _precacheBackground();
    }
  }

  @override
  void dispose() {
    widget.themeController.removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    _updateProvider();
    _precacheBackground();
    setState(() {});
  }

  void _updateProvider() {
    final path = widget.themeController.backgroundImagePath;
    if (path != null && path != _cachedPath) {
      _cachedPath = path;
      _imageProvider = FileImage(File(path));
    }
  }

  void _precacheBackground() {
    if (_imageProvider != null) {
      precacheImage(_imageProvider!, context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.themeController.backgroundEnabled;
    final path = widget.themeController.backgroundImagePath;

    if (!enabled || path == null || _imageProvider == null) {
      return widget.child;
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final overlayColor = isDark ? const Color(0xFF06070A) : Colors.white;
    final opacity = widget.themeController.backgroundOpacity;

    return Stack(
      children: [
        // 背景图层（复用同一个 FileImage provider，避免重复解码）
        Positioned.fill(
          child: Image(
            image: _imageProvider!,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
        // 半透明遮罩（opacity 越大遮罩越透明，背景图越明显）
        Positioned.fill(
          child: ColoredBox(
            color: overlayColor.withValues(alpha: 1.0 - opacity),
          ),
        ),
        // 页面内容
        widget.child,
      ],
    );
  }
}

class _SystemUiOverlay extends StatelessWidget {
  const _SystemUiOverlay({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final overlayStyle = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness: isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: colorScheme.surface,
      systemNavigationBarIconBrightness: isDark
          ? Brightness.light
          : Brightness.dark,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarContrastEnforced: false,
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: child,
    );
  }
}
