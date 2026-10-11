import 'dart:io';

import 'package:flutter/material.dart';
import '../design_tokens.dart';
import 'package:flutter/services.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/download_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../controllers/local_music_controller.dart';
import '../../services/cache_service.dart';
import '../../services/music_api.dart';
import '../widgets/mini_player.dart';
import '../widgets/car_left_player_panel.dart';
import '../widgets/window_title_bar.dart';
import '../widgets/tv_focus.dart'; // ====【新增/Android TV 遥控器适配】====
import '../widgets/tv_nav_bar.dart'; // ====【新增/Android TV 遥控器适配】====
import '../widgets/tv_controls.dart'; // ====【新增/Android TV 遥控器适配】====
import '../adaptive_layout.dart';
import 'home_page.dart';
import 'library_page.dart';
import 'search_page.dart';
import 'settings_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.cache,
    required this.downloads,
    required this.theme,
    required this.localMusic,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final CacheService cache;
  final DownloadController downloads;
  final ThemeController theme;
  final LocalMusicController localMusic;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  var _index = 1; // Default to '推荐' tab (index 1) in landscape
  var _lastHomeTab = 1; // Tracks the last active Home sub-tab (1 for Recommend, 2 for Radio)
  final _navigatorKey = GlobalKey<NavigatorState>();
  // ====【新增/Android TV 遥控器适配】====
  // 车机布局里，左侧播放面板在嵌套 Navigator 之外、内容是 Navigator 内的一条路由，
  // 二者处于**不同的 FocusScope**，方向键无法互跨。用两个锚点做跨作用域桥接。
  final _carPanelKey = GlobalKey();
  final _carContentKey = GlobalKey();

  int _getPortraitIndex() {
    return _index == 0 ? 1 : 0;
  }

  void _setPortraitIndex(int index) {
    setState(() {
      _index = index == 0 ? _lastHomeTab : 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppShortcutScope(
      player: widget.player,
      child: _buildShell(context),
    );
  }

  Widget _buildShell(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final colorScheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;

    // 车机布局：仅在横屏且开启车机模式时启用（左侧播放面板 + 顶栏）。
    // 关闭时回到普通布局（宽屏用 NavigationRail），与原项目行为一致；
    // 平板横屏适配留给上游后续开发。
    if (isLandscape && widget.theme.carModeEnabled) {
      // 车机模式下文字相对放大（保留系统无障碍设置）。
      final baseTextScaler = MediaQuery.textScalerOf(context);
      final scaledTextScaler = _RelativeTextScaler(
        base: baseTextScaler,
        multiplier: ThemeController.carModeFontScaleFactor,
      );
      return MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: scaledTextScaler),
        child: PopScope(
          // 拦截 Android 返回键：先尝试 pop 内层 Navigator（搜索/设置/歌单等
          // push 到内层 Navigator 的页面），内层无法 pop 时才退出应用。
          // 不加 PopScope 会导致返回键只 pop root Navigator（只有一个 AppShell
          // route），从歌单页面返回直接退出应用。
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            final nav = _navigatorKey.currentState;
            if (nav != null && nav.canPop()) {
              nav.pop();
            } else {
              SystemNavigator.pop();
            }
          },
          child: Scaffold(
            body: _CarFocusBridge(
              panelKey: _carPanelKey,
              contentKey: _carContentKey,
              child: Row(
              children: [
                // ExcludeSemantics 规避 CarLeftPlayerPanel 频繁响应 player 更新
                // 导致的 Windows AXTree 竞态崩溃（Flutter Windows 引擎 bug）
                ExcludeSemantics(
                  child: CarLeftPlayerPanel(
                    key: _carPanelKey,
                    player: widget.player,
                    auth: widget.auth,
                  ),
                ),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(
                  key: _carContentKey,
                  child: Navigator(
                    key: _navigatorKey,
                    onGenerateRoute: (settings) {
                      return MaterialPageRoute(
                        builder: (navContext) {
                          final homePage = HomePage(
                            api: widget.api,
                            auth: widget.auth,
                            player: widget.player,
                            cache: widget.cache,
                            theme: widget.theme,
                            downloads: widget.downloads,
                            localMusic: widget.localMusic,
                            sectionIndex: _index == 2 ? 1 : 0,
                            onTabSwitch: (index) {
                              setState(() {
                                _index = index;
                                if (index == 1 || index == 2) {
                                  _lastHomeTab = index;
                                }
                              });
                            },
                          );

                          final libraryPage = LibraryPage(
                            api: widget.api,
                            auth: widget.auth,
                            player: widget.player,
                            downloads: widget.downloads,
                            theme: widget.theme,
                            localMusic: widget.localMusic,
                          );

                          final pages = [homePage, libraryPage];
                          final activePageIndex = _index == 0 ? 1 : 0;

                          return Scaffold(
                            body: Column(
                              children: [
                                _buildCarTopNavBar(navContext, colorScheme),
                                const Divider(height: 1),
                                Expanded(
                                  child: _LazyIndexedStack(
                                    index: activePageIndex,
                                    children: pages,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
            ),
          ),
        ),
      );
    }

    // Original Portrait Layout
    final useNavRail = size.width >= 720;
    final portraitIndex = _getPortraitIndex();

    final homePage = HomePage(
      api: widget.api,
      auth: widget.auth,
      player: widget.player,
      cache: widget.cache,
      theme: widget.theme,
      downloads: widget.downloads,
      localMusic: widget.localMusic,
      sectionIndex: _index == 2 ? 1 : 0,
      onTabSwitch: (index) {
        setState(() {
          _index = index;
          if (index == 1 || index == 2) {
            _lastHomeTab = index;
          }
        });
      },
    );

    final libraryPage = LibraryPage(
      api: widget.api,
      auth: widget.auth,
      player: widget.player,
      downloads: widget.downloads,
      theme: widget.theme,
      localMusic: widget.localMusic,
    );

    final pages = [homePage, libraryPage];

    Widget mainContent = Stack(
      children: [
        Positioned.fill(
          child: _LazyIndexedStack(
            index: portraitIndex,
            children: pages,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom:
              bottomInset + (useNavRail ? 16 : kBottomNavigationBarHeight + 10),
          child: MiniPlayer(player: widget.player, auth: widget.auth),
        ),
      ],
    );

    if (useNavRail) {
      mainContent = Row(
        children: [
          TvNavRail(
            currentIndex: portraitIndex,
            onSelect: _setPortraitIndex,
            destinations: const [
              TvNavDestination(
                icon: Icons.home_outlined,
                activeIcon: Icons.home_rounded,
                label: '首页',
              ),
              TvNavDestination(
                icon: Icons.person_outline_rounded,
                activeIcon: Icons.person_rounded,
                label: '我的',
              ),
            ],
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(child: mainContent),
        ],
      );
    }

    return Scaffold(
      extendBody: true,
      body: AdaptiveContentPadding(child: mainContent),
      bottomNavigationBar: useNavRail
          ? null
          : TvBottomNavBar(
              currentIndex: portraitIndex,
              onSelect: _setPortraitIndex,
              destinations: const [
                TvNavDestination(
                  icon: Icons.home_outlined,
                  activeIcon: Icons.home_rounded,
                  label: '首页',
                ),
                TvNavDestination(
                  icon: Icons.person_outline_rounded,
                  activeIcon: Icons.person_rounded,
                  label: '我的',
                ),
              ],
            ),
    );
  }

  Widget _buildCarTopNavBar(BuildContext context, ColorScheme colorScheme) {
    final tabs = ['我的', '推荐', '电台'];
    final topInset = MediaQuery.paddingOf(context).top;
    return Container(
      // 顶部加上状态栏高度，避免导航栏内容被状态栏遮挡；
      // Windows 上右端为窗口控制按钮让出空间，避免"设置"按钮与窗口按钮重叠。
      padding: EdgeInsets.fromLTRB(
        16,
        topInset,
        16 + (Platform.isWindows ? WindowTitleBar.controlAreaRight : 0),
        0,
      ),
      height: 72 + topInset, // Increased from 64
      child: Row(
        children: [
          // Search Pill Button（TV：可聚焦 + 确定键触发）
          TvTapArea(
            radius: AppRadius.xxl,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SearchPage(
                  api: widget.api,
                  auth: widget.auth,
                  player: widget.player,
                ),
              ),
            ),
            child: Container(
              height: 46, // Increased from 38
              padding: const EdgeInsets.symmetric(horizontal: 20), // Increased from 16
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withValues(
                  alpha: .54,
                ),
                borderRadius: BorderRadius.circular(AppRadius.xxl), // Increased from 19 (height/2)
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.search_rounded,
                    color: colorScheme.onSurfaceVariant,
                    size: 22, // Increased from 20
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '搜索',
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 16, // Increased from default
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 32), // Increased from 24
          // Tabs（TV：可聚焦标签芯片，替代无法稳定聚焦的 ChoiceChip）
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final entry in tabs.indexed)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: TvChipButton(
                        label: entry.$2,
                        selected: _index == entry.$1,
                        onTap: () => setState(() {
                          _index = entry.$1;
                          if (entry.$1 == 1 || entry.$1 == 2) {
                            _lastHomeTab = entry.$1;
                          }
                        }),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // Settings Icon（TV：可聚焦图标按钮）
          TvIconButton(
            tooltip: '设置',
            icon: Icons.settings_rounded,
            iconSize: 28,
            padding: const EdgeInsets.all(10),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SettingsPage(
                    api: widget.api,
                    auth: widget.auth,
                    player: widget.player,
                    theme: widget.theme,
                    downloads: widget.downloads,
                    cache: widget.cache,
                    localMusic: widget.localMusic,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 只在首次被选中时才构建对应 child 的 [IndexedStack]。
///
/// 普通 IndexedStack 会一次性构建全部 children，导致所有页面
/// 都在 initState 中发起网络请求。这里通过懒构建
/// 保证只有被访问过的 tab 才会真正初始化，避免重复请求与重复监听。
class _LazyIndexedStack extends StatefulWidget {
  const _LazyIndexedStack({required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  State<_LazyIndexedStack> createState() => _LazyIndexedStackState();
}

class _LazyIndexedStackState extends State<_LazyIndexedStack> {
  final _built = <int>{};

  @override
  void initState() {
    super.initState();
    _built.add(widget.index);
  }

  @override
  void didUpdateWidget(covariant _LazyIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    _built.add(widget.index);
  }

  @override
  Widget build(BuildContext context) {
    return IndexedStack(
      index: widget.index,
      children: [
        for (var i = 0; i < widget.children.length; i++)
          _built.contains(i) ? widget.children[i] : const SizedBox.shrink(),
      ],
    );
  }
}

/// 在已有 [TextScaler] 基础上再乘固定倍数（Flutter 内置 TextScaler 无 `*` 运算符）。
class _RelativeTextScaler extends TextScaler {
  const _RelativeTextScaler({required this.base, required this.multiplier});

  final TextScaler base;
  final double multiplier;

  @override
  double scale(double fontSize) => base.scale(fontSize) * multiplier;

  @override
  double get textScaleFactor {
    // ignore: deprecated_member_use
    final baseFactor = base.textScaleFactor;
    return baseFactor * multiplier;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _RelativeTextScaler &&
          base == other.base &&
          multiplier == other.multiplier;

  @override
  int get hashCode => Object.hash(base, multiplier);

  @override
  String toString() => '$base × $multiplier';
}

/// 全局快捷键作用域。
///
/// * 桌面端：空格播放/暂停，左右方向键切歌；
/// * Android TV / 车机（[TvFocusMode.enabled] 为 true）：**左右方向键必须留给
///   焦点遍历**，不能再绑成切歌，否则遥控器左右键只会切歌、控件焦点无法移动。
///   TV 上的"上一首/下一首"由遥控器媒体键（见 [TvNavigationScope]）负责。
class AppShortcutScope extends StatelessWidget {
  const AppShortcutScope({
    super.key,
    required this.player,
    required this.child,
  });

  final PlayerController player;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isTv = TvFocusMode.enabled;
    return Shortcuts(
      shortcuts: {
        const SingleActivator(LogicalKeyboardKey.space):
            const _PlayPauseIntent(),
        // 仅在桌面端把左右键设为切歌；TV 上让位给焦点遍历。
        if (!isTv) ...{
          const SingleActivator(LogicalKeyboardKey.arrowRight):
              const _NextIntent(),
          const SingleActivator(LogicalKeyboardKey.arrowLeft):
              const _PreviousIntent(),
        },
      },
      child: Actions(
        actions: {
          _PlayPauseIntent: CallbackAction<_PlayPauseIntent>(
            onInvoke: (_) {
              // 输入框聚焦时不拦截空格。
              final focused = FocusManager.instance.primaryFocus;
              final editing = focused
                  ?.context
                  ?.findAncestorWidgetOfExactType<EditableText>();
              if (editing == null) player.togglePlay();
              return null;
            },
          ),
          _NextIntent: CallbackAction<_NextIntent>(
            onInvoke: (_) {
              player.next();
              return null;
            },
          ),
          _PreviousIntent: CallbackAction<_PreviousIntent>(
            onInvoke: (_) {
              player.previous();
              return null;
            },
          ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}

class _PlayPauseIntent extends Intent {
  const _PlayPauseIntent();
}
class _NextIntent extends Intent {
  const _NextIntent();
}
class _PreviousIntent extends Intent {
  const _PreviousIntent();
}

/// ====【新增/Android TV 遥控器适配】====
///
/// 跨 FocusScope 的焦点桥接。
///
/// 车机布局中左侧播放面板与右侧内容分处两个 FocusScope，Flutter 的方向键遍历
/// 只在**同一个 scope** 内工作，导致：
///   * 内容区按左键，焦点**进不去**左侧面板；
///   * 反之亦然。
///
/// 这里在车机布局外层拦一层 `Focus.onKeyEvent`（它比根部的默认方向键 Shortcuts
/// 更靠近焦点，因此能先拿到按键）：
///   * 内容区按左且**已无更左的可聚焦节点**时 → 把焦点交给左侧面板首个可聚焦项；
///   * 左侧面板按右时 → 把焦点交回内容区上次聚焦的位置。
/// 其余情况一律 `ignored`，交还框架默认的几何遍历，不改变既有顺序。
class _CarFocusBridge extends StatefulWidget {
  const _CarFocusBridge({
    required this.panelKey,
    required this.contentKey,
    required this.child,
  });

  final GlobalKey panelKey;
  final GlobalKey contentKey;
  final Widget child;

  @override
  State<_CarFocusBridge> createState() => _CarFocusBridgeState();
}

class _CarFocusBridgeState extends State<_CarFocusBridge> {
  FocusNode? _lastContentFocus;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_track);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_track);
    super.dispose();
  }

  /// 记录内容区最近一次聚焦的节点，供"从面板按右键回来"时恢复。
  void _track() {
    if (!TvFocusMode.enabled) return;
    try {
      final f = FocusManager.instance.primaryFocus;
      if (f != null && _isIn(f.context, widget.contentKey)) {
        _lastContentFocus = f;
      }
    } catch (_) {
      // 焦点跟踪属于增强功能，任何异常都不应影响主流程。
    }
  }

  bool _isIn(BuildContext? ctx, GlobalKey key) {
    final ancestor = key.currentContext;
    if (ctx == null || ancestor == null) return false;
    var found = false;
    ctx.visitAncestorElements((el) {
      if (identical(el, ancestor)) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  FocusNode? _firstFocusable(BuildContext? ctx) {
    if (ctx == null) return null;
    FocusNode? found;
    void visit(Element el) {
      if (found != null) return;
      final w = el.widget;
      if (w is Focus && w.canRequestFocus != false) {
        final n = w.focusNode;
        if (n != null && n.canRequestFocus) {
          found = n;
          return;
        }
      }
      el.visitChildren(visit);
    }

    (ctx as Element).visitChildren(visit);
    return found;
  }

  /// 判断当前焦点节点在其 scope 内、其"正左侧"是否还存在可聚焦邻居。
  /// 用于决定能否把左键交给默认遍历（有邻居）还是需要桥接到左侧面板（无邻居）。
  bool _hasDirectLeftNeighbor(FocusNode f) {
    try {
      final scope = f.nearestScope;
      final ro = f.context?.findRenderObject();
      if (scope == null || ro is! RenderBox || !ro.hasSize) return false;
      final myRect = ro.localToGlobal(Offset.zero) & ro.size;
      for (final n in scope.traversalDescendants) {
        if (identical(n, f)) continue;
        final r = n.context?.findRenderObject();
        if (r is! RenderBox || !r.hasSize) continue;
        final rect = r.localToGlobal(Offset.zero) & r.size;
        final vOverlap =
            rect.top < myRect.bottom - 1 && rect.bottom > myRect.top + 1;
        if (vOverlap && rect.right <= myRect.left + 1) return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!TvFocusMode.enabled) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final isLeft = key == LogicalKeyboardKey.arrowLeft;
    final isRight = key == LogicalKeyboardKey.arrowRight;
    if (!isLeft && !isRight) return KeyEventResult.ignored;

    try {
      final f = FocusManager.instance.primaryFocus;
      if (f == null) return KeyEventResult.ignored;
      final inPanel = _isIn(f.context, widget.panelKey);
      final inContent = _isIn(f.context, widget.contentKey);
      if (!inPanel && !inContent) return KeyEventResult.ignored;

      // 内容区按左：若左侧已无邻居，则跨到左侧播放面板。
      if (isLeft && inContent) {
        if (_hasDirectLeftNeighbor(f)) return KeyEventResult.ignored;
        final target = _firstFocusable(widget.panelKey.currentContext);
        if (target != null && target.canRequestFocus) {
          target.requestFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }

      // 左侧面板按右：跨回内容区（优先回到上次内容区焦点）。
      if (isRight && inPanel) {
        final target = _lastContentFocus ??
            _firstFocusable(widget.contentKey.currentContext);
        if (target != null && target.canRequestFocus) {
          target.requestFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }
    } catch (_) {
      // 桥接失败时交还框架默认遍历，绝不吞键。
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: widget.child,
    );
  }
}
