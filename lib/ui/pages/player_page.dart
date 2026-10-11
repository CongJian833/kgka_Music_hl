import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'dart:ui' as ui; // ====【需求/离线高斯位图】as 别名以引用 ui.Image(避免与 material 的 Image widget 冲突)====

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerSignalEvent, PointerScrollEvent;
import '../design_tokens.dart';
import '../widgets/tv_focus.dart'; // ====【新增/TV 遥控器焦点】====
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lyric/flutter_lyric.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../services/main_thread_lag_monitor.dart';
import '../../controllers/theme_controller.dart';
import '../../models/music_models.dart';
import '../../services/lyric_converter.dart';
import '../../services/lyric_adjustments.dart'; // ====【新增/歌词调整】集中配置服务 ====
import '../widgets/audio_effects_sheet.dart';
import '../widgets/window_title_bar.dart';
import '../widgets/audio_quality_sheet.dart';
import '../widgets/blurred_lyric_view.dart';
import '../widgets/artwork.dart';
import '../widgets/playback_speed_sheet.dart';
import '../widgets/sleep_timer_sheet.dart';
import '../widgets/song_action_sheets.dart';
import '../widgets/toast.dart';
import 'artist_detail_page.dart';
import 'comment_page.dart';
import 'desktop_lyrics_settings_page.dart';
import 'rhythm_game/rhythm_game_page.dart';
import 'settings_page.dart'; // ====【新增】更多菜单-设置 ====
import 'lyric_adjustments_page.dart'; // ====【新增/歌词调整】更多菜单-歌词调整 ====

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.player,
    required this.auth,
  });

  final PlayerController player;
  final AuthController auth;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  static const _screenChannel = MethodChannel('kgka_music_hl/screen');

  @override
  void initState() {
    super.initState();
    unawaited(_setKeepScreenOn(true));
    // 不在此处调用 setPreferredOrientations：方向策略由 ThemeController 全局管理。
    // 如果这里解锁方向，即使用户在设置里没开横屏模式，旋转手机时播放页也会
    // 跟着旋转，影响竖屏体验。
  }

  @override
  void dispose() {
    unawaited(_setKeepScreenOn(false));
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _setKeepScreenOn(bool enabled) async {
    try {
      await _screenChannel.invokeMethod<void>('setKeepScreenOn', enabled);
    } on MissingPluginException {
      // Non-Android targets can ignore this page-level screen setting.
    } on PlatformException {
      // Keeping playback usable is more important than failing the page open.
    }
  }

  @override
  Widget build(BuildContext context) {
    // ====【诊断/启动卡顿】==== 播放器页顶层 build 耗时。
    final diagSw = Stopwatch()..start();
    try {
      return _buildPlayerPage(context);
    } finally {
      diagSw.stop();
      MainThreadLagMonitor.record('playerPage.build', diagSw.elapsedMilliseconds);
    }
  }

  Widget _buildPlayerPage(BuildContext context) {
    // ===== 【性能优化】播放器页顶层改为"条件重建"门控，静态层不再随位置 notify 全量重建 =====
    // 原实现：AnimatedBuilder(animation: player) 包住整个 body。player 的位置流会高频
    // notifyListeners（可能每帧），导致背景/封面/顶栏/控制栏/歌词等所有子件每次都
    // 全量 rebuild + 重绘，是播放器页 GPU 占用高达 60% 左右的主要来源（即使背景/封面
    // 已加 RepaintBoundary，父层每次 rebuild 依旧会让静态子件 markNeedsPaint）。
    // 新实现：改为 _PlayerGate 条件重建——只对真正的结构性状态（当前歌曲、UI 可见性、
    // 播放/暂停、准备中）变化才重建静态 body；位置 notify 时静态层直接跳过 build。
    // 依赖位置的进度条改为 _Progress 内部 ListenableBuilder 局部更新，歌词本就用自身
    // ticker(~20fps) 驱动，二者不牵连静态层。
    return _PlayerGate(
      player: widget.player,
      auth: widget.auth,
      onClose: () => Navigator.of(context).pop(),
      onQueue: () => _showQueue(context),
    );
    // ===== 原实现（备份，供回退）=====
    // ===== 顶层驱动方式：AnimatedBuilder(listenable: widget.player) 全包 body =====
    // return AnimatedBuilder(
    //   animation: widget.player,
    //   builder: (context, _) {
    //     final song = widget.player.currentSong;
    //     if (song == null) {
    //       return const Scaffold(body: SizedBox.shrink());
    //     }
    //     final body = _PlayerBody(
    //       player: widget.player,
    //       auth: widget.auth,
    //       song: song,
    //       onClose: () => Navigator.of(context).pop(),
    //       onQueue: () => _showQueue(context),
    //     );
    //     return TickerMode(
    //       enabled: widget.player.isUIVisible,
    //       child: body,
    //     );
    //   },
    // );
  }

  void _showQueue(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (context) {
        return AnimatedBuilder(
          animation: widget.player,
          builder: (context, _) {
            return ListView.builder(
              itemCount: widget.player.queue.length,
              itemBuilder: (context, index) {
                final song = widget.player.queue[index];
                final active = widget.player.currentSong?.hash == song.hash;
                return ListTile(
                  selected: active,
                  leading: Artwork(url: song.coverUrl, size: 44),
                  title: Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.player.playSong(song, queue: widget.player.queue);
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

/// ===== 【性能优化】播放器页顶层"条件重建"门控 =====
///
/// 背景：原顶层用 `AnimatedBuilder(listenable: player)` 包住整个 body，而 player 的
/// 位置流会高频 notifyListeners（可能每帧）。由于 notifyListeners 不分事件类型，
/// 无法在 ListenableBuilder 层面区分"位置变化"与"切歌/播放态变化"，导致 body 内
/// 所有静态子件（背景、封面、顶栏、控制栏等）每次都全量 rebuild + 重绘。
///
/// 做法：这里用一个固定监听器 `_onPlayerChanged`，只在"真正的结构性状态"（当前歌曲、
/// UI 可见性、播放/暂停、是否准备中）发生翻转时才 setState 重建。位置 notify 时这些
/// 值通常保持稳定，直接跳过，从而静态 body 不再随每次 notify 全量重建。
/// 依赖播放位置的高频部件（进度条 → 自身 ListenableBuilder、歌词 → 自身 ticker）
/// 已各自独立局部更新，不牵连静态层。性能模式/画风/交互行为与视觉、导航完全不变。
class _PlayerGate extends StatefulWidget {
  const _PlayerGate({
    required this.player,
    required this.auth,
    required this.onClose,
    required this.onQueue,
  });

  final PlayerController player;
  final AuthController auth;
  final VoidCallback onClose;
  final VoidCallback onQueue;

  @override
  State<_PlayerGate> createState() => _PlayerGateState();
}

class _PlayerGateState extends State<_PlayerGate> {
  Song? _lastSong;
  bool _lastUIVisible = true;
  bool _lastIsPlaying = false;
  bool _lastIsPreparing = false;
  // ===== 【重构】性能 4 个独立开关作为结构性状态（任一翻转即触发静态 body 重建）=====
  // 替代原单一 performanceMode 字段及 _lastPerformanceMode 比较（原实现备份于下）。
  bool _lastPerfLyricBlurOff = false;
  bool _lastPerfBgAnimOff = false;
  bool _lastPerfCoverAnimOff = false;
  bool _lastPerfLightLyric = false;
  // ===== 原实现（备份，供回退）=====
  // bool _lastPerformanceMode = false;
  PlaybackMode _lastPlaybackMode = PlaybackMode.playlistLoop;
  List<LyricLine>? _lastLyrics;

  @override
  void initState() {
    super.initState();
    _lastSong = widget.player.currentSong;
    _lastUIVisible = widget.player.isUIVisible;
    _lastIsPlaying = widget.player.isPlaying;
    _lastIsPreparing = widget.player.isPreparing;
    _lastPerfLyricBlurOff = widget.player.perfLyricBlurOff;
    _lastPerfBgAnimOff = widget.player.perfBgAnimOff;
    _lastPerfCoverAnimOff = widget.player.perfCoverAnimOff;
    _lastPerfLightLyric = widget.player.perfLightLyric;
    _lastPlaybackMode = widget.player.playbackMode;
    _lastLyrics = widget.player.lyrics;
    widget.player.addListener(_onPlayerChanged);
  }

  @override
  void dispose() {
    widget.player.removeListener(_onPlayerChanged);
    super.dispose();
  }

  /// 位置 notify 时，除 smoothPosition 外的所有"结构性/离散"状态都保持稳定，因此不会
  /// 命中这里条件、不会重建静态 body；只有这些状态真实翻转时才 setState 重建。
  void _onPlayerChanged() {
    final p = widget.player;
    final song = p.currentSong;
    final uiVisible = p.isUIVisible;
    final isPlaying = p.isPlaying;
    final isPreparing = p.isPreparing;
    // ===== 【重构】性能 4 个独立开关任一翻转即视为结构性状态变化，触发重建 =====
    final perfLyricBlurOff = p.perfLyricBlurOff;
    final perfBgAnimOff = p.perfBgAnimOff;
    final perfCoverAnimOff = p.perfCoverAnimOff;
    final perfLightLyric = p.perfLightLyric;
    final playbackMode = p.playbackMode;
    final lyrics = p.lyrics;
    if (song != _lastSong ||
        uiVisible != _lastUIVisible ||
        isPlaying != _lastIsPlaying ||
        isPreparing != _lastIsPreparing ||
        perfLyricBlurOff != _lastPerfLyricBlurOff ||
        perfBgAnimOff != _lastPerfBgAnimOff ||
        perfCoverAnimOff != _lastPerfCoverAnimOff ||
        perfLightLyric != _lastPerfLightLyric ||
        playbackMode != _lastPlaybackMode ||
        lyrics != _lastLyrics) {
      _lastSong = song;
      _lastUIVisible = uiVisible;
      _lastIsPlaying = isPlaying;
      _lastIsPreparing = isPreparing;
      _lastPerfLyricBlurOff = perfLyricBlurOff;
      _lastPerfBgAnimOff = perfBgAnimOff;
      _lastPerfCoverAnimOff = perfCoverAnimOff;
      _lastPerfLightLyric = perfLightLyric;
      _lastPlaybackMode = playbackMode;
      _lastLyrics = lyrics;
      // ====【修复/低端设备 UI 不刷新·防御】====
      // 上面已先把"上次状态记录"更新为新值，因此此处 setState 一旦丢失
      //（widget 已销毁、或异常时机）就再没有任何重建机会，UI 会永久停在旧状态。
      // 故补 mounted 判断：未挂载时不更新记录，保证 widget 重建后仍能检出差异。
      if (!mounted) {
        _lastSong = null;
        return;
      }
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.player.currentSong;
    if (song == null) {
      return const Scaffold(body: SizedBox.shrink());
    }

    // ===== 【修复】收进托盘后停掉播放器页所有动画 Ticker，降低隐藏态 GPU 占用 =====
    // 仅收进托盘(isUIVisible=false)时停用全部 Ticker。性能模式不停用整体 Ticker
    // （那会连带停掉歌词滚动/高亮），只单独暂停封面/背景旋转（见各旋转 widget 的
    // _syncRotation）。
    return TickerMode(
      enabled: widget.player.isUIVisible,
      child: _PlayerBody(
        player: widget.player,
        auth: widget.auth,
        song: song,
        onClose: widget.onClose,
        onQueue: widget.onQueue,
      ),
    );
  }
}

class _PlayerBody extends StatefulWidget {
  const _PlayerBody({
    required this.player,
    required this.auth,
    required this.song,
    required this.onClose,
    required this.onQueue,
  });

  final PlayerController player;
  final AuthController auth;
  final Song song;
  final VoidCallback onClose;
  final VoidCallback onQueue;

  @override
  State<_PlayerBody> createState() => _PlayerBodyState();
}

Future<void> _showAudioQualityPicker(
  BuildContext context,
  PlayerController player,
) async {
  final quality = await showAudioQualitySheet(
    context: context,
    selected: player.audioQuality,
    title: '切换音质',
    subtitle: '会重新加载当前歌曲并尽量保持播放进度',
  );
  if (quality == null) {
    return;
  }

  await player.setAudioQuality(quality, reloadCurrent: true);
  Toast.success('已切换到 ${quality.label}');
}

class _PlayerBodyState extends State<_PlayerBody> {
  final _pageController = PageController();
  var _page = 0;
  var _pageScrolling = false;
  bool? _lastSystemUiLandscape;

  bool get _lyricPageVisible => _page == 1 || _pageScrolling;

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    if (size.height < 150 || size.width < 150) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: SizedBox.shrink(),
      );
    }
    final landscape = size.width > size.height;
    _syncSystemUi(landscape);
    // 横屏分栏布局是车机专属，普通横屏仍用竖屏的翻页布局。
    final isCarLayout = landscape && ThemeController.instance.carModeEnabled;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            _ArtworkBackground(song: widget.song, player: widget.player),
            SafeArea(
              // 横屏时同样需要处理顶部状态栏和底部系统导航栏（如车机空调控制栏）的遮挡。
              // 竖屏已由外层 Scaffold 处理，这里对所有方向统一保留 SafeArea。
              child: Column(
                children: [
                  if (!isCarLayout)
                    _TopBar(
                      player: widget.player,
                      auth: widget.auth,
                      song: widget.song,
                      onClose: widget.onClose,
                      onArtistTap: _openArtist,
                    ),
                  Expanded(
                    child: isCarLayout
                        ? ExcludeSemantics(
                            child: _LandscapePlayerContent(
                              player: widget.player,
                              auth: widget.auth,
                              song: widget.song,
                              onClose: widget.onClose,
                              onQueue: widget.onQueue,
                              onArtistTap: _openArtist,
                            ),
                          )
                        : NotificationListener<ScrollNotification>(
                            onNotification: _handlePageScrollNotification,
                            child: PageView(
                              controller: _pageController,
                              allowImplicitScrolling: true,
                              onPageChanged: (value) =>
                                  _setPageState(page: value),
                              children: [
                                _PosterPlayerPage(
                                  key: const PageStorageKey(
                                    'poster-player-page',
                                  ),
                                  player: widget.player,
                                  song: widget.song,
                                  onQueue: widget.onQueue,
                                  onSwitchToLyrics: _switchToLyricPage,
                                ),
                                _LyricPlayerPage(
                                  key: const PageStorageKey(
                                    'lyric-player-page',
                                  ),
                                  player: widget.player,
                                  song: widget.song,
                                  isPageVisible: _lyricPageVisible,
                                  onReturnToPoster: _returnToPosterPage,
                                ),
                              ],
                            ),
                          ),
                  ),
                  if (!isCarLayout) _PageDots(page: _page),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _syncSystemUi(bool landscape) {
    if (_lastSystemUiLandscape == landscape) {
      return;
    }
    _lastSystemUiLandscape = landscape;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    });
  }

  bool _handlePageScrollNotification(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.horizontal) {
      return false;
    }

    if (notification is ScrollStartNotification) {
      _setPageState(scrolling: true);
    } else if (notification is ScrollEndNotification) {
      final page = (_pageController.page ?? _page.toDouble()).round().clamp(
        0,
        1,
      );
      _setPageState(page: page, scrolling: false);
    }
    return false;
  }

  void _setPageState({int? page, bool? scrolling}) {
    final nextPage = page ?? _page;
    final nextScrolling = scrolling ?? _pageScrolling;

    if (nextPage == _page && nextScrolling == _pageScrolling) {
      return;
    }

    setState(() {
      _page = nextPage;
      _pageScrolling = nextScrolling;
    });
  }

  /// 封面页点击封面/歌词预览区域：切换到歌词滚动页。
  void _switchToLyricPage() {
    if (!_pageController.hasClients) return;
    _pageController.animateToPage(
      1,
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
    );
  }

  /// 歌词页点击歌词：返回封面页。
  void _returnToPosterPage() {
    if (!_pageController.hasClients) return;
    _pageController.animateToPage(
      0,
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _openArtist(Song song) async {
    if (song.source != SongSource.kugou) {
      Toast.info('其他平台歌曲暂不支持查看歌手');
      return;
    }
    final artists = song.artists;
    if (artists.isEmpty) {
      Toast.info('暂无歌手详情');
      return;
    }

    ArtistRef? selected;
    if (artists.length == 1) {
      selected = artists.first;
    } else {
      selected = await showModalBottomSheet<ArtistRef>(
        context: context,
        showDragHandle: true,
        backgroundColor: Theme.of(context).colorScheme.surface,
        builder: (context) {
          return SafeArea(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              itemCount: artists.length,
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemBuilder: (context, index) {
                final artist = artists[index];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundImage: artist.avatarUrl == null
                        ? null
                        : NetworkImage(artist.avatarUrl!),
                    child: artist.avatarUrl == null
                        ? const Icon(Icons.person_rounded)
                        : null,
                  ),
                  title: Text(artist.name),
                  onTap: () => Navigator.of(context).pop(artist),
                );
              },
            ),
          );
        },
      );
    }

    if (selected == null || !mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArtistDetailPage(
          api: widget.player.api,
          auth: widget.auth,
          artist: selected!,
          player: widget.player,
        ),
      ),
    );
  }
}

enum _LyricDisplayMode {
  lyricsWithTranslation,
  lyricsOnly,
  lyricsWithRomanization,
}

List<_LyricDisplayMode> _availableLyricDisplayModes(List<LyricLine> lyrics) {
  if (lyrics.isEmpty) {
    return const [];
  }

  final modes = <_LyricDisplayMode>[];
  final hasTranslation = lyrics.any(
    (line) => line.translation != null && line.translation!.isNotEmpty,
  );
  final hasRomanization = lyrics.any(
    (line) => line.romanization != null && line.romanization!.isNotEmpty,
  );

  if (hasTranslation) {
    modes.add(_LyricDisplayMode.lyricsWithTranslation);
  }
  modes.add(_LyricDisplayMode.lyricsOnly);
  if (hasRomanization) {
    modes.add(_LyricDisplayMode.lyricsWithRomanization);
  }
  return modes;
}

String _lyricDisplayModeLabel(_LyricDisplayMode mode) {
  return switch (mode) {
    _LyricDisplayMode.lyricsWithTranslation => '歌词 + 翻译',
    _LyricDisplayMode.lyricsWithRomanization => '歌词 + 音译',
    _LyricDisplayMode.lyricsOnly => '仅歌词',
  };
}

class _ArtworkBackground extends StatefulWidget {
  const _ArtworkBackground({required this.song, required this.player});

  final Song song;
  final PlayerController player;

  @override
  State<_ArtworkBackground> createState() => _ArtworkBackgroundState();
}

class _ArtworkBackgroundState extends State<_ArtworkBackground>
    with SingleTickerProviderStateMixin {
  // =====【需求/性能优化·背景旋转】原"高性能缓存模糊"方案(JPG 模糊已缓存+旋转)
  // 实测 GPU 仍高：ImageFiltered(σ=34) 图层在旋转时很难被位图缓存，且作用域是
  // 1.5×屏大图层，旋转期间每帧都在做全屏高斯卷积+放大 → GPU fill/卷积开销巨大。
  // 故废除 ImageFiltered(不再每帧卷积)。关键权衡是【解码分辨率】：
  //  - 太细(如 108px)：放大铺屏成色块/马赛克，损失色调层次，观感差；
  //  - 太粗(如原图全尺寸)：GPU 将该大纹理 blit 放大铺满 1.5×屏，fill 又上来。
  // 故【效果+性能并重】重构为：极小源纹理(≈0.18×屏长边)上先做高斯模糊(无色团马赛克、柔和)，
  // 放大铺屏=柔和渐变背景；旋转仅 blit 小纹理 + 限帧 ~25fps → GPU 接近"转小图"。原实现见 backup。
  late final AnimationController _rotationController;
  // 背景旋转【限帧】定时器：慢速背景旋转无需 60fps（每帧都对整屏做 fill，这才是 GPU 大头）。
  // 降到 ~25fps 直接把每帧 fill 的次数砍去约 60%，观感几乎不变。用 Timer 手动推进角度，
  // 避免 AnimationController 默认 60fps 驱动。
  Timer? _bgRotationTimer;
  bool _bgRotating = false;
  // =====【需求/性能优化·离线高斯位图（跨平台根治每帧滤镜）】=====
  // 封面加载时离屏一次性生成"已高斯模糊"的小位图缓存到 _bgBlurImage，之后旋转直接 RawImage 转它，
  // 渲染管线无 ImageFiltered，杜绝每帧重算高斯(Windows/Android 一致)。切歌/封面变化用 _bgReqId 防竞态。
  ui.Image? _bgBlurImage;
  int _bgReqId = 0;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 40), // 40 seconds for a full rotation
    );
    // 背景旋转动画跟随播放状态：暂停时停在当前角度，恢复播放时从暂停处继续。
    widget.player.addListener(_syncRotation);
    _syncRotation();
    // 【离线高斯位图】首帧后离屏生成已模糊位图(需 MediaQuery 尺寸就绪，故用 post-frame)。
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _loadBackgroundBlur(widget.song.coverUrl),
    );
  }

  @override
  void dispose() {
    widget.player.removeListener(_syncRotation);
    _bgRotationTimer?.cancel();
    _bgRotationTimer = null;
    _bgBlurImage?.dispose();
    _bgBlurImage = null;
    _rotationController.dispose();
    super.dispose();
  }

  // 【离线高斯位图】封面/尺寸就绪后重新生成；didUpdateWidget 在切歌时被调。
  @override
  void didUpdateWidget(covariant _ArtworkBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.coverUrl != widget.song.coverUrl) {
      _loadBackgroundBlur(widget.song.coverUrl);
    }
  }

  // 离屏一次性生成"已高斯模糊"的小位图，缓存后不再参与渲染滤镜(旋转直接转 RawImage)。
  //
  // ====【修复/封面与背景过渡不同步】====
  // 原实现用独立 HttpClient 重新下载封面字节并自行解码 —— 与封面（Image.network 走
  // ImageCache）是两条独立管线，背景必然比封面晚就绪（实测 79~284ms），淡入无法同步。
  // 现改为解析【与封面完全相同的 ImageProvider】（同 url + 同解码宽度）：
  //  · 封面已下载/已预热 → resolve 立即命中 ImageCache，仅剩模糊渲染（几毫秒~几十毫秒）；
  //  · 封面尚未下载 → 复用同一次网络下载（ImageCache 按 provider 去重），二者同时就绪。
  // 图像归 ImageCache / 封面所有：在监听回调内 clone 一份 ImageInfo 句柄供本次使用、用完
  // dispose 该句柄，绝不 dispose ui.Image 本体（否则会破坏封面正在使用的缓存图像）。
  Future<void> _loadBackgroundBlur(String? url) async {
    if (url == null || url.isEmpty) return;
    if (!url.startsWith('http://') && !url.startsWith('https://')) return;
    final reqId = ++_bgReqId;
    final maxDim = math.max(
      MediaQuery.sizeOf(context).width,
      MediaQuery.sizeOf(context).height,
    );
    // 高斯 σ：越大越糊。10 进一步弱化模糊，背景更清楚但仍保留背景质感。
    // 演化：22(过于平滑)→14→10(现在，微调再清晰一点点)。
    const sigma = 10.0;
    // 目标位图边长：≈0.40×屏长边，放大约 2.5×，双线性保留更细层次，看得清封面内容。
    final target = (maxDim * 0.40).round();
    ImageStream? stream;
    ImageStreamListener? listener;
    ImageInfo? info;
    try {
      // 与封面同一个 provider（同 url + 同解码宽度 → 命中同一 ImageCache 条目）
      final provider = playerCoverProvider(url);
      final completer = Completer<ImageInfo>();
      stream = provider.resolve(createLocalImageConfiguration(context));
      listener = ImageStreamListener(
        (imageInfo, _) {
          if (!completer.isCompleted) {
            // clone：监听回调返回后原句柄即失效，clone 出的句柄由本方法持有并释放。
            completer.complete(imageInfo.clone());
          }
        },
        onError: (error, stackTrace) {
          if (!completer.isCompleted) completer.completeError(error);
        },
      );
      stream.addListener(listener);
      info = await completer.future;
      if (!mounted || reqId != _bgReqId) return;
      final src = info.image;
      // ===== 封面 cover 裁到方形 → 离屏高斯模糊（本方法仅此一步在主 isolate）=====
      final srcW = src.width.toDouble();
      final srcH = src.height.toDouble();
      final scale = math.max(target / srcW, target / srcH);
      final sw = target / scale;
      final sh = target / scale;
      final sdx = (srcW - sw) / 2;
      final sdy = (srcH - sh) / 2;
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final pad = sigma * 2;
      canvas.saveLayer(
        Rect.fromLTWH(0, 0, target.toDouble(), target.toDouble()).inflate(
          pad,
        ),
        ui.Paint()
          ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      );
      canvas.drawImageRect(
        src,
        Rect.fromLTWH(sdx, sdy, sw, sh),
        Rect.fromLTWH(0, 0, target.toDouble(), target.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.low,
      );
      canvas.restore();
      final blurred = await recorder.endRecording().toImage(target, target);
      if (!mounted || reqId != _bgReqId) {
        blurred.dispose();
        return;
      }
      _bgBlurImage?.dispose();
      _bgBlurImage = blurred;
      if (mounted) setState(() {});
    } catch (_) {
      // 失败静默：渐变兜底仍在 Stack 中。
    } finally {
      // 释放本方法 clone 的 ImageInfo 句柄；ui.Image 本体归 ImageCache / 封面所有，不可 dispose。
      try {
        info?.dispose();
      } catch (_) {}
      if (stream != null && listener != null) {
        try {
          stream.removeListener(listener);
        } catch (_) {}
      }
    }
  }

  void _syncRotation() {
    // ===== 【重构·需求/性能优化】背景旋转：独立开关 perfBgAnimOff 控制 + 限帧 ~25fps =====
    // 关键认知：铺满全屏的旋转，每一帧 GPU 都要对整屏做 fill。60fps 就是 GPU 大头。
    // 降到 ~25fps 直接把每帧 fill 次数砍去约 60%，观感几乎不变(40s/周慢速旋转)。
    // 用 Timer 手动推进角度，避开 AnimationController 默认 60fps 驱动。
    // 原实现（备份，供回退）：_rotationController.repeat()（60fps）。
    final wantPlay = widget.player.isPlaying && !widget.player.perfBgAnimOff;
    if (wantPlay) {
      if (!_bgRotating) {
        _bgRotating = true;
        _bgRotationTimer = Timer.periodic(
          const Duration(milliseconds: 40), // ≈25fps
          (_) => _rotationController.value =
              (_rotationController.value + 1 / (40 / 0.04)) % 1.0,
        );
      }
    } else {
      if (_bgRotating) {
        _bgRotating = false;
        _bgRotationTimer?.cancel();
        _bgRotationTimer = null;
      }
      if (_rotationController.isAnimating) {
        // canceled: false 保留当前进度，恢复时不会跳回起点。
        _rotationController.stop(canceled: false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final coverUrl = widget.song.coverUrl;
    final size = MediaQuery.sizeOf(context);
    final maxDim = math.max(size.width, size.height);
    final squareSize = maxDim * 1.5;
    // 【离线高斯位图】背景模糊由 _loadBackgroundBlur 离屏生成并缓存到 _bgBlurImage(极小尺寸、高斯柔和)，
    // build 不再有 ImageFiltered/Image.network → 每帧零高斯零滤镜，旋转只 blit 已模糊位图。

    // ===== 【性能优化】背景是静态装饰层(旋转已在性能模式暂停) =====
    // 用 RepaintBoundary 隔离：即使播放器因播放位置高频 notify 而 rebuild，这段
    // (大图高斯模糊封面) 的合成层可被 GPU 缓存复用，避免每帧重算 blur——这是
    // 性能模式下 GPU 占用的大头来源之一。
    return RepaintBoundary(
      child: ExcludeSemantics(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 始终显示渐变兜底背景，避免封面加载期间出现纯黑背景
            const _FallbackBackground(),
            // 封面背景的旋转动画由 _syncRotation 在性能模式暂停；这里始终渲染
            // 背景，性能模式下背景保留为静态。
            if (coverUrl != null)
              OverflowBox(
                maxWidth: squareSize,
                maxHeight: squareSize,
                minWidth: squareSize,
                minHeight: squareSize,
                child: RotationTransition(
                  turns: _rotationController,
                  // =====【需求/性能优化·离线高斯位图 + 限帧旋转（跨平台根治）】=====
                  // 内层直接用 _loadBackgroundBlur 离屏生成的"已高斯模糊"位图(RawImage)，渲染树无
                  // ImageFiltered/Image.network → 每帧零高斯零滤镜重算；旋转仅 blit 这张小位图，
                  // 配合 _syncRotation 25fps 限帧 → Windows/Android 一致"转一张图"性能。
                  child: RepaintBoundary(
                    // ====【需求/视觉优先·切歌背景淡入】新歌离线模糊图就绪后用 AnimatedSwitcher
                    // 淡入；AnimatedSwitcher 内部 Stack 为 loose 约束，必须 SizedBox.expand 包住
                    // RawImage 撑满屏幕（否则 RawImage 按图片原始尺寸显示成小方形）。====
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child: _bgBlurImage == null
                          ? const SizedBox.expand(
                              key: ValueKey('bg-empty')) // 未就绪时用渐变兜底
                          : SizedBox.expand(
                              key: ValueKey(_bgBlurImage),
                              child: RawImage(
                                image: _bgBlurImage,
                                fit: BoxFit.cover,
                                filterQuality: ui.FilterQuality.medium,
                              ),
                            ),
                    ),
                  ),
                ),
                // =====【需求/性能优化】原实现（备份，供回退）：旋转在模糊内层，每帧对 1.5×屏大图重滤波。=====
                // child: ImageFiltered(
                //   imageFilter: _blurNormal,
                //   child: RotationTransition(
                //     turns: _rotationController,
                //     child: Image.network(coverUrl, fit: BoxFit.cover, errorBuilder: ... SizedBox.shrink()),
                //   ),
                // ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: .32),
                  Colors.black.withValues(alpha: .56),
                  Colors.black.withValues(alpha: .82),
                ],
              ),
            ),
          ),
          ColoredBox(color: Colors.black.withValues(alpha: .12)),
        ],
      ),
      ),
    );
  }
}

class _FallbackBackground extends StatelessWidget {
  const _FallbackBackground();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF153D35), Color(0xFF061219), Color(0xFF2C1320)],
        ),
      ),
    );
  }
}

class _LandscapePlayerContent extends StatelessWidget {
  const _LandscapePlayerContent({
    required this.player,
    required this.auth,
    required this.song,
    required this.onClose,
    required this.onQueue,
    required this.onArtistTap,
  });

  final PlayerController player;
  final AuthController auth;
  final Song song;
  final VoidCallback onClose;
  final VoidCallback onQueue;
  final ValueChanged<Song> onArtistTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 350;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 14 : 24,
            compact ? 4 : 10,
            compact ? 16 : 30,
            compact ? 24 : 36,
          ),
          child: Column(
            children: [
              _LandscapeHeader(
                player: player,
                auth: auth,
                song: song,
                onClose: onClose,
                compact: compact,
                onArtistTap: onArtistTap,
              ),
              SizedBox(height: compact ? 2 : 10),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      flex: 9,
                      child: _LandscapeArtworkShowcase(
                        player: player,
                        song: song,
                        compact: compact,
                      ),
                    ),
                    SizedBox(width: compact ? 18 : 34),
                    Expanded(
                      flex: 12,
                      child: _LandscapeRightPanel(
                        player: player,
                        onQueue: onQueue,
                        compact: compact,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LandscapeHeader extends StatelessWidget {
  const _LandscapeHeader({
    required this.player,
    required this.auth,
    required this.song,
    required this.onClose,
    required this.compact,
    required this.onArtistTap,
  });

  final PlayerController player;
  final AuthController auth;
  final Song song;
  final VoidCallback onClose;
  final bool compact;
  final ValueChanged<Song> onArtistTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: auth,
      builder: (context, _) {
        final liked = auth.isLiked(song);
        return Padding(
          padding: EdgeInsets.only(
            right: Platform.isWindows ? WindowTitleBar.controlAreaRight : 0,
          ),
          child: SizedBox(
            height: compact ? 40 : 48,
            child: Row(
            children: [
              _LandscapeHeaderButton(
                tooltip: '返回',
                size: compact ? 38 : 44,
                iconSize: compact ? 30 : 34,
                onPressed: onClose,
                icon: Icons.keyboard_arrow_left_rounded,
              ),
              SizedBox(width: compact ? 10 : 18),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white.withValues(alpha: .92),
                        fontSize: compact ? 14 : 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (!compact)
                      Text(
                        song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(
                              color: Colors.white.withValues(alpha: .7),
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                  ],
                ),
              ),
              _LandscapeHeaderButton(
                tooltip: liked ? '取消喜欢' : '喜欢',
                size: compact ? 38 : 44,
                iconSize: compact ? 22 : 24,
                onPressed: song.source == SongSource.kugou
                    ? () => auth.toggleLike(song)
                    : null,
                icon: liked
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
              ),
              SizedBox(width: compact ? 6 : 8),
              _LandscapeHeaderButton(
                tooltip: '更多',
                size: compact ? 38 : 44,
                iconSize: compact ? 22 : 24,
                onPressed: () => _showMoreSheet(context),
                icon: Icons.more_horiz_rounded,
              ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showMoreSheet(BuildContext context) {
    showSongActionSheet(
      context: context,
      song: song,
      actions: [
        // ====【新增】更多菜单-设置：车机/横屏更多菜单 ====
        SongSheetAction(
          icon: Icons.settings_rounded,
          title: '设置',
          onTap: () => _openPlayerSettings(context, player, auth),
        ),
        // ====【新增/歌词调整】更多菜单-歌词调整：车机/横屏更多菜单 ====
        SongSheetAction(
          icon: Icons.tune_rounded,
          title: '歌词调整',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => LyricAdjustmentsPage(player: player),
            ),
          ),
        ),
        SongSheetAction(
          icon: Icons.speed_rounded,
          title: '倍速播放',
          subtitle: player.playbackSpeedLabel,
          onTap: () => showPlaybackSpeedSheet(context: context, player: player),
        ),
        SongSheetAction(
          icon: Icons.high_quality_rounded,
          title: '音质：${player.audioQuality.label}',
          subtitle: '切换当前播放音质',
          onTap: () => _showAudioQualityPicker(context, player),
        ),
        SongSheetAction(
          icon: Icons.auto_awesome_rounded,
          title: '试听高潮',
          subtitle: '播放歌曲高潮片段',
          onTap: () async {
            final ok = await player.playClimaxPreview();
            if (!ok) Toast.error('暂无高潮片段');
          },
        ),
        SongSheetAction(
          icon: Icons.graphic_eq_rounded,
          title: '音效',
          subtitle: player.audioEffectsLabel,
          onTap: () => showAudioEffectsSheet(context: context, player: player),
        ),
        if (song.source == SongSource.kugou)
          SongSheetAction(
            icon: Icons.playlist_add_rounded,
            title: '添加到歌单',
            onTap: () =>
                showAddToPlaylistSheet(context: context, auth: auth, song: song),
          ),
        SongSheetAction(
          icon: Icons.bedtime_rounded,
          title: '定时播放',
          subtitle: player.isSleepTimerActive
              ? '剩余 ${_formatSleepRemaining(player.sleepTimerRemaining)}'
              : player.isSleepFinishCurrentSong
                  ? '播完歌曲后停止'
                  : null,
          onTap: () => showSleepTimerSheet(context: context, player: player),
        ),
        if (player.isDesktopLyricsSupported) ...[
          SongSheetAction(
            icon: player.desktopLyricsEnabled
                ? Icons.lyrics_rounded
                : Icons.lyrics_outlined,
            title: '桌面歌词',
            subtitle: player.desktopLyricsEnabled ? '已开启' : '已关闭',
            onTap: () async {
              Navigator.of(context).pop();
              await player.setDesktopLyricsEnabled(!player.desktopLyricsEnabled);
            },
          ),
          if (player.desktopLyricsEnabled)
            SongSheetAction(
              icon: Icons.tune_rounded,
              title: '歌词设置',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DesktopLyricsSettingsPage(player: player),
                ),
              ),
            ),
        ],
      ],
    );
  }
}

// ====【新增】更多菜单-设置：PlayerPage 跳转 SettingsPage 的参数拼装 ====
// SettingsPage 需要 api/auth/player/theme（必填）+ downloads/cache/localMusic（可选）。
// PlayerController 已暴露 api、cacheService、localMusic、downloadController，
// theme 使用全局单例 ThemeController.instance，故仅凭 player+auth 即可拼齐全部参数。
void _openPlayerSettings(
  BuildContext context,
  PlayerController player,
  AuthController auth,
) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => SettingsPage(
        api: player.api,
        auth: auth,
        player: player,
        theme: ThemeController.instance,
        downloads: player.downloadController,
        cache: player.cacheService,
        localMusic: player.localMusic,
      ),
    ),
  );
}

class _LandscapeHeaderButton extends StatelessWidget {
  const _LandscapeHeaderButton({
    required this.tooltip,
    required this.size,
    required this.iconSize,
    required this.onPressed,
    required this.icon,
  });

  final String tooltip;
  final double size;
  final double iconSize;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withValues(alpha: .12),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: SizedBox.square(
          dimension: size,
          child: IconButton(
            color: Colors.white,
            iconSize: iconSize,
            padding: EdgeInsets.zero,
            constraints: BoxConstraints.tightFor(width: size, height: size),
            onPressed: onPressed,
            icon: Icon(icon),
          ),
        ),
      ),
    );
  }
}

class _LandscapeArtworkShowcase extends StatefulWidget {
  const _LandscapeArtworkShowcase({
    required this.player,
    required this.song,
    required this.compact,
  });

  final PlayerController player;
  final Song song;
  final bool compact;

  @override
  State<_LandscapeArtworkShowcase> createState() =>
      _LandscapeArtworkShowcaseState();
}

class _LandscapeArtworkShowcaseState extends State<_LandscapeArtworkShowcase>
    with TickerProviderStateMixin {
  late final AnimationController _rotationController;
  // ====【需求/视觉·切歌不归位】当前这首歌封面的相位偏移（0~1，等价 0~360°）====
  // 唱片角度不再在切歌时归零，因此新封面出现时若不补偿，会带着旧角度斜着出现。
  // 在【新封面开始淡入的那一刻】把偏移设为当时的唱片角度，并对该封面反向旋转同样角度，
  // 使其出现时正好是正面(0°)、随后随唱片继续旋转 —— 即"视觉上不归位，但新封面仍从
  // 归位后的位置开始旋转"。用 ValueNotifier 而非 setState：_onCoverLoaded 由 Artwork 的
  // loadingBuilder 在 build 期间回调，那里 setState 会触发"build 期间 markNeedsBuild"错误。
  final ValueNotifier<double> _coverPhaseOffset = ValueNotifier<double>(0);
  // ====【需求/视觉优先·封面交叉淡入】同 _PosterPlayerPageState 方案：切歌保持旧封面，
  // 新封面图片就绪后交叉淡入（旧出+新进）；hash 标记防暂停/播放 rebuild 误触发。====
  late final AnimationController _coverFade; // 新封面 0→1（旧封面层保持不透明，新封面在上层淡入；
  // 淡入完成后移除旧封面层，见 _onCoverFadeStatus —— 否则半透明占位图会透出旧封面）
  String? _prevCoverUrl;
  String? _coverFadeAppliedHash;
  Timer? _coverFallbackTimer;
  // ====【修复/过渡被卡顿吞掉·已恢复即时淡入】====
  // 原实现"图片就绪后固定干等 300ms 再淡入"，用于避开切歌高峰卡顿（当时根因是 prefs
  // 同步整写 8.67MB 文件造成 ~890ms 主线程阻塞，会把动画吞掉）。该根因已修复（切歌路径
  // 0 次 prefs 写入 + prefs 瘦身到 ~100KB），故恢复"图片就绪即淡入"，并与背景淡入同步。====
  bool _fadeStarted = false;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 32),
    );
    const d = Duration(milliseconds: 300);
    _coverFade = AnimationController(vsync: this, duration: d, value: 1.0);
    // ====【修复/占位图透出旧封面】淡入完成后移除旧封面层：无封面歌曲的新封面是
    // Artwork 的 fallback（半透明渐变），若旧封面层仍留在下方会透出来，出现
    // "一半占位图、一半上一首封面"的观感；移除后仅占位图叠在页面背景上，观感正确。====
    _coverFade.addStatusListener(_onCoverFadeStatus);
    _syncRotation();
  }

  @override
  void didUpdateWidget(covariant _LandscapeArtworkShowcase oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.hash != widget.song.hash) {
      // ====【需求/视觉·切歌不归位】原实现此处 `_rotationController.value = 0`（强制归零），
      // 会让唱片"啪"地转回正面（可见跳变），且发生在过渡动画之前，观感割裂。现不再归零：
      // 旧封面保持当前角度继续旋转（视觉无跳变）；新封面靠 _coverPhaseOffset 相位偏移
      // 在其开始淡入时"从正面(0°)开始旋转"（见 _startFadeIn 与该偏移的用法）。====
      // ===== 原实现（备份，供回退）：_rotationController.value = 0; =====
      // 切歌：旧封面保留显示，新封面透明等待图片就绪（不立刻淡入占位）
      _prevCoverUrl = oldWidget.song.coverUrl;
      _coverFadeAppliedHash = null;
      _coverFade.value = 0;
      _coverFallbackTimer?.cancel();
      _fadeStarted = false;
      // 兜底：图加载失败/过慢时 2s 后仍淡入（显示 fallback），避免旧封面常驻
      _coverFallbackTimer = Timer(const Duration(seconds: 2), () {
        if (mounted && _coverFadeAppliedHash != widget.song.hash) {
          _coverFadeAppliedHash = widget.song.hash;
          _fadeStarted = false;
          _startFadeIn();
        }
      });
    }
    _syncRotation();
  }

  // 新封面图片加载完成 → 交叉淡入（hash 标记防暂停/播放 rebuild 误触发）
  void _onCoverLoaded() {
    if (!mounted) return;
    if (_coverFadeAppliedHash == widget.song.hash) return;
    _coverFadeAppliedHash = widget.song.hash;
    _coverFallbackTimer?.cancel();
    // ====【修复/淡入必生效】强制从 0 起淡入：正常路径 didUpdateWidget 已置 0；若因
    // 异常 State 重建使 controller 初值为 1，直接 forward() 会从 1→1 无动画（硬切）。
    // 此处强制重置，保证图片就绪时一定有交叉淡入动画。====
    _coverFade.value = 0;
    _startFadeIn();
  }

  // ====【修复/占位图透出旧封面】淡入完成 → 丢弃旧封面层，避免半透明占位图透出旧封面 ====
  void _onCoverFadeStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed &&
        mounted &&
        _prevCoverUrl != null) {
      setState(() => _prevCoverUrl = null);
    }
  }

  void _startFadeIn() {
    if (!mounted || _fadeStarted) return;
    _fadeStarted = true;
    if (_coverFadeAppliedHash != widget.song.hash) return;
    // ====【需求/视觉·切歌不归位】在封面开始淡入的这一刻记录唱片当前角度作为相位偏移：
    // 新封面据此反向旋转，出现时正好正面(0°)，随后随唱片继续旋转（唱片本身不归零、
    // 旧封面也无跳变）。====
    _coverPhaseOffset.value = _rotationController.value;
    _coverFade.forward();
  }

  @override
  void dispose() {
    _coverFallbackTimer?.cancel();
    _coverPhaseOffset.dispose();
    _rotationController.dispose();
    _coverFade.dispose();
    super.dispose();
  }

  void _syncRotation() {
    // ===== 【重构】封面旋转：由独立开关 perfCoverAnimOff 控制 =====
    // 开启"关闭封面动画"即暂停车机封面旋转省 GPU。原实现（备份，供回退）：
    // if (widget.player.performanceMode && !widget.player.perfRestoreRotation) { ... }
    if (widget.player.perfCoverAnimOff) {
      if (_rotationController.isAnimating) {
        _rotationController.stop(canceled: false);
      }
      return;
    }
    if (widget.player.isPlaying) {
      if (!_rotationController.isAnimating) {
        _rotationController.repeat();
      }
    } else if (_rotationController.isAnimating) {
      _rotationController.stop(canceled: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0.0;
        if (velocity < -200) {
          widget.player.next();
        } else if (velocity > 200) {
          widget.player.previous();
        }
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final available = math.min(constraints.maxWidth, constraints.maxHeight);
          final discSize = (available * (widget.compact ? .84 : .9))
              .clamp(150.0, 330.0)
              .toDouble();
          final coverSize = discSize * (widget.compact ? .58 : .70);

          return Center(
            // 旋转唱片是纯装饰动画，排除语义树防止 Windows AXTree 竞态崩溃
            child: ExcludeSemantics(
              // ===== 【需求/性能优化·封面旋转不每帧重栅格】====
              // Flutter 官方缓存模式：AnimatedBuilder 的 builder 每帧重建 Transform(旋转)，
              // 但其 child 参数为 RepaintBoundary 包住的"静态唱片盘"，一旦缓存就不随动画重建；
              // Transform 旋转直接用这块已被 GPU 缓存的位图，避免整盘每帧重新栅格(旋转封面 GPU 大头)。
              // 原实现（备份）：外层 RepaintBoundary 包 AnimatedBuilder，Transform 在其内层，
              //   AnimatedBuilder 每帧重建 Transform → RepaintBoundary 内整盘每帧重复栅格。
              child: AnimatedBuilder(
                animation: _rotationController,
                builder: (context, child) {
                  return Transform.rotate(
                    angle: _rotationController.value * math.pi * 2,
                    child: child,
                  );
                },
                child: RepaintBoundary(
                  child: SizedBox.square(
                    dimension: discSize,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              Colors.white.withValues(alpha: .88),
                              Colors.white.withValues(alpha: .58),
                              Colors.white.withValues(alpha: .22),
                            ],
                            stops: const [0, .62, 1],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: .26),
                              blurRadius: 30,
                              offset: const Offset(0, 18),
                            ),
                          ],
                        ),
                        child: const SizedBox.expand(),
                      ),
                      for (final ratio in const [.36, .52, .68, .82])
                        SizedBox.square(
                          dimension: discSize * ratio,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white.withValues(alpha: .16),
                              ),
                            ),
                          ),
                        ),
                      // ====【需求/视觉优先·封面交叉淡入】Stack：旧封面在下层保持不透明显示、
                      // 新封面在上层 0→1 淡入（叠加式交叉淡入，无背景透出）；淡入完成后旧封面层
                      // 由 _onCoverFadeStatus 移除。====
                      // ====【修复/圆形封面塌缩】不能 fit: StackFit.expand：本 Stack 是外层唱片
                      // Stack 的非定位子元素，约束为 loose(0..discSize)，expand 会把非定位 children
                      // 压成 tight(constraints.smallest)=(0,0)，封面图 0×0 不可见（用户反馈"唱片
                      // 覆盖层没了"）。改回默认 loose，Artwork 按 coverSize 正常显示。====
                      Stack(
                        children: [
                          if (_prevCoverUrl != null &&
                              _prevCoverUrl != widget.song.coverUrl)
                            ClipOval(
                              child: Artwork(
                                url: _prevCoverUrl,
                                size: coverSize,
                                borderRadius: coverSize,
                                decodeSize: kPlayerCoverDecodeWidth,
                              ),
                            ),
                          FadeTransition(
                            opacity: _coverFade,
                            // ====【需求/视觉·切歌不归位】按相位偏移反向旋转当前封面，使其
                            // 出现时正好正面(0°)、随后随唱片一起旋转。注意必须把 ClipOval
                            // 一并旋转（而不是只转里面的方形图）——方形图在圆形裁剪内单独
                            // 旋转会在圆边露出 4 个缺口。====
                            child: ValueListenableBuilder<double>(
                              valueListenable: _coverPhaseOffset,
                              builder: (context, offset, child) =>
                                  Transform.rotate(
                                angle: -offset * math.pi * 2,
                                child: child,
                              ),
                              child: ClipOval(
                                child: Artwork(
                                  url: widget.song.coverUrl,
                                  size: coverSize,
                                  borderRadius: coverSize,
                                  // ====【修复/封面与背景过渡不同步】解码宽度与背景统一为同一常量，
                                  // 使封面与背景解析到同一个 ImageProvider（共享下载/解码/缓存条目）。====
                                  decodeSize: kPlayerCoverDecodeWidth,
                                  onImageLoaded: _onCoverLoaded,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox.square(
                        dimension: discSize * .08,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withValues(alpha: .82),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
                ),
            ),
          );
        },
      ),
    );
  }
}

class _LandscapeRightPanel extends StatelessWidget {
  const _LandscapeRightPanel({
    required this.player,
    required this.onQueue,
    required this.compact,
  });

  final PlayerController player;
  final VoidCallback onQueue;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final song = player.currentSong;
    return LayoutBuilder(
      builder: (context, constraints) {
        final veryTight = constraints.maxHeight < 250;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (song != null)
              Padding(
                padding: EdgeInsets.only(
                  bottom: veryTight ? 6.0 : 12.0,
                  top: veryTight ? 2.0 : 6.0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            color: Colors.white.withValues(alpha: .92),
                            fontSize: compact ? 18 : 22,
                            fontWeight: FontWeight.w900,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Colors.white.withValues(alpha: .6),
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ],
                ),
              ),
            Expanded(
              // ====【新增/TV 遥控器适配】==== 歌词区作为单个焦点落点：
              //   * 只有"当前行"会被高亮为可聚焦；
              //   * 按确定键 = 与该行屏幕单击一致（seek 到该行开始时间）。
              child: TvLyricFocus(
                player: player,
                lyrics: player.lyrics,
                child: _LandscapeLyricPanel(
                  player: player,
                  songHash: song?.hash ?? '',
                  lyrics: player.lyrics,
                  compact: compact || veryTight,
                ),
              ),
            ),
            SizedBox(height: veryTight ? 2 : 6),
            _Progress(player: player, bright: true, compact: true),
            SizedBox(height: veryTight ? 0 : 4),
            _Controls(
              player: player,
              bright: true,
              onQueue: onQueue,
              compactOverride: true,
              denseOverride: veryTight,
            ),
          ],
        );
      },
    );
  }
}

class _LandscapeLyricPanel extends StatefulWidget {
  const _LandscapeLyricPanel({
    required this.player,
    required this.songHash,
    required this.lyrics,
    required this.compact,
  });

  final PlayerController player;
  final String songHash;
  final List<LyricLine> lyrics;
  final bool compact;

  @override
  State<_LandscapeLyricPanel> createState() => _LandscapeLyricPanelState();
}

class _LandscapeLyricPanelState extends State<_LandscapeLyricPanel> {
  late final LyricController _lyricController;
  // ===== 原实现（备份，供回退）：late final Ticker _ticker; int? _lastLyricSubmitMs; =====
  // Ticker(start()) 在回调里即使立即 return，也会持续每帧请求 frame → 播放期间维持整条
  // 60fps 渲染管线，是 GPU 高占用的根因。改为 ~30fps（33ms）Timer 低频驱动，把频控作为
  // 渲染上限（Timer 只在不可见/暂停/拖动时取消，不产生无谓帧）。
  Timer? _ticker;
  // 性能模式"仅行切换更新"用的上一次活动歌词行
  int _lastActiveRow = -1;
  bool _isUserSelecting = false;

  @override
  void initState() {
    super.initState();
    _lyricController = LyricController();
    _lyricController.setOnTapLineCallback((position) {
      widget.player.seek(position);
    });
    // =====【新增/歌词调整】监听歌词调整配置，实时刷新高亮色/行距/透明度/偏移 =====
    LyricAdjustments.notifier.addListener(_onAdjustmentsChanged);
    LyricAdjustments.reload();
    _lyricController.isSelectingNotifier.addListener(_onSelectingChanged);
    _syncLyrics();
    // ===== 原实现（备份，供回退）：_ticker = Ticker(_onTick); =====
    // 不再在 initState 直接创建 Ticker；改由 _syncTicker 在满足播放条件时按需创建
    // ~30fps Timer（见 _syncTicker）。
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant _LandscapeLyricPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.songHash != widget.songHash ||
        oldWidget.lyrics != widget.lyrics) {
      _syncLyrics();
    }
    _syncTicker();
  }

  @override
  void dispose() {
    LyricAdjustments.notifier.removeListener(_onAdjustmentsChanged); // ====【新增/歌词调整】====
    _lyricController.isSelectingNotifier.removeListener(_onSelectingChanged);
    _ticker?.cancel();
    _lyricController.dispose();
    super.dispose();
  }

  // =====【新增/歌词调整】配置变更 → 重建本视图（实时生效）=====
  void _onAdjustmentsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  // =====【新增/歌词调整】当前歌曲的进度偏移存储键（hash 优先）=====
  String get _songKey {
    final s = widget.player.currentSong;
    if (s == null) return '';
    return LyricAdjustments.resolveOffsetKey(hash: s.hash, id: s.id);
  }

  // =====【新增/歌词调整】带偏移的"当前行判定位置"（实际位置 + 歌词偏移）。仅用于
  // 行高亮/滚动判定以对齐歌词；不改音频位置、进度条、smoothPosition 本身。=====
  Duration get _offsetProbe =>
      widget.player.smoothPosition +
      Duration(
          milliseconds:
              (LyricAdjustments.offsetFor(_songKey) * 1000).round());

  void _onSelectingChanged() {
    _isUserSelecting = _lyricController.isSelectingNotifier.value;
    _syncTicker();
  }

  void _syncLyrics() {
    final lyrics = widget.lyrics;
    if (lyrics.isNotEmpty) {
      final model = convertToFlutterLyricModel(lyrics);
      _lyricController.loadLyricModel(model);
    }
  }

  void _syncTicker() {
    // ===== 【修复】窗口收进托盘时（player.isUIVisible=false）停止横屏歌词滚动 Ticker =====
    // 原因：托盘隐藏后窗口内歌词 Ticker 仍每帧请求提交导致 GPU 满载；加入 isUIVisible
    // 门控在托盘隐藏时停止该 Ticker，不影响音频播放（托盘收起后音乐仍继续播）。
    // ===== 原实现（备份，供回退）=====
    //   if (shouldTick && !_ticker.isActive) { _ticker.start(); }
    //   else if (!shouldTick && _ticker.isActive) { _ticker.stop(); }
    final shouldTick =
        widget.player.isUIVisible &&
        widget.player.isPlaying &&
        widget.lyrics.isNotEmpty &&
        !widget.player.isScrubbing &&
        !_isUserSelecting;
    // Timer 版：满足播放条件时按需创建 ~30fps Timer（复用实例避免重复分配），
    // 否则取消。注意 Timer 不受外层 TickerMode 管控，这里必须显式纳入 isUIVisible。
    if (shouldTick) {
      _ticker ??= Timer.periodic(
        const Duration(milliseconds: 50),
        _onTick,
      );
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  // ===== 原实现（备份，供回退）：Ticker + ≈20fps 二次降采样 =====
  //   void _onTick(Duration elapsed) {
  //     if (!mounted || widget.player.isScrubbing) return;
  //     final nowMs = DateTime.now().millisecondsSinceEpoch;
  //     if (_lastLyricSubmitMs != null && (nowMs - _lastLyricSubmitMs!) < 50) return;
  //     _lastLyricSubmitMs = nowMs;
  //     _lyricController.setProgress(widget.player.smoothPosition);
  //   }
  //
  // 现改为 ~30fps（33ms）Timer 驱动：Timer 本身是唯一节奏源（不再有"每帧 Ticker +
  // 帧内 return"的浪费调度），频率即渲染上限，因此移除原 50ms 二次降采样。
  void _onTick(Timer timer) {
    if (!mounted || widget.player.isScrubbing) {
      return;
    }
    // ====【诊断/启动卡顿】==== 歌词面板每帧 tick 耗时（判断卡顿是否来自这里）。
    final diagSw = Stopwatch()..start();
    try {
      _onTickInner(timer);
    } finally {
      diagSw.stop();
      MainThreadLagMonitor.record('lyricPanel.tick', diagSw.elapsedMilliseconds);
    }
  }

  void _onTickInner(Timer timer) {
    if (!mounted || widget.player.isScrubbing) {
      return;
    }
    // =====【新增/歌词调整】带偏移的"当前行判定位置"（实际位置 + 歌词偏移）=====
    // 仅用于行高亮/滚动判定以对齐歌词；不改音频位置、进度条、smoothPosition 本身。
    final probe = _offsetProbe;
    // =====【重构-轻量歌词】仅当前行切换时才更新歌词 =====
    // 有歌词时歌词渲染是 GPU 大头。开启 perfLightLyric 后改为只在"活动歌词行变化"
    // 时刷新，行内静止，GPU 大幅下降(视觉为逐行对齐)。原实现（备份，供回退）：
    // if (widget.player.performanceMode) { ... }
    if (widget.player.perfLightLyric) {
      // =====【新增/歌词调整】行判定用带偏移的 probe（原实现：activeLyricIndex）=====
      final row = _activeLyricIndexFor(widget.lyrics, probe);
      if (row == _lastActiveRow) {
        return;
      }
      _lastActiveRow = row;
      // 整行高亮：把进度推到"当前行结束处(下一行开始)"，使该行 100% 高亮，
      // 而不是停在行首只标亮第一个字。
      final ly = widget.player.lyrics;
      if (row >= 0 && row < ly.length && row + 1 < ly.length) {
        _lyricController.setProgress(ly[row + 1].time);
        return;
      }
    }
    // =====【新增/歌词调整】进度用带偏移的 probe（原实现：smoothPosition）=====
    _lyricController.setProgress(probe);
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final lyrics = widget.lyrics;
    if (lyrics.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          player.isPreparing || player.lyricsLoading
              ? '歌词加载中...'
              : '暂无歌词',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: Colors.white.withValues(alpha: .82),
            fontWeight: FontWeight.w900,
          ),
        ),
      );
    }

    // =====【新增/歌词调整】字体大小复用 settings.lyric_scale，并准备好行距/透明度/高亮色 =====
    final lucScale = LyricAdjustments.scale();
    final fontSize = (widget.compact ? 26.0 : 34.0) * lucScale;
    final inactiveFontSize = (widget.compact ? 18.0 : 24.0) * lucScale;
    final subtitleFontSize = (widget.compact ? 13.0 : 15.0) * lucScale;
    final lucSf = LyricAdjustments.lineSpacingFactor();
    final lucCfg = LyricAdjustments.getGlobal();
    final lucHl = Color(lucCfg.highlightColor);
    // ====【需求/颜色统一】车机底色（非当前行）颜色：统一→高亮色，否则→底色 baseColor ====
    final lucBase = Color(lucCfg.baseColorValue());
    final lucOpacity = lucCfg.opacity;
    // ====【需求/颜色统一·当前行随底色透明度】车机当前行高光透明度 = opacity×(unified?1:highlightOpacity) ====
    final lucHighlightAlpha = lucCfg.currentLineAlpha();
    // ====【需求/颜色统一】车机底色用 base（统一时=高亮色）====
    // 原实现（备份）：lucInactive = lucHl.withValues(alpha: 0.34 * lucOpacity);
    final lucInactive = lucBase.withValues(alpha: 0.34 * lucOpacity);

    // ===== 【重构-轻量歌词】自绘整行歌词（轻量、低 GPU）=====
    // 开启 perfLightLyric 且歌词非空时，用 _PerfLyricList 整行统一高亮替换
    // BlurredLyricView，忽略逐词时间轴、只在活动行切换时重绘。原实现（备份，供回退）：
    // if (widget.player.performanceMode) { ... }
    if (widget.player.perfLightLyric) {
      return ExcludeSemantics(
        // 排除语义树，防止 Windows AXTree 竞态崩溃（与原有歌词视图一致）。
        child: _PerfLyricList(
          player: widget.player,
          lyrics: lyrics,
          currentIndex: widget.player.activeLyricIndex,
          fontSize: fontSize,
          inactiveFontSize: inactiveFontSize,
          subtitleFontSize: subtitleFontSize,
          // =====【新增/歌词调整】active/inactive 颜色改用配置的高亮色与透明度 =====
          activeColor: lucHl,
          inactiveColor: lucInactive,
          showTranslation: false,
          textAlign: TextAlign.left,
          padding: EdgeInsets.symmetric(
            horizontal: 24,
            vertical: widget.compact ? 20 : 40,
          ),
          // ===== 【双模糊·与原版同一逻辑】车机原版用 2.0/0.7，轻量沿用 =====
          maxBlurSigma: widget.player.perfLyricBlurOff ? 0.0 : 2.0,
          blurStep: 0.7,
          // ===== 【修复】性能模式车机全屏歌词点击交互（需求1/3）=====
          // 车机布局(isCarLayout)无独立"歌词页 vs 封面页"分页，封面(右面板左侧的歌词/封面
          // 区域固定可见)，故与 _LandscapeLyricPanel 正常模式一致：点击任意一行 → seek 到
          // 该行开始时间。当前行进不进封面页（车机没有封面页切换），故不返回封面。
          onTapLine: (index) {
            widget.player.seek(widget.lyrics[index].time);
          },
        ),
      );
    }
    // ===== 原实现（备份，供回退）=====
    return ExcludeSemantics(
      // 歌词视图高频更新会触发 Windows AXTree 竞态崩溃，排除语义树
      child: BlurredLyricView(
        controller: _lyricController,
        // =====【新增/歌词调整】行距/透明度/高亮色/字号横跨车机原版歌词 =====
        // ====【需求/字体粗细】整体字重：三处都用 lucCfg.lyricFontWeight()（默认 700）。
        // 原实现（备份）：textStyle w800 / activeStyle w900 / translationStyle w500。
        style: LyricStyles.default1.copyWith(
          textStyle: Theme.of(context).textTheme.titleLarge!.copyWith(
            color: lucInactive,
            fontSize: inactiveFontSize,
            height: 1.18 * lucSf,
            fontWeight: lucCfg.lyricFontWeight(),
          ),
          activeStyle: Theme.of(context).textTheme.headlineMedium!.copyWith(
            // ====【修复/拆分当前行底色与高亮】车机当前行"底色层"独立：
            //   * 颜色 = baseColorValue()（统一颜色时=高亮色，关闭时=baseColor）
            //   * alpha = opacity（只随"底色透明度"，关闭统一透明度时不受 highlightOpacity 影响）
            // 原实现（备份）：color: lucHl.withValues(alpha: 0.34 * lucHighlightAlpha),
            color: lucBase.withValues(alpha: 0.34 * lucOpacity),
            fontSize: fontSize,
            height: 1.18 * lucSf,
            fontWeight: lucCfg.lyricFontWeight(),
          ),
          // ====【需求/翻译行接入自适应色】车机翻译行随自适应色：
          //   非当前行翻译 → 底色 base（alpha 0.5，比原文非当前行更清晰可读）；
          //   当前行翻译   → 高亮色（alpha 0.95，在封面/背景上保持清晰）。
          // 原实现（备份）：未设置 translationStyle/translationActiveColor（走灰白默认）。
          translationStyle: Theme.of(context).textTheme.titleLarge!.copyWith(
            color: lucBase.withValues(alpha: 0.5 * lucOpacity),
            fontSize: subtitleFontSize,
            height: 1.18 * lucSf,
            fontWeight: lucCfg.lyricFontWeight(),
          ),
          translationActiveColor:
              lucHl.withValues(alpha: 0.95 * lucHighlightAlpha),
          lineGap: (widget.compact ? 10 : 16) * lucSf,
          contentPadding: EdgeInsets.symmetric(
            horizontal: 24,
            vertical: (widget.compact ? 20 : 40) * lucSf,
          ),
          fadeRange: FadeRange(top: 40, bottom: 40),
          textAlign: TextAlign.left,
          contentAlignment: CrossAxisAlignment.start,
          // ====【需求/拆分透明度】车机当前行高亮色随高光透明度（不再裸 opacity）====
          // 原实现（备份 1）：activeHighlightColor: lucHl,
          // 原实现（备份 2）：activeHighlightColor: lucHl.withValues(alpha: lucOpacity),
          activeHighlightColor: lucHl.withValues(alpha: lucHighlightAlpha),
        ),
        maxBlurSigma: widget.player.perfLyricBlurOff ? 0.0 : 2.0,
        blurStep: 0.7,
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.player,
    required this.auth,
    required this.song,
    required this.onClose,
    required this.onArtistTap,
  });

  final PlayerController player;
  final AuthController auth;
  final Song song;
  final VoidCallback onClose;
  final ValueChanged<Song> onArtistTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: auth,
      builder: (context, _) {
        final liked = auth.isLiked(song);
        return Padding(
          // ===== 沉浸式顶栏让位：Windows 下右侧为右上角窗口按钮留出空间，避免重叠 =====
          padding: EdgeInsets.fromLTRB(
            8,
            8,
            16 + (Platform.isWindows ? WindowTitleBar.controlAreaRight : 0),
            6,
          ),
          child: Row(
            children: [
              IconButton(
                tooltip: '返回',
                color: Colors.white,
                onPressed: onClose,
                icon: const Icon(Icons.keyboard_arrow_down_rounded),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.white.withValues(alpha: .82),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              _GlassIconButton(
                tooltip: liked ? '取消喜欢' : '喜欢',
                onPressed: song.source == SongSource.kugou
                    ? () => auth.toggleLike(song)
                    : null,
                icon: liked
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
              ),
              const SizedBox(width: 8),
              _GlassIconButton(
                tooltip: '更多',
                onPressed: () => _showMoreSheet(context),
                icon: Icons.more_horiz_rounded,
              ),
            ],
          ),
        );
      },
    );
  }

  void _showMoreSheet(BuildContext context) {
    showSongActionSheet(
      context: context,
      song: song,
      actions: [
        // Grid actions
        // ====【新增】更多菜单-设置：普通模式（竖屏/普通横屏）更多菜单 ====
        SongSheetAction(
          icon: Icons.settings_rounded,
          title: '设置',
          isGrid: true,
          onTap: () => _openPlayerSettings(context, player, auth),
        ),
        // ====【新增/歌词调整】更多菜单-歌词调整：普通模式（竖屏/普通横屏）更多菜单 ====
        SongSheetAction(
          icon: Icons.tune_rounded,
          title: '歌词调整',
          isGrid: true,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => LyricAdjustmentsPage(player: player),
            ),
          ),
        ),
        SongSheetAction(
          icon: Icons.speed_rounded,
          title: '倍速',
          subtitle: player.playbackSpeedLabel,
          isGrid: true,
          onTap: () => showPlaybackSpeedSheet(context: context, player: player),
        ),
        SongSheetAction(
          icon: Icons.high_quality_rounded,
          title: '音质',
          subtitle: player.audioQuality.badge,
          isGrid: true,
          onTap: () => _showAudioQualityPicker(context, player),
        ),
        SongSheetAction(
          icon: Icons.graphic_eq_rounded,
          title: '音效',
          isGrid: true,
          onTap: () => showAudioEffectsSheet(context: context, player: player),
        ),
        SongSheetAction(
          icon: Icons.auto_awesome_rounded,
          title: '高潮',
          isGrid: true,
          onTap: () async {
            final ok = await player.playClimaxPreview();
            if (!ok) Toast.error('暂无高潮片段');
          },
        ),
        SongSheetAction(
          icon: Icons.bedtime_rounded,
          title: '定时',
          isGrid: true,
          onTap: () => showSleepTimerSheet(context: context, player: player),
        ),

        if (player.isDesktopLyricsSupported) ...[
          SongSheetAction(
            icon: player.desktopLyricsEnabled
                ? Icons.lyrics_rounded
                : Icons.lyrics_outlined,
            title: '桌面歌词',
            isGrid: true,
            onTap: () async {
              Navigator.of(context).pop();
              await player.setDesktopLyricsEnabled(!player.desktopLyricsEnabled);
            },
          ),
          if (player.desktopLyricsEnabled)
            SongSheetAction(
              icon: Icons.tune_rounded,
              title: '歌词设置',
              isGrid: true,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DesktopLyricsSettingsPage(player: player),
                ),
              ),
            ),
        ],
        SongSheetAction(
          icon: Icons.queue_music_rounded,
          title: '下一首',
          isGrid: true,
          onTap: () => addSongToQueueWithFeedback(
            context: context,
            player: player,
            song: song,
          ),
        ),
        // List actions
        if (song.source == SongSource.kugou)
          SongSheetAction(
            icon: Icons.playlist_add_rounded,
            title: '添加到歌单',
            onTap: () =>
                showAddToPlaylistSheet(context: context, auth: auth, song: song),
          ),
      ],
    );
  }
}

String _formatSleepRemaining(Duration? remaining) {
  if (remaining == null || remaining <= Duration.zero) return '';
  final minutes = remaining.inMinutes;
  final seconds = remaining.inSeconds.remainder(60);
  return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
}

class _PosterPlayerPage extends StatefulWidget {
  const _PosterPlayerPage({
    super.key,
    required this.player,
    required this.song,
    required this.onQueue,
    required this.onSwitchToLyrics,
  });

  final PlayerController player;
  final Song song;
  final VoidCallback onQueue;
  final VoidCallback onSwitchToLyrics;

  @override
  State<_PosterPlayerPage> createState() => _PosterPlayerPageState();
}

class _PosterPlayerPageState extends State<_PosterPlayerPage>
    with AutomaticKeepAliveClientMixin, TickerProviderStateMixin {
  @override
  bool get wantKeepAlive => true;

  // ====【需求/视觉优先·封面交叉淡入】====
  // 切歌时【保持旧封面显示】（下层），直到新封面图片真正加载完成才交叉淡入——
  // 消除"硬切到空白图"与"有缓存硬切+再淡入"的怪观感。时长 300ms 与背景淡入同步。
  // 用 _coverFadeAppliedHash 标记"当前歌曲已淡入过"，暂停/播放等 rebuild 不会再触发淡入。
  late final AnimationController _coverFade; // 新封面 0→1（旧封面层保持不透明，新封面在上层淡入；
  // 淡入完成后移除旧封面层，见 _onCoverFadeStatus —— 否则半透明占位图会透出旧封面）
  String? _prevCoverUrl;
  String? _coverFadeAppliedHash;
  Timer? _coverFallbackTimer;
  // ====【修复/过渡被卡顿吞掉·已恢复即时淡入】====
  // 原实现"图片就绪后固定干等 300ms 再淡入"，用于避开切歌高峰卡顿（当时根因是 prefs
  // 同步整写 8.67MB 文件造成 ~890ms 主线程阻塞，会把动画吞掉）。该根因已修复（切歌路径
  // 0 次 prefs 写入 + prefs 瘦身到 ~100KB），故恢复"图片就绪即淡入"，并与背景淡入同步。====
  bool _fadeStarted = false;

  @override
  void initState() {
    super.initState();
    const d = Duration(milliseconds: 300);
    _coverFade = AnimationController(vsync: this, duration: d, value: 1.0);
    // ====【修复/占位图透出旧封面】淡入完成后移除旧封面层：无封面歌曲的新封面是
    // Artwork 的 fallback（半透明渐变），若旧封面层仍留在下方会透出来，出现
    // "一半占位图、一半上一首封面"的观感；移除后仅占位图叠在页面背景上，观感正确。====
    _coverFade.addStatusListener(_onCoverFadeStatus);
  }

  @override
  void didUpdateWidget(covariant _PosterPlayerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.hash != widget.song.hash) {
      // 切歌：旧封面保留显示，新封面透明等待图片就绪（不立刻淡入占位）
      _prevCoverUrl = oldWidget.song.coverUrl;
      _coverFadeAppliedHash = null;
      _coverFade.value = 0;
      _coverFallbackTimer?.cancel();
      _fadeStarted = false;
      // 兜底：图加载失败/过慢时 2s 后仍淡入（显示 fallback），避免旧封面常驻
      _coverFallbackTimer = Timer(const Duration(seconds: 2), () {
        if (mounted && _coverFadeAppliedHash != widget.song.hash) {
          _coverFadeAppliedHash = widget.song.hash;
          _fadeStarted = false;
          _startFadeIn();
        }
      });
    }
  }

  // 新封面图片加载完成 → 交叉淡入（hash 标记防暂停/播放 rebuild 误触发）
  void _onCoverLoaded() {
    if (!mounted) return;
    if (_coverFadeAppliedHash == widget.song.hash) return;
    _coverFadeAppliedHash = widget.song.hash;
    _coverFallbackTimer?.cancel();
    // ====【修复/淡入必生效】强制从 0 起淡入：正常路径 didUpdateWidget 已置 0；若因
    // 异常 State 重建使 controller 初值为 1，直接 forward() 会从 1→1 无动画（硬切）。
    // 此处强制重置，保证图片就绪时一定有交叉淡入动画。====
    _coverFade.value = 0;
    _startFadeIn();
  }

  // ====【修复/占位图透出旧封面】淡入完成 → 丢弃旧封面层，避免半透明占位图透出旧封面 ====
  void _onCoverFadeStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed &&
        mounted &&
        _prevCoverUrl != null) {
      setState(() => _prevCoverUrl = null);
    }
  }

  void _startFadeIn() {
    if (!mounted || _fadeStarted) return;
    _fadeStarted = true;
    if (_coverFadeAppliedHash != widget.song.hash) return;
    _coverFade.forward();
  }

  @override
  void dispose() {
    _coverFallbackTimer?.cancel();
    _coverFade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 620;
        final artworkMaxWidth = compact ? 250.0 : 330.0;

        return Padding(
          padding: const EdgeInsets.fromLTRB(28, 12, 28, 18),
          child: Column(
            children: [
              const Spacer(),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: artworkMaxWidth),
                child: AspectRatio(
                  aspectRatio: 1,
                  // 点击封面切换到歌词滚动页。
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onSwitchToLyrics,
                    child: Hero(
                      tag: 'player_cover',
                      // ====【需求/视觉优先·封面交叉淡入】Stack：旧封面在下层保持不透明显示、
                      // 新封面在上层 0→1 淡入（叠加式交叉淡入，无背景透出）；淡入完成后旧封面层
                      // 由 _onCoverFadeStatus 移除。====
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (_prevCoverUrl != null &&
                              _prevCoverUrl != widget.song.coverUrl)
                            Artwork(
                              url: _prevCoverUrl,
                              size: double.infinity,
                              borderRadius: 8,
                            ),
                          FadeTransition(
                            opacity: _coverFade,
                            child: Artwork(
                              url: widget.song.coverUrl,
                              size: double.infinity,
                              borderRadius: 8,
                              // ====【修复/封面与背景过渡不同步】与背景统一解码宽度，二者解析到
                              // 同一个 ImageProvider（共享下载/解码/缓存条目），淡入方能同步。====
                              decodeSize: kPlayerCoverDecodeWidth,
                              onImageLoaded: _onCoverLoaded,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(height: compact ? 14 : 26),
              _PosterLyricPreview(
                player: widget.player,
                onTap: widget.onSwitchToLyrics,
              ),
              if (!compact) const SizedBox(height: 4),
              _CommentEntry(player: widget.player, song: widget.song),
              const Spacer(),
              _Progress(player: widget.player, bright: true),
              const SizedBox(height: 10),
              _Controls(
                player: widget.player,
                bright: true,
                onQueue: widget.onQueue,
              ),
            ],
          ),
        );
      },
    );
  }
}

int _activeLyricIndexFor(List<LyricLine> lyrics, Duration position) {
  if (lyrics.isEmpty) return -1;
  var index = 0;
  for (var i = 0; i < lyrics.length; i++) {
    if (position >= lyrics[i].time) {
      index = i;
    } else {
      break;
    }
  }
  return index;
}

class _PosterLyricPreview extends StatefulWidget {
  const _PosterLyricPreview({required this.player, this.onTap});

  final PlayerController player;
  final VoidCallback? onTap;

  @override
  State<_PosterLyricPreview> createState() => _PosterLyricPreviewState();
}

class _PosterLyricPreviewState extends State<_PosterLyricPreview> {
  // ===== 原实现（备份，供回退）：late final Ticker _ticker; int? _lastLyricSubmitMs; =====
  // 改为 ~30fps（33ms）Timer 低频驱动，从根上砍掉播放期间 60fps 渲染管线（见
  // _LandscapeLyricPanelState 注释）。预览同样由 _syncTicker 管控启停。
  Timer? _ticker;
  // ===== 【顺滑重构】位置流用 ValueNotifier 隔离，只驱动 karaoke 逐字局部重绘；行切换才 setState =====
  // 之前位置流直接走 setState，每 tick 把整棵封面预览（AnimatedSwitcher + 两个 Marquee +
  // karaoke）都重建，即便 60fps 也会因过量重建+布局测量而卡顿。改为：
  //   * _position 仅在行内更新 notifier.value，ValueListenableBuilder 只重绘 karaoke 那片；
  //   * 仅当活动行变化时才 setState（触发 AnimatedSwitcher/Marquee），行内零整树重建。
  final ValueNotifier<Duration> _position = ValueNotifier<Duration>(Duration.zero);
  // 行切换检测用的上一次活动行索引（用于判断是否触发 setState）。
  int _lastIndex = -1;
  // 性能模式"仅行切换更新"用的上一次活动歌词行。
  // ===== 【修复】封面预览性能模式已改复用 _PerfLyricList 自绘，_onTick 性能分支
  // 不再维护/使用 _lastActiveRow（高亮由 _PerfLyricList 内部驱动），故删除该字段。
  // ===== 原实现（备份，供回退）：int _lastActiveRow = -1;

  @override
  void initState() {
    super.initState();
    // ===== 【顺滑修复】progress 用 smoothPosition（连续），行判定用 lyricPosition（不超前）=====
    // ===== 原实现（备份，供回退）：_position = widget.player.smoothPosition; =====
    _position.value = widget.player.smoothPosition;
    _lastIndex = _activeLyricIndexFor(widget.player.lyrics, widget.player.lyricPosition);
    // ===== 原实现（备份，供回退）：_ticker = Ticker(_onTick); =====
    // 不再在 initState 直接创建 Ticker；改由 _syncTicker 在满足播放条件时按需创建
    // ~30fps Timer（见 _syncTicker）。
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant _PosterLyricPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.player.isScrubbing) {
      // ===== 【顺滑修复】同上：progress=smooth、行判定=lyricPosition =====
      // ===== 原实现（备份，供回退）：_position = widget.player.smoothPosition; =====
      _position.value = widget.player.smoothPosition;
      _lastIndex = _activeLyricIndexFor(widget.player.lyrics, widget.player.lyricPosition);
    }
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _position.dispose();
    super.dispose();
  }

  void _syncTicker() {
    // ===== 原实现（备份，供回退）=====
    //   if (shouldTick && !_ticker.isActive) { _ticker.start(); }
    //   else if (!shouldTick && _ticker.isActive) { _ticker.stop(); }
    // 该预览原本随外层 TickerMode（isUIVisible=false）整体停用；改 Timer 后不受
    // TickerMode 管控，故补上 isUIVisible 门控，确保收进托盘/隐藏时停表不耗 GPU。
    final shouldTick =
        widget.player.isUIVisible &&
        widget.player.isPlaying &&
        widget.player.lyrics.isNotEmpty &&
        !widget.player.isScrubbing;
    if (shouldTick) {
      // ===== 【修复·顺滑】逐字高亮 20fps→60fps =====
      // 之前为降 GPU 用 50ms(≈20fps) 驱动封面预览的 karaoke 逐字推色，导致一字一顿。
      // 该封面预览区域仅 96px 高、逐字 CustomPaint 更新独立且极小，60fps 的额外开销有限；
      // 若在意 GPU 可开启"轻量歌词"（走零动画的 _PerfLyricTwoLinePreview）。
      _ticker ??= Timer.periodic(
        const Duration(milliseconds: 16),
        _onTick,
      );
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  // ===== 原实现（备份，供回退）：Ticker + ≈20fps 二次降采样 =====
  //   void _onTick(Duration elapsed) {
  //     if (!mounted || widget.player.isScrubbing) return;
  //     final nowMs = DateTime.now().millisecondsSinceEpoch;
  //     if (_lastLyricSubmitMs != null && (nowMs - _lastLyricSubmitMs!) < 50) return;
  //     _lastLyricSubmitMs = nowMs;
  //     setState(() => _position = widget.player.smoothPosition);
  //   }
  //
  // 改 ~30fps（33ms）Timer：Timer 是唯一节奏源，频率即渲染上限，移除原 50ms 二次降采样。
  void _onTick(Timer timer) {
    if (!mounted || widget.player.isScrubbing) {
      return;
    }
    // ===== 【重构-轻量歌词】封面预览：高亮/居中已由 _PerfLyricTwoLinePreview 自绘接管 =====
    // 开启 perfLightLyric 时 build 直接返回 _PerfLyricTwoLinePreview，其自身监听
    // activeLyricIndex 更新高亮与居中，无需再在 _onTick 里更新 _position；直接返回。
    // ===== 原实现（备份，供回退）：if (widget.player.performanceMode) { return; } =====
    if (widget.player.perfLightLyric) {
      return;
    }
    // ===== 【顺滑重构】位置流只更新 notifier，仅活动行变化时才 setState =====
    // * 行内：只更新 _position.value → ValueListenableBuilder 仅重绘 karaoke 那片，零整树重建；
    // * 行切换：_lastIndex 变化才 setState → AnimatedSwitcher/Marquee 重建，做行间过渡。
    // 相比此前每 tick 无条件 setState（整棵重建）大幅降低布局/绘制开销。
    //
    // ===== 【修复·顺滑】逐字高亮用 smoothPosition(连续外推)，行判定用 lyricPosition(不超前) =====
    // 根因：此前为修"高亮超前一句"把 progress 也传成 lyricPosition(=position，低频步进，
    // 只在 position 通知时更新)，导致逐字高亮进度一块块跳，看起来"卡"。而 smoothPosition
    // 用 _positionClock 连续外推，progress 丝滑推进。行切换判定仍用 lyricPosition 保证
    // 不高亮超前到下一句；行内 progress 用 smoothPosition 保证连续。两者各司其职。
    // ====【修复/低端设备歌词高亮卡在行首】==== 主动从 handler 刷新位置基线：
    // 位置流在这台 TV 上 2.3~9.6 秒才来一次，只靠它推算 smoothPosition 会让逐字高亮几乎不动。
    widget.player.refreshPositionFromHandler();
    final pos = widget.player.lyricPosition;
    final smooth = widget.player.smoothPosition;
    final next = _activeLyricIndexFor(widget.player.lyrics, pos);
    if (next != _lastIndex) {
      _lastIndex = next;
      setState(() {});
    }
    _position.value = smooth;
  }

  @override
  Widget build(BuildContext context) {
    final lyrics = widget.player.lyrics;
    if (lyrics.isEmpty) {
      // 点击“暂无歌词”占位区域同样切换到歌词滚动页。
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: SizedBox(
          height: 104,
          child: Center(
            child: Text(
              widget.player.isPreparing || widget.player.lyricsLoading
                  ? '歌词加载中...'
                  : '暂无歌词',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Colors.white.withValues(alpha: .78),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      );
    }

    // ===== 【重构-轻量歌词】封面预览：两行歌词（当前行 + 下一句）=====
    // 开启 perfLightLyric 时，封面页下方歌词预览走 _PerfLyricTwoLinePreview 两行预览
    // 组件（当前行高亮 + 下一句灰字，整体垂直居中，行切换时重建，低 GPU）。
    // 原实现（备份，供回退）：if (widget.player.performanceMode) { ... }
    if (widget.player.perfLightLyric) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: ExcludeSemantics(
          child: SizedBox(
            height: 96,
            child: _PerfLyricTwoLinePreview(
              player: widget.player,
              lyrics: lyrics,
              currentIndex: widget.player.activeLyricIndex,
            ),
          ),
        ),
      );
    }
    // ===== 原实现（备份，供回退）：下述 _position + _activeLyricIndexFor(lyrics, _position) 推导 =====
    // ===== 【顺滑重构】index 已由 _onTick 维护到 _lastIndex（行切换时 setState）。=====
    final index = _lastIndex;
    final current = lyrics[index];
    final next = index + 1 < lyrics.length ? lyrics[index + 1] : null;
    final currentStyle = Theme.of(context).textTheme.titleLarge!.copyWith(
      color: Colors.white,
      fontSize: 22,
      height: 1.22,
      fontWeight: FontWeight.w900,
    );
    final nextStyle = Theme.of(context).textTheme.titleMedium!.copyWith(
      color: Colors.white.withValues(alpha: .46),
      height: 1.18,
      fontWeight: FontWeight.w700,
    );

    // 歌词预览每帧更新位置，用 ExcludeSemantics 防止 Windows AXTree 竞态崩溃
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: ExcludeSemantics(
        child: SizedBox(
          height: 96,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeOutCubic,
            child: Column(
              key: ValueKey(current.time.inMilliseconds),
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  height: 36,
                  child: _MarqueeSingleLine(
                    textKey: current.time.inMilliseconds,
                    // ===== 【顺滑重构】karaoke 逐字高亮用 ValueListenableBuilder 隔离：位置流只
                    // 重建这一小片（_position.value 每 tick 更新），Marquee/AnimatedSwitcher 不再
                    // 跟随重建，消除整树重建导致的卡顿。=====
                    child: ValueListenableBuilder<Duration>(
                      valueListenable: _position,
                      builder: (context, pos, _) => _LyricText(
                        line: current,
                        active: true,
                        position: pos,
                        styleOverride: currentStyle,
                        textAlign: TextAlign.center,
                        singleLine: true,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 25,
                  child: _MarqueeSingleLine(
                    textKey: current.translation != null && current.translation!.isNotEmpty
                        ? current.time.inMilliseconds
                        : (next?.time.inMilliseconds ?? -1),
                    child: Text(
                      current.translation != null && current.translation!.isNotEmpty
                          ? current.translation!
                          : (next?.text ?? ''),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.visible,
                      style: nextStyle,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MarqueeSingleLine extends StatefulWidget {
  const _MarqueeSingleLine({required this.child, required this.textKey});

  final Widget child;
  final Object textKey;

  @override
  State<_MarqueeSingleLine> createState() => _MarqueeSingleLineState();
}

class _MarqueeSingleLineState extends State<_MarqueeSingleLine>
    with SingleTickerProviderStateMixin {
  final _viewportKey = GlobalKey();
  final _contentKey = GlobalKey();
  late final AnimationController _controller;
  double _overflow = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void didUpdateWidget(covariant _MarqueeSingleLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.textKey != widget.textKey) {
      _controller
        ..stop()
        ..reset();
      _overflow = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _measure() {
    if (!mounted) {
      return;
    }
    final viewport = _viewportKey.currentContext?.size?.width ?? 0;
    final content = _contentKey.currentContext?.size?.width ?? 0;
    final overflow = math.max(0.0, content - viewport);
    if ((overflow - _overflow).abs() < 1) {
      return;
    }
    setState(() => _overflow = overflow);
    if (overflow > 0) {
      _controller
        ..duration = Duration(milliseconds: (overflow * 42).round() + 2600)
        ..repeat(reverse: true);
    } else {
      _controller
        ..stop()
        ..reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return ClipRect(
          key: _viewportKey,
          child: SizedBox(
            width: constraints.maxWidth,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                final offset = _overflow <= 0
                    ? 0.0
                    : -_overflow * _controller.value;
                return Align(
                  alignment: _overflow <= 0
                      ? Alignment.center
                      : Alignment.centerLeft,
                  child: Transform.translate(
                    offset: Offset(offset, 0),
                    child: child,
                  ),
                );
              },
              child: OverflowBox(
                minWidth: 0,
                maxWidth: double.infinity,
                alignment: Alignment.centerLeft,
                child: RepaintBoundary(key: _contentKey, child: widget.child),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LyricPlayerPage extends StatefulWidget {
  const _LyricPlayerPage({
    super.key,
    required this.player,
    required this.song,
    required this.isPageVisible,
    required this.onReturnToPoster,
  });

  final PlayerController player;
  final Song song;
  final bool isPageVisible;
  final VoidCallback onReturnToPoster;

  @override
  State<_LyricPlayerPage> createState() => _LyricPlayerPageState();
}

class _LyricPlayerPageState extends State<_LyricPlayerPage>
    with AutomaticKeepAliveClientMixin {
  late _LyricDisplayMode _displayMode;

  /// 歌词字体缩放倍率（持久化）。
  static const _lyricScaleKey = 'settings.lyric_scale';
  double _lyricScale = 1.0;

  @override
  void initState() {
    super.initState();
    _displayMode = _initialLyricDisplayMode(widget.player.lyrics);
    _loadLyricScale();
  }

  Future<void> _loadLyricScale() async {
    // =====【新增/歌词调整】经由集中服务加载，使歌词调整页与渲染共享同一缓存 =====
    await LyricAdjustments.reload();
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _lyricScale = prefs.getDouble(_lyricScaleKey) ?? 1.0);
    }
  }

  Future<void> _setLyricScale(double scale) async {
    final clamped = scale.clamp(0.7, 1.6);
    setState(() => _lyricScale = clamped);
    // =====【新增/歌词调整】同步到集中服务（缓存 + 持久化 + 通知），保证跨页实时生效 =====
    await LyricAdjustments.setScale(clamped);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_lyricScaleKey, clamped);
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void didUpdateWidget(covariant _LyricPlayerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.hash != widget.song.hash ||
        oldWidget.player.lyrics != widget.player.lyrics) {
      _displayMode = _normalizeLyricDisplayMode(
        widget.player.lyrics,
        _displayMode,
      );
    }
  }

  _LyricDisplayMode _initialLyricDisplayMode(List<LyricLine> lyrics) {
    final availableModes = _availableLyricDisplayModes(lyrics);
    return availableModes.isNotEmpty
        ? availableModes.first
        : _LyricDisplayMode.lyricsOnly;
  }

  _LyricDisplayMode _normalizeLyricDisplayMode(
    List<LyricLine> lyrics,
    _LyricDisplayMode currentMode,
  ) {
    final availableModes = _availableLyricDisplayModes(lyrics);
    if (availableModes.contains(currentMode)) {
      return currentMode;
    }
    return availableModes.isNotEmpty
        ? availableModes.first
        : _LyricDisplayMode.lyricsOnly;
  }

  void _toggleLyricDisplayMode() {
    final availableModes = _availableLyricDisplayModes(widget.player.lyrics);
    if (availableModes.length <= 1) {
      return;
    }

    final currentIndex = availableModes.indexOf(_displayMode);
    final nextIndex = currentIndex >= 0
        ? (currentIndex + 1) % availableModes.length
        : 0;
    setState(() => _displayMode = availableModes[nextIndex]);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final availableModes = _availableLyricDisplayModes(widget.player.lyrics);
    final canToggleLyricDisplayMode = availableModes.length > 1;
    final displayMode = _normalizeLyricDisplayMode(
      widget.player.lyrics,
      _displayMode,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
      child: Stack(
        children: [
          _LyricViewport(
            player: widget.player,
            lyrics: widget.player.lyrics,
            isPreparing: widget.player.isPreparing,
            displayMode: displayMode,
            isPageVisible: widget.isPageVisible,
            lyricScale: _lyricScale,
            onReturnToPoster: widget.onReturnToPoster,
          ),
          // 字体大小调节 + 歌词模式切换（右下角，任务3：缩小/放大已从左下移到右下）
          Positioned(
            right: 0,
            bottom: 16,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (canToggleLyricDisplayMode)
                  _GlassIconButton(
                    tooltip: '切换歌词模式（当前：${_lyricDisplayModeLabel(displayMode)}）',
                    onPressed: _toggleLyricDisplayMode,
                    icon: switch (displayMode) {
                      _LyricDisplayMode.lyricsWithTranslation =>
                        Icons.translate_rounded,
                      _LyricDisplayMode.lyricsWithRomanization =>
                        Icons.record_voice_over_rounded,
                      _LyricDisplayMode.lyricsOnly => Icons.lyrics_rounded,
                    },
                  ),
                const SizedBox(width: 8),
                _GlassIconButton(
                  tooltip: '缩小歌词',
                  onPressed: () => _setLyricScale(_lyricScale - 0.1),
                  icon: Icons.text_decrease_rounded,
                ),
                const SizedBox(width: 8),
                _GlassIconButton(
                  tooltip: '放大歌词',
                  onPressed: () => _setLyricScale(_lyricScale + 0.1),
                  icon: Icons.text_increase_rounded,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LyricViewport extends StatefulWidget {
  const _LyricViewport({
    required this.player,
    required this.lyrics,
    required this.isPreparing,
    required this.displayMode,
    required this.isPageVisible,
    required this.lyricScale,
    required this.onReturnToPoster,
  });

  final PlayerController player;
  final List<LyricLine> lyrics;
  final bool isPreparing;
  final _LyricDisplayMode displayMode;
  final bool isPageVisible;
  final double lyricScale;
  final VoidCallback onReturnToPoster;

  @override
  State<_LyricViewport> createState() => _LyricViewportState();
}

class _LyricViewportState extends State<_LyricViewport> {
  static const double _lyricAnchorFraction = 0.43;
  static const double _lyricBlurSigma = 3.0;
  static const double _lyricBlurStep = 0.7;

  late final LyricController _lyricController;
  // ===== 原实现（备份，供回退）：late final Ticker _ticker; int? _lastLyricSubmitMs; =====
  // Ticker(start()) 在回调里即使立即 return，也会持续每帧请求 frame → 播放期间维持整条
  // 60fps 渲染管线，是 GPU 高占用的根因。改为 ~30fps（33ms）Timer 低频驱动，把频控作为
  // 渲染上限（Timer 只在不可见/暂停/拖动时取消，不产生无谓帧）。
  Timer? _ticker;
  // 性能模式"仅行切换更新"用的上一次活动歌词行
  int _lastActiveRow = -1;
  bool _isUserSelecting = false;

  @override
  void initState() {
    super.initState();
    _lyricController = LyricController();
    _lyricController.setOnTapLineCallback((position) {
      if (_lyricController.isSelectingNotifier.value) {
        // 用户长按歌词浏览上下文期间点击某行：保持原有的“跳转到该行进度”行为，
        // 不做页面切换，避免打断浏览。
        widget.player.seek(position);
        return;
      }
      // ===== 【修复】全屏歌词点击：非当前行改为 seek 该行 =====
      // 现象：普通/全屏歌词下点除当前播放行外的其它行也会切回封面预览，错误。
      // 期望：点“当前正在播放行”→ 返回封面预览页；点其它行 → seek 到该行开始时间。
      // 实现：用 _activeLyricIndexFor 把被点击行的 position(行开始时间)映射回行索引，
      //       与 player.activeLyricIndex(当前播放行)比较来判定“当前行 vs 其他行”，
      //       判为当前行才 onReturnToPoster，否则 player.seek(position)。
      // ===== 原实现（备份，供回退）：widget.onReturnToPoster(); =====
      final tappedIndex = _activeLyricIndexFor(widget.lyrics, position);
      if (tappedIndex >= 0 &&
          tappedIndex == widget.player.activeLyricIndex) {
        widget.onReturnToPoster();
      } else {
        widget.player.seek(position);
      }
    });
    _lyricController.isSelectingNotifier.addListener(_onSelectingChanged);
    _syncLyrics();
    // =====【新增/歌词调整】监听歌词调整配置，实时刷新高亮色/行距/透明度/偏移 =====
    LyricAdjustments.notifier.addListener(_onAdjustmentsChanged);
    // 进入时加载持久化配置到内存缓存（reload 完成后会触发 notifier 重建）。
    LyricAdjustments.reload();
    // ===== 原实现（备份，供回退）：_ticker = Ticker(_onTick); =====
    // 不再在 initState 直接创建 Ticker；改由 _syncTicker 在满足播放条件时按需创建
    // ~30fps Timer（见 _syncTicker）。
    _syncTicker();
  }

  // =====【新增/歌词调整】配置变更 → 重建本视图（实时生效）=====
  void _onAdjustmentsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  // =====【新增/歌词调整】当前歌曲的进度偏移存储键（hash 优先）=====
  String get _songKey {
    final s = widget.player.currentSong;
    if (s == null) return '';
    return LyricAdjustments.resolveOffsetKey(hash: s.hash, id: s.id);
  }

  // =====【新增/歌词调整】带偏移的"当前行判定位置"（实际位置 + 歌词偏移）。仅用于
  // 行高亮/滚动判定以对齐歌词；不改音频位置、进度条、smoothPosition 本身。=====
  // 修复：负偏移且歌曲在开头时 probe 可能为负，抛给歌词引擎(flutter_lyric)会死循环卡死；
  // 故钳制到 >=0（偏移最多"回到开头"，不得为负时长）。
  Duration get _offsetProbe {
    final base = widget.player.smoothPosition +
        Duration(
            milliseconds:
                (LyricAdjustments.offsetFor(_songKey) * 1000).round());
    return base.isNegative ? Duration.zero : base;
  }

  @override
  void didUpdateWidget(covariant _LyricViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lyrics != widget.lyrics ||
        oldWidget.displayMode != widget.displayMode) {
      _syncLyrics();
    }
    _syncTicker();
  }

  @override
  void dispose() {
    LyricAdjustments.notifier.removeListener(_onAdjustmentsChanged); // ====【新增/歌词调整】====
    _lyricController.isSelectingNotifier.removeListener(_onSelectingChanged);
    _ticker?.cancel();
    _lyricController.dispose();
    super.dispose();
  }

  void _onSelectingChanged() {
    _isUserSelecting = _lyricController.isSelectingNotifier.value;
    _syncTicker();
  }

  void _syncLyrics() {
    final lyrics = widget.lyrics;
    if (lyrics.isEmpty) return;
    final showTranslation =
        widget.displayMode == _LyricDisplayMode.lyricsWithTranslation;
    final showRomanization =
        widget.displayMode == _LyricDisplayMode.lyricsWithRomanization;
    _lyricController.loadLyricModel(
      convertToFlutterLyricModel(
        lyrics,
        showTranslation: showTranslation,
        showRomanization: showRomanization,
      ),
    );
  }

  void _syncTicker() {
    // ===== 【修复】窗口收进托盘时（player.isUIVisible=false）停止歌词滚动 Ticker =====
    // 原因：托盘隐藏后窗口内歌词 Ticker 仍每帧请求提交导致 GPU 满载。加入 isUIVisible
    // 门控让托盘隐藏时停止该 Ticker；不影响音频播放（托盘收起后音乐仍继续播）。
    // ===== 原实现（备份，供回退）=====
    //   if (shouldTick && !_ticker.isActive) { _ticker.start(); }
    //   else if (!shouldTick && _ticker.isActive) { _ticker.stop(); }
    final shouldTick =
        widget.isPageVisible &&
        widget.player.isUIVisible &&
        widget.player.isPlaying &&
        widget.lyrics.isNotEmpty &&
        !widget.player.isScrubbing &&
        !_isUserSelecting;
    // Timer 版：见 _LandscapeLyricPanelState._syncTicker 注释。Timer 不受 TickerMode
    // 管控，故需显式纳入 isPageVisible 与 isUIVisible。
    if (shouldTick) {
      _ticker ??= Timer.periodic(
        const Duration(milliseconds: 50),
        _onTick,
      );
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  // ===== 原实现（备份，供回退）：Ticker + ≈20fps 二次降采样 =====
  //   void _onTick(Duration elapsed) {
  //     if (!mounted || widget.player.isScrubbing) return;
  //     final nowMs = DateTime.now().millisecondsSinceEpoch;
  //     if (_lastLyricSubmitMs != null && (nowMs - _lastLyricSubmitMs!) < 50) return;
  //     _lastLyricSubmitMs = nowMs;
  //     _lyricController.setProgress(widget.player.smoothPosition);
  //   }
  //
  // 现改为 ~30fps（33ms）Timer 驱动：Timer 本身是唯一节奏源（不再有"每帧 Ticker +
  // 帧内 return"的浪费调度），频率即渲染上限，因此移除原 50ms 二次降采样。
  void _onTick(Timer timer) {
    if (!mounted || widget.player.isScrubbing) {
      return;
    }
    // =====【新增/歌词调整】带偏移的"当前行判定位置"（实际位置 + 歌词偏移）=====
    // 仅用于行高亮/滚动判定以对齐歌词；不改音频位置、进度条、smoothPosition 本身。
    final probe = _offsetProbe;
    // =====【重构-轻量歌词】仅当前行切换时才更新歌词 =====
    // 有歌词时歌词渲染是 GPU 大头。开启 perfLightLyric 后改为只在"活动歌词行变化"
    // 时刷新，行内静止，GPU 大幅下降(视觉为逐行对齐)。原实现（备份，供回退）：
    // if (widget.player.performanceMode) { ... }
    if (widget.player.perfLightLyric) {
      // =====【新增/歌词调整】行判定用带偏移的 probe（原实现：activeLyricIndex）=====
      final row = _activeLyricIndexFor(widget.lyrics, probe);
      if (row == _lastActiveRow) {
        return;
      }
      _lastActiveRow = row;
      // 整行高亮：把进度推到"当前行结束处(下一行开始)"，使该行 100% 高亮，
      // 而不是停在行首只标亮第一个字。
      final ly = widget.player.lyrics;
      if (row >= 0 && row < ly.length && row + 1 < ly.length) {
        _lyricController.setProgress(ly[row + 1].time);
        return;
      }
    }
    // =====【新增/歌词调整】进度用带偏移的 probe（原实现：smoothPosition）=====
    _lyricController.setProgress(probe);
  }

  @override
  Widget build(BuildContext context) {
    final lyrics = widget.lyrics;
    if (lyrics.isEmpty) {
      // 无歌词时点击占位区域返回封面页。
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onReturnToPoster,
        child: Center(
          child: Text(
            widget.isPreparing || widget.player.lyricsLoading
                ? '歌词加载中...'
                : '暂无歌词',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      );
    }

    // =====【新增/歌词调整】统一从配置服务读取字体缩放/行距/透明度/高亮色，实时生效 =====
    // 字体大小复用 settings.lyric_scale（LyricAdjustments.scale）。
    final scale = LyricAdjustments.scale();
    final mainFontSize = 38.0 * scale;
    final inactiveFontSize = 30.0 * scale;
    final subtitleFontSize = 20.0 * scale;
    // 行距：默认 lineSpacing=1.3 对应原观感；textStyle height 按 lineSpacing/1.3 换算，
    // lineGap / 垂直 padding 按同系数放大，实现"行距"调节。
    final spacingFactor = LyricAdjustments.lineSpacingFactor();
    final lineHeight = 1.24 * spacingFactor;
    final translationHeight = 1.3 * spacingFactor;
    // 透明度 + 高亮色：非当前行 alpha 乘 (opacity/100)；当前行用所选高亮色替换 White。
    final cfg = LyricAdjustments.getGlobal();
    final highlightColor = Color(cfg.highlightColor);
    // ====【需求/颜色统一】非当前行（底色/翻译非当前行）颜色：统一→高亮色，否则→底色 baseColor ====
    final lyricBaseColor = Color(cfg.baseColorValue());
    final lyricOpacity = cfg.opacity;
    // ====【需求/颜色统一·当前行随底色透明度】当前行高光透明度 = opacity×(unified?1:highlightOpacity) ====
    final lyricHighlightAlpha = cfg.currentLineAlpha();
    // ====【需求/颜色统一】底色(非当前行)用 base；alpha 仍 = 0.30×opacity ====
    // 原实现（备份）：inactiveColor = highlightColor.withValues(alpha: 0.30 * lyricOpacity);
    final inactiveColor =
        lyricBaseColor.withValues(alpha: 0.30 * lyricOpacity);
    // ====【修复/拆分当前行底色与高亮】当前行"底色层"独立：
    //   * 颜色 = baseColorValue()（非当前行同一来源；统一颜色时=高亮色，关闭时=baseColor）
    //   * alpha = opacity（只随"底色透明度"，关闭统一透明度时不受 highlightOpacity 影响）
    // ====【需求/颜色统一】非当前行（底色/翻译非当前行）颜色：统一→高亮色，否则→底色 baseColor ====
    // 原实现（备份）：activeBaseColor = highlightColor.withValues(alpha: 0.34 * lyricHighlightAlpha);
    final activeBaseColor =
        lyricBaseColor.withValues(alpha: 0.34 * lyricOpacity);

    final lyricStyle = LyricStyles.default1.copyWith(
      // ====【需求/字体粗细】整体字重：三处都改用 cfg.lyricFontWeight()（默认 700）。
      // 原实现（备份）：textStyle w700 / activeStyle w900 / translationStyle w500。
      textStyle: Theme.of(context).textTheme.headlineSmall!.copyWith(
        color: inactiveColor,
        fontSize: inactiveFontSize,
        height: lineHeight,
        fontWeight: cfg.lyricFontWeight(),
        letterSpacing: -0.5,
      ),
      activeStyle: Theme.of(context).textTheme.headlineMedium!.copyWith(
        color: activeBaseColor,
        fontSize: mainFontSize,
        height: lineHeight,
        fontWeight: cfg.lyricFontWeight(),
        letterSpacing: -0.5,
      ),
      translationStyle: Theme.of(context).textTheme.titleLarge!.copyWith(
        // ====【需求/翻译行接入自适应色】翻译非当前行(底色)用 base；alpha 提高到 0.5（比原文
        // 非当前行 0.30 更清晰、可读，且随色弱化）。原实现（备份）：
        //   color: lyricBaseColor.withValues(alpha: 0.25 * lyricOpacity),
        color: lyricBaseColor.withValues(alpha: 0.5 * lyricOpacity),
        fontSize: subtitleFontSize,
        height: translationHeight,
        fontWeight: cfg.lyricFontWeight(),
      ),
      // ====【需求/颜色统一·当前行随底色透明度】当前行翻译文字随 currentLineAlpha（色保持高亮色）====
      // 原实现（备份 1）：translationActiveColor: highlightColor.withValues(alpha: 0.95),
      // 原实现（备份 2）：translationActiveColor: highlightColor.withValues(alpha: 0.95 * lyricOpacity),
      translationActiveColor:
          highlightColor.withValues(alpha: 0.95 * lyricHighlightAlpha),
      lineGap: 16 * scale * spacingFactor,
      translationLineGap: 6 * scale * spacingFactor,
      contentPadding: EdgeInsets.symmetric(
        horizontal: 20,
        vertical: 40 * scale * spacingFactor,
      ),
      anchorPosition: _lyricAnchorFraction,
      activeAnchorPosition: _lyricAnchorFraction,
      fadeRange: FadeRange(top: 40, bottom: 40),
      textAlign: TextAlign.left,
      contentAlignment: CrossAxisAlignment.start,
      // ====【需求/拆分透明度】当前行高亮色随高光透明度（不再裸 opacity）====
      // 原实现（备份 1）：activeHighlightColor: highlightColor,
      // 原实现（备份 2）：activeHighlightColor: highlightColor.withValues(alpha: lyricOpacity),
      activeHighlightColor:
          highlightColor.withValues(alpha: lyricHighlightAlpha),
      scrollDuration: const Duration(milliseconds: 480),
      scrollCurve: const Cubic(0.16, 1.0, 0.3, 1.0),
    );

    // ===== 【重构-轻量歌词】自绘整行歌词（轻量、低 GPU）=====
    // 开启 perfLightLyric 且歌词非空时，用 _PerfLyricList 整行统一高亮替换
    // BlurredLyricView，忽略逐词时间轴、只在活动行切换时重绘；仅保留歌词与可选的
    // 当前行小字翻译。原实现（备份，供回退）：if (widget.player.performanceMode) { ... }
    if (widget.player.perfLightLyric) {
      return ExcludeSemantics(
        // 排除语义树，防止 Windows AXTree 竞态崩溃（与原有歌词视图一致）。
        child: _PerfLyricList(
          player: widget.player,
          lyrics: lyrics,
          currentIndex: widget.player.activeLyricIndex,
          fontSize: mainFontSize,
          inactiveFontSize: inactiveFontSize,
          subtitleFontSize: subtitleFontSize,
          // =====【新增/歌词调整】active/inactive 颜色改用配置的高亮色与透明度（实时生效）=====
          activeColor: highlightColor,
          // ====【需求/颜色统一】轻量非当前行(底色)用 base ====
          // 原实现（备份）：inactiveColor: highlightColor.withValues(alpha: 0.30 * lyricOpacity),
          inactiveColor:
              lyricBaseColor.withValues(alpha: 0.30 * lyricOpacity),
          showTranslation:
              widget.displayMode == _LyricDisplayMode.lyricsWithTranslation,
          textAlign: TextAlign.left,
          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 40 * scale),
          // ===== 【双模糊·与原版同一逻辑】歌词页原版用 _lyricBlurSigma/Step，轻量沿用 =====
          maxBlurSigma: widget.player.perfLyricBlurOff ? 0.0 : _lyricBlurSigma,
          blurStep: _lyricBlurStep,
          // ===== 【修复】性能模式全屏歌词页点击交互（需求1/3）=====
          // 与正常模式 _LyricViewport 的 tap 语义对齐：
          //   * 点击"当前播放行" → 切回封面预览页（正常模式普通状态下点当前行即返回封面页）；
          //   * 点击"非当前行" → seek 到该行开始时间（正常模式浏览中点其它行跳到该行进度）。
          // index == activeLyricIndex 即"判定当前行"，与正常模式 BlurredLyricView 的
          // setOnTapLineCallback 判定一致。
          onTapLine: (index) {
            if (index == widget.player.activeLyricIndex) {
              widget.onReturnToPoster();
            } else {
              widget.player.seek(widget.lyrics[index].time);
            }
          },
        ),
      );
    }
    // ===== 原实现（备份，供回退）=====
    return ExcludeSemantics(
      // 歌词视图高频更新会触发 Windows AXTree 竞态崩溃，排除语义树
      child: BlurredLyricView(
        controller: _lyricController,
        style: lyricStyle,
        maxBlurSigma: widget.player.perfLyricBlurOff ? 0.0 : _lyricBlurSigma,
        blurStep: _lyricBlurStep,
      ),
    );
  }
}

/// ===== 【修复】隐藏性能模式歌词的滚动条 =====
///
/// 背景：原 _PerfLyricList 用的是原生 ListView.builder。Flutter 在 Windows/桌面平台
/// 默认 ScrollBehavior 会为可滚动区域注入一个叠加式滚动条(Scrollbar)，而正常模式的
/// BlurredLyricView 是自定义绘制、不带滚动条。这导致"性能模式歌词自动滚动时多出一条
/// 右侧滚动条"，与不开启性能模式时视觉不一致。
///
/// 修复：定制 ScrollBehavior 覆盖 buildScrollbar 为空，仅去掉滚动条，ListView 的滚轮 /
/// 拖拽等滚动能力完全保留。
class _NoScrollbarBehavior extends ScrollBehavior {
  const _NoScrollbarBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) =>
      child;
}

/// ===== 【修复】让 ListView 不再处理滚轮、也不参与原生拖拽的 ScrollPhysics =====
/// 需求1：滚轮改为按行走。Flutter 中 Scrollable 的滚轮事件经 PointerSignalResolver 只交给
/// 深层的 Scrollable 处理、不走 physics，从 Listener 无法直接"抢占"或 preventDefault。
/// 这里利用 Scrollable._handlePointerSignal 的门控：当 physics.shouldAcceptUserOffset 为
/// false 时，Scrollable 不会注册滚轮 handler、也不处理滚轮；同时 canDrag=false 取消原生
/// 拖拽。于是滚轮由外层 Listener（_onPointerSignal，按行走）接管、拖拽由外层
/// GestureDetector（_onVerticalDragUpdate，自由滚）接管，互不打架，也彻底消除
/// "默认自由滚 + 我们按行滚"造成的双滚/跳行。
class _PerfLyricScrollPhysics extends ClampingScrollPhysics {
  const _PerfLyricScrollPhysics({super.parent});

  @override
  _PerfLyricScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _PerfLyricScrollPhysics(parent: buildParent(ancestor));

  // 注意：ScrollPhysics 没有 canDrag 成员，原生拖拽能否参与由 shouldAcceptUserOffset 决定
  //（Scrollable 通过 physics.shouldAcceptUserOffset 驱动 setCanDrag），故这里只关滚轮即可，
  // 原生拖拽会随之被禁用并改由外层 GestureDetector 接管。
  // 继承 ClampingScrollPhysics 以保留 createBallisticSimulation(惯性快滑)：外部
  // _onVerticalDragEnd 松手时调用 position.goBallistic(v) 即可获得与原版一致的 fling。
  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) => false; // 关闭滚轮自由滚动
}

// ====== 【性能模式】自绘整行歌词（轻量、低 GPU）=====
///
/// 背景：正常模式用 flutter_lyric 的 BlurredLyricView 渲染歌词，当歌词带逐词时间戳
/// (words) 时它呈现"行内逐词/部分高亮"，且其滚动/模糊/淡入淡出会在播放期间维持每帧
/// 重绘，GPU 占用高。
///
/// 本组件仅用于性能模式：忽略逐词时间轴，把"当前行"整行统一高亮（整行白色加粗，
/// 其余行灰色），并在活动行切换时滚动使其大致居中。保持轻量：
///   * 无逐词进度、无每帧动画、无高斯模糊；
///   * 通过固定 itemExtent 的 ListView 精确滚动定位；
///   * 只监听 player 的活动歌词行 index，仅在行切换时才 setState 与滚动，行内静止。
class _PerfLyricList extends StatefulWidget {
  const _PerfLyricList({
    required this.player,
    required this.lyrics,
    required this.currentIndex,
    required this.fontSize,
    required this.inactiveFontSize,
    required this.subtitleFontSize,
    required this.activeColor,
    required this.inactiveColor,
    this.showTranslation = false,
    this.textAlign = TextAlign.left,
    this.padding = EdgeInsets.zero,
    this.onTapLine,
    // ===== 【双模糊·与原版同一逻辑】模糊强度参数，由调用方传原版 BlurredLyricView 同值 =====
    this.maxBlurSigma = 2.0,
    this.blurStep = 0.7,
  });

  final PlayerController player;
  final List<LyricLine> lyrics;
  final int currentIndex;
  final double fontSize;
  final double inactiveFontSize;
  final double subtitleFontSize;
  final Color activeColor;
  final Color inactiveColor;
  final bool showTranslation;
  final TextAlign textAlign;
  final EdgeInsets padding;
  /// 模糊强度上限（与原版 BlurredLyricView.maxBlurSigma 对齐）。
  final double maxBlurSigma;
  /// 每远离一行增加的模糊强度（与原版 BlurredLyricView.blurStep 对齐）。
  final double blurStep;

  /// ===== 【修复】点击某行回调（需求1/3）=====
  /// 把"点某一行"这一步处理下放到调用方（全屏歌词页/车机各按正常模式语义接线）：
  ///   * 点击回调传入被点击行的索引 index，由调用方判定是否为当前行（activeLyricIndex），
  ///     activeLyricIndex 是全项目统一的"当前播放行"，据此做"点当前行切页 / 点其它行 seek"。
  final void Function(int index)? onTapLine;

  @override
  State<_PerfLyricList> createState() => _PerfLyricListState();
}

class _PerfLyricListState extends State<_PerfLyricList> {
  final ScrollController _sc = ScrollController();
  late int _index;
  bool _initialCentered = false;
  // ===== 【双模糊·实时驱动】广播"画面居中行"，随滚动每帧更新 =====
  // 解决 ListView 懒加载导致的偶发性：ListView 只会懒加载 index 首次进入视口时构建 item，
  // 滚动中已显示的 item 不复用重建 → 若 blur 参数固化在 item 首次 build，则滚动不实时。
  // 这里用一个 ValueNotifier 广播画面中线行，滚动中每帧更新；每个可见行外层监听它,
  // 只重建轻量的 ImageFiltered 层（不改文本），从而"你滚到哪、哪就实时清晰"，与原版
  // CustomPaint 每帧重算的观感一致，且不整树重建、不每帧重算 layout。
  final ValueNotifier<int> _centerRow = ValueNotifier<int>(0);

  // ===== 【修复】允许用户手动滚轮/拖拽滚动歌词，自动居中仅在非用户操作时执行 =====
  // 背景：原实现用 NeverScrollableScrollPhysics 禁用了 ListView 的手动滚动，仅靠自研
  // _scrollToCenter 自动定位，导致性能模式（车机/全屏歌词页）无法用滚轮/鼠标拖拽浏览
  // 其它行歌词。现放开滚动，并：
  //   * 监听用户的滚轮(PointerScrollEvent)与指针拖拽(ScrollNotification.dragDetails)，
  //     进入"用户浏览"状态并启动冷却计时；
  //   * 活动歌词行切换时，若用户正在手动浏览(冷却期未过)则不强拉回当前行，只更新高亮；
  //     用户停止滚动一小段时间后恢复自动跟随当前行居中，避免互相打架。
  bool _userScrolling = false;
  Timer? _userScrollCooldown;
  static const _userScrollCooldownMs = 3000;
  // ===== 【修复】对标原版滚轮的"浏览行索引" =====
  // 原版 BlurredLyricView 维护一个 selectedIndex（初始跟随当前播放活动行），滚轮以它为
  // 基准逐行前进/后退，冷却后回归当前播放行。这里 _browseIndex 即该语义：null 表示
  // 跟随当前播放行 _index；滚轮后保存用户正在浏览的行索引，作为下一次滚轮基准。
  int? _browseIndex;

  void _markUserScroll() {
    _userScrolling = true;
    _userScrollCooldown?.cancel();
    _userScrollCooldown = Timer(Duration(milliseconds: _userScrollCooldownMs), () {
      if (!mounted) {
        return;
      }
      _userScrolling = false;
      // ===== 【修复】对标原版 resumeActiveLine：冷却结束恢复自动跟随当前播放行 =====
      // 用户停止滚轮/拖拽一段时间后，除结束"用户浏览"状态外，还清空浏览行索引并平滑
      // 滚回当前播放行 _index，与正常模式歌词面板一致。冷却期内若用户再次滚动，会由
      // _markUserScroll 的 cancel + 重建 Timer 自动重置计时，不会在滚动中强行拉回。
      _browseIndex = null;
      _restoreToActiveLine();
    });
  }

  bool _onScrollNotification(ScrollNotification notification) {
    // 指针拖拽（鼠标/触摸拖动）驱动才算用户手动滚动；programmatic 的 animateTo/jumpTo
    // 产生的更新 dragDetails 为 null，不会被误判。（各派生类 dragDetails 类型不同，
    // 故在各自分支内独立判断。）
    if (notification is ScrollStartNotification) {
      if (notification.dragDetails != null) {
        _markUserScroll();
      }
    } else if (notification is ScrollUpdateNotification) {
      if (notification.dragDetails != null) {
        _markUserScroll();
      }
      // ===== 【双模糊·实时驱动】滚动中每帧广播"画面居中行"，让各可见行实刷新模糊 =====
      // 同时覆盖用户手动滚动（滚轮/拖拽）与自动回归滚动（animateTo），保证模糊中心实时。
      _centerRow.value = _viewCenterRow();
    }
    return false;
  }

  // ===== 【修复】滚轮改为"按行走"，不再自由像素滚动 =====
  // 背景：此前滚轮由 ListView 自由像素滚动，而每行 itemExtent 较小（几十像素），一次滚轮
  // 常越过好几行，无法逐行浏览歌词。本组件的 ListView 现使用 _PerfLyricScrollPhysics
  //（shouldAcceptUserOffset=false → Scrollable 不会注册/处理滚轮；canDrag=false → 也不
  // 参与原生拖拽，拖拽改由外层 GestureDetector 接管见 _onVerticalDragUpdate），彻底消除
  // "默认自由滚 + 我们按行滚"造成的双滚/跳行。
  //
  // 这里在 Listener 拦截滚轮：
  //   * 将每次滚轮折算为"前进/后退一行 itemExtent"，并把 ListView 内部位置 animateTo 到
  //     以行边界对齐的居中目标，保证每行都能被浏览到、绝不越过某行；
  //   * 手动浏览状态与冷却逻辑不变（_markUserScroll），停止后仍恢复自动跟随当前行。
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      _markUserScroll();
      if (!_sc.hasClients || widget.lyrics.isEmpty) {
        return;
      }
      final dy = event.scrollDelta.dy;
      if (dy == 0) {
        return;
      }
      // 滚轮前进/后退一整行（dy>0 为滚向下/下一页，与正常模式 _handleLyricMouseWheel 方向一致）。
      final step = dy > 0 ? 1 : -1;
      // ===== 【修复】对标原版滚轮语义：以"浏览行索引"为基准逐行前进/后退 =====
      // 原版 BlurredLyricView 的 selectedIndexNotifier（== 这里的 _browseIndex，
      // null 表示跟随当前播放行 _index）：cur=_browseIndex ?? _index；target=(cur+dir)
      // .clamp(0,count-1)（原版 clamp 上限 count-1，这里 count>=1 因已判空）；记录并平滑
      // 滚动定位到 target 行。相比旧实现"从视觉中心行反解 curRow 再 ±1"，本实现把基准
      // 锁定为用户浏览行，连续滚轮在手感上与正常模式完全一致、不跳行。
      // ===== 原实现（备份，供回退）：基于"视觉中心行反解" curRow ±1 =====
      //   final itemExtent = _itemExtent;
      //   final position = _sc.position;
      //   final viewport = position.viewportDimension;
      //   final base = math.max(0.0, widget.padding.top);
      //   final curRow = ((position.pixels + viewport/2 - base)/itemExtent)
      //       .floor().clamp(0, widget.lyrics.length - 1);
      //   final nextRow = (curRow + step).clamp(0, widget.lyrics.length - 1);
      //   final raw = base + nextRow*itemExtent + itemExtent/2 - viewport/2;
      //   final target = raw.clamp(position.minScrollExtent, position.maxScrollExtent);
      //   if ((target - position.pixels).abs() < 0.5) return;
      //   _sc.animateTo(target, duration: Duration(milliseconds:180), curve: Curves.easeOutCubic);
      final count = widget.lyrics.length;
      final browseBase = _browseIndex ?? _index;
      final targetIdx = (browseBase + step).clamp(0, count - 1);
      if (targetIdx == browseBase) {
        // 已到首行/末行，无需滚动。
        return;
      }
      _browseIndex = targetIdx;
      _scrollToIndex(
        targetIdx,
        animate: true,
        // 对齐原版 BlurredLyricView 滚轮速度(style.scrollDuration=240ms)，
        // 使轻量与原版歌词滚轮手感一致。
        duration: const Duration(milliseconds: 240),
      );
    }
  }

  // ===== 【修复】拖拽自由滚动手动接管（配合 _PerfLyricScrollPhysics 关闭原生拖拽）=====
  // physics 关闭原生拖拽后，鼠标/触摸拖动改由外层 GestureDetector 承办：拖拽仍可自由
  // 像素滚动（符合"拖拽仍可自由滚动"），并同样进入"用户浏览"冷却态。
  void _onVerticalDragStart(DragStartDetails details) {
    _markUserScroll();
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (!_sc.hasClients) {
      return;
    }
    final position = _sc.position;
    final next =
        (position.pixels - details.delta.dy)
            .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((next - position.pixels).abs() < 0.001) {
      return;
    }
    _markUserScroll();
    _sc.jumpTo(next);
  }

  // ===== 【修复】松手惯性快滑（对标原版 fling）=====
  // 原版 BlurredLyricView（flutter_lyric）拖拽松开后有惯性滑动；轻量歌词此前是松手即
  // 停。利用继承 ClampingScrollPhysics 得到的 ballistic，按松手瞬间的主轴速度触发惯性，
  // 让快滑/松手的手感与原版一致。
  void _onVerticalDragEnd(DragEndDetails details) {
    _markUserScroll();
    final v = details.primaryVelocity ?? 0;
    if (!_sc.hasClients || v.abs() < 200) {
      return; // 速度过小视为普通拖动，不触发惯性
    }
    final position = _sc.position;
    // 由松手速度估算滑行距离(与拖拽方向一致)，用 easeOut 渐停，模拟 fling 惯性。
    // 系数 0.20：比原 0.12 更快、更有惯性，贴近原版手感。
    final dist = (v * 0.20).clamp(-6000.0, 6000.0);
    final target =
        (position.pixels - dist).clamp(position.minScrollExtent, position.maxScrollExtent);
    final durMs = (150 + (v.abs() * 0.15)).clamp(150.0, 600.0).round();
    _sc.animateTo(
      target,
      duration: Duration(milliseconds: durMs),
      curve: Curves.easeOutCubic,
    );
  }
  /// 固定单行高度：按"活动行字号 + 翻译预留"统一计算，保证每行 itemExtent 一致，
  /// 从而滚动定位可通过 index * itemExtent 精确计算。
  double get _itemExtent {
    // =====【新增/歌词调整】行距按配置换算（默认 lineSpacing=1.3 → spacingFactor=1.0）=====
    final sf = LyricAdjustments.lineSpacingFactor();
    final textHeight = widget.fontSize * (1.3 * sf);
    final translationSpace = widget.showTranslation
        ? (widget.subtitleFontSize * (1.4 * sf) + 6)
        : 0.0;
    return textHeight + translationSpace + 10;
  }

  // =====【新增/歌词调整】歌词调整配置访问（行距/透明度/高亮色）=====
  double get _spacingFactor => LyricAdjustments.lineSpacingFactor();
  double get _lineHeightText => 1.2 * _spacingFactor;
  // ====【需求/颜色统一·当前行随底色透明度】轻量当前行色随 currentLineAlpha（=opacity×(unified?1:highlightOpacity)）====
  // 原实现（备份 1）：return Color(c.highlightColor);
  // 原实现（备份 2）：return Color(c.highlightColor).withValues(alpha: c.highlightAlpha());
  Color get _activeColor {
    final c = LyricAdjustments.getGlobal();
    return Color(c.highlightColor).withValues(alpha: c.currentLineAlpha());
  }
  // ====【需求/颜色统一·当前行随底色透明度】轻量当前行翻译色随 currentLineAlpha（保留 .95 亮读比例）====
  // 原实现（备份）：return Color(c.highlightColor).withValues(alpha: 0.95 * c.highlightAlpha());
  Color get _activeTranslateColor {
    final c = LyricAdjustments.getGlobal();
    return Color(c.highlightColor)
        .withValues(alpha: 0.95 * c.currentLineAlpha());
  }
  // ====【需求/颜色统一】轻量非当前行(底色)色用 baseColorValue（统一→高亮色）====
  // 原实现（备份）：return Color(c.highlightColor).withValues(alpha: (0.30 * c.opacity));
  Color get _inactiveColor {
    final c = LyricAdjustments.getGlobal();
    return Color(c.baseColorValue())
        .withValues(alpha: (0.30 * c.opacity));
  }

  // =====【新增/歌词调整】当前歌曲的进度偏移存储键（hash 优先）=====
  String get _songKey {
    final s = widget.player.currentSong;
    if (s == null) return '';
    return LyricAdjustments.resolveOffsetKey(hash: s.hash, id: s.id);
  }

  // =====【新增/歌词调整】带偏移的当前行索引（实际位置 + 歌词偏移）。
  // 仅用于行高亮/滚动判定以对齐歌词；不改音频位置、进度条、activeLyricIndex 本身。=====
  int get _offsetActiveIndex {
    final offset = LyricAdjustments.offsetFor(_songKey);
    final probe = widget.player.smoothPosition +
        Duration(milliseconds: (offset * 1000).round());
    return _activeLyricIndexFor(widget.lyrics, probe);
  }

  @override
  void initState() {
    super.initState();
    _index = _offsetActiveIndex.clamp(0, widget.lyrics.length - 1);
    _centerRow.value = _index;
    // 监听 player：位置流 notify 高频，但下面只在该 index 变化时才处理，行内静止。
    widget.player.addListener(_onPlayerNotify);
    // =====【新增/歌词调整】监听配置变更实时刷新（颜色/行距）=====
    LyricAdjustments.notifier.addListener(_onAdjustmentsChanged);
    LyricAdjustments.reload();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToCenter(animate: false),
    );
  }

  // =====【新增/歌词调整】配置变更 → 重建本列表（实时生效颜色/行距）=====
  void _onAdjustmentsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant _PerfLyricList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.removeListener(_onPlayerNotify);
      widget.player.addListener(_onPlayerNotify);
    }
    if (oldWidget.lyrics != widget.lyrics) {
      _index = _offsetActiveIndex.clamp(0, widget.lyrics.length - 1);
      _centerRow.value = _index;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToCenter(animate: false),
      );
    }
  }

  @override
  void dispose() {
    widget.player.removeListener(_onPlayerNotify);
    LyricAdjustments.notifier.removeListener(_onAdjustmentsChanged); // ====【新增/歌词调整】====
    _userScrollCooldown?.cancel();
    _centerRow.dispose();
    _sc.dispose();
    super.dispose();
  }

  void _onPlayerNotify() {
    if (!mounted) {
      return;
    }
    // =====【新增/歌词调整】行高亮/居中 index 用"带偏移的当前行"（实际位置+歌词偏移）=====
    // 不与 player.activeLyricIndex 同步，避免影响桌面歌词等其它对 activeLyricIndex 的消费方
    // （原实现：final next = widget.player.activeLyricIndex;）。
    final next = _offsetActiveIndex;
    if (next < 0 || next >= widget.lyrics.length || next == _index) {
      return;
    }
    // 活动歌词行切换：重建一次；行内静止不触发。
    setState(() => _index = next);
    // ===== 【修复】用户在手动浏览（滚轮/拖拽冷却期内）时不自动拉回当前行，仅更新高亮。
    // 仅当用户未在手动操作时才平滑滚到当前行居中。 =====
    // ===== 原实现（备份，供回退）：注释掉的自动居中调用在最下方 =====
    if (_userScrolling) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToCenter(animate: true),
    );
  }

  /// 把指定行滚动到视口中央；越界时 clamp 到 [minScrollExtent, maxScrollExtent]。
  /// ===== 【修复】对标原版滚轮：抽出通用"定位到指定行索引" =====
  /// 居中精确化说明（保留）：
  /// 根因：ListView 的 `padding` 会被 SliverPadding 包住，第 `_index` 项的顶边在滚动坐标里
  /// 实际是 `padding.top + _index * itemExtent`。旧实现 target 只算了 `_index*itemExtent +
  /// itemExtent/2 - viewport/2`，漏掉 `widget.padding.top`，导致滚动整体少滚一段——活动行
  /// 始终落在视口中心偏下的位置（视觉"偏一行"）；又因只在行切换时滚动、播放中不重算所以
  /// "一直偏、不归位"。同时旧 `maxExtent = count*itemExtent - viewport` 未计入 padding
  /// 的 top+bottom，末几行会因越界 clamp 到偏小的上限而无法真正居中。
  /// 修复：把顶部 padding 纳入居中基准 `base`，并直接用 ScrollPosition 的真实
  /// minScrollExtent / maxScrollExtent（已含 padding.top+bottom）做 clamp，杜绝越界。
  void _scrollToIndex(
    int idx, {
    bool animate = true,
    // 默认 300ms（行切换自动居中）；滚轮浏览可传更短时长以更跟手、降低"阻尼感"。
    Duration duration = const Duration(milliseconds: 300),
  }) {
    if (!_sc.hasClients || widget.lyrics.isEmpty) {
      return;
    }
    final itemExtent = _itemExtent;
    final position = _sc.position;
    final viewport = position.viewportDimension;
    // 内容起点：顶部 padding 在滚动坐标中先占一段偏移，居中基准需加上它。
    final base = math.max(0.0, widget.padding.top);
    final raw = base + idx * itemExtent + itemExtent / 2 - viewport / 2;
    final target = raw.clamp(position.minScrollExtent, position.maxScrollExtent);
    if (animate && _initialCentered) {
      _sc.animateTo(
        target,
        duration: duration,
        curve: Curves.easeOutCubic,
      );
    } else {
      _initialCentered = true;
      _sc.jumpTo(target);
    }
  }

  /// 把当前播放行滚动到视口中央（滚轮/拖拽冷却结束后的自动回归，以及行切换跟随等）。
  void _scrollToCenter({bool animate = true}) {
    _scrollToIndex(_index, animate: animate);
  }

  /// ===== 【双模糊·与原版同一逻辑】画面居中行（第二模糊中心）=====
  /// 根据当前滚动位置反解视口中线所在行，与 _BlurredLyricPainter 的
  /// previewCenterIndex（indexAtScrollAnchor）口径一致。
  int _viewCenterRow() {
    if (!_sc.hasClients || widget.lyrics.isEmpty) {
      return _index;
    }
    final position = _sc.position;
    final base = math.max(0.0, widget.padding.top);
    final row =
        ((position.pixels + position.viewportDimension / 2 - base) / _itemExtent)
            .floor();
    return row.clamp(0, widget.lyrics.length - 1);
  }

  /// ===== 【双模糊·与原版同一逻辑】到"双中心"较近者的距离 =====
  /// 与原版 _BlurredLyricPainter.drawLine 的
  ///   distance = min(|index-playIndex|, |index-previewCenterIndex|) 完全一致，
  /// 其中"画面居中行"取实时广播的 _centerRow。
  int _dualBlurDistance(int index) {
    final dPlay = (index - _index).abs();
    final dView = (index - _centerRow.value).abs();
    return math.min(dPlay, dView);
  }

  /// ===== 【修复】对标原版 resumeActiveLine：冷却结束后回归当前播放活动行 =====
  /// 当用户浏览（滚轮/拖拽）后停止达到冷却时长，把滚动位置恢复为当前播放行 _index 居中。
  /// 若当前视口中心所在行已是 _index，则无需滚动（避免无谓动画）。
  void _restoreToActiveLine() {
    if (!_sc.hasClients || widget.lyrics.isEmpty) {
      return;
    }
    final itemExtent = _itemExtent;
    final position = _sc.position;
    final viewport = position.viewportDimension;
    final base = math.max(0.0, widget.padding.top);
    final curRow = ((position.pixels + viewport / 2 - base) / itemExtent)
        .floor()
        .clamp(0, widget.lyrics.length - 1);
    if (curRow == _index) {
      return;
    }
    _scrollToIndex(_index, animate: true);
  }

  @override
  Widget build(BuildContext context) {
    // ===== 【修复】放开手动滚动，并把自动居中限制在"非用户操作"时 =====
    // ListView 改用默认 ScrollPhysics（原为 NeverScrollableScrollPhysics，禁用滚轮/拖拽）。
    // 外层用 Listener(滚轮 PointerScrollEvent) + NotificationListener(拖拽 dragDetails)
    // 检测用户手动滚动，进入"用户浏览"状态：行切换时仅更新高亮、不自动居中；用户滚动
    // 停止一段时间后恢复自动跟随当前行居中，避免强制拉回与用户浏览打架。
    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: Listener(
        onPointerSignal: _onPointerSignal,
        behavior: HitTestBehavior.opaque,
        // ===== 【修复】拖拽手动接管：包一层 GestureDetector 承载鼠标/触摸拖动，配合
        // physics 关闭原生拖拽后仍可用手指/鼠标拖拽自由浏览歌词（见 _onVerticalDragUpdate）。=====
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: _onVerticalDragStart,
          onVerticalDragUpdate: _onVerticalDragUpdate,
          onVerticalDragEnd: _onVerticalDragEnd,
          child: ScrollConfiguration(
          // ===== 【修复】隐藏性能模式歌词滚动条（问题2）=====
          // 用 _NoScrollbarBehavior 覆盖默认 buildScrollbar，去掉桌面平台自动注入的
          // 滚动条；滚轮/拖拽等 ListView 手动滚动能力不受影响（仍由外层 Listener/
          // NotificationListener 识别为用户浏览）。
          // ===== 原实现（备份，供回退）：child: ListView.builder(（默认 ScrollBehavior
          // 会在桌面平台自动显示滚动条）=====
          behavior: const _NoScrollbarBehavior(),
          child: ListView.builder(
          controller: _sc,
          // =====【底部留白·对齐原版】滚动到底后底部保留大片空白 =====
          // 原版 BlurredLyricView 滚动到底时最后一行被锚定在视口约 activeAnchorPosition
          //（歌词页 fraction 0.43）处，底部留白随窗口高度按比例变（≈0.5 视口）。轻量此前
          // 贴底（最后一行动压在底部，模糊下看不清）。这里按视口比例追加底部空白，滚动到
          // 底后最后一行上移、底部露出与窗口成比例的留白 → 与原版观感一致且随窗口缩放。
          padding: widget.padding.copyWith(
            bottom: widget.padding.bottom +
                (MediaQuery.sizeOf(context).height * 0.5),
          ),
          // =====【修复】滚轮与拖拽改由外层统一接管：用 _PerfLyricScrollPhysics
          // 让 Scrollable 既不处理滚轮（shouldAcceptUserOffset=false）也不参与原生拖拽
          //（canDrag=false）；滚轮按行走见 _onPointerSignal、拖拽自由滚见
          // _onVerticalDragUpdate，二者互不打架。
          // ===== 原实现（备份，供回退）：默认 physics（滚轮自由滚，一次可越过多行）=====
          physics: const _PerfLyricScrollPhysics(),
          itemExtent: _itemExtent,
          itemCount: widget.lyrics.length,
          itemBuilder: (context, index) {
        final line = widget.lyrics[index];
        final active = index == _index;
        // =====【新增/歌词调整】颜色/行高改用配置值（实时生效）=====
        final useActiveColor = active ? _activeColor : _inactiveColor;
        final useLineHeight = _lineHeightText;
        // ====【需求/字体粗细】整体字重（默认 700）。原实现（备份）：active w900 / inactive w700 / 翻译 w500。
        final useFontWeight = LyricAdjustments.getGlobal().lyricFontWeight();
        final textStyle = (active
                ? TextStyle(
                    color: useActiveColor,
                    fontSize: widget.fontSize,
                    height: useLineHeight,
                    fontWeight: useFontWeight,
                  )
                : TextStyle(
                    color: widget.inactiveColor,
                    fontSize: widget.inactiveFontSize,
                    height: useLineHeight,
                    fontWeight: useFontWeight,
                  ));
        final mainText = Text(
          line.text,
          style: textStyle,
          textAlign: widget.textAlign,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );

        Widget body = mainText;
        if (widget.showTranslation &&
            active &&
            line.translation != null &&
            line.translation!.isNotEmpty) {
          body = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              mainText,
              const SizedBox(height: 4),
              Text(
                line.translation!,
                style: TextStyle(
                  // =====【新增/歌词调整】翻译色随高亮色 + 透明度缩放 =====
                  // ====【修复/透明度】当前行翻译改用独立 getter——保留 .95 亮读比例且乘 opacity。
                  // 旧实现（备份）用 useActiveColor.withValues(alpha:.95)，会覆盖掉 _activeColor
                  // 已乘的 opacity，导致翻译色不受透明度影响，故改为 _activeTranslateColor。====
                  color: _activeTranslateColor,
                  fontSize: widget.subtitleFontSize,
                  height: 1.3 * _spacingFactor,
                  // ====【需求/字体粗细】翻译行也接整体字重。原实现（备份）：w500。
                  fontWeight: useFontWeight,
                ),
                textAlign: widget.textAlign,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          );
        }

        // ===== 【修复】封面预览改两行组件后，本单行列表固定靠左（车机/全屏沿用）=====
        // ===== 原实现（备份，供回退）：
        //   alignment: widget.itemAlignment,
        // =====（此前封面预览传入 Alignment.center 居中单行，已改由两行组件承载）=====
        final Widget lineWidget = Align(
          alignment: AlignmentDirectional.centerStart,
          child: body,
        );
        // ===== 【双模糊·与原版同一逻辑】逐行累计高斯模糊 =====
        // 与原版 BlurredLyricView 的 _BlurredLyricPainter 用同一公式：
        //   distance = min(|index-播放行|, |index-画面居中行|)
        //   sigma    = min(maxBlurSigma, blurStep * distance)
        // 不设"是否手动滚动"开关 —— 播放行(自动)与画面居中行(手动浏览)随视图自适应：
        //   自动(播放行居中)时画面居中行≈播放行 → 等同单中心；
        //   手动滚动偏离播放行后 → 自动以画面居中行为中心清晰、上下累计变糊，
        //   持续到结束浏览回归播放行居中，因此始终存在、不偶发，与原版观感一致。
        Widget display = lineWidget;
        if (!widget.player.perfLyricBlurOff && !(index == _index)) {
          // ===== 【双模糊·实时驱动】每行只监听实时"画面居中行"，滚动中实刷新模糊 =====
          // 值变化时仅重建这一层 ImageFiltered（不改文本、不整树 rebuild），实现
          // "滚到哪、哪实时清晰，上下累计变糊且保留播放行核心"，与原版实时观感一致。
          display = ValueListenableBuilder<int>(
            valueListenable: _centerRow,
            builder: (context, center, _) {
              final distance = _dualBlurDistance(index);
              final sigma = math
                  .min(widget.maxBlurSigma, widget.blurStep * distance)
                  .toDouble();
              if (sigma <= 0.0) {
                return lineWidget;
              }
              return ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                child: lineWidget,
              );
            },
          );
        }
        // ===== 【修复】点击某行（需求1/3）=====
        // 传入 onTapLine 时给整行挂 onTap，把被点击行索引交给调用方；未传入时不包
        // GestureDetector（封面预览等场景原样返回，无行为变化）。
        final onTap = widget.onTapLine;
        if (onTap == null) {
          return display;
        }
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onTap(index),
          child: display,
        );
          },
        ),
          ), // ===== 【修复】关闭 ScrollConfiguration（隐藏滚动条）=====
        ), // ===== 【修复】关闭 GestureDetector（拖拽手动接管）=====
      ),
    );
  }
}

/// ===== 【修复】性能模式封面预览：两行歌词（当前行 + 下一句）=====
///
/// 需求：性能模式封面页下方歌词预览由"居中单行"改为"同时显示两行"，观感参照
/// 非性能模式的"当前行+下一句"预览（当前行白/大/加粗，下一行灰/小/中粗，整体居中）。
///
/// 实现要点：
///   * 独立小组件，纯自绘、无滚动/拖拽/滚轮逻辑，与 _PerfLyricList 完全解耦，
///     因此对车机/全屏歌词的单行居中列表毫无影响；
///   * 内部监听 player.activeLyricIndex，仅在行切换时 setState 重建（低 GPU、无动画），
///     与 _PerfLyricList 同源，天然不超前、不依赖 _onTick 的 setState。
class _PerfLyricTwoLinePreview extends StatefulWidget {
  const _PerfLyricTwoLinePreview({
    required this.player,
    required this.lyrics,
    required this.currentIndex,
  });

  final PlayerController player;
  final List<LyricLine> lyrics;
  final int currentIndex;

  @override
  State<_PerfLyricTwoLinePreview> createState() =>
      _PerfLyricTwoLinePreviewState();
}

class _PerfLyricTwoLinePreviewState extends State<_PerfLyricTwoLinePreview> {
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.currentIndex.clamp(0, widget.lyrics.length - 1);
    widget.player.addListener(_onPlayerNotify);
  }

  @override
  void didUpdateWidget(covariant _PerfLyricTwoLinePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.removeListener(_onPlayerNotify);
      widget.player.addListener(_onPlayerNotify);
    }
    if (oldWidget.lyrics != widget.lyrics) {
      _index = widget.currentIndex.clamp(0, widget.lyrics.length - 1);
    }
  }

  @override
  void dispose() {
    widget.player.removeListener(_onPlayerNotify);
    super.dispose();
  }

  void _onPlayerNotify() {
    if (!mounted) {
      return;
    }
    final next = widget.player.activeLyricIndex;
    if (next < 0 || next >= widget.lyrics.length || next == _index) {
      return;
    }
    setState(() => _index = next);
  }

  @override
  Widget build(BuildContext context) {
    final index = _index;
    final current = widget.lyrics[index];
    final next =
        index + 1 < widget.lyrics.length ? widget.lyrics[index + 1] : null;
    // 观感参照非性能模式预览：当前行白/大/加粗，下一句灰/小/中粗，整体垂直居中。
    final currentStyle = TextStyle(
      color: Colors.white,
      fontSize: 22,
      height: 1.2,
      fontWeight: FontWeight.w900,
    );
    final nextStyle = TextStyle(
      color: Colors.white.withValues(alpha: .46),
      fontSize: 16,
      height: 1.2,
      fontWeight: FontWeight.w700,
    );
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          current.text,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: currentStyle,
        ),
        const SizedBox(height: 8),
        Text(
          next?.text ?? '',
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: nextStyle,
        ),
      ],
    );
  }
}

class _LyricText extends StatelessWidget {
  const _LyricText({
    required this.line,
    required this.active,
    required this.position,
    this.styleOverride,
    this.textAlign = TextAlign.start,
    this.singleLine = false,
  });

  final LyricLine line;
  final bool active;
  final Duration position;
  final TextStyle? styleOverride;
  final TextAlign textAlign;
  final bool singleLine;

  @override
  Widget build(BuildContext context) {
    final style =
        styleOverride ??
        Theme.of(context).textTheme.headlineMedium!.copyWith(
          color: Colors.white,
          fontSize: active ? 34 : 27,
          height: 1.24,
          // ====【需求/字体粗细】兜底 style 也接整体字重（默认 700）。
          // 原实现（备份）：active ? w900 : w800。
          fontWeight: LyricAdjustments.getGlobal().lyricFontWeight(),
        );

    if (!active || line.words.isEmpty) {
      if (singleLine) {
        return Text(
          line.text,
          textAlign: textAlign,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.visible,
          style: style,
        );
      }
      return Text(line.text, textAlign: textAlign, style: style);
    }

    if (singleLine) {
      final painter = _KaraokeLinePainter(
        line: line,
        position: position,
        style: style,
        baseColor: Colors.white.withValues(alpha: .34),
        activeColor: Colors.white,
        textDirection: Directionality.of(context),
        textAlign: textAlign,
        maxLines: 1,
        maxWidth: double.infinity,
      );
      return CustomPaint(
        size: Size(painter.width, painter.height),
        painter: painter,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = _KaraokeLinePainter(
          line: line,
          position: position,
          style: style,
          baseColor: Colors.white.withValues(alpha: .34),
          activeColor: Colors.white,
          textDirection: Directionality.of(context),
          textAlign: textAlign,
          maxLines: null,
          maxWidth: constraints.maxWidth,
        );
        return CustomPaint(
          size: Size(constraints.maxWidth, painter.height),
          painter: painter,
        );
      },
    );
  }
}

class _KaraokeLinePainter extends CustomPainter {
  _KaraokeLinePainter({
    required this.line,
    required this.position,
    required this.style,
    required this.baseColor,
    required this.activeColor,
    required this.textDirection,
    required this.textAlign,
    required this.maxLines,
    required this.maxWidth,
  }) {
    // ===== 【顺滑重构】文本排版全部缓存到构造时，paint 只做裁剪与绘制 =====
    // 旧实现每次 paint 都为每个已开始的字 new 一个 TextPainter 并 .layout(整行)，
    // N 字 × 60fps = 每帧 N 次 TextPainter.layout（Flutter 最贵的文本操作），是高光卡顿根源。
    // 文字/样式/字符框都不依赖播放进度（只有 clip 宽度依赖），故全部预计算一次。
    _textPainter = TextPainter(
      text: TextSpan(
        text: line.text,
        style: style.copyWith(color: baseColor),
      ),
      textDirection: textDirection,
      textAlign: textAlign,
      maxLines: maxLines,
    )..layout(maxWidth: maxLines == 1 ? double.infinity : maxWidth);
    // 高亮层复用同一个已 layout 的 TextPainter，仅颜色不同。
    _highlightPainter = TextPainter(
      text: TextSpan(
        text: line.text,
        style: style.copyWith(color: activeColor),
      ),
      textDirection: textDirection,
      textAlign: textAlign,
      maxLines: maxLines,
    )..layout(maxWidth: maxLines == 1 ? double.infinity : maxWidth);
    // 预计算每个"字"对应的字符框（start/end 恒定，与进度无关）。
    var start = 0;
    for (final word in line.words) {
      final end = start + word.text.length;
      _wordBoxes.add(
        _textPainter
            .getBoxesForSelection(
              TextSelection(baseOffset: start, extentOffset: end),
            )
            .map((e) => e.toRect())
            .toList(),
      );
      start = end;
    }
  }

  final LyricLine line;
  final Duration position;
  final TextStyle style;
  final Color baseColor;
  final Color activeColor;
  final TextDirection textDirection;
  final TextAlign textAlign;
  final int? maxLines;
  final double maxWidth;
  late final TextPainter _textPainter;
  late final TextPainter _highlightPainter;
  final List<List<Rect>> _wordBoxes = [];

  double get width => _textPainter.width;
  double get height => _textPainter.height;

  @override
  void paint(Canvas canvas, Size size) {
    // =====【需求/性能优化·合并已开始字的进度区域，单次绘制高亮】=====
    // 旧实现对每个已开始字单独 clipRect + 整行高亮 TextPainter.paint：N 字=每帧 N 次整行 fill
    // （只显示 clip 内部、其余裁掉），高亮越推 fill 越夸张，纯属浪费。
    // 现合并所有已开始字的进度区域为一个外接矩形 hull，每帧仅 1 次整行高亮绘制 + 1 次 clip：
    // 颜色恒定(activeColor)、推色仍精确到字，视觉与逐字绘制完全一致，fill 从 N→1。
    _textPainter.paint(canvas, Offset.zero);
    Rect? hull;
    for (var i = 0; i < line.words.length; i++) {
      final progress = _wordProgress(line.words[i]);
      if (progress <= 0) continue;
      for (final rect in _wordBoxes[i]) {
        final w = rect.width * progress.clamp(0, 1);
        if (w <= 0) continue;
        final wordRect = Rect.fromLTWH(rect.left, rect.top, w, rect.height);
        hull = hull == null ? wordRect : hull.expandToInclude(wordRect);
      }
    }
    if (hull == null) return;
    canvas.save();
    canvas.clipRect(hull);
    _highlightPainter.paint(canvas, Offset.zero);
    canvas.restore();
  }

  double _wordProgress(LyricWord word) {
    if (position < word.time) return 0;
    final durationMs = word.duration.inMilliseconds;
    if (durationMs <= 0) return 1;
    final elapsed = position.inMilliseconds - word.time.inMilliseconds;
    return (elapsed / durationMs).clamp(0, 1).toDouble();
  }

  // 【原实现（备份，供回退）】逐字 clip+整行高亮 paint：N 字=每帧 N 次整行 fill（已废弃，
  // 被 paint 内的"合并 hull 单次绘制"替代。最大区分：fill 从 N→1，观感一致）。
  // void _paintWordProgress(Canvas canvas, List<Rect> boxes, double progress) {
  //   for (final rect in boxes) {
  //     final clipWidth = rect.width * progress.clamp(0, 1);
  //     if (clipWidth <= 0) continue;
  //     canvas.save();
  //     canvas.clipRect(Rect.fromLTWH(rect.left, rect.top, clipWidth, rect.height));
  //     _highlightPainter.paint(canvas, Offset.zero);
  //     canvas.restore();
  //   }
  // }

  @override
  bool shouldRepaint(covariant _KaraokeLinePainter oldDelegate) {
    return oldDelegate.position != position ||
        oldDelegate.line != line ||
        oldDelegate.style != style ||
        oldDelegate.maxWidth != maxWidth;
  }
}

class _Progress extends StatefulWidget {
  const _Progress({
    required this.player,
    this.bright = false,
    this.compact = false,
  });

  final PlayerController player;
  final bool bright;
  final bool compact;

  @override
  State<_Progress> createState() => _ProgressState();
}

class _ProgressState extends State<_Progress> {
  // ===== 原实现（备份，供回退）=====
  // 原为 StatelessWidget，build 里：
  //   return ListenableBuilder(
  //     listenable: player,
  //     builder: (context, _) => _buildProgress(context),
  //   );
  // 每次 player 位置 notify 都会让进度条随帧 markNeedsBuild，叠加到 60fps 渲染管线，
  // 是播放期间 GPU 高的主要来源之一。现改为 StatefulWidget + 内部 ~30fps 节流：
  //   * 位置平滑推进 → 内部 33ms Timer 定时 setState（复用实例，不随 notify 高频重建）；
  //   * 切歌 / 播放暂停 / 拖动开始·结束 → 通过 player listener 检测结构性变化立即刷新；
  //   * 进度拖动(scrub) 的滑块实时手感由 Slider 自身本地管理，这里只在拖动态变化时同步。
  Timer? _timer;
  dynamic _lastSong;
  bool _lastPlaying = false;
  bool _lastScrubbing = false;

  PlayerController get player => widget.player;
  bool get bright => widget.bright;
  bool get compact => widget.compact;

  @override
  void initState() {
    super.initState();
    widget.player.addListener(_onPlayerNotify);
    _onPlayerNotify();
  }

  @override
  void didUpdateWidget(covariant _Progress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.removeListener(_onPlayerNotify);
      widget.player.addListener(_onPlayerNotify);
      _lastSong = null; // 强制下一帧按切歌处理
    }
    _onPlayerNotify();
  }

  @override
  void dispose() {
    widget.player.removeListener(_onPlayerNotify);
    _timer?.cancel();
    super.dispose();
  }

  void _onPlayerNotify() {
    final p = widget.player;
    final song = p.currentSong;
    final playing = p.isPlaying;
    final scrubbing = p.isScrubbing;
    final songChanged = song != _lastSong;
    _lastSong = song;
    final stateDirty =
        songChanged || playing != _lastPlaying || scrubbing != _lastScrubbing;
    _lastPlaying = playing;
    _lastScrubbing = scrubbing;
    // 结构性状态变化（切歌/暂停/拖动结束）时立即重建一次。
    if (stateDirty && mounted) setState(() {});
    // 播放中且非拖动且 UI 可见时，用 ~30fps Timer 驱动位置刷新（节流），
    // 暂停/隐藏/拖动时停表，避免无谓帧。
    if (playing && !scrubbing && p.isUIVisible) {
      _timer ??= Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    // ====【新增/TV 遥控器适配】==== 进度条聚焦时：左键后退 5 秒、右键前进 5 秒
    //（Android TV 标准）。Shortcuts 只作用于本子树，不影响其它页面的左右键语义。
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.arrowLeft): _TvSeekBackIntent(),
        SingleActivator(LogicalKeyboardKey.arrowRight): _TvSeekForwardIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _TvSeekBackIntent: CallbackAction<_TvSeekBackIntent>(
            onInvoke: (_) {
              final target = widget.player.smoothPosition -
                  const Duration(seconds: 5);
              widget.player.seek(
                  target < Duration.zero ? Duration.zero : target);
              return null;
            },
          ),
          _TvSeekForwardIntent: CallbackAction<_TvSeekForwardIntent>(
            onInvoke: (_) {
              final duration = widget.player.duration;
              var target = widget.player.smoothPosition +
                  const Duration(seconds: 5);
              if (duration > Duration.zero && target > duration) {
                target = duration;
              }
              widget.player.seek(target);
              return null;
            },
          ),
        },
        child: _buildProgressInner(context),
      ),
    );
  }

  Widget _buildProgressInner(BuildContext context) {
    // ===== 原实现（备份，供回退）=====
    //   return ListenableBuilder(
    //     listenable: player,
    //     builder: (context, _) => _buildProgress(context),
    //   );
    // 现改为 ~30fps 节流：位置刷新由内部 Timer 驱动，不再随位置 notify 每帧重建。
    return _buildProgress(context);
  }

  /// 进度条实际内容（随播放位置每帧更新）。原 build 逻辑原样保留。
  Widget _buildProgress(BuildContext context) {
    final max = player.duration.inMilliseconds <= 0
        ? 1.0
        : player.duration.inMilliseconds.toDouble();
    final value = player.smoothPosition.inMilliseconds
        .clamp(0, max.toInt())
        .toDouble();
    final textColor = bright
        ? Colors.white.withValues(alpha: .64)
        : Theme.of(context).colorScheme.onSurfaceVariant;
    // 高潮片段时间点（进度条小圆点），无高潮或无效时为空。
    final climax = player.climax;
    final climaxFraction = climax != null &&
            climax.isValid &&
            max > 0 &&
            climax.startTime.inMilliseconds <= max.toInt()
        ? climax.startTime.inMilliseconds / max
        : null;

    return Column(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final thumbRadius = compact ? 4.0 : 5.0;
            final dotSize = compact ? 7.0 : 8.0;
            return Stack(
              alignment: Alignment.centerLeft,
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: compact ? 3 : 5,
                    thumbShape: RoundSliderThumbShape(
                      enabledThumbRadius: compact ? 4 : 5,
                    ),
                    overlayShape: RoundSliderOverlayShape(
                      overlayRadius: compact ? 10 : 14,
                    ),
                    activeTrackColor: bright
                        ? Colors.white.withValues(alpha: .86)
                        : Theme.of(context).colorScheme.primary,
                    inactiveTrackColor: bright
                        ? Colors.white.withValues(alpha: .25)
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: value,
                    max: max,
                    onChanged: (value) =>
                        player.previewSeek(
                            Duration(milliseconds: value.round())),
                    onChangeEnd: (value) =>
                        player.seek(Duration(milliseconds: value.round())),
                  ),
                ),
                if (climaxFraction != null)
                  Positioned(
                    left: thumbRadius +
                        climaxFraction * (width - 2 * thumbRadius) -
                        dotSize / 2,
                    top: 24 - dotSize / 2,
                    child: IgnorePointer(
                      child: Container(
                        width: dotSize,
                        height: dotSize,
                        decoration: BoxDecoration(
                          color: bright
                              ? Colors.white
                              : Theme.of(context).colorScheme.primary,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: bright
                                ? Colors.black.withValues(alpha: .4)
                                : Colors.white,
                            width: 1.2,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 2 : 4),
          child: Row(
            children: [
              Text(
                formatDuration(player.smoothPosition),
                style: TextStyle(
                  color: textColor,
                  fontSize: compact ? 12 : null,
                ),
              ),
              const Spacer(),
              Text(
                formatDuration(player.duration),
                style: TextStyle(
                  color: textColor,
                  fontSize: compact ? 12 : null,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.player,
    required this.onQueue,
    this.bright = false,
    this.compactOverride = false,
    this.denseOverride = false,
  });

  final PlayerController player;
  final VoidCallback onQueue;
  final bool bright;
  final bool compactOverride;
  final bool denseOverride;

  @override
  Widget build(BuildContext context) {
    final color = bright
        ? Colors.white
        : Theme.of(context).colorScheme.onSurface;
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = compactOverride || constraints.maxWidth < 360;
        final dense = denseOverride;
        // 超大按钮仅在车机模式开启时使用，普通横屏用标准尺寸。
        final isCar = isLandscape && ThemeController.instance.carModeEnabled;
        final edgeButtonSize = dense ? 34.0 : (isCar ? 56.0 : (compact ? 40.0 : 44.0));
        final edgeIconSize = dense ? 21.0 : (isCar ? 34.0 : (compact ? 24.0 : 27.0));
        final skipButtonSize = dense ? 42.0 : (isCar ? 72.0 : (compact ? 50.0 : 56.0));
        final skipIconSize = dense ? 33.0 : (isCar ? 54.0 : (compact ? 40.0 : 46.0));
        final playButtonSize = dense ? 58.0 : (isCar ? 96.0 : (compact ? 72.0 : 82.0));
        final playIconSize = dense ? 46.0 : (isCar ? 72.0 : (compact ? 56.0 : 64.0));
        final gap = dense ? 3.0 : (isCar ? 24.0 : (compact ? 5.0 : 9.0));

        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox.square(
              dimension: edgeButtonSize,
              child: IconButton(
                tooltip: player.playbackModeLabel,
                color: color,
                iconSize: edgeIconSize,
                padding: EdgeInsets.zero,
                onPressed: () {
                  player.cyclePlaybackMode();
                  Toast.show(
                    '已切换到${player.playbackModeLabel}',
                    duration: const Duration(milliseconds: 1100),
                  );
                },
                icon: Icon(_playbackModeIcon(player.playbackMode)),
              ),
            ),
            SizedBox(width: gap),
            SizedBox.square(
              dimension: skipButtonSize,
              child: IconButton(
                tooltip: '上一首',
                color: color,
                iconSize: skipIconSize,
                padding: EdgeInsets.zero,
                onPressed: player.previous,
                icon: const Icon(Icons.skip_previous_rounded),
              ),
            ),
            SizedBox(width: gap),
            SizedBox.square(
              dimension: playButtonSize,
              child: IconButton(
                tooltip: player.isPlaying ? '暂停' : '播放',
                color: color,
                padding: EdgeInsets.zero,
                onPressed: player.isPreparing ? null : player.togglePlay,
                iconSize: playIconSize,
                icon: player.isPreparing
                    ? SizedBox.square(
                        dimension: isCar ? 36 : (compact ? 24 : 28),
                        child: const CircularProgressIndicator(
                          strokeWidth: 3,
                          color: Colors.white,
                        ),
                      )
                    : Icon(
                        player.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
              ),
            ),
            SizedBox(width: gap),
            SizedBox.square(
              dimension: skipButtonSize,
              child: IconButton(
                tooltip: '下一首',
                color: color,
                iconSize: skipIconSize,
                padding: EdgeInsets.zero,
                onPressed: player.next,
                icon: const Icon(Icons.skip_next_rounded),
              ),
            ),
            SizedBox(width: gap),
            SizedBox.square(
              dimension: edgeButtonSize,
              child: IconButton(
                tooltip: '播放列表',
                color: color,
                iconSize: edgeIconSize,
                padding: EdgeInsets.zero,
                onPressed: onQueue,
                icon: const Icon(Icons.queue_music_rounded),
              ),
            ),
          ],
        );
      },
    );
  }

  IconData _playbackModeIcon(PlaybackMode mode) {
    return switch (mode) {
      PlaybackMode.playlistLoop => Icons.repeat_rounded,
      PlaybackMode.shuffle => Icons.shuffle_rounded,
      PlaybackMode.singleLoop => Icons.repeat_one_rounded,
    };
  }
}

class _GlassIconButton extends StatelessWidget {
  const _GlassIconButton({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withValues(alpha: .14),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: IconButton(
          color: Colors.white,
          onPressed: onPressed,
          icon: Icon(icon),
        ),
      ),
    );
  }
}

class _CommentEntry extends StatelessWidget {
  const _CommentEntry({required this.player, required this.song});

  final PlayerController player;
  final Song song;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 评论按钮（在左侧）
          if (song.source == SongSource.kugou)
            Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                onTap: () {
                  final mixsongid = song.albumAudioId ?? song.id;
                  if (mixsongid.isEmpty) return;
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          CommentPage(api: player.api, mixsongid: mixsongid),
                    ),
                  );
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Icon(
                    Icons.comment_outlined,
                    size: 20,
                    color: Colors.white54,
                  ),
                ),
              ),
            ),

          if (song.source == SongSource.kugou) const SizedBox(width: 4),

          // 音乐游戏按钮（在评论按钮右侧）
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => RhythmGamePage(player: player),
                  ),
                );
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Icon(
                  Icons.sports_esports_outlined,
                  size: 22,
                  color: Colors.white54,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PageDots extends StatelessWidget {
  const _PageDots({required this.page});

  final int page;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(2, (index) {
          final active = index == page;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: active ? 18 : 7,
            height: 7,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: active ? .86 : .32),
              borderRadius: BorderRadius.circular(99),
            ),
          );
        }),
      ),
    );
  }
}

// ====【新增/TV 遥控器适配】==== 进度条左右键 ±5 秒。
class _TvSeekBackIntent extends Intent {
  const _TvSeekBackIntent();
}

class _TvSeekForwardIntent extends Intent {
  const _TvSeekForwardIntent();
}

/// ====【新增/Android TV 遥控器适配】====
///
/// 歌词区的"当前行可聚焦"落点：
///   * 作为**一个**焦点节点（不逐行建节点，避免歌词列表产生上百个 focus node）；
///   * 聚焦后按确定键 → 与"单击当前歌词行"完全一致的逻辑：
///     seek 到**当前行**的开始时间（该偏移已计入用户的歌词偏移设置）；
///   * 聚焦时给歌词区一个轻量高亮边框，让遥控器用户知道"焦点在这里"。
class TvLyricFocus extends StatefulWidget {
  const TvLyricFocus({
    super.key,
    required this.player,
    required this.lyrics,
    required this.child,
  });

  final PlayerController player;
  final List<LyricLine> lyrics;
  final Widget child;

  @override
  State<TvLyricFocus> createState() => _TvLyricFocusState();
}

class _TvLyricFocusState extends State<TvLyricFocus> {

  /// 与 _LandscapeLyricPanelState._offsetProbe 同一算法：
  /// 实际播放位置 + 用户为该曲设置的歌词偏移。
  Duration get _probe {
    final s = widget.player.currentSong;
    final key = s == null
        ? ''
        : LyricAdjustments.resolveOffsetKey(hash: s.hash, id: s.id);
    return widget.player.smoothPosition +
        Duration(
            milliseconds: (LyricAdjustments.offsetFor(key) * 1000).round());
  }

  int _activeIndex() {
    final lyrics = widget.lyrics;
    if (lyrics.isEmpty) return -1;
    final pos = _probe;
    var index = 0;
    for (var i = 0; i < lyrics.length; i++) {
      if (pos >= lyrics[i].time) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  /// 与"单击当前歌词行"一致：跳转到当前行开始时间。
  void _selectCurrentLine() {
    final i = _activeIndex();
    if (i < 0 || i >= widget.lyrics.length) return;
    widget.player.seek(widget.lyrics[i].time);
  }

  @override
  Widget build(BuildContext context) {
    return TvFocusTarget(
      onSelect: _selectCurrentLine,
      builder: (context, focused) => TvFocusHighlight(
        focused: focused,
        radius: 12,
        // 歌词区较大，放大反而会溢出，故不缩放，只加边框/微光。
        scale: 1.0,
        glow: false,
        child: widget.child,
      ),
    );
  }
}
