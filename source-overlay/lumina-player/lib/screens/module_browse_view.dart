import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/modules_service.dart';
import '../services/synthetiq_module_runtime.dart';
import 'module_title_screen.dart';

/// Lumina module browser backed by the Lumina API and compatible legacy handlers.
class ModuleBrowseView extends StatefulWidget {
  const ModuleBrowseView({super.key});

  @override
  State<ModuleBrowseView> createState() => _ModuleBrowseViewState();
}

class _ModuleBrowseViewState extends State<ModuleBrowseView> {
  final _runtime = LuminaModuleRuntime();
  final _query = TextEditingController();
  final Map<String, List<dynamic>> _results = {};
  final Map<String, String> _errors = {};
  bool _searching = false;

  @override
  void dispose() {
    _query.dispose();
    _runtime.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final modules = context.read<ModulesService>().installed
        .where((m) => m.contentType.toLowerCase() == 'video')
        .toList();
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
      _errors.clear();
    });
    for (final module in modules) {
      if (!mounted) return;
      try {
        final list = await loadModuleItems(_runtime, module, _query.text);
        _results[module.id] = list;
        if (list.isEmpty) _errors[module.id] = 'No results returned.';
      } catch (e) {
        _errors[module.id] = e.toString();
      }
      if (mounted) setState(() {});
    }
    if (mounted) setState(() => _searching = false);
  }

  Future<void> _openTitle(InstalledModule module, dynamic card) =>
      openModuleTitle(context, _runtime, module, card);

  @override
  Widget build(BuildContext context) {
    final modules = context.watch<ModulesService>().installed
        .where((m) => m.contentType.toLowerCase() == 'video')
        .toList();
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
                  decoration: const InputDecoration(
                    hintText: 'Search installed providers',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
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
          child: _results.isEmpty
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
                          leading: moduleImage(moduleString(card, ['image', 'poster', 'posterUrl', 'imageUrl'])),
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

/// A titled row of cards on a module's home page ("Trending Now", "Latest"...).
/// A module that returns a plain list gets a single section with an empty title.
class ModuleSection {
  const ModuleSection(this.title, this.items);
  final String title;
  final List<dynamic> items;
}

/// Loads a module's home feed as sections. Modules that return
/// `{sections: [{title, items}]}` from `discoveryHome` keep their rows; anything
/// else becomes a single untitled section.
Future<List<ModuleSection>> loadModuleSections(
  LuminaModuleRuntime runtime,
  InstalledModule module,
) async {
  dynamic value;
  try {
    value = await runtime.call(module, 'discoveryHome');
  } catch (_) {
    value = null;
  }
  if (value is Map && value['sections'] is List) {
    final sections = <ModuleSection>[];
    for (final section in value['sections'] as List) {
      if (section is! Map) continue;
      final items = section['items'] is List ? section['items'] as List : const <dynamic>[];
      if (items.isEmpty) continue;
      sections.add(ModuleSection(moduleString(section, ['title', 'name', 'label']), items));
    }
    return sections;
  }
  if (value is List) return [ModuleSection('', value)];
  List<dynamic> flat;
  try {
    value = await runtime.call(module, 'extractHome');
    if (value is List) {
      flat = value;
    } else if (value is Map && value['items'] is List) {
      flat = value['items'] as List;
    } else {
      flat = const <dynamic>[];
    }
  } catch (_) {
    value = await runtime.call(module, 'searchResults', ['']);
    flat = value is List ? value : const <dynamic>[];
  }
  return [ModuleSection('', flat)];
}

/// Loads the list of cards for one module. An empty [query] loads the module's
/// own home feed (all sections joined); otherwise it runs the module's search.
Future<List<dynamic>> loadModuleItems(
  LuminaModuleRuntime runtime,
  InstalledModule module,
  String query,
) async {
  final q = query.trim();
  if (q.isNotEmpty) {
    final value = await runtime.call(module, 'searchResults', [q]);
    return value is List ? value : const <dynamic>[];
  }
  final sections = await loadModuleSections(runtime, module);
  return sections.expand((section) => section.items).toList();
}

/// Opens a title card: its page with the episode grid, from which the player
/// is started.
Future<void> openModuleTitle(
  BuildContext context,
  LuminaModuleRuntime runtime,
  InstalledModule module,
  dynamic card,
) async {
  final href = moduleString(card, ['href', 'url', 'id', 'link']);
  if (href.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('This result does not include a title reference.')),
    );
    return;
  }
  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => ModuleTitleScreen(runtime: runtime, module: module, card: card),
  ));
}

/// A single module's own page: its suggested media (home feed) plus a search
/// box that searches only this module.
class ModuleHomePage extends StatefulWidget {
  const ModuleHomePage({super.key, required this.module, required this.runtime});

  final InstalledModule module;
  final LuminaModuleRuntime runtime;

  @override
  State<ModuleHomePage> createState() => _ModuleHomePageState();
}

class _ModuleHomePageState extends State<ModuleHomePage> {
  final _query = TextEditingController();
  List<dynamic> _items = const [];
  bool _loading = true;
  String? _error;
  String _shownQuery = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final q = _query.text.trim();
    setState(() {
      _loading = true;
      _error = null;
      _shownQuery = q;
    });
    try {
      final items = await loadModuleItems(widget.runtime, widget.module, q)
          .timeout(const Duration(seconds: 30));
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _items = const [];
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.module.name)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: TextField(
              controller: _query,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _load(),
              decoration: InputDecoration(
                hintText: 'Search ${widget.module.name}',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  tooltip: 'Search',
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: _load,
                ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _shownQuery.isEmpty ? 'Suggested' : 'Results for "$_shownQuery"',
                style: theme.textTheme.titleMedium,
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('Could not load this module: $_error',
                                  textAlign: TextAlign.center),
                              const SizedBox(height: 12),
                              FilledButton(onPressed: _load, child: const Text('Try again')),
                            ],
                          ),
                        ),
                      )
                    : _items.isEmpty
                        ? Center(
                            child: Text(_shownQuery.isEmpty
                                ? 'This module did not suggest anything. Try searching.'
                                : 'No results.'))
                        : RefreshIndicator(
                            onRefresh: _load,
                            child: ListView.builder(
                              itemCount: _items.length,
                              itemBuilder: (context, i) {
                                final card = _items[i];
                                final title = moduleString(card, ['title', 'name']);
                                return ListTile(
                                  leading: moduleImage(moduleString(
                                      card, ['image', 'poster', 'posterUrl', 'imageUrl'])),
                                  title: Text(title.isEmpty ? 'Untitled' : title),
                                  subtitle: Text(moduleString(card, ['year', 'description']),
                                      maxLines: 2, overflow: TextOverflow.ellipsis),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () =>
                                      openModuleTitle(context, widget.runtime, widget.module, card),
                                );
                              },
                            ),
                          ),
          ),
        ],
      ),
    );
  }
}

String moduleString(dynamic value, List<String> keys) {
  if (value is! Map) return value is String ? value : '';
  for (final key in keys) {
    final candidate = value[key];
    if (candidate != null && candidate.toString().trim().isNotEmpty) return candidate.toString();
  }
  return '';
}

Widget moduleImage(String url, {double width = 48, double height = 68}) {
  if (url.startsWith('http://') || url.startsWith('https://')) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(url, width: width, height: height, fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => SizedBox(width: width, child: const Icon(Icons.movie_outlined))),
    );
  }
  return SizedBox(width: width, child: const Icon(Icons.movie_outlined));
}
