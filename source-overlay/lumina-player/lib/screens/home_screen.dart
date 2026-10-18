import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/module_state_service.dart';
import '../services/modules_service.dart';
import '../services/synthetiq_module_runtime.dart';
import 'module_poster_card.dart';
import 'module_browse_view.dart';
import 'module_player_screen.dart';

/// Home: pick a module, search it, flip through its suggested titles in a
/// carousel (Play / info / favourite), then Continue Watching and more.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _runtime = LuminaModuleRuntime();
  final _search = TextEditingController();
  final _pageController = PageController(viewportFraction: 0.78);

  final Map<String, List<dynamic>> _feeds = {};
  final Map<String, String> _feedErrors = {};
  final Set<String> _loadingFeeds = {};

  int _page = 0;
  String _searchedQuery = '';
  List<dynamic> _searchItems = const [];
  bool _searching = false;
  String? _searchError;

  @override
  void dispose() {
    _search.dispose();
    _pageController.dispose();
    _runtime.dispose();
    super.dispose();
  }

  // ----- data -------------------------------------------------------------

  InstalledModule? _current(List<InstalledModule> modules, ModuleStateService state) {
    if (modules.isEmpty) return null;
    for (final m in modules) {
      if (m.id == state.selectedModuleId) return m;
    }
    return modules.first;
  }

  void _ensureFeed(InstalledModule module) {
    if (_feeds.containsKey(module.id) ||
        _loadingFeeds.contains(module.id) ||
        _feedErrors.containsKey(module.id)) {
      return;
    }
    _loadingFeeds.add(module.id);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadFeed(module));
  }

  Future<void> _loadFeed(InstalledModule module) async {
    if (!mounted) return;
    setState(() {
      _loadingFeeds.add(module.id);
      _feedErrors.remove(module.id);
    });
    try {
      final items = await loadModuleItems(_runtime, module, '')
          .timeout(const Duration(seconds: 30));
      if (!mounted) return;
      setState(() {
        _feeds[module.id] = items;
        _loadingFeeds.remove(module.id);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _feedErrors[module.id] = e.toString();
        _loadingFeeds.remove(module.id);
      });
    }
  }

  Future<void> _runSearch(InstalledModule module) async {
    final q = _search.text.trim();
    if (q.isEmpty) {
      _clearSearch();
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _searchedQuery = q;
      _searchItems = const [];
      _searchError = null;
    });
    try {
      final items = await loadModuleItems(_runtime, module, q)
          .timeout(const Duration(seconds: 30));
      if (!mounted) return;
      setState(() {
        _searchItems = items;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searchError = e.toString();
        _searching = false;
      });
    }
  }

  void _clearSearch() {
    _search.clear();
    setState(() {
      _searchedQuery = '';
      _searchItems = const [];
      _searchError = null;
      _searching = false;
    });
  }

  void _selectModule(String id) {
    context.read<ModuleStateService>().selectModule(id);
    _search.clear();
    setState(() {
      _page = 0;
      _searchedQuery = '';
      _searchItems = const [];
      _searchError = null;
    });
    if (_pageController.hasClients) _pageController.jumpToPage(0);
  }

  // ----- actions ----------------------------------------------------------

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _play(InstalledModule module, dynamic card) =>
      openModuleTitle(context, _runtime, module, card);

  void _toggleFavourite(InstalledModule module, dynamic card) {
    final href = moduleString(card, const ['href', 'url', 'id', 'link']);
    if (href.isEmpty) {
      _snack('This title has no reference to save.');
      return;
    }
    context.read<ModuleStateService>().toggleFavourite(ModuleFavourite(
          moduleId: module.id,
          href: href,
          title: moduleString(card, const ['title', 'name']),
          image: moduleString(card, const ['image', 'poster', 'posterUrl', 'imageUrl']),
        ));
  }

  Future<dynamic> _details(InstalledModule module, String href) async {
    if (href.isEmpty) return null;
    try {
      return await _runtime
          .call(module, 'extractDetails', [href])
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      return null;
    }
  }

  void _showInfo(InstalledModule module, dynamic card) {
    final href = moduleString(card, const ['href', 'url', 'id', 'link']);
    final future = _details(module, href);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: FutureBuilder<dynamic>(
            future: future,
            builder: (context, snapshot) {
              final data = snapshot.data ?? card;
              String field(List<String> keys) {
                final fromDetails = moduleString(data, keys);
                return fromDetails.isNotEmpty ? fromDetails : moduleString(card, keys);
              }

              final title = field(const ['title', 'name']);
              final year = field(const ['year', 'released', 'date']);
              final description =
                  field(const ['description', 'synopsis', 'summary', 'overview']);
              final waiting = snapshot.connectionState != ConnectionState.done;
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title.isEmpty ? 'Untitled' : title,
                        style: Theme.of(context).textTheme.titleLarge),
                    if (year.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(year, style: Theme.of(context).textTheme.bodySmall),
                    ],
                    const SizedBox(height: 12),
                    if (waiting) const LinearProgressIndicator(),
                    if (description.isNotEmpty) Text(description),
                    if (!waiting && description.isEmpty)
                      const Text('This module did not provide a description.'),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _resume(ModuleHistoryEntry entry) async {
    InstalledModule? module;
    for (final m in context.read<ModulesService>().installed) {
      if (m.id == entry.moduleId) module = m;
    }
    if (module == null) {
      _snack('The module for ${entry.title} is no longer installed.');
      return;
    }
    await resumeModuleTitle(context, _runtime, module, entry);
  }

  // ----- UI ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final modulesService = context.watch<ModulesService>();
    final state = context.watch<ModuleStateService>();
    final videoModules = modulesService.installed
        .where((m) => m.contentType.toLowerCase() == 'video')
        .toList();
    final module = _current(videoModules, state);

    if (module == null) return _emptyState(theme, modulesService.loading);

    _ensureFeed(module);
    final items = _feeds[module.id] ?? const <dynamic>[];
    final loading = _loadingFeeds.contains(module.id);
    final error = _feedErrors[module.id];
    final hero = items.take(10).toList();
    final extra = items.length > 10 ? items.skip(10).toList() : const <dynamic>[];
    final watching = state.continueWatching;
    final searching = _searchedQuery.isNotEmpty;
    if (_page >= hero.length && hero.isNotEmpty) _page = 0;

    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        onRefresh: () => _loadFeed(module),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(top: 8, bottom: 24),
          children: [
            Center(child: _modulePill(theme, module, videoModules)),
            _searchField(module),
            if (searching)
              ..._searchSection(theme, module)
            else ...[
              if (loading && hero.isEmpty)
                const SizedBox(height: 300, child: Center(child: CircularProgressIndicator()))
              else if (error != null && hero.isEmpty)
                _message(
                  'Could not load ${module.name}: $error',
                  action: FilledButton(
                    onPressed: () => _loadFeed(module),
                    child: const Text('Try again'),
                  ),
                )
              else if (hero.isEmpty)
                _message('This module did not suggest anything. Try searching.')
              else ...[
                _hero(module, hero),
                _titleRow(theme, module, state, hero[_page < hero.length ? _page : 0]),
              ],
              if (watching.isNotEmpty) ...[
                const SizedBox(height: 24),
                _sectionTitle(theme, 'Continue Watching'),
                const SizedBox(height: 12),
                SizedBox(
                  height: 210,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: watching.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 12),
                    itemBuilder: (context, i) {
                      final e = watching[i];
                      return SizedBox(
                        width: 130,
                        child: ModulePosterCard(
                          title: e.title,
                          image: e.image,
                          subtitle: e.episodeTitle,
                          progress: e.fraction,
                          onTap: () => _resume(e),
                          onLongPress: () {
                            context.read<ModuleStateService>().removeHistory(e.key);
                            _snack('Removed ${e.title} from Continue Watching.');
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
              if (extra.isNotEmpty) ...[
                const SizedBox(height: 24),
                _sectionTitle(theme, 'More from ${module.name}'),
                const SizedBox(height: 12),
                SizedBox(
                  height: 210,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: extra.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 12),
                    itemBuilder: (context, i) => SizedBox(
                      width: 130,
                      child: _posterFor(module, extra[i]),
                    ),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _posterFor(InstalledModule module, dynamic card) => ModulePosterCard(
        title: moduleString(card, const ['title', 'name']),
        image: moduleString(card, const ['image', 'poster', 'posterUrl', 'imageUrl']),
        subtitle: moduleString(card, const ['year']),
        onTap: () => _play(module, card),
      );

  Widget _sectionTitle(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          text,
          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
        ),
      );

  Widget _message(String text, {Widget? action}) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text(text, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 12), action],
          ],
        ),
      );

  Widget _emptyState(ThemeData theme, bool loading) {
    if (loading) return const Center(child: CircularProgressIndicator());
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.extension_outlined,
                size: 72, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('No video modules yet', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text(
              'Open the Modules tab to install a video module from a repository '
              'or import a module ZIP. It will appear here.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _modulePill(ThemeData theme, InstalledModule module, List<InstalledModule> all) {
    return PopupMenuButton<String>(
      tooltip: 'Switch module',
      onSelected: _selectModule,
      itemBuilder: (_) => [
        for (final m in all)
          PopupMenuItem<String>(
            value: m.id,
            child: Row(
              children: [
                Icon(
                  m.id == module.id ? Icons.check_circle : Icons.circle_outlined,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Flexible(child: Text(m.name, overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                module.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.keyboard_arrow_down),
          ],
        ),
      ),
    );
  }

  Widget _searchField(InstalledModule module) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: TextField(
        controller: _search,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _runSearch(module),
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          hintText: 'Search ${module.name}…',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: (_search.text.isEmpty && _searchedQuery.isEmpty)
              ? null
              : IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.close),
                  onPressed: _clearSearch,
                ),
          filled: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(28),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }

  List<Widget> _searchSection(ThemeData theme, InstalledModule module) {
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Expanded(
              child: Text('Results for "$_searchedQuery"',
                  style: theme.textTheme.titleMedium),
            ),
            if (_searching)
              const SizedBox(
                  width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ),
      ),
      const SizedBox(height: 12),
      if (_searchError != null)
        _message('Search failed: $_searchError')
      else if (!_searching && _searchItems.isEmpty)
        _message('No results.')
      else
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            childAspectRatio: 0.58,
            crossAxisSpacing: 10,
            mainAxisSpacing: 12,
          ),
          itemCount: _searchItems.length,
          itemBuilder: (context, i) => _posterFor(module, _searchItems[i]),
        ),
    ];
  }

  Widget _hero(InstalledModule module, List<dynamic> hero) {
    return SizedBox(
      height: 420,
      child: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            itemCount: hero.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (context, i) => AnimatedBuilder(
              animation: _pageController,
              builder: (context, child) {
                var page = _page.toDouble();
                if (_pageController.hasClients) {
                  page = _pageController.page ?? page;
                }
                final delta = (page - i).abs();
                final scale = 1 - (delta > 1 ? 1 : delta) * 0.12;
                return Transform.scale(scale: scale, child: child);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: GestureDetector(
                  onTap: () => _play(module, hero[i]),
                  child: _heroCard(hero[i]),
                ),
              ),
            ),
          ),
          Positioned(
            left: 6,
            top: 0,
            bottom: 0,
            child: Center(
              child: _arrow(Icons.chevron_left, () {
                _pageController.previousPage(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                );
              }),
            ),
          ),
          Positioned(
            right: 6,
            top: 0,
            bottom: 0,
            child: Center(
              child: _arrow(Icons.chevron_right, () {
                _pageController.nextPage(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _arrow(IconData icon, VoidCallback onTap) {
    return Material(
      color: const Color(0xAA000000),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: Colors.white, size: 28),
        ),
      ),
    );
  }

  Widget _heroCard(dynamic card) {
    final title = moduleString(card, const ['title', 'name']);
    final image = moduleString(card, const ['image', 'poster', 'posterUrl', 'imageUrl']);
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Stack(
        fit: StackFit.expand,
        children: [
          moduleNetworkImage(image),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x00000000), Color(0xCC000000)],
                stops: [0.55, 1.0],
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 14,
            child: Text(
              title.isEmpty ? 'Untitled' : title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _titleRow(
    ThemeData theme,
    InstalledModule module,
    ModuleStateService state,
    dynamic card,
  ) {
    final title = moduleString(card, const ['title', 'name']);
    final href = moduleString(card, const ['href', 'url', 'id', 'link']);
    final favourite = state.isFavourite(module.id, href);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title.isEmpty ? 'Untitled' : title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: () => _play(module, card),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Play'),
            style: FilledButton.styleFrom(
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            ),
          ),
          IconButton(
            tooltip: 'Details',
            icon: const Icon(Icons.info_outline),
            onPressed: () => _showInfo(module, card),
          ),
          IconButton(
            tooltip: favourite ? 'Remove favourite' : 'Add favourite',
            icon: Icon(
              favourite ? Icons.favorite : Icons.favorite_border,
              color: favourite ? Colors.redAccent : null,
            ),
            onPressed: () => _toggleFavourite(module, card),
          ),
        ],
      ),
    );
  }
}
