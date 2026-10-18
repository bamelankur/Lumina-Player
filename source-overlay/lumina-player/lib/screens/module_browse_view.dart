import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../services/modules_service.dart';
import '../services/synthetiq_module_runtime.dart';

/// A Synthetiq module browser backed by the documented module handlers.
class ModuleBrowseView extends StatefulWidget {
  const ModuleBrowseView({super.key});

  @override
  State<ModuleBrowseView> createState() => _ModuleBrowseViewState();
}

class _ModuleBrowseViewState extends State<ModuleBrowseView> {
  final _runtime = SynthetiqModuleRuntime();
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
          ..['modules'] = 'Install a compatible Synthetiq video module from the Repository tab first.';
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
        dynamic value;
        List<dynamic> list;
        if (_query.text.trim().isEmpty) {
          try {
            value = await _runtime.call(module, 'discoveryHome');
          } catch (_) {
            value = null;
          }
          if (value is Map && value['sections'] is List) {
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
        if (list.isEmpty) _errors[module.id] = 'No results returned.';
      } catch (e) {
        _errors[module.id] = e.toString();
      }
      if (mounted) setState(() {});
    }
    if (mounted) setState(() => _searching = false);
  }

  Future<void> _openTitle(InstalledModule module, dynamic card) async {
    final href = _string(card, ['href', 'url', 'id', 'link']);
    if (href.isEmpty) {
      _notice('This result does not include a title reference.');
      return;
    }
    try {
      dynamic details;
      try {
        details = await _runtime.call(module, 'extractDetails', [href]);
      } catch (_) {
        details = card;
      }
      final title = _string(details, ['title', 'name']).isNotEmpty
          ? _string(details, ['title', 'name'])
          : _string(card, ['title', 'name']);
      final episodeValue = await _runtime.call(module, 'extractEpisodes', [href]);
      final episodes = episodeValue is List ? episodeValue : const [];
      if (!mounted) return;
      if (episodes.isEmpty) {
        _notice('No episodes were returned for $title.');
        return;
      }
      final chosen = await showModalBottomSheet<dynamic>(
        context: context,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.7,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(title, style: Theme.of(context).textTheme.titleLarge),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: episodes.length,
                    itemBuilder: (context, index) {
                      final ep = episodes[index];
                      final label = _string(ep, ['title', 'name']).isNotEmpty
                          ? _string(ep, ['title', 'name'])
                          : 'Episode ${index + 1}';
                      final season = _string(ep, ['season']);
                      return ListTile(
                        leading: const Icon(Icons.play_circle_outline),
                        title: Text(label),
                        subtitle: season.isEmpty ? null : Text('Season $season'),
                        onTap: () => Navigator.pop(context, ep),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      if (chosen == null || !mounted) return;
      final episodeHref = _string(chosen, ['href', 'url', 'id']);
      if (episodeHref.isEmpty) {
        _notice('The selected episode has no playable reference.');
        return;
      }
      final stream = await _runtime.call(module, 'extractStreamUrl', [episodeHref, 'sub', false]);
      final streamUrl = _findStreamUrl(stream);
      if (streamUrl.isEmpty) {
        _notice('The module did not return a direct playable URL.');
        return;
      }
      final headers = _findHeaders(stream);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _ModuleVideoPlayer(title: title, url: streamUrl, headers: headers),
      ));
    } catch (e) {
      _notice('Could not open title: $e');
    }
  }

  void _notice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

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
            child: Text('No video providers installed. Open Repository, install a compatible Synthetiq video module, then return here.'),
          ),
        Expanded(
          child: _results.isEmpty
              ? Center(
                  child: Text(_searching
                      ? 'Searching modules…'
                      : 'Search runs against each installed compatible Synthetiq video module.'))
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
                          leading: _image(_string(card, ['image', 'poster', 'posterUrl', 'imageUrl'])),
                          title: Text(_string(card, ['title', 'name']).isEmpty ? 'Untitled' : _string(card, ['title', 'name'])),
                          subtitle: Text(_string(card, ['year', 'description'])),
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

String _string(dynamic value, List<String> keys) {
  if (value is! Map) return value is String ? value : '';
  for (final key in keys) {
    final candidate = value[key];
    if (candidate != null && candidate.toString().trim().isNotEmpty) return candidate.toString();
  }
  return '';
}

String _findStreamUrl(dynamic value) {
  if (value is String && value.startsWith('http')) return value;
  if (value is List) {
    for (final item in value) {
      final found = _findStreamUrl(item);
      if (found.isNotEmpty) return found;
    }
  }
  if (value is Map) {
    for (final key in ['url', 'file', 'src', 'streamUrl', 'stream_url', 'link']) {
      final candidate = value[key];
      if (candidate is String && (candidate.startsWith('http://') || candidate.startsWith('https://'))) {
        return candidate;
      }
    }
    for (final key in ['streams', 'sources', 'data', 'result', 'links']) {
      if (value.containsKey(key)) {
        final found = _findStreamUrl(value[key]);
        if (found.isNotEmpty) return found;
      }
    }
  }
  return '';
}

Map<String, String> _findHeaders(dynamic value) {
  if (value is Map) {
    final headers = value['headers'] ?? value['streamHeaders'];
    if (headers is Map) return headers.map((key, val) => MapEntry(key.toString(), val.toString()));
    for (final key in ['streams', 'sources', 'data', 'result', 'links']) {
      if (value.containsKey(key)) {
        final found = _findHeaders(value[key]);
        if (found.isNotEmpty) return found;
      }
    }
  } else if (value is List) {
    for (final item in value) {
      final found = _findHeaders(item);
      if (found.isNotEmpty) return found;
    }
  }
  return {};
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

class _ModuleVideoPlayer extends StatefulWidget {
  const _ModuleVideoPlayer({required this.title, required this.url, required this.headers});
  final String title;
  final String url;
  final Map<String, String> headers;

  @override
  State<_ModuleVideoPlayer> createState() => _ModuleVideoPlayerState();
}

class _ModuleVideoPlayerState extends State<_ModuleVideoPlayer> {
  late final VideoPlayerController _controller;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url), httpHeaders: widget.headers)
      ..initialize().then((_) {
        if (mounted) setState(() {});
        _controller.play();
      }).catchError((Object error) {
        if (mounted) setState(() => _error = error);
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Center(
        child: _error != null
            ? Padding(padding: const EdgeInsets.all(20), child: Text('Playback failed: $_error'))
            : !_controller.value.isInitialized
                ? const CircularProgressIndicator()
                : AspectRatio(
                    aspectRatio: _controller.value.aspectRatio,
                    child: Stack(
                      alignment: Alignment.bottomCenter,
                      children: [
                        VideoPlayer(_controller),
                        VideoProgressIndicator(_controller, allowScrubbing: true),
                        Align(
                          alignment: Alignment.center,
                          child: IconButton.filled(
                            iconSize: 42,
                            onPressed: () => setState(() {
                              _controller.value.isPlaying ? _controller.pause() : _controller.play();
                            }),
                            icon: Icon(_controller.value.isPlaying ? Icons.pause : Icons.play_arrow),
                          ),
                        ),
                      ],
                    ),
                  ),
      ),
    );
  }
}
