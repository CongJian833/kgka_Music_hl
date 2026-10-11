import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';

Future<double?> showPlaybackSpeedSheet({
  required BuildContext context,
  required PlayerController player,
}) {
  return showModalBottomSheet<double>(
    context: context,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (sheetContext) {
      return _PlaybackSpeedSheet(player: player);
    },
  );
}

class _PlaybackSpeedSheet extends StatefulWidget {
  const _PlaybackSpeedSheet({required this.player});

  final PlayerController player;

  @override
  State<_PlaybackSpeedSheet> createState() => _PlaybackSpeedSheetState();
}

class _PlaybackSpeedSheetState extends State<_PlaybackSpeedSheet> {
  static const _min = 0.5;
  static const _max = 3.0;
  // 倍速滑块的 0.1 步进间隔数：(3.0-0.5)/0.1 = 25 档
  static const _divisions = 25;

  late double _speed;
  // ====【需求/音调调节】音调（0.5–2.0，0.1 步进）。Windows 已切 BASS（SoundTouch 2.0）
  // 支持独立变调，不再禁用；Android ExoPlayer 同样支持。====
  late double _pitch;

  @override
  void initState() {
    super.initState();
    _speed = widget.player.playbackSpeed;
    _pitch = widget.player.pitch;
  }

  String _formatSpeed(double value) {
    if (value == value.roundToDouble()) return '${value.round()}x';
    return '${value.toStringAsFixed(1)}x';
  }

  /// 吸附到 0.1 步进（滑块 divisions 对齐，位置与数值严格对应）。
  double _snapStep01(double value) => (value * 10).roundToDouble() / 10;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '倍速播放',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 4),
            Text(
              '调整音乐播放速度',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            // Current speed display
            Center(
              child: Text(
                _formatSpeed(_speed),
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: _speed == 1.0
                      ? colorScheme.onSurface
                      : colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Slider
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 6,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
                activeTrackColor: colorScheme.primary,
                inactiveTrackColor: colorScheme.surfaceContainerHighest,
                thumbColor: colorScheme.primary,
              ),
              child: Slider(
                value: _speed.clamp(_min, _max),
                min: _min,
                max: _max,
                // ====【需求/倍速 0.1 步进】滑块按 0.1 分档，位置与底部倍速刻度严格对应 ====
                divisions: _divisions,
                onChanged: (value) {
                  setState(() => _speed = _snapStep01(value));
                },
                onChangeEnd: (value) {
                  final snapped = _snapStep01(value);
                  widget.player.setPlaybackSpeed(snapped);
                },
              ),
            ),
            // 底部倍速刻度：按数值比例定位，与滑块位置严格对应（原 spaceBetween 均分会错位）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final w = constraints.maxWidth;
                  Widget anchor(String text, double v, {bool leftEnd = false, bool rightEnd = false}) {
                    if (leftEnd) {
                      return Positioned(
                        left: 0,
                        child: Text(text, style: _stepLabelStyle(context, _speed == v)),
                      );
                    }
                    if (rightEnd) {
                      return Positioned(
                        right: 0,
                        child: Text(text, style: _stepLabelStyle(context, _speed == v)),
                      );
                    }
                    final left = (v - _min) / (_max - _min) * w;
                    return Positioned(
                      left: left,
                      child: FractionalTranslation(
                        translation: const Offset(-0.5, 0),
                        child: Text(text, style: _stepLabelStyle(context, _speed == v)),
                      ),
                    );
                  }

                  return SizedBox(
                    height: 20,
                    child: Stack(
                      children: [
                        anchor('0.5x', 0.5, leftEnd: true),
                        anchor('1x', 1.0),
                        anchor('2x', 2.0),
                        anchor('3x', 3.0, rightEnd: true),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            // ====【需求/音调调节】独立音调调节区：Windows(BASS)/Android(ExoPlayer) 均支持 ====
            const Divider(height: 24),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '音调',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '独立调整音高，不影响播放速度',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  _pitch.toStringAsFixed(1),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: _pitch == 1.0
                        ? colorScheme.onSurface
                        : colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 6,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
                activeTrackColor: colorScheme.primary,
                inactiveTrackColor: colorScheme.surfaceContainerHighest,
                thumbColor: colorScheme.primary,
              ),
              child: Slider(
                value: _pitch.clamp(0.5, 2.0),
                min: 0.5,
                max: 2.0,
                divisions: 15, // 0.5~2.0 步 0.1
                label: _pitch.toStringAsFixed(1),
                onChanged: (value) =>
                    setState(() => _pitch = (value * 10).roundToDouble() / 10),
                onChangeEnd: (value) =>
                    widget.player.setPitch((value * 10).roundToDouble() / 10),
              ),
            ),
            const SizedBox(height: 12),
            // Reset button
            Center(
              child: TextButton.icon(
                onPressed: (_speed == 1.0 && _pitch == 1.0)
                    ? null
                    : () {
                        setState(() {
                          _speed = 1.0;
                          _pitch = 1.0;
                        });
                        widget.player.setPlaybackSpeed(1.0);
                        widget.player.setPitch(1.0);
                      },
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                label: const Text('恢复默认'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  TextStyle? _stepLabelStyle(BuildContext context, bool active) {
    final colorScheme = Theme.of(context).colorScheme;
    return Theme.of(context).textTheme.bodySmall?.copyWith(
      color: active ? colorScheme.primary : colorScheme.onSurfaceVariant,
      fontWeight: active ? FontWeight.w800 : FontWeight.w500,
    );
  }
}
