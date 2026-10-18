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

  // DUB availability per episode href. Modules do not list which episodes are
  // dubbed, so in DUB mode the visible episodes are asked for a dub stream.
  final Map<String, bool> _dubOk = {};
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

  // ------------------------------------------------------------------ dub

  /// What the module itself says about dub availability, if anything.
  bool? _declaredDub(dynamic episode) {
    if (episode is! Map) return null;
    for (final key in const ['hasDub', 'dub', 'dubbed', 'isDubbed', 'dubAvailable']) {
      final raw = episode[key];
      if (raw is bool) return raw;
      if (raw is num) return raw != 0;
      if (raw is String) {
        final t = raw.trim().toLowerCase();
        if (t == 'true' || t == 'yes' || t == '1') return true;
        if (t == 'false' || t == 'no' || t == '0') return false;
      }
    }
    for (final key in const ['audio', 'audios', 'languages']) {
      final raw = episode[key];
      if (raw == null) continue;
      final text = raw.toString().trim().toLowerCase();
      if (text.isEmpty) continue;
      return text.contains('dub');
    }
    return null;
  }

  /// true = dubbed, false = not dubbed, null = not known yet.
  bool? _dubStatus(EpisodeInfo info) =>
      _dubOk[info.href] ?? _declaredDub(_episodes[info.index]);

  bool get _probing => _probeDone < _probeTotal;

  /// The episodes whose dub status matters right now: the open range, or the
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

  Future<void> _ensureDub() async {
    final token = ++_probeToken;
    if (_mode != 'dub' || _episodes.isEmpty) {
      if (mounted && _probeTotal != 0) {
        setState(() {
          _probeDone = 0;
          _probeTotal = 0;
        });
      }
      return;
    }
    final pending = _probeTargets()
        .where((e) => e.href.isNotEmpty && _dubStatus(e) == null)
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
          final value = await widget.runtime
              .call(widget.module, 'extractStreamUrl', [info.href, 'dub', false])
              .timeout(const Duration(seconds: 30));
          ok = !parseModuleStreams(value).isEmpty;
        } catch (_) {
          // A network error is not proof the dub is missing: leave it unknown.
          ok = null;
        }
        if (token != _probeToken || !mounted) return;
        final result = ok;
        setState(() {
          if (result != null) _dubOk[info.href] = result;
          _probeDone++;
        });
      }
    }

    await Future.wait([worker(), worker(), worker()]);
  }

  // ------------------------------------------------------------- download

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<ModuleStream?> _pickQuality(ModuleStreamBundle bundle) {
    return showModalBottomSheet<ModuleStream>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Download quality', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
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

  Future<void> _download(EpisodeInfo info) async {
    final downloads = context.read<DownloadService>();
    final mode = _mode;
    _snack('Preparing episode ${info.number}…');
    try {
      final value = await widget.runtime
          .call(widget.module, 'extractStreamUrl', [info.href, mode, false])
          .timeout(const Duration(seconds: 45));
      final bundle = parseModuleStreams(value);
      if (bundle.isEmpty) {
        _snack('The module did not return a downloadable stream for episode ${info.number}.');
        return;
      }
      var stream = bundle.streams.first;
      if (bundle.streams.length > 1) {
        if (!mounted) return;
        final picked = await _pickQuality(bundle);
        if (picked == null) return;
        stream = picked;
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
        quality: stream.label,
        url: stream.url,
        headers: stream.headers,
      );
      _snack('Downloading episode ${info.number}. Progress is on the Downloads tab.');
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

      dynamic details;
      try {
        details = await widget.runtime
            .call(widget.module, 'extractDetails', [_href])
            .timeout(const Duration(seconds: 20));
      } catch (_) {
        details = null;
      }
      if (details is List && details.isNotEmpty) details = details.first;

      _title = _field(details, const ['title', 'name']);
      if (_title.isEmpty) _title = 'Untitled';
      _poster = _field(details, const ['image', 'poster', 'posterUrl', 'imageUrl', 'cover']);
      _description = _field(details, const ['description', 'synopsis', 'summary', 'overview']);
      _year = _field(details, const ['year', 'released', 'date']);

      final value = await widget.runtime
          .call(widget.module, 'extractEpisodes', [_href])
          .timeout(const Duration(seconds: 45));
      final episodes = value is List ? value : const <dynamic>[];
      if (episodes.isEmpty) {
        throw StateError('${widget.module.name} returned no episodes for $_title.');
      }
      _episodes = episodes;
      _infos = describeEpisodes(episodes);
      final seen = <String>[];
      for (final info in _infos) {
        if (!seen.contains(info.season)) seen.add(info.season);
      }
      _seasons = seen;
      if (!mounted) return;
      _refreshLast();
      _selectLastWatched();

      if (!mounted) return;
      setState(() => _loading = false);
      unawaited(_ensureDub());
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

  List<EpisodeInfo> _inSeason(String season) =>
      _infos.where((e) => e.season == season).toList();

  Future<void> _play(EpisodeInfo info) async {
    final last = _last;
    final resume = (last != null && last.episodeHref == info.href) ? last.positionMs : 0;
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
  }

  void _setMode(String mode) {
    setState(() => _mode = mode);
    _lastMode = mode;
    unawaited(_ensureDub());
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
    // In DUB mode only episodes that really have a dub are listed.
    final dubMode = _mode == 'dub';
    final visible = dubMode
        ? candidates.where((e) => _dubStatus(e) == true).toList()
        : candidates;

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
              child: Column(
                children: [
                  _audioRow(Icons.closed_caption, 'SUB', 'sub'),
                  const Divider(height: 24),
                  _audioRow(Icons.mic, 'DUB', 'dub'),
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
                              unawaited(_ensureDub());
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
                          unawaited(_ensureDub());
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
        if (dubMode)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _probing
                        ? 'Checking which episodes are dubbed… $_probeDone/$_probeTotal'
                        : '${visible.length} dubbed episode${visible.length == 1 ? '' : 's'} here',
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
                            : dubMode
                                ? (query.isEmpty
                                    ? 'No dubbed episodes in this range.'
                                    : 'No dubbed episode matches "$query".')
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

  Widget _audioRow(IconData icon, String label, String value) {
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
          selected: _mode == value,
          showCheckmark: false,
          onSelected: (_) => _setMode(value),
        ),
      ],
    );
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
        unawaited(_ensureDub());
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
