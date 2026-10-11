// ====【新增/歌词调整】歌词调整页（普通/车机「更多」菜单入口 → 实时生效原版/轻量歌词）====
//
// 共 5 项设置：歌词大小、歌词行距、歌词透明度、歌词进度偏移（当前歌曲）、歌词高亮颜色。
// 全部通过 LyricAdjustments 服务读写 SharedPreferences，并在内存缓存 + ChangeNotifier
// 通知播放器歌词渲染处实时刷新。
import 'dart:async';

import 'package:flutter/material.dart';

// ====【需求/提色诊断·明亮主色】触发点日志（songKey 记录）用 await 写文件，try-catch 静默====
import 'dart:io';

import '../../controllers/player_controller.dart';
// ====【需求/自适应歌词颜色】引入封面主色提取工具 =====
import '../../services/cover_color_extractor.dart';
import '../../services/lyric_adjustments.dart';
import '../design_tokens.dart';

class LyricAdjustmentsPage extends StatefulWidget {
  const LyricAdjustmentsPage({super.key, required this.player});

  final PlayerController player;

  @override
  State<LyricAdjustmentsPage> createState() => _LyricAdjustmentsPageState();
}

class _LyricAdjustmentsPageState extends State<LyricAdjustmentsPage> {
  late LyricAdjustmentConfig _cfg;
  late double _scale;
  late double _offset;

  // ====【需求/自适应歌词颜色】自适应提色状态 =====
  /// 正在从封面提取颜色（仅用于页面小提示；不阻塞 UI）。
  bool _adaptiveExtracting = false;

  /// 上一次成功提色针对的歌曲 key，用于"切歌重提 / 显示所属歌曲"。
  String? _adaptiveSongKey;

  // ====【修复/切歌刷新】上一次"真实触发重提"的歌曲 key（触发即更新）====
  // 与 _adaptiveSongKey（成功/失败后才更新）职责分离：它只表示"当前这次要提的是哪首"，
  // 供 _onPlayerChanged 判断是否切歌，避免"结果记录与触发门禁耦合"导致切歌漏提、停在旧颜色。
  String? _lastAdaptiveSongKey;

  /// 提色请求序号：切歌/手动触发会自增，旧请求返回时若序号已变则丢弃（防串色）。
  int _extractSerial = 0;

  // ====【需求/加载成功后自动重提·有限重试】自动重试状态 =====
  // 当封面 URL 非空但本次提取失败(下载/解码/无有效样本等)时，短暂延时后自动重试提色，
  // 让"封面加载不及时/网络抖动"在封面稍好后也能自动补上正确颜色(更新时间带低消耗过渡)。
  // URL 为空 / 本地 content:// 封面等"确定不可提取"则仅回退默认、不重试。
  /// 待命中的自动重试计时器；dispose / 触发重提 / 成功 / 切歌时取消。
  Timer? _adaptiveRetryTimer;

  /// 当前这首歌已尝试的提色次数（真正触发时归 0，重试时递增）。
  int _adaptiveRetryPass = 0;

  /// 自动重试前的延时（封面"稍等一会才好"的常见缓存/网络抖动窗口）。
  static const Duration _adaptiveRetryDelay = Duration(milliseconds: 3000);

  /// 提色总尝试次数上限（首次 + 最多 2~3 次重试），避免网络抖动造成无限重试。
  static const int _adaptiveMaxAttempts = 3;

  String get _songKey {
    final s = widget.player.currentSong;
    if (s == null) return '';
    return LyricAdjustments.resolveOffsetKey(hash: s.hash, id: s.id);
  }

  @override
  void initState() {
    super.initState();
    // ====【需求/自适应歌词颜色】监听播放器切歌：仅当开关开启且歌曲变化时重提一次 =====
    // player 通知较频繁（位置每帧），这里只做"歌曲 key 是否变化"的轻量比对，重提仍走异步。
    widget.player.addListener(_onPlayerChanged);
    // 重新加载最新配置（含启动后首次）。
    LyricAdjustments.reload().then((_) {
      if (!mounted) return;
      setState(() => _readFromService());
      // ====【需求/自适应歌词颜色】进入页面且开关已开启 → 补一次提色（若当前歌还没提过）====
      if (_cfg.adaptiveColor && _adaptiveSongKey != _songKey) {
        unawaited(_runAdaptiveExtract());
      }
    });
  }

  @override
  void dispose() {
    // ====【需求/自适应歌词颜色】移除切歌监听，避免内存泄露 =====
    widget.player.removeListener(_onPlayerChanged);
    // ====【需求/加载成功后自动重提·有限重试】取消待命中的自动重试计时器，避免dispose后回调崩毁====
    _adaptiveRetryTimer?.cancel();
    super.dispose();
  }

  // ====【需求/自适应歌词颜色】切歌/封面变化时：若开启自适应则重提一次 =====
  // ====【修复/切歌刷新】原实现以 _adaptiveSongKey（成功后才更新）做"是否已提过"的门禁：
  // 切歌瞬间它仍指上一首，且某次触发的提取结果若被 _extractSerial 竞态丢弃后并无重试 →
  // 会漏提、歌词颜色停在上一首。现改为以"上一次真实触发重提的歌曲 key"（_lastAdaptiveSongKey，
  // 调用 _runAdaptiveExtract 时即更新）做门禁：只要 currentSong 的 key 与上次不同就重提一次；
  // 提取结果是否最终生效仍由 _extractSerial 防串色，触发与生效两条路径职责分离。====
  void _onPlayerChanged() {
    if (!mounted || !_cfg.adaptiveColor) return;
    final key = _songKey;
    if (key.isEmpty) return; // 当前无歌；切歌完成后会再次 notify 并携带新 key
    if (key == _lastAdaptiveSongKey) return; // 仍是同一首（播放中每帧通知），不重复提
    unawaited(_runAdaptiveExtract());
  }

  // ====【需求/自适应歌词颜色】执行封面提色；成功写高亮(+底色)，失败/无封面回退默认 =====
  // ====【需求/加载成功后自动重提·有限重试】====
  // 新增可选参数 [retryPass]：真正触发(切歌/开关/重新提色)由调用方默认传 0；失败后的自动重试
  // 由 [_adaptiveRetryTimer] 回调以 retryPass>0 再次进入本方法。这样既能完整复用既有逻辑
  // (日志 / _extractSerial 防串色 / 成功应用 / 失败回退)，又能区分"触发"与"重试"，
  // 避免重试把计数重置成首次导致无限循环。
  Future<void> _runAdaptiveExtract({int retryPass = 0}) async {
    final song = widget.player.currentSong;
    final key = _songKey;
    if (song == null || key.isEmpty || !_cfg.adaptiveColor) return;
    // ====【需求/加载成功后自动重提·有限重试】只有"真正触发(retryPass==0)"才重置尝试序号并取消旧重试。
    // 切歌/开关/重新提色会先清掉上一次失败的待重试，避免旧歌把颜色写错；重试失败路径在到达
    // 上限或成功后自行结束。====
    _adaptiveRetryPass = retryPass;
    if (retryPass == 0) {
      _adaptiveRetryTimer?.cancel();
    }
    // ====【修复/切歌刷新】确要提这一首 → 先同步记录"上一首触发提色的歌曲"。这样门禁
    // 在提取完成前就更新，同一首不会因本次只提一次而被重复触发；同时也覆盖 initState /
    // 开关开启 / 重新提色按钮等所有进入路径，让 _onPlayerChanged 能正确识别切歌。
    _lastAdaptiveSongKey = key;
    // ====【需求/提色诊断·明亮主色】触发点日志：记录 songKey 与封面 URL 是否为空 ====
    final e = widget.player.currentSong;
    scheduleMicrotask(() {
      try {
        final tmp = Platform.environment['TEMP'];
        if (tmp == null || tmp.isEmpty) return;
        File('$tmp\\ka_cover_color.log').writeAsStringSync(
            '[${DateTime.now().toIso8601String()}] 页面触发提色 '
            'songKey=$key coverUrl=${e?.coverUrl}'
            '${(e?.coverUrl ?? '').isEmpty ? ' →封面URL为空' : ''}\n',
            mode: FileMode.append);
      } catch (_) {
        // 静默：日志失败不影响提色。
      }
    });
    final serial = ++_extractSerial;
    setState(() => _adaptiveExtracting = true);
    // ====【需求/中心区域取色可选项】把配置的"仅中心取色"开关作为 centerOnly 传入
    //（关闭→false=全图=现状；开启→true=中心 crop=0.15）====
    final result = await CoverColorExtractor.extract(song.coverUrl,
        centerOnly: LyricAdjustments.centerCrop());
    if (!mounted || serial != _extractSerial) return; // 已被切歌/重触发覆盖，丢弃
    setState(() => _adaptiveExtracting = false);

    if (result == null) {
      // ====【需求/加载成功后自动重提·有限重试】判断本次失败是否"值得自动重试"====
      // 仅当封面 URL 非空且非本地 content://（确定可通过 HTTP 下载、只是当前网络/解码抖动）
      // 时，才短暂延时后自动重试提色，使"封面加载不及时/网络抖动"在封面稍好后也能自动补色；
      // URL 为空或本地封面（确定不可提取）则不重试，仅回退默认。重试发车绑"当前仍是同一首"。
      final retryable =
          song.coverUrl != null &&
          song.coverUrl!.isNotEmpty &&
          !song.coverUrl!.startsWith('content://');
      if (retryable && _adaptiveRetryPass + 1 < _adaptiveMaxAttempts) {
        _adaptiveRetryPass++;
        _adaptiveRetryTimer?.cancel();
        _adaptiveRetryTimer = Timer(_adaptiveRetryDelay, () {
          // 重试发车前再次校验：页面仍在、开关仍开、当前仍是同一首歌。
          if (!mounted || !_cfg.adaptiveColor) return;
          if (_songKey != key) return; // 已切歌：让新歌走自己的触发，旧重试直接作废
          unawaited(_runAdaptiveExtract(retryPass: _adaptiveRetryPass));
        });
        return;
      }
      // ====【需求/自适应歌词颜色】失败/无封面（或已达重试上限）→ 回退默认色（高亮白；底色保持默认一致）====
      final next = _cfg.copyWith(
        highlightColor: 0xFFFFFFFF,
        baseColor: 0xFFFFFFFF,
      );
      setState(() {
        _cfg = next;
        _adaptiveSongKey = key;
      });
      await LyricAdjustments.setGlobal(next);
      return;
    }

    // ====【需求/加载成功后自动重提·有限重试】成功提色 → 取消可能待命中的重试计时器 ====
    _adaptiveRetryTimer?.cancel();
    // ====【需求/自适应歌词颜色】成功 → 按 unifiedColor 决定写一个还是两个颜色 ====
    // 统一(open) → 一种主色同时用于高亮与底色；关闭统一 → 高亮 + 配套底色各写各。
    final next = _cfg.copyWith(
      highlightColor: result.highlight.toARGB32(),
      baseColor: _cfg.unifiedColor
          ? result.highlight.toARGB32()
          : result.base.toARGB32(),
    );
    setState(() {
      _cfg = next;
      _adaptiveSongKey = key;
    });
    await LyricAdjustments.setGlobal(next);
  }

  // ====【需求/自适应歌词颜色】开关切换：开启时立即提一次；关闭时仅停用（保留已提取的颜色值）====
  void _onAdaptiveToggle(bool value) {
    final next = _cfg.copyWith(adaptiveColor: value);
    setState(() => _cfg = next);
    if (value) {
      // 让可能仍在等待的旧提色请求作废，然后对当前歌立即重新提取
      _extractSerial++;
      if (_songKey.isNotEmpty) {
        unawaited(_runAdaptiveExtract());
      }
    }
    unawaited(LyricAdjustments.setGlobal(next));
  }

  void _readFromService() {
    _cfg = LyricAdjustments.getGlobal();
    _scale = LyricAdjustments.scale().clamp(0.7, 1.6);
    _offset = LyricAdjustments.offsetFor(_songKey).clamp(-1.5, 1.5);
  }

  Future<void> _updateGlobal(
    LyricAdjustmentConfig Function(LyricAdjustmentConfig c) fn,
  ) async {
    setState(() => _cfg = fn(_cfg));
    await LyricAdjustments.setGlobal(_cfg);
  }

  Future<void> _setScale(double v) async {
    final clamped = v.clamp(0.7, 1.6);
    setState(() => _scale = clamped);
    await LyricAdjustments.setScale(clamped);
  }

  Future<void> _setOffset(double v) async {
    final clamped = ((v.clamp(-1.5, 1.5) * 10).round() / 10);
    setState(() => _offset = clamped);
    if (_songKey.isNotEmpty) {
      await LyricAdjustments.setOffsetFor(_songKey, clamped);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('歌词调整')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _SectionHeader(title: '歌词样式'),
          const SizedBox(height: 8),
          _SettingsCard(
            children: [
              _SliderTile(
                icon: Icons.format_size_rounded,
                iconColor: colorScheme.primary,
                title: '歌词大小',
                value: _scale,
                min: 0.7,
                max: 1.6,
                label: '${(_scale * 100).round()}%',
                // ====【修复/卡顿】拖动即时仅更新本页滑块/标签；松手才写盘+通知渲染 =====
                // 原实现（备份）：onChanged: _setScale,
                onChanged: (v) => setState(() => _scale = v.clamp(0.7, 1.6)),
                onChangeEnd: _setScale,
              ),
              _SettingsDivider(),
              _SliderTile(
                icon: Icons.format_line_spacing_rounded,
                iconColor: colorScheme.primary,
                title: '歌词行距',
                value: _cfg.lineSpacing,
                min: 1.0,
                max: 1.8,
                label: _cfg.lineSpacing.toStringAsFixed(1),
                // ====【修复/卡顿】拖动即时仅更新本页滑块/标签；松手才写盘+通知渲染 =====
                // 原实现（备份）：onChanged: (v) => _updateGlobal((c) => c.copyWith(lineSpacing: v)),
                onChanged: (v) =>
                    setState(() => _cfg = _cfg.copyWith(lineSpacing: v)),
                onChangeEnd: (v) =>
                    _updateGlobal((c) => c.copyWith(lineSpacing: v)),
              ),
              _SettingsDivider(),
              // ====【需求/字体粗细】"歌词粗细"滑块：6 个百进制整档(400~900)，档位名通俗易懂 =====
              // 作用于所有歌词行（当前行高亮/底色/翻译都同字重），实现整体加粗/变细。
              _SliderTile(
                icon: Icons.format_bold_rounded,
                iconColor: colorScheme.primary,
                title: '歌词粗细',
                subtitle: '整体调节所有歌词行的字重（6 档）',
                value: _cfg.fontWeight.toDouble(),
                min: 400,
                max: 900,
                divisions: 5, // 400/500/600/700/800/900 共 6 档
                label: _fontWeightName(_cfg.fontWeight),
                onChanged: (v) => setState(
                    () => _cfg = _cfg.copyWith(fontWeight: v.round())),
                onChangeEnd: (v) => _updateGlobal(
                    (c) => c.copyWith(fontWeight: v.round())),
              ),
              _SettingsDivider(),
              // ====【需求/拆分透明度】"统一歌词透明度"开关：开→单一滑块(写 opacity)；关→底色/高光两个滑块 ====
              _SwitchTile(
                icon: Icons.tonality_rounded,
                iconColor: colorScheme.primary,
                title: '统一歌词透明度',
                subtitle: _cfg.unifiedOpacity ? '当前行/高光与非当前行透明度一致' : '分开调节当前行高光与非当前行(底色)',
                value: _cfg.unifiedOpacity,
                onChanged: (v) {
                  setState(() => _cfg = _cfg.copyWith(unifiedOpacity: v));
                  _updateGlobal((c) => c.copyWith(unifiedOpacity: v));
                },
              ),
              if (_cfg.unifiedOpacity) ...[
                _SettingsDivider(),
                _SliderTile(
                  icon: Icons.opacity_rounded,
                  iconColor: colorScheme.primary,
                  title: '歌词透明度',
                  subtitle: '作用于所有歌词（含当前行/高光）',
                  value: _cfg.opacity,
                  min: 0.3,
                  max: 1.0,
                  label: '${(_cfg.opacity * 100).round()}%',
                  // ====【修复/卡顿】拖动即时仅更新本页滑块/标签；松手才写盘+通知渲染 =====
                  // 原实现（备份）：onChanged: (v) => _updateGlobal((c) => c.copyWith(opacity: v)),
                  onChanged: (v) =>
                      setState(() => _cfg = _cfg.copyWith(opacity: v)),
                  onChangeEnd: (v) =>
                      _updateGlobal((c) => c.copyWith(opacity: v)),
                ),
              ] else ...[
                _SettingsDivider(),
                _SliderTile(
                  icon: Icons.blur_on_rounded,
                  iconColor: colorScheme.primary,
                  title: '底色透明度',
                  subtitle: '只作用于非当前行（底色）',
                  value: _cfg.opacity,
                  min: 0.3,
                  max: 1.0,
                  label: '${(_cfg.opacity * 100).round()}%',
                  onChanged: (v) =>
                      setState(() => _cfg = _cfg.copyWith(opacity: v)),
                  onChangeEnd: (v) =>
                      _updateGlobal((c) => c.copyWith(opacity: v)),
                ),
                _SettingsDivider(),
                _SliderTile(
                  icon: Icons.highlight_rounded,
                  iconColor: colorScheme.primary,
                  title: '高光透明度',
                  subtitle: '只作用于当前行（高光）',
                  value: _cfg.highlightOpacity,
                  min: 0.3,
                  max: 1.0,
                  label: '${(_cfg.highlightOpacity * 100).round()}%',
                  onChanged: (v) =>
                      setState(() => _cfg = _cfg.copyWith(highlightOpacity: v)),
                  onChangeEnd: (v) =>
                      _updateGlobal((c) => c.copyWith(highlightOpacity: v)),
                ),
              ],
              _SettingsDivider(),
              // ====【需求/自适应歌词颜色】新增"自适应歌词颜色"开关（置于手动颜色设置之前）====
              // 开 → 禁用下方所有手动歌词颜色设置（统一歌词颜色开关、高亮/底色选择器、预设搭配），
              //      改为从当前歌曲封面自动提取主色作为歌词颜色；
              // 关 → 恢复现有的手动歌词颜色设置。
              _SwitchTile(
                icon: Icons.auto_awesome_rounded,
                iconColor: colorScheme.primary,
                title: '自适应歌词颜色',
                subtitle: _cfg.adaptiveColor
                    ? '从当前封面自动提取，手动颜色设置已停用'
                    : '开启后按封面自动提取歌词主色',
                value: _cfg.adaptiveColor,
                onChanged: _onAdaptiveToggle,
              ),
              if (_cfg.adaptiveColor) ...[
                _SettingsDivider(),
                // ====【需求/中心区域取色可选项】"中心区域取色"开关 =====
                // 开启 → 仅从封面中心约 70% 区域取色（避免边缘颜色干扰主导色）；
                // 关闭(默认) → 全图取色，行为与旧版一致。开关直接 onChanged 写盘持久化
                //（"松手才持久化"约定仅针对滑块拖动，开关无拖动过程，可直接 onChanged 写）。
                _SwitchTile(
                  icon: Icons.center_focus_strong_rounded,
                  iconColor: colorScheme.primary,
                  title: '中心区域取色',
                  subtitle: _cfg.centerCrop
                      ? '仅从封面中心取色，避免边缘颜色干扰'
                      : '从整张封面取色',
                  value: _cfg.centerCrop,
                  onChanged: (v) {
                    setState(() => _cfg = _cfg.copyWith(centerCrop: v));
                    _updateGlobal((c) => c.copyWith(centerCrop: v));
                  },
                ),
                _SettingsDivider(),
                // ====【需求/自适应歌词颜色】开启时的手动设置替代区：状态提示 + 颜色预览 + 重新提色 ====
                // 颜色预览用 AnimatedContainer 做低消耗隐式过渡（颜色变更时平滑过渡，不逐帧动画）。
                _AdaptiveColorStatusTile(
                  extracting: _adaptiveExtracting,
                  // 失败/无封面回退仍是白色；用"有效底色"(统一时=高亮色)展示更直观
                  highlight: Color(_cfg.highlightColor),
                  base: Color(_cfg.baseColorValue()),
                  hasCover: _cfg.adaptiveColor &&
                      (widget.player.currentSong?.coverUrl?.isNotEmpty ?? false),
                  onRetry: _adaptiveExtracting
                      ? null
                      : () => unawaited(_runAdaptiveExtract()),
                ),
              ] else ...[
                _SettingsDivider(),
                // ====【需求/颜色统一】新增"统一歌词颜色"开关（与上方"统一歌词透明度"开关相互独立）====
                // 开 → 单一"歌词颜色"选择器(写 highlightColor，作用于高亮与底色同色)；
                // 关 → "高亮颜色"(写 highlightColor) 与 "底色颜色"(写 baseColor) 两个选择器。
                _SwitchTile(
                  icon: Icons.color_lens_rounded,
                  iconColor: colorScheme.primary,
                  title: '统一歌词颜色',
                  subtitle: _cfg.unifiedColor
                      ? '当前行与非当前行颜色一致'
                      : '分开调节高亮颜色与底色颜色',
                  value: _cfg.unifiedColor,
                  onChanged: (v) {
                    setState(() => _cfg = _cfg.copyWith(unifiedColor: v));
                    _updateGlobal((c) => c.copyWith(unifiedColor: v));
                  },
                ),
                if (_cfg.unifiedColor) ...[
                  _SettingsDivider(),
                  _ColorPickerTile(
                    // ====【需求/颜色统一】原"歌词高亮颜色"改名"歌词颜色" =====
                    title: '歌词颜色',
                    subtitle: '同时作用于高亮与底色',
                    currentColor: Color(_cfg.highlightColor),
                    presets: _lyricColorPresets,
                    onChanged: (c) => _updateGlobal(
                        (s) => s.copyWith(highlightColor: c.toARGB32())),
                  ),
                ] else ...[
                  _SettingsDivider(),
                  // ====【需求/预设颜色搭配】关闭"统一歌词颜色"时，在两个选择器上方显示预设搭配 =====
                  // 横排圆形(外圈高亮色 + 内圆底色色)、可横向滚动；点按→同时更新并持久化高亮+底色。
                  _PresetColorPairsTile(
                    highlightColor: _cfg.highlightColor,
                    baseColor: _cfg.baseColor,
                    onTap: (pair) => _updateGlobal((s) => s.copyWith(
                          highlightColor: pair.highlight,
                          baseColor: pair.base,
                        )),
                  ),
                  _SettingsDivider(),
                  _ColorPickerTile(
                    title: '高亮颜色',
                    subtitle: '只作用于当前行（高亮）',
                    currentColor: Color(_cfg.highlightColor),
                    presets: _lyricColorPresets,
                    onChanged: (c) => _updateGlobal(
                        (s) => s.copyWith(highlightColor: c.toARGB32())),
                  ),
                  _SettingsDivider(),
                  _ColorPickerTile(
                    title: '底色颜色',
                    subtitle: '只作用于非当前行（底色）',
                    currentColor: Color(_cfg.baseColor),
                    presets: _lyricColorPresets,
                    onChanged: (c) => _updateGlobal(
                        (s) => s.copyWith(baseColor: c.toARGB32())),
                  ),
                ],
              ],
            ],
          ),
          const SizedBox(height: 24),
          _SectionHeader(title: '歌词对齐'),
          const SizedBox(height: 8),
          _SettingsCard(
            children: [
              _SliderTile(
                icon: Icons.timeline_rounded,
                iconColor: colorScheme.primary,
                title: '歌词进度偏移',
                subtitle: '针对当前歌曲；仅用于高亮/滚动对齐，不改音频与进度条',
                value: _offset,
                min: -1.5,
                max: 1.5,
                label: _offset > 0
                    ? '+${_offset.toStringAsFixed(1)}s'
                    : '${_offset.toStringAsFixed(1)}s',
                // ====【修复/卡顿】拖动即时仅更新本页滑块/标签；松手才写 clamp + 盘+通知渲染 =====
                // 原实现（备份）：onChanged: _setOffset,
                onChanged: (v) => setState(() =>
                    _offset = ((v.clamp(-1.5, 1.5) * 10).round() / 10)),
                onChangeEnd: _setOffset,
              ),
            ],
          ),
          if (_songKey.isEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '暂无可调整歌词的歌曲（请先开始播放）',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ],
      ),
    );
  }
}

// --- 以下小组件样式参考 desktop_lyrics_settings_page.dart（字号/透明度滑块 + 色板） ---

// ====【需求/颜色统一】可复用歌词颜色板（17 色、横向滚动），供"歌词颜色/高亮颜色/底色颜色"共用 ====
const List<Color> _lyricColorPresets = [
  // ====【需求/扩充颜色】在原 9 色基础上新增美观色到 17 色（可选性强、对比清晰）====
  // 原有 9 色：
  Colors.white, // 纯白
  Color(0xFFFFD700), // Gold 暖金
  Color(0xFFFF69B4), // Pink 樱粉
  Color(0xFFFFA500), // Orange 橙
  Color(0xFFFF4500), // Red-orange 落日红
  Color(0xFF00BFFF), // Sky blue 天蓝
  Color(0xFF00FF7F), // Spring green 草绿
  Color(0xFF7FFF00), // Chartreuse 青柠绿
  Color(0xFF800080), // Purple 紫
  // 新增 8 色：
  Color(0xFFFFC107), // 香槟金(Amber)
  Color(0xFFFF8A80), // 珊瑚橙
  Color(0xFFE91E63), // 玫红
  Color(0xFF2196F3), // 宝蓝
  Color(0xFF3F51B5), // 靛蓝
  Color(0xFF7C4DFF), // 紫罗兰
  Color(0xFFB39DDB), // 薰衣草
  Color(0xFF4CAF50), // 草坪绿
];

// ====【需求/字体粗细】档位名映射：6 个百进制字重档位，通俗易懂；700(默认)显示"默认"====
String _fontWeightName(int w) => switch (w) {
      400 => '纤细',
      500 => '偏细',
      600 => '适中',
      700 => '默认',
      800 => '偏粗',
      900 => '特粗',
      _ => 'w$w',
    };

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

class _SettingsDivider extends StatelessWidget {
  const _SettingsDivider();

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      indent: 54,
      color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: .4),
    );
  }
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.label,
    required this.onChanged,
    this.onChangeEnd,
    this.subtitle,
    // ====【需求/字体粗细】可选：Slider 档位数 ====
    this.divisions,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final double value;
  final double min;
  final double max;
  final String label;
  final ValueChanged<double> onChanged;
  // ====【需求/字体粗细】可选：Slider 档位数（divisions），用于把连续滑块改为若干整档 ====
  final int? divisions;
  // ====【修复/卡顿】松手时才触发持久化的轻量页内更新之外的最终回调 =====
  // onChanged 在拖动过程每帧高频触发（只能做本页 setState）；onChangeEnd 仅松手触发一次，
  // 用于执行"写 SharedPreferences + 通知歌词渲染"的原持久化逻辑，避免拖动全程反复全量重建。
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 22, color: iconColor),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context)
                          .textTheme
                          .bodyLarge
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                  ],
                ),
              ),
              Text(
                label,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
            // ====【修复/卡顿】滑块松手时才执行持久化/通知（避免拖动高频触发全量重建）====
            onChangeEnd: onChangeEnd,
          ),
        ],
      ),
    );
  }
}

// ====【需求/拆分透明度】新增开关行组件（"统一歌词透明度"开关）====
class _SwitchTile extends StatelessWidget {
  const _SwitchTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        children: [
          Icon(icon, size: 22, color: iconColor),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context)
                      .textTheme
                      .bodyLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

// ====【需求/自适应歌词颜色】自适应提色的状态/预览区组件 =====
// 展示：正在提取 / 当前高亮色+底色预览（AnimatedContainer 低消耗隐式过渡） / 重新提色按钮。
// 说明：此处仅做页面内的小圆点预览动画（隐式、低开销）；歌词本体颜色由 setGlobal 通知
// 渲染层即时生效，不在渲染热路径加逐帧动画，避免耗性能。
class _AdaptiveColorStatusTile extends StatelessWidget {
  const _AdaptiveColorStatusTile({
    required this.extracting,
    required this.highlight,
    required this.base,
    required this.hasCover,
    required this.onRetry,
  });

  final bool extracting;
  final Color highlight;
  final Color base;
  final bool hasCover;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final String statusText;
    if (extracting) {
      statusText = '正在从封面提取颜色…';
    } else if (!hasCover) {
      statusText = '暂无可用封面，已回退默认颜色（可重新提色）';
    } else {
      statusText = '已从当前封面提取歌词颜色';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.palette_outlined, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  statusText,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
              // 重新提色按钮（提取中禁用）
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(extracting ? '提取中…' : '重新提色'),
                style: TextButton.styleFrom(
                  foregroundColor: colorScheme.primary,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 当前高亮 / 底色预览（AnimatedContainer 平滑过渡颜色变化）
          Row(
            children: [
              _AdaptiveColorDot(
                label: '高亮',
                color: highlight,
                labelColor: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 20),
              _AdaptiveColorDot(
                label: '底色',
                color: base,
                labelColor: colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ====【需求/自适应歌词颜色】单个颜色小圆点预览（AnimatedContainer 隐式过渡）====
class _AdaptiveColorDot extends StatelessWidget {
  const _AdaptiveColorDot({
    required this.label,
    required this.color,
    required this.labelColor,
  });

  final String label;
  final Color color;
  final Color labelColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOut,
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: labelColor.withValues(alpha: .35)),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: .35),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(color: labelColor)),
      ],
    );
  }
}

class _ColorPickerTile extends StatelessWidget {
  const _ColorPickerTile({
    required this.title,
    required this.currentColor,
    required this.presets,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final Color currentColor;
  final List<Color> presets;
  final ValueChanged<Color> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.palette_rounded, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context)
                          .textTheme
                          .bodyLarge
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color:
                                  Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // ====【需求/扩充颜色】色板项增多，横向一排放不下 → 用横向滚动包裹，保证不溢出 ====
          // 原实现（备份）：Row(mainAxisAlignment: spaceEvenly, ...)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final color in presets)
                  GestureDetector(
                    onTap: () => onChanged(color),
                    child: Container(
                      width: 36,
                      height: 36,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: currentColor.toARGB32() == color.toARGB32()
                              ? Theme.of(context).colorScheme.primary
                              : (color.toARGB32() == Colors.black.toARGB32()
                                  ? Colors.white30
                                  : Colors.transparent),
                          width: 3,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: color.toARGB32() == Colors.black.toARGB32()
                                ? Colors.white12
                                : color.withValues(alpha: .4),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: currentColor.toARGB32() == color.toARGB32()
                          ? Icon(Icons.check_rounded,
                              color: color.toARGB32() == Colors.black.toARGB32()
                                  ? Colors.white70
                                  : Colors.black54,
                              size: 20)
                          : null,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ====【需求/预设颜色搭配】每套预设 = "高亮色 + 底色色" 组合的数据模型 =====
class _PresetColorPair {
  const _PresetColorPair(this.highlight, this.base);

  /// 高亮色 ARGB int。
  final int highlight;

  /// 底色色 ARGB int。
  final int base;
}

// ====【需求/预设颜色搭配】预设清单（14 套高对比度 + 美学；底色偏深、高亮偏亮)====
// 说明：歌词常处深色背景，故底色多取深色调、高亮取明亮色，确保对比清晰、观看舒适。
// 原实现（备份）：旧 14 组底色过深(近纯黑如 0xFF37474F/0xFF102027)、对比过高、底色难辨。
// ====【需求/预设颜色搭配·协调底色】过渡版 14 组：底色为"中等深但有辨识度"色调 ====
// 高亮保持"鲜明但不刺眼"，与底色同处一个色相/色彩体系(高亮≈色系亮档、底色≈同色系中深灰档)，
// 观感自然成套；每组间仍保留明显可辨的高亮 vs 底色对比。
// 原 14 组底色（备份，均偏暗）：
//   0xFF795548 0xFF8E5567 0xFF8D6E63 0xFF6E7446 0xFF4A6075 0xFF3E5A54 0xFF7C4A55
//   0xFF6E6A5E 0xFF5A5570 0xFF4E6B66 0xFF6E5438 0xFF46587A 0xFF7A4F52 0xFF665F73
// ====【需求/提亮预设底色】新 14 组底色整体提亮到中等偏亮(Material 300~400 档，亮度≈0.5~0.62)，
// 保持色相与高亮成套协调、对比清晰；高亮色基本保持不变。====
const List<_PresetColorPair> _presetColorPairs = [
  _PresetColorPair(0xFFFF8A65, 0xFFA1887F), // 1 暖橙 × 暖褐(亮)
  _PresetColorPair(0xFFF06292, 0xFFC79AA8), // 2 樱粉 × 藕粉(亮)
  _PresetColorPair(0xFFFFD54F, 0xFFB9A89C), // 3 琥珀金 × 暖褐灰(亮)
  _PresetColorPair(0xFFD4E157, 0xFF9AA571), // 4 青柠黄 × 黄绿灰(亮)
  _PresetColorPair(0xFF4FC3F7, 0xFF7E93A8), // 5 天蓝 × 中蓝灰(亮)
  _PresetColorPair(0xFF26A69A, 0xFF7BA39B), // 6 青绿(teal) × 青灰(亮)
  _PresetColorPair(0xFFEC407A, 0xFFB9909B), // 7 玫红 × 玫灰(亮)
  _PresetColorPair(0xFFFFF8E1, 0xFFA8A399), // 8 暖白 × 暖灰(亮)
  _PresetColorPair(0xFF9575CD, 0xFF9C96B3), // 9 紫罗兰 × 藕紫灰(亮)
  _PresetColorPair(0xFF80CBC4, 0xFF9AB8B2), // 10 薄荷 × 薄荷灰(亮)
  _PresetColorPair(0xFFFFC107, 0xFFB39B7A), // 11 香槟金 × 暖棕(焦糖褐,亮)
  _PresetColorPair(0xFF42A5F5, 0xFF8AA3C4), // 12 宝蓝 × 宝蓝灰(亮)
  _PresetColorPair(0xFFE57373, 0xFFB8A0A2), // 13 珊瑚红 × 红灰(亮)
  _PresetColorPair(0xFFB39DDB, 0xFFA3A0BB), // 14 薰衣草 × 薰衣草灰(亮)
];

// ====【需求/预设颜色搭配】预设颜色搭配选块组件（外圈高亮色 + 内圆底色色，横向滚动）====
// ====【需求/预设颜色搭配·对角线两半】图标由"外圈高亮+内圆底色"改为"圆内一条对角直线(左下→右上)均分两半，一半高亮色、一半底色色"====
// 样式对齐既有 _ColorPickerTile（左图标+标题副标题，下方横向滚动圆点行）；
// 选中态由"高亮/底色同时命中"驱动；点按由 onTap(pair) 回调到上层持久化。
class _PresetColorPairsTile extends StatelessWidget {
  const _PresetColorPairsTile({
    required this.highlightColor,
    required this.baseColor,
    required this.onTap,
  });

  final int highlightColor;
  final int baseColor;
  final ValueChanged<_PresetColorPair> onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.layers_rounded, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '预设颜色搭配',
                      style: Theme.of(context)
                          .textTheme
                          .bodyLarge
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      '一键应用"高亮 + 底色"配色（深底亮字）',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final pair in _presetColorPairs)
                  GestureDetector(
                    onTap: () => onTap(pair),
                    child: Container(
                      width: 38,
                      height: 38,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        // ====【需求/预设颜色搭配·对角线两半】color 改为透明，两半色由 child 的 CustomPaint 绘制 ====
                        // 原实现（备份）：color: Color(pair.highlight),
                        color: Colors.transparent,
                        border: Border.all(
                          // ====【需求/预设颜色搭配】选中态：高亮与底色同时命中当前配置才高亮 ====
                          color:
                              (pair.highlight == highlightColor &&
                                      pair.base == baseColor)
                                  ? colorScheme.primary
                                  : Colors.transparent,
                          width: 3,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Color(pair.highlight).withValues(alpha: .4),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      // ====【需求/预设颜色搭配·对角线两半】用一个圆 + 圆内沿"左下→右上"对角直线均分两半 ====
                      // 用 _DiagonalHalvesPainter 画两个三角（上半=高亮、下半=底色），配合 ClipOval 裁成圆形。
                      // 原实现（备份）：内圆 Container(width20, fill base) 组成"外圈高亮+内圆底色"组合圆。
                      child: ClipOval(
                        child: CustomPaint(
                          size: const Size.square(38),
                          painter: _DiagonalHalvesPainter(
                            topColor: Color(pair.highlight),
                            bottomColor: Color(pair.base),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ====【需求/预设颜色搭配·对角线两半】在圆内画"左下→右上"对角直线均分两半的自定义画笔 ====
// 直角坐标系下用两个三角形互补覆盖整个正方形：
//   上三角(高亮)：(0,0)-(w,0)-(0,h)；下三角(底色)：(w,0)-(w,h)-(0,h)。
// 两者共享斜边 (w,0)-(0,h)，即为"左下→右上"的对角分界线；外层 ClipOval 裁成纯圆后，
// 即得到"一个圆内半高亮色、半底色色、以对角线分界"的视觉效果。
class _DiagonalHalvesPainter extends CustomPainter {
  const _DiagonalHalvesPainter({
    required this.topColor,
    required this.bottomColor,
  });

  /// 对角线上半 / 前半区域颜色（高亮色）。
  final Color topColor;

  /// 对角线下半 / 后半区域颜色（底色色）。
  final Color bottomColor;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    // 上半三角（含左上角与右上角，斜边即"右上→左下"对角线）填高亮色。
    final topPath = Path()
      ..moveTo(0, 0)
      ..lineTo(w, 0)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(topPath, Paint()..color = topColor);
    // 下半三角（含右下角与底边，共享同一条对角线）填底色色。
    final bottomPath = Path()
      ..moveTo(w, 0)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(bottomPath, Paint()..color = bottomColor);
  }

  @override
  bool shouldRepaint(_DiagonalHalvesPainter oldDelegate) =>
      oldDelegate.topColor != topColor ||
      oldDelegate.bottomColor != bottomColor;
}