import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/media_item.dart';
import '../services/download_service.dart';
import 'library_screen.dart';
import 'module_poster_card.dart';
import 'player_screen.dart';

/// Downloaded episodes (playable offline), plus the older on-device files view.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  bool _showLocal = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('Downloads'), icon: Icon(Icons.download_done)),
                ButtonSegment(value: true, label: Text('Local files'), icon: Icon(Icons.folder_outlined)),
              ],
              selected: {_showLocal},
              onSelectionChanged: (s) => setState(() => _showLocal = s.first),
            ),
          ),
        ),
        Expanded(child: _showLocal ? const LibraryScreen() : const _DownloadsList()),
      ],
    );
  }
}

class _DownloadsList extends StatelessWidget {
  const _DownloadsList();

  static String _size(int bytes) {
    if (bytes <= 0) return '';
    const mb = 1024 * 1024;
    if (bytes >= 1024 * mb) return '${(bytes / (1024 * mb)).toStringAsFixed(2)} GB';
    return '${(bytes / mb).toStringAsFixed(bytes >= 100 * mb ? 0 : 1)} MB';
  }

  void _play(BuildContext context, DownloadItem item) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(
        item: MediaItem(
          id: 'download:${item.id}',
          title: '${item.title} · ${item.episodeTitle}',
          path: item.filePath,
          type: MediaType.video,
          dateAdded: DateTime.fromMillisecondsSinceEpoch(item.createdAt),
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<DownloadService>();
    final items = service.items;
    if (items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Nothing downloaded yet.\nOpen a title and tap the download icon on any episode.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final theme = Theme.of(context);
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final item = items[i];
        final downloading = item.state == DownloadState.downloading;
        final failed = item.state == DownloadState.failed;
        final details = <String>[
          item.episodeTitle.isEmpty ? 'Episode ${item.episodeNumber}' : item.episodeTitle,
          item.mode.toUpperCase(),
          if (item.quality.isNotEmpty) item.quality,
          if (_size(item.bytes).isNotEmpty) _size(item.bytes),
        ];
        return ListTile(
          leading: SizedBox(
            width: 48,
            height: 64,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: moduleNetworkImage(item.image),
            ),
          ),
          title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                failed ? 'Failed: ${item.error ?? 'unknown error'}' : details.join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: failed ? TextStyle(color: theme.colorScheme.error) : null,
              ),
              if (downloading) ...[
                const SizedBox(height: 6),
                LinearProgressIndicator(value: item.progress),
              ],
            ],
          ),
          trailing: IconButton(
            tooltip: downloading ? 'Cancel' : 'Delete',
            icon: Icon(downloading ? Icons.close : Icons.delete_outline),
            onPressed: () {
              if (downloading) {
                service.remove(item.id);
                return;
              }
              showDialog<void>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('Delete download?'),
                  content: Text('${item.title} · ${item.episodeTitle}'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () {
                        Navigator.pop(dialogContext);
                        service.remove(item.id);
                      },
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              );
            },
          ),
          onTap: item.state == DownloadState.done ? () => _play(context, item) : null,
        );
      },
    );
  }
}
