import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ====【修复/封面与背景过渡不同步】====
// 播放器页的【封面、背景模糊、切歌预缓存】必须使用【完全相同的 ImageProvider】
// （同 url + 同解码宽度）才能命中同一 ImageCache 条目、共享同一次下载与解码：
// 这样封面图片就绪与背景模糊生成几乎同时完成（只差模糊渲染的几毫秒~几十毫秒），
// 300ms 淡入才能同步。此前背景用独立 HttpClient 重新下载封面，实测背景比封面晚
// 79~284ms 就绪，出现"封面先淡入、背景随后跟进"的不同步观感。
//
// 取值 512：网络封面源多为 400px，ResizeImage 默认不允许放大，实际解码即源尺寸，
// 因此统一到该值不会增加内存/解码成本。
//
// 注意：Artwork 内部用 `Image.network(cacheWidth: N)` 构造，它等价于
// `ResizeImage(NetworkImage(url), width: N)`（相同 width/height/policy/allowUpscaling）。
// 二者必须保持一致；改动一侧需同步另一侧，否则会退化为两条独立下载管线。
const double kPlayerCoverDecodeWidth = 512;

/// 构建与 Artwork 内部一致的封面 ImageProvider（供背景模糊、切歌预缓存复用）。
ImageProvider playerCoverProvider(String url) => ResizeImage(
      NetworkImage(url),
      width: kPlayerCoverDecodeWidth.round(),
    );

class Artwork extends StatelessWidget {
  const Artwork({
    super.key,
    this.url,
    required this.size,
    this.borderRadius = 8,
    this.icon = Icons.music_note_rounded,
    // ====【需求/性能优化·封面解码尺寸】可选：限制网络封面图的解码宽度，避免整图解码后
    // 被旋转唱片等每帧合成大纹理。null(默认)保持原行为(原尺寸解码)，不影响其它用法。====
    this.decodeSize,
    // ====【需求/视觉优先·封面淡入】可选：网络图片加载完成时回调（用于切歌封面平滑淡入）====
    this.onImageLoaded,
  });

  final String? url;
  final double size;
  final double borderRadius;
  final IconData icon;
  final double? decodeSize;
  final VoidCallback? onImageLoaded;

  @override
  Widget build(BuildContext context) {
    final imageUrl = url;
    final child = imageUrl == null
        ? _Fallback(icon: icon)
        : imageUrl.startsWith('content://')
            ? _ContentUriImage(
                uri: imageUrl,
                size: size,
                borderRadius: borderRadius,
                icon: icon,
              )
            : Image.network(
                imageUrl,
                fit: BoxFit.cover,
                // ====【需求/性能优化·封面解码尺寸】按调用方传入的解码宽度解码，降低旋转合成纹理负载====
                cacheWidth: decodeSize?.round(),
                errorBuilder: (context, error, stackTrace) =>
                    _Fallback(icon: icon),
                loadingBuilder: (context, child, progress) {
                  if (progress == null) {
                    // 图片就绪：触发调用方淡入回调（切歌封面平滑出现；重复调用无害）。
                    onImageLoaded?.call();
                    return child;
                  }
                  return _ShimmerBox(
                    size: size,
                    borderRadius: borderRadius,
                  );
                },
              );

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: size.isFinite
          ? SizedBox.square(dimension: size, child: child)
          : SizedBox.expand(child: child),
    );
  }
}

/// 加载 content:// URI 的图片（用于本地音乐专辑封面）。
class _ContentUriImage extends StatefulWidget {
  const _ContentUriImage({
    required this.uri,
    required this.size,
    required this.borderRadius,
    required this.icon,
  });

  final String uri;
  final double size;
  final double borderRadius;
  final IconData icon;

  @override
  State<_ContentUriImage> createState() => _ContentUriImageState();
}

class _ContentUriImageState extends State<_ContentUriImage> {
  static const _channel = MethodChannel('kgka_music_hl/local_music');
  Uint8List? _bytes;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void didUpdateWidget(covariant _ContentUriImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 列表刷新/重排时同一位置会复用 State，uri 变化需要重新加载封面，
    // 否则会显示上一次的旧封面（封面错位）。
    if (oldWidget.uri != widget.uri) {
      _bytes = null;
      _loading = true;
      _loadImage();
    }
  }

  Future<void> _loadImage() async {
    // 记录发起加载时的 uri，用于丢弃过期结果，避免快速刷新时的竞态。
    final uri = widget.uri;
    try {
      // 从 content URI 中提取 albumId
      final albumId = int.tryParse(uri.split('/').last);
      if (albumId == null || albumId <= 0) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final bytes = await _channel.invokeMethod<Uint8List>(
        'getAlbumArt',
        {'albumId': albumId},
      );
      if (!mounted || widget.uri != uri) return;
      setState(() {
        _bytes = bytes;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return _ShimmerBox(size: widget.size, borderRadius: widget.borderRadius);
    }
    if (_bytes == null) {
      return _Fallback(icon: widget.icon);
    }
    return Image.memory(_bytes!, fit: BoxFit.cover);
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primary.withValues(alpha: .88),
            const Color(0xFF70D6FF),
            colorScheme.secondary.withValues(alpha: .72),
          ],
        ),
      ),
      child: Icon(icon, color: Colors.white, size: 28),
    );
  }
}

/// 图片加载时的 Shimmer 占位效果。
class _ShimmerBox extends StatefulWidget {
  const _ShimmerBox({required this.size, required this.borderRadius});

  final double size;
  final double borderRadius;

  @override
  State<_ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<_ShimmerBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
    _animation = Tween(begin: -1.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseColor = isDark
        ? colorScheme.surfaceContainerHighest
        : colorScheme.surfaceContainer;
    final highlightColor = isDark
        ? colorScheme.surfaceContainerHighest.withValues(alpha: .4)
        : Colors.white.withValues(alpha: .6);

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment(_animation.value - 0.5, 0),
                end: Alignment(_animation.value + 0.5, 0),
                colors: [baseColor, highlightColor, baseColor],
                stops: const [0, 0.5, 1],
              ),
            ),
            child: child,
          ),
        );
      },
      child: SizedBox(
        width: widget.size.isFinite ? widget.size : null,
        height: widget.size.isFinite ? widget.size : null,
      ),
    );
  }
}
