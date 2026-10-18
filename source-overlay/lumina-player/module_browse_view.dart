import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/module_data.dart';
import '../services/modules_service.dart';
import '../services/synthetiq_module_runtime.dart';
import 'module_title_screen.dart';

/// Lumina module browser backed by the Lumina API and compatible legacy handlers.
class ModuleBrowseView extends StatefulWidget {
  const ModuleBrowseView({
    super.key,
    this.module,
    this.initialQuery = '',
    this.autoRun = false,
  });

  /// When set, only this module is browsed/searched (module homepage mode).
  final InstalledModule? module;

  /// Text to pre-fill in the search box.
  final String initialQuery;

  /// Run the search (or the module's home feed when the query is empty)
  /// as soon as the screen opens.
  final bool autoRun;

  @override
  State<ModuleBrowseView> createState() => _ModuleBrowseViewState();
}

/// One horizontally scrolling row on a module's home page.
class _HomeSection {
  const _HomeSection(this.title, this.items);
  final String title;
  final List<dynamic> items;
}

class _ModuleBrowseViewState extends State<ModuleBrowseView> {
  final _runtime = LuminaModuleRuntime();
  final _query = TextEditingController();
  final Map<String, List<dynamic>> _results = {};
  final Map<String, List<_HomeSection>> _sections = {};
  bool _homeMode = false;
  final Map<String, String> _errors = {};
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _query.text = widget.initialQuery;
    if (widget.autoRun) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _search();
      });
    }
  }

  List<InstalledModule> _videoModules(ModulesService service) {
    final only = widget.module;
    return service.installed
        .where((m) =>
            (only == null || m.id == only.id) &&
            m.contentType.toLowerCase() == 'video')
        .toList();
  }

  @override
  void dispose() {
    _query.dispose();
    _runtime.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final modules = _videoModules(context.read<ModulesService>());
    if (modules.isEmpty) {
      setState(() {
        _results.clear();
        _errors
          ..clear()
          ..['modules'] = 'Install a compatible video module from Repository or import a Lumina module ZIP first.';
      });
      return;
    }
    setState(() {
      _searching = true;
      _results.clear();
      _sections.clear();
      _errors.clear();
      _homeMode = widget.module != null && _query.text.trim().isEmpty;
    });
    for (final module in modules) {
      if (!mounted) return;
      try {
        dynamic value;
        List<dynamic> list;
        if (_query.text.trim().isEmpty) {
          try {
            value = await _runtime.call(module, 'discoveryHome');
          } catch (_) {
            value = null;
          }
          if (value is Map && value['sections'] is List) {
            final parsed = <_HomeSection>[];
            for (final section in value['sections'] as List) {
              if (section is! Map) continue;
              final items = section['items'] is List ? section['items'] as List : const <dynamic>[];
              if (items.isEmpty) continue;
              final title = moduleString(section, ['title', 'name']);
              parsed.add(_HomeSection(title.isEmpty ? 'Browse' : title, items));
            }
            if (parsed.isNotEmpty) _sections[module.id] = parsed;
            list = (value['sections'] as List)
                .whereType<Map>()
                .expand((section) => section['items'] is List ? section['items'] as List : const <dynamic>[])
                .toList();
          } else if (value is List) {
            list = value;
          } else {
            try {
              value = await _runtime.call(module, 'extractHome');
              list = value is List ? value : (value is Map && value['items'] is List ? value['items'] as List : const <dynamic>[]);
            } catch (_) {
              value = await _runtime.call(module, 'searchResults', ['']);
              list = value is List ? value : const [];
            }
          }
        } else {
          value = await _runtime.call(module, 'searchResults', [_query.text.trim()]);
          list = value is List ? value : const [];
        }
        _results[module.id] = list;
        if (_homeMode && !_sections.containsKey(module.id) && list.isNotEmpty) {
          _sections[module.id] = [_HomeSection('Browse', list)];
        }
        if (list.isEmpty) _errors[module.id] = 'No results returned.';
      } catch (e) {
        _errors[module.id] = e.toString();
      }
      if (mounted) setState(() {});
    }
    if (mounted) setState(() => _searching = false);
  }

  Future<void> _openTitle(InstalledModule module, dynamic card) async {
    final href = moduleString(card, ['href', 'url', 'id', 'link']);
    if (href.isEmpty) {
      _notice('This result does not include a title reference.');
      return;
    }
    final allVideoModules = context
        .read<ModulesService>()
        .installed
        .where((m) => m.contentType.toLowerCase() == 'video')
        .toList();
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ModuleTitleScreen(
        module: module,
        runtime: _runtime,
        card: card,
        allModules: allVideoModules,
      ),
    ));
  }

  Widget _buildHome(InstalledModule module) {
    final sections = _sections[module.id] ?? const <_HomeSection>[];
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        for (final section in sections) _buildSection(module, section),
      ],
    );
  }

  Widget _buildSection(InstalledModule module, _HomeSection section) {
    final theme = Theme.of(context);
    final ranked = RegExp(r'trend|top|popular|rank|hot', caseSensitive: false).hasMatch(section.title);
    final shown = section.items.take(ranked ? 10 : 20).toList();
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                if (ranked)
                  Container(
                    width: 4,
                    height: 22,
                    margin: const EdgeInsets.only(right: 10),
                    decoration: BoxDecoration(
                      color: Colors.amber,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                Expanded(
                  child: Text(
                    section.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                if (section.items.length > shown.length || section.items.length > 6)
                  TextButton(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => _SectionGridPage(
                        title: section.title,
                        items: section.items,
                        onOpen: (card) => _openTitle(module, card),
                      ),
                    )),
                    child: const Text('View all'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: ranked ? 200 : 255,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: shown.length,
              separatorBuilder: (_, __) => SizedBox(width: ranked ? 6 : 12),
              itemBuilder: (context, index) => ranked
                  ? _buildRankedCard(module, shown[index], index + 1)
                  : _buildPosterCard(module, shown[index]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRankedCard(InstalledModule module, dynamic card, int rank) {
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.amber;
    const base = TextStyle(fontSize: 76, fontWeight: FontWeight.w900, height: 1);
    return GestureDetector(
      onTap: () => _openTitle(module, card),
      child: SizedBox(
        width: 150,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 34,
              right: 0,
              top: 0,
              bottom: 0,
              child: _posterImage(moduleString(card, ['image', 'poster', 'posterUrl', 'imageUrl', 'cover'])),
            ),
            Positioned(
              left: 0,
              bottom: -6,
              child: Stack(
                children: [
                  Text('$rank', style: base.copyWith(foreground: outline)),
                  Text('$rank', style: base.copyWith(color: Colors.black)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPosterCard(InstalledModule module, dynamic card) {
    final title = moduleString(card, ['title', 'name']);
    return GestureDetector(
      onTap: () => _openTitle(module, card),
      child: SizedBox(
        width: 130,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 190,
              width: 130,
              child: _posterImage(moduleString(card, ['image', 'poster', 'posterUrl', 'imageUrl', 'cover'])),
            ),
            const SizedBox(height: 6),
            Text(
              title.isEmpty ? 'Untitled' : title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  void _notice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final modules = _videoModules(context.watch<ModulesService>());
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _query,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    hintText: widget.module == null
                        ? 'Search installed providers'
                        : 'Search ${widget.module!.name}',
                    prefixIcon: const Icon(Icons.search),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _searching ? null : _search,
                child: _searching
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Search'),
              ),
            ],
          ),
        ),
        if (modules.isEmpty)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text('No video providers installed. Install a compatible module from Repository or import a Lumina module ZIP, then return here.'),
          ),
        Expanded(
          child: (_homeMode && modules.length == 1 && (_sections[modules.first.id]?.isNotEmpty ?? false))
              ? _buildHome(modules.first)
              : _results.isEmpty
              ? Center(
                  child: Text(_searching
                      ? 'Searching modules…'
                      : 'Search runs against each installed compatible video module.'))
              : ListView(
                  children: [
                    for (final module in modules) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text(module.name, style: Theme.of(context).textTheme.titleMedium),
                      ),
                      if (_errors.containsKey(module.id))
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                          child: Text(_errors[module.id]!, style: Theme.of(context).textTheme.bodySmall),
                        ),
                      for (final card in (_results[module.id] ?? const <dynamic>[]))
                        ListTile(
                          leading: _image(moduleString(card, ['image', 'poster', 'posterUrl', 'imageUrl'])),
                          title: Text(moduleString(card, ['title', 'name']).isEmpty ? 'Untitled' : moduleString(card, ['title', 'name'])),
                          subtitle: Text(moduleString(card, ['year', 'description'])),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _openTitle(module, card),
                        ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

Widget _image(String url) {
  if (url.startsWith('http://') || url.startsWith('https://')) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(url, width: 48, height: 68, fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const SizedBox(width: 48, child: Icon(Icons.movie_outlined))),
    );
  }
  return const SizedBox(width: 48, child: Icon(Icons.movie_outlined));
}

Widget _posterImage(String url) {
  final placeholder = Container(
    color: Colors.white10,
    alignment: Alignment.center,
    child: const Icon(Icons.movie_outlined, size: 32),
  );
  return ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: url.startsWith('http://') || url.startsWith('https://')
        ? Image.network(
            url,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            errorBuilder: (_, __, ___) => placeholder,
          )
        : placeholder,
  );
}

/// Full grid for a section's "View all".
class _SectionGridPage extends StatelessWidget {
  const _SectionGridPage({required this.title, required this.items, required this.onOpen});

  final String title;
  final List<dynamic> items;
  final void Function(dynamic card) onOpen;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 14,
          crossAxisSpacing: 12,
          childAspectRatio: 0.52,
        ),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final card = items[index];
          final name = moduleString(card, ['title', 'name']);
          return GestureDetector(
            onTap: () => onOpen(card),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _posterImage(moduleString(card, ['image', 'poster', 'posterUrl', 'imageUrl', 'cover'])),
                ),
                const SizedBox(height: 6),
                Text(
                  name.isEmpty ? 'Untitled' : name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
