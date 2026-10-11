import 'package:flutter/material.dart';
import '../design_tokens.dart';
import '../widgets/tv_focus.dart'; // ====【新增/TV 遥控器焦点】====
import '../widgets/tv_controls.dart'; // ====【新增/Android TV 遥控器适配】====
import 'package:flutter/services.dart';

import '../../config/app_config.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/download_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../controllers/local_music_controller.dart';
import '../../services/app_update_service.dart';
import '../../services/cache_diag_logger.dart'; // ====【诊断/缓存清理卡顿】====
import '../../services/cache_service.dart';
import '../../services/music_api.dart';
import '../../services/desktop_controller.dart';
import '../../services/loudness_gain_policy.dart'; // ====【新增/响度归一化】目标响度档位枚举 ====
import '../../services/loudness_normalization.dart'; // ====【响应"清理响度缓存后重置标记"】====
import '../widgets/audio_effects_sheet.dart';
import '../widgets/audio_quality_sheet.dart';
import '../widgets/toast.dart';
import 'about_page.dart';
import 'audio_interruption_settings_page.dart';
import 'desktop_lyrics_settings_page.dart';
import 'personalization_settings_page.dart';
import 'vip_info_page.dart';
import 'playback_history_page.dart';
import 'playback_stats_page.dart';
import '../adaptive_layout.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.theme,
    this.localMusic,
    this.cache,
    this.downloads,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final ThemeController theme;
  final LocalMusicController? localMusic;
  final CacheService? cache;
  final DownloadController? downloads;

  String _fontScaleLabel(double scale) {
    if (scale >= 1.2) return '特大';
    if (scale >= 1.1) return '大';
    return '标准';
  }

  Future<void> _selectFontScale(BuildContext context, ThemeController theme) async {
    final selected = await showModalBottomSheet<double>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '字体大小',
                  style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                for (final scale in ThemeController.fontScaleOptions) ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      scale == theme.fontScale
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_off_rounded,
                      color: scale == theme.fontScale
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant,
                    ),
                    title: Text(_fontScaleLabel(scale)),
                    subtitle: Text(
                      scale == 1.0
                          ? '默认大小'
                          : scale == 1.1
                              ? '整体放大 10%'
                              : '整体放大 20%',
                    ),
                    onTap: () => Navigator.of(sheetContext).pop(scale),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
    if (selected != null) {
      await theme.setFontScale(selected);
    }
  }

  void _openVipInfo(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VipInfoPage(api: api, auth: auth),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // ====【新增/TV 遥控器适配】==== 页面级焦点作用域：
    //   * 进入页面后焦点落到第一个可聚焦组件；
    //   * 离开再回来恢复上次位置（debugLabel 作为记忆键）。
    return TvFocusScope(
      debugLabel: 'settings',
      child: _buildSettingsInner(context),
    );
  }

  Widget _buildSettingsInner(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: colorScheme.brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
        statusBarBrightness: colorScheme.brightness == Brightness.dark
            ? Brightness.dark
            : Brightness.light,
      ),
      child: Scaffold(
        appBar: AppBar(title: const Text('设置')),
        body: AnimatedBuilder(
          animation: Listenable.merge([
            auth,
            player,
            ?localMusic,
            theme,
            DesktopController.instance,
          ]),
          builder: (context, _) {
            return AdaptiveContentPadding(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                // Account section
                _SectionHeader(title: '账号'),
                const SizedBox(height: 8),
                _SettingsCard(
                  children: [
                    _SettingsTile(
                      icon: Icons.sync_rounded,
                      iconColor: colorScheme.primary,
                      title: '同步个人信息',
                      subtitle: '刷新头像、昵称和歌单数据',
                      loading: auth.isLoading,
                      onTap:
                          auth.isLoading ? null : () => auth.refreshProfile(),
                    ),
                    _SettingsDivider(),
                    _SettingsTile(
                      icon: Icons.workspace_premium_rounded,
                      iconColor: const Color(0xFFE8A33D),
                      title: '我的 VIP',
                      subtitle: 'VIP 状态与每日福利',
                      onTap: () => _openVipInfo(context),
                    ),
                    _SettingsDivider(),
                    _SettingsTile(
                      icon: Icons.logout_rounded,
                      iconColor: colorScheme.error,
                      title: '退出登录',
                      titleColor: colorScheme.error,
                      onTap: auth.isLoading
                          ? null
                          : () => _confirmLogout(context),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                // ===== 模式分类（横屏/车机，置于账号与播放之间）=====
                // ===== 原实现（备份，供回退）：本分类原含"性能模式"总开关与
                // "性能模式下恢复旋转动画"，已删除并迁移至下方"性能"分类。=====
                _SectionHeader(title: '模式'),
                const SizedBox(height: 8),
                _SettingsCard(
                  children: [
                    _SettingsSwitchTile(
                      icon: Icons.screen_rotation_rounded,
                      iconColor: colorScheme.primary,
                      title: '横屏模式',
                      subtitle: '允许手机横屏时自动旋转（平板默认开启）',
                      value: theme.landscapeEnabled,
                      onChanged: (value) {
                        theme.setLandscapeEnabled(value, AdaptiveLayout.isTablet(context));
                      },
                    ),
                    _SettingsDivider(),
                    _SettingsSwitchTile(
                      icon: Icons.directions_car_rounded,
                      iconColor: colorScheme.primary,
                      title: '车机模式',
                      subtitle: '横屏时使用左侧播放面板布局并放大文字',
                      value: theme.carModeEnabled,
                      onChanged: (value) => theme.setCarModeEnabled(value),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                // Playback section
                _SectionHeader(title: '播放'),
                const SizedBox(height: 8),
                _SettingsCard(
                  children: [
                    _SettingsTile(
                      icon: Icons.high_quality_rounded,
                      iconColor: colorScheme.primary,
                      title: '默认音质',
                      subtitle: player.audioQuality.label,
                      onTap: () => _selectDefaultAudioQuality(context),
                    ),
                    _SettingsDivider(),
                    _SettingsSwitchTile(
                      icon: Icons.auto_awesome_rounded,
                      iconColor: colorScheme.primary,
                      title: '智能音质',
                      subtitle: '播放失败时自动降级音质重试',
                      value: player.smartQualityEnabled,
                      onChanged: player.setSmartQualityEnabled,
                    ),
                    _SettingsDivider(),
                    _SettingsSwitchTile(
                      icon: Icons.power_settings_new_rounded,
                      iconColor: colorScheme.primary,
                      title: '开机自启播放',
                      subtitle: '打开应用时自动加载并播放推荐歌单',
                      value: player.autoPlayOnStartupEnabled,
                      onChanged: player.setAutoPlayOnStartupEnabled,
                    ),
                    _SettingsDivider(),
                    _SettingsSwitchTile(
                      icon: Icons.bluetooth_audio_rounded,
                      iconColor: colorScheme.primary,
                      title: '连接新音频设备自动播放',
                      subtitle: '连接蓝牙或耳机时自动恢复播放',
                      value: player.autoPlayOnDeviceConnected,
                      onChanged: player.setAutoPlayOnDeviceConnected,
                    ),
                    _SettingsDivider(),
                    _SettingsSwitchTile(
                      icon: Icons.volume_up_rounded,
                      iconColor: colorScheme.primary,
                      // ====【响度归一化】==== 原文案为「音量均衡 / 降低各首歌曲音量差异，
                      // 自动控制音量」，对应的是曲内动态压缩方案（已废弃不调用）。
                      // 新方案为按曲目响度施加固定增益偏移（业界标准做法，完整保留动态，双端生效）。
                      title: '响度归一化',
                      subtitle: '让所有歌听感音量一致，完整保留歌曲动态',
                      value: player.volumeNormalizationEnabled,
                      onChanged: player.setVolumeNormalizationEnabled,
                    ),
                    _SettingsDivider(),
                    // ====【响度归一化】目标响度档位（响亮/标准/安静），仅开关开启时有实际作用。
                    _SettingsTile(
                      icon: Icons.tune_rounded,
                      iconColor: colorScheme.primary,
                      title: '目标响度',
                      subtitle:
                          '${player.loudnessTarget.label} · ${player.loudnessTarget.description}',
                      onTap: () => _selectLoudnessTarget(context),
                    ),
                    _SettingsDivider(),
                    // ====【响度归一化·预分析】默认关闭：默认占用后台 CPU/带宽（在线歌需下载）。
                    _SettingsSwitchTile(
                      icon: Icons.bolt_rounded,
                      iconColor: colorScheme.primary,
                      title: '预分析歌曲',
                      subtitle: '后台提前分析队列歌曲，切歌时音量立即生效（占用后台资源）',
                      value: player.loudnessPrescanEnabled,
                      onChanged: player.setLoudnessPrescanEnabled,
                    ),
                    _SettingsDivider(),
                    _SettingsSwitchTile(
                      icon: Icons.skip_next_rounded,
                      iconColor: colorScheme.primary,
                      title: '自动跳过无法播放的歌曲',
                      subtitle: '播放卡死(零进度约 8 秒)时自动切到下一首',
                      value: player.autoSkipUnplayable,
                      onChanged: player.setAutoSkipUnplayable,
                    ),
                    _SettingsDivider(),
                    _SettingsTile(
                      icon: Icons.graphic_eq_rounded,
                      iconColor: colorScheme.primary,
                      title: '音效',
                      subtitle: player.audioEffectsLabel,
                      onTap: () => showAudioEffectsSheet(
                        context: context,
                        player: player,
                      ),
                    ),
                    _SettingsDivider(),
                    _SettingsTile(
                      icon: Icons.bar_chart_rounded,
                      iconColor: colorScheme.primary,
                      title: '播放统计',
                      subtitle: '听歌时长、最常听歌手等',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => PlaybackStatsPage(player: player),
                        ),
                      ),
                    ),
                    _SettingsDivider(),
                    _SettingsTile(
                      icon: Icons.history_rounded,
                      iconColor: colorScheme.primary,
                      title: '播放历史',
                      subtitle: '最近播放的歌曲',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => PlaybackHistoryPage(
                            api: api,
                            auth: auth,
                            player: player,
                          ),
                        ),
                      ),
                    ),
                    _SettingsDivider(),
                    _SettingsTile(
                      icon: Icons.block_rounded,
                      title: '后台打断机制',
                      subtitle: _audioInterruptionSummary(player),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => AudioInterruptionSettingsPage(
                            player: player,
                          ),
                        ),
                      ),
                    ),
                    _SettingsDivider(),
                    _SettingsSwitchTile(
                      icon: Icons.bar_chart_rounded,
                      iconColor: colorScheme.primary,
                      title: '增加听歌时长',
                      subtitle: '每播放 30 分钟自动同步一次',
                      value: player.addListeningTimeEnabled,
                      onChanged: player.setAddListeningTimeEnabled,
                    ),
                    if (player.isDesktopLyricsSupported) ...[
                      _SettingsDivider(),
                      _SettingsSwitchTile(
                        icon: Icons.lyrics_rounded,
                        iconColor: colorScheme.primary,
                        title: '桌面歌词',
                        subtitle: '在其他应用上方显示歌词悬浮窗',
                        value: player.desktopLyricsEnabled,
                        onChanged: (value) async {
                          await player.setDesktopLyricsEnabled(value);
                          if (!player.desktopLyricsEnabled && value) {
                            Toast.error('需要悬浮窗权限才能使用桌面歌词');
                          }
                        },
                      ),
                      if (player.desktopLyricsEnabled) ...[
                        _SettingsDivider(),
                        _SettingsTile(
                          icon: Icons.tune_rounded,
                          iconColor: colorScheme.primary,
                          title: '歌词设置',
                          subtitle: '透明度、颜色、锁定位置等',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => DesktopLyricsSettingsPage(player: player),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
                const SizedBox(height: 24),
                // ===== 【重构】性能分类（置于播放与网络之间）=====
                // 原"性能模式"总开关拆分为 4 个独立开关，迁移至此分类。
                _SectionHeader(title: '性能'),
                const SizedBox(height: 8),
                _SettingsCard(
                  children: [
                    _SettingsSwitchTile(
                      icon: Icons.blur_off_rounded,
                      iconColor: colorScheme.primary,
                      title: '关闭歌词模糊',
                      subtitle: '关闭歌词高斯模糊效果，降低 GPU 占用',
                      value: player.perfLyricBlurOff,
                      onChanged: player.setPerfLyricBlurOff,
                    ),
                    _SettingsDivider(),
                    _SettingsSwitchTile(
                      icon: Icons.image_not_supported_rounded,
                      iconColor: colorScheme.primary,
                      title: '关闭背景动画',
                      subtitle: '关闭播放器页背景旋转动画',
                      value: player.perfBgAnimOff,
                      onChanged: player.setPerfBgAnimOff,
                    ),
                    _SettingsDivider(),
                    _SettingsSwitchTile(
                      icon: Icons.album_rounded,
                      iconColor: colorScheme.primary,
                      title: '关闭封面动画',
                      subtitle: '关闭车机封面旋转动画',
                      value: player.perfCoverAnimOff,
                      onChanged: player.setPerfCoverAnimOff,
                    ),
                    _SettingsDivider(),
                    _SettingsSwitchTile(
                      icon: Icons.bolt_rounded,
                      iconColor: colorScheme.primary,
                      title: '轻量歌词',
                      subtitle: '歌词改用自绘整行高亮、仅行切换刷新，降低 GPU 占用',
                      value: player.perfLightLyric,
                      onChanged: player.setPerfLightLyric,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                // Network section
                _SectionHeader(title: '网络'),
                const SizedBox(height: 8),
                _SettingsCard(
                  children: [
                    _SettingsTile(
                      icon: Icons.dns_rounded,
                      iconColor: colorScheme.primary,
                      title: 'API 服务器地址',
                      subtitle: AppConfig.hasCustomBaseUrl
                          ? AppConfig.customBaseUrl
                          : '默认：${AppConfig.defaultApiBaseUrl}',
                      onTap: () => _editApiBaseUrl(context),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                // Cache section
                _SectionHeader(title: '缓存'),
                const SizedBox(height: 8),
                _SettingsCard(
                  children: [
                    _SettingsTile(
                      icon: Icons.storage_rounded,
                      iconColor: colorScheme.primary,
                      title: '缓存管理',
                      subtitle: '查看和清理缓存',
                      onTap: () => _showCacheManagement(context),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                // Desktop section (Windows)
                if (DesktopController.instance.isSupported) ...[
                  _SectionHeader(title: '桌面'),
                  const SizedBox(height: 8),
                  _SettingsCard(
                    children: [
                      _SettingsSwitchTile(
                        icon: Icons.window_rounded,
                        iconColor: colorScheme.primary,
                        title: '关闭窗口时收进托盘',
                        subtitle: '关闭按钮隐藏到系统托盘，不退出程序',
                        value: DesktopController.instance.closeBehavior ==
                            CloseBehavior.hideToTray,
                        onChanged: (value) =>
                            DesktopController.instance.setCloseBehavior(
                          value
                              ? CloseBehavior.hideToTray
                              : CloseBehavior.quit,
                        ),
                      ),
                      _SettingsDivider(),
                      _SettingsSwitchTile(
                        icon: Icons.power_settings_new_rounded,
                        iconColor: colorScheme.primary,
                        title: '开机自动启动',
                        subtitle: '登录 Windows 后自动启动 KA Music',
                        value: DesktopController.instance.launchAtStartup,
                        onChanged: DesktopController.instance.setLaunchAtStartup,
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 24),
                // Personalization section
                _SectionHeader(title: '个性化'),
                const SizedBox(height: 8),
                _SettingsCard(
                  children: [
                    _SettingsTile(
                      icon: Icons.palette_rounded,
                      iconColor: colorScheme.primary,
                      title: '皮肤与背景',
                      subtitle: '配色方案与自定义全局背景图',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => PersonalizationSettingsPage(
                            themeController: theme,
                          ),
                        ),
                      ),
                    ),
                    _SettingsDivider(),
                    _SettingsTile(
                      icon: Icons.text_fields_rounded,
                      iconColor: colorScheme.primary,
                      title: '字体大小',
                      subtitle: _fontScaleLabel(theme.fontScale),
                      onTap: () => _selectFontScale(context, theme),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                // App section
                _SectionHeader(title: '应用'),
                const SizedBox(height: 8),
                _SettingsCard(
                  children: [
                    _SettingsTile(
                      icon: Icons.info_outline_rounded,
                      iconColor: colorScheme.primary,
                      title: '关于',
                      subtitle: AppUpdateService.isSupportedPlatform
                          ? '版本、更新日志与检查更新'
                          : '版本与更新日志',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => AboutPage(api: api),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
      ),
    );
  }

  String _audioInterruptionSummary(PlayerController player) {
    final parts = <String>[];
    if (!player.audioInterruptionEnabled) parts.add('已阻止打断');
    if (player.autoResumeAfterInterruption) parts.add('自动恢复');
    return parts.isEmpty ? '未开启' : parts.join(' · ');
  }

  Future<void> _selectDefaultAudioQuality(BuildContext context) async {
    final quality = await showAudioQualitySheet(
      context: context,
      selected: player.audioQuality,
      title: '默认音质',
      subtitle: '新播放的歌曲会使用这个音质',
    );
    if (quality == null) return;
    await player.setAudioQuality(quality);
  }

  /// ====【新增/响度归一化】目标响度三档选择 ====
  ///
  /// 三档对应主流流媒体平台的参考值（−11 / −14 / −19 LUFS）：
  ///   响亮 = 嘈杂环境（车载/户外）；标准 = 与主流平台一致；安静 = 夜深人静。
  Future<void> _selectLoudnessTarget(BuildContext context) async {
    final selected = await showDialog<LoudnessTarget>(
      context: context,
      builder: (dialogContext) {
        return SimpleDialog(
          title: const Text('目标响度'),
          children: [
            for (final target in LoudnessTarget.values)
              RadioListTile<LoudnessTarget>(
                value: target,
                groupValue: player.loudnessTarget,
                title: Text('${target.label}（${target.lufs.toStringAsFixed(0)} LUFS）'),
                subtitle: Text(target.description),
                onChanged: (value) => Navigator.of(dialogContext).pop(value),
              ),
          ],
        );
      },
    );
    if (selected == null) return;
    await player.setLoudnessTarget(selected);
  }

  /// 打开缓存管理 BottomSheet。
  Future<void> _showCacheManagement(BuildContext context) async {
    final cache = this.cache;
    final downloads = this.downloads;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) {
        return _CacheManagementSheet(
          cache: cache,
          downloads: downloads,
        );
      },
    );
  }

  Future<void> _editApiBaseUrl(BuildContext context) async {
    final controller = TextEditingController(
      text: AppConfig.customBaseUrl ?? '',
    );

    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('API 服务器地址'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '留空则使用默认地址',
                style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                  color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '默认：${AppConfig.defaultApiBaseUrl}',
                style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                  color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  hintText: 'https://example.com/api',
                  labelText: 'Base URL',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            if (AppConfig.hasCustomBaseUrl)
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(''),
                child: Text(
                  '恢复默认',
                  style: TextStyle(color: Theme.of(dialogContext).colorScheme.error),
                ),
              ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );

    if (result == null || !context.mounted) return;

    await AppConfig.saveCustomBaseUrl(result);
    if (!context.mounted) return;

    Toast.success(
      AppConfig.hasCustomBaseUrl
          ? '已切换到 ${AppConfig.customBaseUrl}，重启后生效'
          : '已恢复默认 API 地址，重启后生效',
    );
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('退出登录'),
          content: const Text('确定要退出当前账号吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('退出登录'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !context.mounted) return;
    await auth.logout();
    if (!context.mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }
}

// --- Shared widgets ---

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Column(children: children),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    this.iconColor,
    this.titleColor,
    this.subtitle,
    this.loading = false,
    this.onTap,
  });

  final IconData icon;
  final Color? iconColor;
  final String title;
  final Color? titleColor;
  final String? subtitle;
  final bool loading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // ====【新增/TV 遥控器焦点】==== 可聚焦 + 高亮 + 确定键触发。
    return TvFocusTarget(
      onSelect: onTap,
      builder: (context, focused) => TvFocusHighlight(
        focused: focused,
        radius: AppRadius.md,
        child: _buildSettingsTileInner(context),
      ),
    );
  }

  Widget _buildSettingsTileInner(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            SizedBox(
              width: 32,
              child: loading
                  ? SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: colorScheme.primary,
                      ),
                    )
                  : Icon(icon, size: 22, color: iconColor ?? colorScheme.primary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: titleColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (onTap != null)
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: colorScheme.outline,
              ),
          ],
        ),
      ),
    );
  }
}

class _SettingsSwitchTile extends StatelessWidget {
  const _SettingsSwitchTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.iconColor,
    this.subtitle,
  });

  final IconData icon;
  final Color? iconColor;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return TvTapArea(
      radius: AppRadius.md,
      onTap: () => onChanged(!value),
      child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            child: Icon(icon, size: 22, color: iconColor ?? colorScheme.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    ));
  }
}

class _SettingsDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      indent: 62,
      color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: .4),
    );
  }
}

/// 缓存管理 BottomSheet。
class _CacheManagementSheet extends StatefulWidget {
  const _CacheManagementSheet({this.cache, this.downloads});

  final CacheService? cache;
  final DownloadController? downloads;

  @override
  State<_CacheManagementSheet> createState() => _CacheManagementSheetState();
}

class _CacheManagementSheetState extends State<_CacheManagementSheet> {
  int? _dataCacheSize;
  int? _downloadSize;
  int? _playCacheSize;
  // ====【新增/响度缓存改为手动清理】====
  int? _loudnessCacheSize;
  int? _loudnessCacheCount;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _loadSizes();
  }

  Future<void> _loadSizes() async {
    // ====【诊断/缓存清理卡顿】==== 打开「缓存管理」时逐项统计耗时（含同步目录扫描）。
    final sw = Stopwatch()..start();
    int? dataCache, download, playCache;
    int? loudnessSize;
    int? loudnessCount;
    final stageMs = <String, int>{};
    if (widget.cache != null) {
      try {
        final s = Stopwatch()..start();
        dataCache = await widget.cache!.getCacheSize();
        s.stop();
        stageMs['dataCache'] = s.elapsedMilliseconds;
      } catch (_) {}
      try {
        // 响度分析缓存单独统计（它已被排除在"数据缓存"的总量之外）
        final stats = await widget.cache!.prefixStats(
          CacheService.loudnessCachePrefix,
        );
        loudnessSize = stats.bytes;
        loudnessCount = stats.count;
      } catch (_) {}
    }
    if (widget.downloads != null) {
      try {
        final s = Stopwatch()..start();
        download = await widget.downloads!.getDownloadDirSize();
        s.stop();
        stageMs['downloadDir'] = s.elapsedMilliseconds;
      } catch (_) {}
      try {
        final s = Stopwatch()..start();
        playCache = await widget.downloads!.getPlayCacheDirSize();
        s.stop();
        stageMs['playCacheDir'] = s.elapsedMilliseconds;
      } catch (_) {}
    }
    sw.stop();
    CacheDiagLogger.log(
      'ui.cacheManagementSheet',
      'dataCache=${stageMs['dataCache'] ?? -1}ms '
      'downloadDir=${stageMs['downloadDir'] ?? -1}ms '
      'playCacheDir=${stageMs['playCacheDir'] ?? -1}ms',
      ms: sw.elapsedMilliseconds,
    );
    if (mounted) {
      setState(() {
        _dataCacheSize = dataCache;
        _downloadSize = download;
        _playCacheSize = playCache;
        _loudnessCacheSize = loudnessSize;
        _loudnessCacheCount = loudnessCount;
      });
    }
  }

  String _formatSize(int? bytes) {
    if (bytes == null) return '计算中…';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _formatLimit(int? bytes) {
    if (bytes == null) return '300 MB';
    if (bytes < 0) return '无限制';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).round()} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).round()} GB';
  }

  Future<void> _selectCacheLimit(BuildContext context) async {
    final downloads = widget.downloads;
    if (downloads == null) return;

    final currentLimit = downloads.playCacheLimit;
    final options = [
      (label: '100 MB', value: 100 * 1024 * 1024),
      (label: '300 MB', value: 300 * 1024 * 1024),
      (label: '500 MB', value: 500 * 1024 * 1024),
      (label: '1 GB', value: 1024 * 1024 * 1024),
      (label: '2 GB', value: 2 * 1024 * 1024 * 1024),
      (label: '5 GB', value: 5 * 1024 * 1024 * 1024),
      (label: '无限制', value: -1),
    ];

    final selected = await showDialog<int>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('设置播放缓存上限'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: options.map((opt) {
                return RadioListTile<int>(
                  title: Text(opt.label),
                  value: opt.value,
                  groupValue: currentLimit,
                  onChanged: (val) {
                    Navigator.of(dialogContext).pop(val);
                  },
                );
              }).toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
          ],
        );
      },
    );

    if (selected != null && mounted) {
      setState(() => _clearing = true);
      try {
        await downloads.setPlayCacheLimit(selected);
        await _loadSizes();
        Toast.success('已修改缓存上限');
      } catch (_) {
        Toast.error('修改失败');
      }
      if (mounted) {
        setState(() => _clearing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '缓存管理',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 16),
            _CacheItem(
              icon: Icons.storage_rounded,
              title: '数据缓存',
              size: _formatSize(_dataCacheSize),
              onClear:
                  widget.cache != null &&
                      _dataCacheSize != null &&
                      _dataCacheSize! > 0
                  ? () async {
                      setState(() => _clearing = true);
                      try {
                        await widget.cache!.clearAllCache();
                        await _loadSizes();
                        if (mounted) {
                          Toast.success('数据缓存已清理');
                        }
                      } catch (_) {
                        if (mounted) {
                          Toast.error('清理失败');
                        }
                      }
                      if (mounted) {
                        setState(() => _clearing = false);
                      }
                    }
                  : null,
            ),
            const SizedBox(height: 10),
            // ====【新增/响度缓存改为手动清理】====
            // 响度分析结果（每首歌一条，约 200 字节）已从"数据缓存"的总量中排除，
            // 避免一键清理时把"算力换来的结果"误清掉（清理后所有歌都要重新分析）。
            // 是否需要清理交给用户自行决定。
            _CacheItem(
              icon: Icons.graphic_eq_rounded,
              title: '响度分析缓存',
              size: _loudnessCacheCount != null && _loudnessCacheCount! > 0
                  ? '${_formatSize(_loudnessCacheSize)} · $_loudnessCacheCount 首'
                  : _formatSize(_loudnessCacheSize),
              onClear:
                  widget.cache != null &&
                      _loudnessCacheCount != null &&
                      _loudnessCacheCount! > 0
                  ? () async {
                      setState(() => _clearing = true);
                      try {
                        await widget.cache!.removeByPrefix(
                          CacheService.loudnessCachePrefix,
                        );
                        // ====【响度归一化】通知编排层重置"已处理"标记与内存缓存，
                        // 否则预扫描仍认为这些歌已分析，不会重新生成缓存。
                        LoudnessNormalization.onLoudnessCacheCleared();
                        await _loadSizes();
                        if (mounted) {
                          Toast.success('响度分析缓存已清理（相关歌曲会重新分析）');
                        }
                      } catch (_) {
                        if (mounted) {
                          Toast.error('清理失败');
                        }
                      }
                      if (mounted) {
                        setState(() => _clearing = false);
                      }
                    }
                  : null,
            ),
            const SizedBox(height: 10),
            _CacheItem(
              icon: Icons.download_rounded,
              title: '下载文件',
              size: _formatSize(_downloadSize),
              onClear: null, // 下载文件用户主动管理，不提供一键清理
            ),
            const SizedBox(height: 10),
            _CacheItem(
              icon: Icons.cached_rounded,
              title: '播放缓存',
              size: _formatSize(_playCacheSize),
              onClear: widget.downloads != null &&
                      _playCacheSize != null &&
                      _playCacheSize! > 0
                  ? () async {
                      setState(() => _clearing = true);
                      try {
                        await widget.downloads!.clearPlayCache();
                        await _loadSizes();
                        if (mounted) {
                          Toast.success('播放缓存已清理');
                        }
                      } catch (_) {
                        if (mounted) {
                          Toast.error('清理失败');
                        }
                      }
                      if (mounted) {
                        setState(() => _clearing = false);
                      }
                    }
                  : null,
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Row(
                children: [
                  Icon(Icons.rule_rounded, size: 22, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '播放缓存上限',
                          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          _formatLimit(widget.downloads?.playCacheLimit),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => _selectCacheLimit(context),
                    child: const Text('修改'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            if (_clearing) const Center(child: CircularProgressIndicator()),
          ],
        ),
      ),
    );
  }
}

/// 缓存管理中的单项条目。
class _CacheItem extends StatelessWidget {
  const _CacheItem({
    required this.icon,
    required this.title,
    required this.size,
    this.onClear,
  });

  final IconData icon;
  final String title;
  final String size;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          Icon(icon, size: 22, color: colorScheme.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  size,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (onClear != null)
            TextButton(
              onPressed: onClear,
              child: Text(
                '清理',
                style: TextStyle(color: colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}
