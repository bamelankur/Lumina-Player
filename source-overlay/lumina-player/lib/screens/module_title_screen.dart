import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/media_item.dart';
import '../services/download_service.dart';
import '../services/module_episodes.dart';
import '../services/module_state_service.dart';
import '../services/modules_service.dart';
import '../services/synthetiq_module_runtime.dart';
import 'module_player_screen.dart';
import 'player_screen.dart';

const int _episodesPerRange = 100;

/// A title's page: poster and synopsis, SUB/DUB, season buttons and a number
/// grid of episodes. Opened from any module card.
class ModuleTitleScreen extends StatefulWidget {
  const ModuleTitleScreen({
    super.key,
    required this.runtime,
    required this.module,
    required this.card,
  });

  final LuminaModuleRuntime runtime;
  final InstalledModule module;

  /// The card that was tapped (search result, rail item, favourite...).
  final dynamic card;

  @override
  State<ModuleTitleScreen> createState() => _ModuleTitleScreenState();
}

class _ModuleTitleScreenState extends State<ModuleTitleScreen> {
  // Remembered for the app session so SUB/DUB carries across titles.
  static String _lastMode = 'sub';

  final _numberController = TextEditingController();

  bool _loading = true;
  String? _error;

  String _href = '';
  String _title = '';
  String _poster = '';
  String _description = '';
  String _year = '';

  List<dynamic> _episodes = const [];
  List<EpisodeInfo> _infos = const [];
  List<String> _seasons = const [];
  String _season = '';
  int _range = 0;
  String _mode = _lastMode;
  ModuleHistoryEntry? _last;
  bool _descriptionOpen = false;

  // Languages this module offers, and which episodes have which one. Modules
  // rarely list that per episode, so for languages other than the first the
  // visible episodes are asked for a stream in that language (results cached).
  List<ModuleLanguage> _languages = const [];
  final Map<String, bool> _langOk = {};
  final Map<String, List<EpisodeInfo>> _seasonCache = {};
  int _probeToken = 0;
  int _probeDone = 0;
  int _probeTotal = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _probeToken++;
    _numberController.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- language

  bool get _isDefaultLanguage => _languages.isEmpty || _mode == _languages.first.id;

  String get _languageName => languageLabel(_mode);

  /// true = available in the chosen language, false = not, null = not known yet.
  bool? _languageStatus(EpisodeInfo info) =>
      _langOk['$_mode|${info.href}'] ?? episodeHasLanguage(_episodes[info.index], _mode);

  /// The first language lists everything (minus episodes known to lack it);
  /// any other language lists only episodes confirmed to have it.
  bool _shown(EpisodeInfo info) {
    final status = _languageStatus(info);
    return _isDefaultLanguage ? status != false : status == true;
  }

  bool get _probing => _probeDone < _probeTotal;

  /// The episodes whose availability matters right now: the open range, or the
  /// ones matching the number search.
  List<EpisodeInfo> _probeTargets() {
    final season = _inSeason(_season);
    final query = _numberController.text.trim();
    if (query.isNotEmpty) {
      return season.where((e) => e.number.toString().contains(query)).take(40).toList();
    }
    final start = _range * _episodesPerRange;
    if (start >= season.length) return const [];
    final end = start + _episodesPerRange > season.length
        ? season.length
        : start + _episodesPerRange;
    return season.sublist(start, end);
  }

  Future<void> _ensureLanguage() async {
    final token = ++_probeToken;
    final language = _mode;
    if (_isDefaultLanguage || _episodes.isEmpty) {
      if (mounted && _probeTotal != 0) {
        setState(() {
          _probeDone = 0;
          _probeTotal = 0;
        });
      }
      return;
    }
    final pending = _probeTargets()
        .where((e) => e.href.isNotEmpty && _languageStatus(e) == null)
        .toList();
    if (!mounted) return;
    setState(() {
      _probeDone = 0;
      _probeTotal = pending.length;
    });
    if (pending.isEmpty) return;

    var next = 0;
    Future<void> worker() async {
      while (token == _probeToken && next < pending.length) {
        final info = pending[next++];
        bool? ok;
        try {
          // Goes through the shared stream cache, so tapping an episode that
          // was just checked starts without another module call.
          final bundle = await ModuleStreamResolver.resolve(
            widget.runtime,
            widget.module,
            info.href,
            language,
            timeout: const Duration(seconds: 30),
          );
          ok = !bundle.isEmpty;
        } catch (_) {
          // A network error is not proof the language is missing: leave it unknown.
          ok = null;
        }
        if (token != _probeToken || !mounted) return;
        final result = ok;
        setState(() {
          if (result != null) _langOk['$language|${info.href}'] = result;
          _probeDone++;
        });
      }
    }

    // Two at a time, so the module stays free for whatever the user taps next.
    await Future.wait([worker(), worker()]);
  }

  // ------------------------------------------------------------- download

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<ModuleStream?> _pickStream(ModuleStreamBundle bundle) {
    return showModalBottomSheet<ModuleStream>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Download source', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final stream in bundle.streams)
                    ListTile(
                      title: Text(stream.label),
                      onTap: () => Navigator.pop(sheetContext, stream),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<HlsVariant?> _pickVariant(List<HlsVariant> variants) {
    return showModalBottomSheet<HlsVariant>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('Download quality', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Lower quality downloads faster and takes less space.'),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final variant in variants)
                    ListTile(
                      title: Text(variant.label),
                      subtitle: variant.bandwidth > 0
                          ? Text('${(variant.bandwidth / 1000000).toStringAsFixed(1)} Mbps')
                          : null,
                      onTap: () => Navigator.pop(sheetContext, variant),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _download(EpisodeInfo info) async {
    final downloads = context.read<DownloadService>();
    final mode = _mode;
    _snack('Preparing episode ${info.number}…');
    try {
      final bundle = await ModuleStreamResolver.resolve(
        widget.runtime,
        widget.module,
        info.href,
        mode,
      );
      if (bundle.isEmpty) {
        _snack('The module did not return a downloadable stream for episode ${info.number}.');
        return;
      }
      var stream = bundle.streams.first;
      if (bundle.streams.length > 1) {
        if (!mounted) return;
        final picked = await _pickStream(bundle);
        if (picked == null) return;
        stream = picked;
      }

      // Most modules return one HLS playlist that lists several qualities:
      // read it so the choice can be made here.
      var url = stream.url;
      var quality = stream.label;
      final variants = await DownloadService.fetchHlsVariants(url, stream.headers);
      var onlyOneQuality = bundle.streams.length == 1;
      if (variants.length > 1) {
        onlyOneQuality = false;
        if (!mounted) return;
        final picked = await _pickVariant(variants);
        if (picked == null) return;
        if (picked.separateAudio) {
          _snack('That stream keeps its audio in a separate track, which downloads cannot merge yet.');
          return;
        }
        url = picked.url;
        quality = picked.label;
      } else if (variants.length == 1) {
        if (variants.first.separateAudio) {
          _snack('That stream keeps its audio in a separate track, which downloads cannot merge yet.');
          return;
        }
        url = variants.first.url;
        quality = variants.first.label;
      }

      final episode = _episodes[info.index];
      var episodeTitle = moduleText(episode, const ['title', 'name']);
      if (episodeTitle.isEmpty) episodeTitle = 'Episode ${info.number}';
      await downloads.start(
        moduleId: widget.module.id,
        titleHref: _href,
        title: _title,
        image: _poster,
        episodeHref: info.href,
        episodeTitle: episodeTitle,
        episodeNumber: info.number,
        mode: mode,
        quality: quality,
        url: url,
        headers: stream.headers,
      );
      _snack(
        onlyOneQuality
            ? 'Downloading episode ${info.number}. This one only offers a single quality. Progress is on the Downloads tab.'
            : 'Downloading episode ${info.number} ($quality). Progress is on the Downloads tab.',
      );
    } catch (e) {
      _snack('Could not start the download: $e');
    }
  }

  void _playDownloaded(DownloadItem item) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(
        item: MediaItem(
          id: 'download:${item.id}',
          title: '$_title · ${item.episodeTitle}',
          path: item.filePath,
          type: MediaType.video,
          dateAdded: DateTime.fromMillisecondsSinceEpoch(item.createdAt),
        ),
      ),
    ));
  }

  String _field(dynamic details, List<String> keys) {
    final fromDetails = moduleText(details, keys);
    return fromDetails.isNotEmpty ? fromDetails : moduleText(widget.card, keys);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _href = moduleText(widget.card, const ['href', 'url', 'id', 'link']);
      if (_href.isEmpty) throw StateError('This result does not include a title reference.');

      // Details and episodes are independent: ask for both at once.
      final detailsFuture = widget.runtime
          .call(widget.module, 'extractDetails', [_href])
          .timeout(const Duration(seconds: 20))
          .then<dynamic>((v) => v, onError: (_) => null);
      final episodesFuture = widget.runtime
          .call(widget.module, 'extractEpisodes', [_href])
          .timeout(const Duration(seconds: 45));
      episodesFuture.then<void>((_) {}, onError: (_) {});
      dynamic details = await detailsFuture;
      if (details is List && details.isNotEmpty) details = details.first;

      _title = _field(details, const ['title', 'name']);
      if (_title.isEmpty) _title = 'Untitled';
      _poster = _field(details, const ['image', 'poster', 'posterUrl', 'imageUrl', 'cover']);
      _description = _field(details, const ['description', 'synopsis', 'summary', 'overview']);
      _year = _field(details, const ['year', 'released', 'date']);

      final value = await episodesFuture;
      final episodes = value is List ? value : const <dynamic>[];
      if (episodes.isEmpty) {
        throw StateError('${widget.module.name} returned no episodes for $_title.');
      }
      _episodes = episodes;
      _seasonCache.clear();
      _langOk.clear();
      _infos = describeEpisodes(episodes);
      final seen = <String>[];
      for (final info in _infos) {
        if (!seen.contains(info.season)) seen.add(info.season);
      }
      _seasons = seen;
      if (!mounted) return;
      _languages = languagesFor(widget.module, episodes);
      if (!_languages.any((l) => l.id == _mode)) _mode = _languages.first.id;
      _refreshLast();
      _selectLastWatched();
      // The episode you are most likely to tap is the one you stopped on.
      final resume = _last;
      if (resume != null) {
        ModuleStreamResolver.prefetch(widget.runtime, widget.module, resume.episodeHref, _mode);
      }

      if (!mounted) return;
      setState(() => _loading = false);
      unawaited(_ensureLanguage());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst(RegExp(r'^(Bad state|Exception):\s*'), '');
      });
    }
  }

  void _refreshLast() {
    final key = '${widget.module.id}|$_href';
    ModuleHistoryEntry? found;
    for (final entry in context.read<ModuleStateService>().continueWatching) {
      if (entry.key == key) found = entry;
    }
    _last = found;
  }

  /// Opens on the season and range that contain the episode last watched.
  void _selectLastWatched() {
    _season = _seasons.first;
    _range = 0;
    final last = _last;
    if (last == null) return;
    for (final season in _seasons) {
      final list = _inSeason(season);
      final at = list.indexWhere((e) => e.href == last.episodeHref);
      if (at >= 0) {
        _season = season;
        _range = at ~/ _episodesPerRange;
        return;
      }
    }
  }

  List<EpisodeInfo> _inSeason(String season) => _seasonCache.putIfAbsent(
        season,
        () => _infos.where((e) => e.season == season).toList(),
      );

  Future<void> _play(EpisodeInfo info) async {
    final last = _last;
    final resume = (last != null && last.episodeHref == info.href) ? last.positionMs : 0;
    // Leave the module free for the episode being opened.
    _probeToken++;
    _probeDone = 0;
    _probeTotal = 0;
    await openModulePlayer(
      context,
      runtime: widget.runtime,
      module: widget.module,
      titleHref: _href,
      title: _title,
      image: _poster,
      episodes: _episodes,
      index: info.index,
      resumeAtMs: resume,
      mode: _mode,
    );
    if (!mounted) return;
    setState(_refreshLast);
    unawaited(_ensureLanguage());
  }

  void _setMode(String mode) {
    setState(() => _mode = mode);
    _lastMode = mode;
    ModuleStreamResolver.lastLanguage[widget.module.id] = mode;
    unawaited(_ensureLanguage());
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    // Watched marks and download progress repaint the episode grid.
    final stateService = context.watch<ModuleStateService>();
    final downloads = context.watch<DownloadService>();
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _title.isEmpty ? widget.module.name : _title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _errorView()
              : _content(context, stateService, downloads),
    );
  }

  Widget _errorView() {
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

  Widget _content(
    BuildContext context,
    ModuleStateService stateService,
    DownloadService downloads,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final width = MediaQuery.of(context).size.width;
    final columns = ((width - 32) / 88).floor().clamp(3, 8).toInt();

    final seasonEpisodes = _inSeason(_season);
    final ranges = <List<EpisodeInfo>>[
      for (var i = 0; i < seasonEpisodes.length; i += _episodesPerRange)
        seasonEpisodes.sublist(
          i,
          i + _episodesPerRange > seasonEpisodes.length ? seasonEpisodes.length : i + _episodesPerRange,
        ),
    ];
    final rangeIndex = ranges.isEmpty ? 0 : _range.clamp(0, ranges.length - 1).toInt();
    final query = _numberController.text.trim();
    final candidates = query.isNotEmpty
        ? seasonEpisodes.where((e) => e.number.toString().contains(query)).toList()
        : (ranges.isEmpty ? <EpisodeInfo>[] : ranges[rangeIndex]);
    // Other than the first language, only episodes confirmed to have it show.
    final languageMode = !_isDefaultLanguage;
    final visible = candidates.where(_shown).toList();

    String rangeLabel(List<EpisodeInfo> r) => '${r.first.number}-${r.last.number}';

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _posterImage(scheme),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_title, style: textTheme.titleLarge),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          Chip(label: Text(widget.module.name), visualDensity: VisualDensity.compact),
                          if (_year.isNotEmpty)
                            Chip(label: Text(_year), visualDensity: VisualDensity.compact),
                          Chip(
                            label: Text('${_infos.length} episodes'),
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
                onTap: () => setState(() => _descriptionOpen = !_descriptionOpen),
                child: Text(
                  _description,
                  maxLines: _descriptionOpen ? null : 4,
                  overflow: _descriptionOpen ? TextOverflow.visible : TextOverflow.ellipsis,
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
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Icon(Icons.translate, color: scheme.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final lang in _languages)
                          ChoiceChip(
                            label: Text(lang.label),
                            selected: _mode == lang.id,
                            showCheckmark: false,
                            onSelected: (_) => _setMode(lang.id),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_seasons.length > 1)
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
                    children: [for (final season in _seasons) _seasonButton(season, scheme)],
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
                                  child: Text('EPS: ${rangeLabel(ranges[i])}'),
                                ),
                            ],
                            onChanged: (value) {
                              if (value == null) return;
                              setState(() {
                                _range = value;
                                _numberController.clear();
                              });
                              unawaited(_ensureLanguage());
                            },
                          )
                        else if (ranges.isNotEmpty)
                          Text('EPS: ${rangeLabel(ranges.first)}'),
                      ],
                    ),
                    SizedBox(
                      width: 180,
                      child: TextField(
                        controller: _numberController,
                        keyboardType: TextInputType.number,
                        onChanged: (_) {
                          setState(() {});
                          unawaited(_ensureLanguage());
                        },
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
        if (languageMode)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _probing
                        ? 'Checking which episodes have $_languageName… $_probeDone/$_probeTotal'
                        : '${visible.length} episode${visible.length == 1 ? '' : 's'} in $_languageName here',
                    style: textTheme.bodySmall,
                  ),
                  if (_probing) ...[
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: _probeTotal == 0 ? null : _probeDone / _probeTotal,
                    ),
                  ],
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
                        _probing
                            ? 'Checking…'
                            : languageMode
                                ? (query.isEmpty
                                    ? 'No episodes in $_languageName in this range.'
                                    : 'No $_languageName episode matches "$query".')
                                : (query.isEmpty ? 'No episodes.' : 'No episode matches "$query".'),
                      ),
                    ),
                  ),
                )
              : SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 2.1,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) =>
                        _episodeTile(visible[index], scheme, stateService, downloads),
                    childCount: visible.length,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _posterImage(ColorScheme scheme) {
    final placeholder = Container(
      width: 100,
      height: 145,
      color: scheme.surfaceContainerHighest,
      child: const Icon(Icons.movie_outlined, size: 36),
    );
    final image = _poster.startsWith('http://') || _poster.startsWith('https://')
        ? Image.network(
            _poster,
            width: 100,
            height: 145,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => placeholder,
          )
        : placeholder;
    return ClipRRect(borderRadius: BorderRadius.circular(8), child: image);
  }

  Widget _seasonButton(String season, ColorScheme scheme) {
    final selected = season == _season;
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: selected ? scheme.primary : scheme.onSurface,
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 1.6 : 1,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      onPressed: () {
        setState(() {
          _season = season;
          _range = 0;
          _numberController.clear();
        });
        unawaited(_ensureLanguage());
      },
      child: Text(seasonLabel(season), style: const TextStyle(fontWeight: FontWeight.w600)),
    );
  }

  Widget _downloadButton(EpisodeInfo info, DownloadService downloads, ColorScheme scheme) {
    final item = downloads.find(widget.module.id, info.href, _mode);
    Widget icon;
    VoidCallback onTap;
    String tooltip;
    if (item != null && item.state == DownloadState.downloading) {
      icon = SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(value: item.progress, strokeWidth: 2),
      );
      onTap = () => downloads.remove(item.id);
      tooltip = 'Cancel download';
    } else if (item != null && item.state == DownloadState.done) {
      icon = Icon(Icons.download_done, size: 18, color: scheme.primary);
      onTap = () => _playDownloaded(item);
      tooltip = 'Play downloaded episode';
    } else {
      icon = const Icon(Icons.download_outlined, size: 18);
      onTap = () => _download(info);
      tooltip = 'Download episode';
    }
    return SizedBox(
      width: 34,
      height: 34,
      child: IconButton(
        padding: EdgeInsets.zero,
        tooltip: tooltip,
        icon: icon,
        onPressed: onTap,
      ),
    );
  }

  Widget _episodeTile(
    EpisodeInfo info,
    ColorScheme scheme,
    ModuleStateService stateService,
    DownloadService downloads,
  ) {
    final isLast = _last != null && _last!.episodeHref == info.href;
    final watched = stateService.isWatched(widget.module.id, _href, info.href);
    // Watched episodes are dimmed and get a check mark; the one you stopped on
    // keeps the strong highlight.
    final dim = watched && !isLast;
    final textColor = isLast
        ? scheme.onSurface
        : (dim ? scheme.onSurfaceVariant.withAlpha(110) : scheme.onSurfaceVariant);
    return Material(
      color: isLast
          ? scheme.onSurface.withAlpha(70)
          : (dim
              ? scheme.surfaceContainerHighest.withAlpha(110)
              : scheme.surfaceContainerHighest),
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _play(info),
        onLongPress: () {
          stateService.toggleWatched(widget.module.id, _href, info.href);
          _snack(watched
              ? 'Episode ${info.number} marked as not watched.'
              : 'Episode ${info.number} marked as watched.');
        },
        child: Row(
          children: [
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (watched) ...[
                    Icon(Icons.check_circle, size: 14, color: scheme.primary.withAlpha(dim ? 150 : 255)),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    '${info.number}',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: isLast ? FontWeight.w800 : FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                ],
              ),
            ),
            _downloadButton(info, downloads, scheme),
          ],
        ),
      ),
    );
  }
}
