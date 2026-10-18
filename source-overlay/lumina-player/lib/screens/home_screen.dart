import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/media_item.dart';
import '../services/library_service.dart';
import '../services/modules_service.dart';
import '../services/progress_service.dart';
import '../services/synthetiq_module_runtime.dart';
import '../widgets/media_card.dart';
import 'module_browse_view.dart';
import 'photo_viewer_screen.dart';
import 'player_screen.dart';

/// Home: search across installed modules, one card per installed module
/// (tap for that module's own page), then the on-device library rails.
///
/// Nothing here waits for the local library or the network, so Home always
/// renders immediately.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _runtime = LuminaModuleRuntime();
  final _query = TextEditingController();
  final Map<String, List<dynamic>> _results = {};
  final Map<String, String> _errors = {};
  bool _searching = false;
  String _searched = '';

  @override
  void dispose() {
    _query.dispose();
    _runtime.dispose();
    super.dispose();
  }

  List<InstalledModule> _videoModules() => context
      .read<ModulesService>()
      .installed
      .where((m) => m.contentType.toLowerCase() == 'video')
      .toList();

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty) {
      _clearSearch();
      return;
    }
    final modules = _videoModules();
    if (modules.isEmpty) {
      _snack('Install a video module from the Modules tab first.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _searched = q;
      _results.clear();
      _errors.clear();
    });
    for (final module in modules) {
      if (!mounted) return;
      try {
        final list = await loadModuleItems(_runtime, module, q)
            .timeout(const Duration(seconds: 30));
        _results[module.id] = list;
        if (list.isEmpty) _errors[module.id] = 'No results.';
      } catch (e) {
        _errors[module.id] = e.toString();
      }
      if (mounted) setState(() {});
    }
    if (mounted) setState(() => _searching = false);
  }

  void _clearSearch() {
    _query.clear();
    setState(() {
      _searched = '';
      _results.clear();
      _errors.clear();
    });
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _openModule(InstalledModule module) {
    if (module.contentType.toLowerCase() != 'video') {
      _snack('${module.name} is a ${module.contentType} module. '
          'This version of Lumina can only browse video modules.');
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ModuleHomePage(module: module, runtime: _runtime),
    ));
  }

  void _openLocal(MediaItem item) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => item.type == MediaType.video
          ? PlayerScreen(item: item)
          : PhotoViewerScreen(item: item),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final modulesService = context.watch<ModulesService>();
    final modules = modulesService.installed;
    final library = context.watch<LibraryService>();
    final progress = context.watch<ProgressService>();

    final byId = {for (final e in library.items) e.id: e};
    final continueWatching = progress.continueWatchingIds
        .map((id) => byId[id])
        .whereType<MediaItem>()
        .toList();
    final recent = library.items.reversed.take(12).toList();
    final showingSearch = _searched.isNotEmpty;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        TextField(
          controller: _query,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _search(),
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: 'Search all installed modules',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _query.text.isEmpty && !showingSearch
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close),
                    onPressed: _clearSearch,
                  ),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 16),
        if (showingSearch) ..._searchResults(theme, modules) else ...[
          Text('Your modules', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (modulesService.loading && modules.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (modules.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'No modules installed yet. Open the Modules tab to install one '
                  'from a repository or import a module ZIP.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            )
          else
            for (final module in modules)
              Card(
                child: ListTile(
                  leading: CircleAvatar(
                    child: Icon(module.contentType.toLowerCase() == 'video'
                        ? Icons.play_circle_outline
                        : Icons.extension_outlined),
                  ),
                  title: Text(module.name),
                  subtitle: Text(
                    module.description.isEmpty
                        ? '${module.contentType} · v${module.version}'
                        : module.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openModule(module),
                ),
              ),
          if (continueWatching.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('Continue watching', style: theme.textTheme.titleMedium),
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
                    child: MediaCard(item: item, onTap: () => _openLocal(item)),
                  );
                },
              ),
            ),
          ],
          if (recent.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('Recently added to your library', style: theme.textTheme.titleMedium),
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
                return MediaCard(item: item, onTap: () => _openLocal(item));
              },
            ),
          ],
        ],
      ],
    );
  }

  List<Widget> _searchResults(ThemeData theme, List<InstalledModule> modules) {
    final videoModules =
        modules.where((m) => m.contentType.toLowerCase() == 'video').toList();
    return [
      Row(
        children: [
          Expanded(
            child: Text('Results for "$_searched"', style: theme.textTheme.titleMedium),
          ),
          if (_searching)
            const SizedBox(
                width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        ],
      ),
      for (final module in videoModules) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
          child: Text(module.name, style: theme.textTheme.titleSmall),
        ),
        if (_errors.containsKey(module.id))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Text(_errors[module.id]!, style: theme.textTheme.bodySmall),
          ),
        for (final card in (_results[module.id] ?? const <dynamic>[]))
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: moduleImage(
                moduleString(card, ['image', 'poster', 'posterUrl', 'imageUrl'])),
            title: Text(moduleString(card, ['title', 'name']).isEmpty
                ? 'Untitled'
                : moduleString(card, ['title', 'name'])),
            subtitle: Text(moduleString(card, ['year', 'description']),
                maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => openModuleTitle(context, _runtime, module, card),
          ),
      ],
    ];
  }
}
