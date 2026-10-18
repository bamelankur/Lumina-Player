import 'package:flutter/material.dart';

import '../services/module_data.dart';
import '../services/modules_service.dart';
import '../services/synthetiq_module_runtime.dart';
import 'lumina_player_screen.dart';

const int _episodesPerRange = 100;

/// Title page opened from a module's search results: poster and synopsis,
/// SUB/DUB choice, season buttons and a number grid of episodes.
class ModuleTitleScreen extends StatefulWidget {
  const ModuleTitleScreen({
    super.key,
    required this.module,
    required this.runtime,
    required this.card,
    required this.allModules,
  });

  final InstalledModule module;
  final LuminaModuleRuntime runtime;

  /// The search/home card that was tapped.
  final dynamic card;

  /// Every installed video module (used by "Switch module" in the player).
  final List<InstalledModule> allModules;

  @override
  State<ModuleTitleScreen> createState() => _ModuleTitleScreenState();
}

class _ModuleTitleScreenState extends State<ModuleTitleScreen> {
  static const _titleKeys = ['title', 'name'];
  static const _imageKeys = ['image', 'poster', 'posterUrl', 'imageUrl', 'cover'];
  static const _descriptionKeys = ['description', 'synopsis', 'overview', 'summary'];

  final _numberController = TextEditingController();

  bool _loading = true;
  String? _error;

  String _href = '';
  String _title = '';
  String _poster = '';
  String _description = '';
  String _year = '';

  List<EpisodeEntry> _all = const [];
  Map<String, List<EpisodeEntry>> _seasons = const {};
  String _season = '';
  int _range = 0;
  String _audio = 'sub';
  String? _lastHref;
  bool _descriptionExpanded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _numberController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _href = moduleString(widget.card, ['href', 'url', 'id', 'link']);
      if (_href.isEmpty) throw StateError('This result does not include a title reference.');

      dynamic details;
      try {
        details = await widget.runtime.call(widget.module, 'extractDetails', [_href]);
      } catch (_) {
        details = null;
      }
      if (details is List && details.isNotEmpty) details = details.first;
      if (details is! Map) details = null;

      String pick(List<String> keys) {
        final fromDetails = moduleString(details, keys);
        return fromDetails.isNotEmpty ? fromDetails : moduleString(widget.card, keys);
      }

      _title = pick(_titleKeys);
      if (_title.isEmpty) _title = 'Untitled';
      _poster = pick(_imageKeys);
      _description = pick(_descriptionKeys);
      _year = pick(['year', 'released', 'date']);

      final episodes = parseEpisodes(await widget.runtime.call(widget.module, 'extractEpisodes', [_href]));
      if (episodes.isEmpty) {
        throw StateError('${widget.module.name} returned no episodes for $_title.');
      }
      _all = episodes;
      _seasons = groupBySeason(episodes);
      _audio = await AudioPreference.load();
      _lastHref = await LastWatched.get(widget.module.id, _href);
      _selectLastWatched();

      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst(RegExp(r'^(Bad state|Exception):\s*'), '');
      });
    }
  }

  /// Opens on the season and range that contain the last episode watched.
  void _selectLastWatched() {
    _season = _seasons.keys.first;
    _range = 0;
    final last = _lastHref;
    if (last == null) return;
    for (final entry in _seasons.entries) {
      final index = entry.value.indexWhere((e) => e.href == last);
      if (index >= 0) {
        _season = entry.key;
        _range = index ~/ _episodesPerRange;
        return;
      }
    }
  }

  List<EpisodeEntry> get _seasonEpisodes => _seasons[_season] ?? const <EpisodeEntry>[];

  List<List<EpisodeEntry>> get _ranges {
    final episodes = _seasonEpisodes;
    return [
      for (var i = 0; i < episodes.length; i += _episodesPerRange)
        episodes.sublist(i, i + _episodesPerRange > episodes.length ? episodes.length : i + _episodesPerRange),
    ];
  }

  String _rangeLabel(List<EpisodeEntry> range) => '${range.first.number}-${range.last.number}';

  Future<void> _play(EpisodeEntry episode) async {
    final index = _all.indexOf(episode);
    if (index < 0) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LuminaPlayerScreen(
          runtime: widget.runtime,
          module: widget.module,
          modules: widget.allModules,
          animeTitle: _title,
          titleHref: _href,
          episodes: _all,
          startIndex: index,
          audio: _audio,
        ),
      ),
    );
    if (!mounted) return;
    final last = await LastWatched.get(widget.module.id, _href);
    if (!mounted) return;
    setState(() => _lastHref = last);
  }

  void _setAudio(String audio) {
    setState(() => _audio = audio);
    AudioPreference.save(audio);
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title.isEmpty ? widget.module.name : _title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildError()
              : _buildContent(context),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40),
            const SizedBox(height: 12),
            Text(_error ?? '', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: _load, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final width = MediaQuery.of(context).size.width;
    final columns = ((width - 32) / 58).floor().clamp(4, 14).toInt();
    final ranges = _ranges;
    final rangeIndex = ranges.isEmpty ? 0 : _range.clamp(0, ranges.length - 1).toInt();
    final query = _numberController.text.trim();
    final visible = query.isNotEmpty
        ? _seasonEpisodes.where((e) => e.number.toString().contains(query)).toList()
        : (ranges.isEmpty ? <EpisodeEntry>[] : ranges[rangeIndex]);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildPoster(scheme),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_title, style: textTheme.titleLarge),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          Chip(
                            label: Text(widget.module.name),
                            visualDensity: VisualDensity.compact,
                          ),
                          if (_year.isNotEmpty)
                            Chip(label: Text(_year), visualDensity: VisualDensity.compact),
                          Chip(
                            label: Text('${_all.length} episodes'),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_description.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: GestureDetector(
                onTap: () => setState(() => _descriptionExpanded = !_descriptionExpanded),
                child: Text(
                  _description,
                  maxLines: _descriptionExpanded ? null : 4,
                  overflow: _descriptionExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
                  style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                children: [
                  _buildAudioRow(Icons.closed_caption, 'SUB', 'sub'),
                  const Divider(height: 24),
                  _buildAudioRow(Icons.mic, 'DUB', 'dub'),
                ],
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Watch more seasons of this anime', style: textTheme.titleMedium),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final season in _seasons.keys) _buildSeasonButton(season, scheme),
                  ],
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('List of episodes:', style: textTheme.titleMedium),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.format_list_bulleted),
                        const SizedBox(width: 10),
                        if (ranges.length > 1)
                          DropdownButton<int>(
                            value: rangeIndex,
                            underline: const SizedBox.shrink(),
                            items: [
                              for (var i = 0; i < ranges.length; i++)
                                DropdownMenuItem(
                                  value: i,
                                  child: Text('EPS: ${_rangeLabel(ranges[i])}'),
                                ),
                            ],
                            onChanged: (value) {
                              if (value == null) return;
                              setState(() {
                                _range = value;
                                _numberController.clear();
                              });
                            },
                          )
                        else if (ranges.isNotEmpty)
                          Text('EPS: ${_rangeLabel(ranges.first)}'),
                      ],
                    ),
                    SizedBox(
                      width: 180,
                      child: TextField(
                        controller: _numberController,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Number of Ep',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          sliver: visible.isEmpty
              ? SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        query.isEmpty ? 'No episodes.' : 'No episode matches "$query".',
                        style: textTheme.bodyMedium,
                      ),
                    ),
                  ),
                )
              : SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1.9,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => _buildEpisodeTile(visible[index], scheme),
                    childCount: visible.length,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildPoster(ColorScheme scheme) {
    final placeholder = Container(
      width: 100,
      height: 145,
      color: scheme.surfaceContainerHighest,
      child: const Icon(Icons.movie_outlined, size: 36),
    );
    if (!_poster.startsWith('http')) return ClipRRect(borderRadius: BorderRadius.circular(8), child: placeholder);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        _poster,
        width: 100,
        height: 145,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => placeholder,
      ),
    );
  }

  Widget _buildAudioRow(IconData icon, String label, String value) {
    final selected = _audio == value;
    return Row(
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 10),
        SizedBox(
          width: 52,
          child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        ),
        ChoiceChip(
          label: Text(widget.module.name),
          selected: selected,
          showCheckmark: false,
          onSelected: (_) => _setAudio(value),
        ),
      ],
    );
  }

  Widget _buildSeasonButton(String season, ColorScheme scheme) {
    final selected = season == _season;
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: selected ? scheme.primary : scheme.onSurface,
        side: BorderSide(color: selected ? scheme.primary : scheme.outlineVariant, width: selected ? 1.6 : 1),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      onPressed: () => setState(() {
        _season = season;
        _range = 0;
        _numberController.clear();
      }),
      child: Text(seasonLabel(season), style: const TextStyle(fontWeight: FontWeight.w600)),
    );
  }

  Widget _buildEpisodeTile(EpisodeEntry episode, ColorScheme scheme) {
    final isLast = episode.href == _lastHref;
    return Material(
      color: isLast ? scheme.onSurface.withAlpha(70) : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _play(episode),
        child: Center(
          child: Text(
            '${episode.number}',
            style: TextStyle(
              fontSize: 16,
              fontWeight: isLast ? FontWeight.w800 : FontWeight.w600,
              color: isLast ? scheme.onSurface : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
