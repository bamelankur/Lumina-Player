import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/media_item.dart';
import '../services/library_service.dart';
import '../widgets/media_card.dart';
import 'photo_viewer_screen.dart';
import 'player_screen.dart';

/// Full library with type filter, file import and folder scan.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  MediaType? _filter;

  void _open(MediaItem item) {
    if (item.type == MediaType.video) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => PlayerScreen(item: item)),
      );
    } else {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => PhotoViewerScreen(item: item)),
      );
    }
  }

  Future<void> _importFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const [
        'mp4', 'mkv', 'avi', 'mov', 'webm', 'm4v',
        'jpg', 'jpeg', 'png', 'webp', 'gif',
      ],
    );
    if (result == null || !mounted) return;
    final paths = result.files.map((f) => f.path).whereType<String>().toList();
    if (paths.isEmpty) return;
    final added = await context.read<LibraryService>().importFiles(paths);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Imported $added file${added == 1 ? '' : 's'}')),
    );
  }

  Future<void> _scanFolder() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null || !mounted) return;
    final added = await context.read<LibraryService>().scanDirectory(Directory(path));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Found $added media file${added == 1 ? '' : 's'}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryService>();
    final items = library.items.where((e) {
      if (_filter == null) return true;
      return e.type == _filter;
    }).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Row(
            children: [
              ChoiceChip(
                label: const Text('All'),
                selected: _filter == null,
                onSelected: (_) => setState(() => _filter = null),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('Videos'),
                selected: _filter == MediaType.video,
                onSelected: (_) => setState(() => _filter = MediaType.video),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('Photos'),
                selected: _filter == MediaType.photo,
                onSelected: (_) => setState(() => _filter = MediaType.photo),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Scan a folder',
                icon: const Icon(Icons.folder_open_outlined),
                onPressed: _scanFolder,
              ),
              IconButton(
                tooltip: 'Import files',
                icon: const Icon(Icons.add),
                onPressed: _importFiles,
              ),
            ],
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? const Center(child: Text('Nothing here yet.'))
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    childAspectRatio: 0.72,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final item = items[i];
                    return MediaCard(item: item, onTap: () => _open(item));
                  },
                ),
        ),
      ],
    );
  }
}
