import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/media_item.dart';
import '../services/library_service.dart';
import '../services/modules_service.dart';
import '../services/progress_service.dart';
import '../widgets/media_card.dart';
import 'module_browse_view.dart';
import 'photo_viewer_screen.dart';
import 'player_screen.dart';

/// Home: search across installed modules, one card per installed module
/// (tap for that module's own homepage), then the local library rails.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _openMedia(MediaItem item) {
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

  void _search() {
    final text = _query.text.trim();
    if (text.isEmpty) return;
    FocusScope.of(context).unfocus();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text('Search: $text')),
          body: ModuleBrowseView(initialQuery: text, autoRun: true),
        ),
      ),
    );
  }

  void _openModule(InstalledModule module) {
    if (module.contentType.toLowerCase() != 'video') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              '${module.name} is a ${module.contentType} module. Only video modules can be browsed in this version.'),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(module.name)),
          body: ModuleBrowseView(module: module, autoRun: true),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final modules = context.watch<ModulesService>();
    final library = context.watch<LibraryService>();
    final progress = context.watch<ProgressService>();

    final byId = {for (final e in library.items) e.id: e};
    final continueWatching = progress.continueWatchingIds
        .map((id) => byId[id])
        .whereType<MediaItem>()
        .toList();
    final recent = library.items.reversed.take(12).toList();
    final titleStyle = Theme.of(context).textTheme.titleMedium;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        TextField(
          controller: _query,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _search(),
          decoration: InputDecoration(
            hintText: 'Search all installed modules',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: IconButton(
              tooltip: 'Search',
              icon: const Icon(Icons.arrow_forward),
              onPressed: _search,
            ),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 16),
        Text('Your modules', style: titleStyle),
        const SizedBox(height: 8),
        if (modules.loading && modules.installed.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (modules.installed.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
                'No modules installed yet. Open the Modules tab to install or import one.'),
          )
        else
          for (final module in modules.installed)
            Card(
              child: ListTile(
                leading: const CircleAvatar(child: Icon(Icons.extension)),
                title: Text(module.name),
                subtitle: Text('${module.contentType} • v${module.version}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openModule(module),
              ),
            ),
        if (modules.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              modules.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (!library.isLoaded)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: Text('Loading your local library…'),
          ),
        if (library.isLoaded && continueWatching.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Continue watching', style: titleStyle),
          const SizedBox(height: 8),
          SizedBox(
            height: 190,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: continueWatching.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final item = continueWatching[i];
                return SizedBox(
                  width: 150,
                  child: MediaCard(item: item, onTap: () => _openMedia(item)),
                );
              },
            ),
          ),
        ],
        if (library.isLoaded && recent.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Recently added', style: titleStyle),
          const SizedBox(height: 8),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              childAspectRatio: 0.72,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: recent.length,
            itemBuilder: (context, i) {
              final item = recent[i];
              return MediaCard(item: item, onTap: () => _openMedia(item));
            },
          ),
        ],
      ],
    );
  }
}
