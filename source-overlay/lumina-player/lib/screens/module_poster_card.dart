import 'package:flutter/material.dart';

/// Poster image from a module card, with a dark placeholder when the module
/// gave no image or it fails to load.
Widget moduleNetworkImage(String url) {
  const placeholder = ColoredBox(
    color: Color(0xFF1E1E1E),
    child: Center(
      child: Icon(Icons.movie_outlined, size: 40, color: Colors.white38),
    ),
  );
  if (url.startsWith('http://') || url.startsWith('https://')) {
    return Image.network(
      url,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => placeholder,
    );
  }
  return placeholder;
}

/// A tappable poster with a title underneath. Used for search results, rails
/// and favourites.
class ModulePosterCard extends StatelessWidget {
  const ModulePosterCard({
    super.key,
    required this.title,
    required this.image,
    required this.onTap,
    this.subtitle = '',
    this.progress,
    this.onLongPress,
    this.onRemove,
    this.onInfo,
  });

  final String title;
  final String image;
  final String subtitle;

  /// 0..1 watch progress; shows a thin bar along the bottom of the poster.
  final double? progress;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Optional small buttons drawn over the poster: X (top right) and info (top left).
  final VoidCallback? onRemove;
  final VoidCallback? onInfo;

  Widget _badge(IconData icon, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: const Color(0xAA000000),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(icon, size: 16, color: Colors.white),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  moduleNetworkImage(image),
                  if (progress != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(value: progress, minHeight: 4),
                    ),
                  if (onInfo != null)
                    Positioned(top: 4, left: 4, child: _badge(Icons.info_outline, 'Details', onInfo!)),
                  if (onRemove != null)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: _badge(Icons.close, 'Remove from Continue Watching', onRemove!),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            title.isEmpty ? 'Untitled' : title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodyMedium,
          ),
          if (subtitle.isNotEmpty)
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}
