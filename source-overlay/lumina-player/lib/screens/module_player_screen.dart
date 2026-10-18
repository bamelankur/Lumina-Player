import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../services/module_episodes.dart';
import '../services/module_state_service.dart';
import '../services/modules_service.dart';
import '../services/synthetiq_module_runtime.dart';

// ---------------------------------------------------------------------------
// Stream parsing
// ---------------------------------------------------------------------------

/// One playable URL a module returned (a quality / server / audio variant).
class ModuleStream {
  const ModuleStream({required this.url, required this.label, required this.headers});
  final String url;
  final String label;
  final Map<String, String> headers;
}

/// An external subtitle file a module returned.
class ModuleSubtitle {
  const ModuleSubtitle({required this.url, required this.label});
  final String url;
  final String label;
}

class ModuleStreamBundle {
  const ModuleStreamBundle({required this.streams, required this.subtitles});
  final List<ModuleStream> streams;
  final List<ModuleSubtitle> subtitles;
  bool get isEmpty => streams.isEmpty;
}

bool _isHttpUrl(String s) => s.startsWith('http://') || s.startsWith('https://');

String _pick(dynamic value, List<String> keys) {
  if (value is! Map) return value is String ? value : '';
  for (final key in keys) {
    final candidate = value[key];
    if (candidate != null && candidate.toString().trim().isNotEmpty) {
      return candidate.toString();
    }
  }
  return '';
}

Map<String, String>? _headersOf(Map value) {
  final raw = value['headers'] ?? value['streamHeaders'];
  if (raw is Map) {
    return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
  }
  return null;
}

String _labelOf(Map value) {
  for (final key in const ['quality', 'label', 'resolution', 'title', 'name', 'server']) {
    final candidate = value[key];
    if (candidate != null && candidate.toString().trim().isNotEmpty) {
      final text = candidate.toString().trim();
      return RegExp(r'^\d{3,4}$').hasMatch(text) ? '${text}p' : text;
    }
  }
  return '';
}

/// Understands the shapes modules return from their stream function: a URL
/// string, a list of them, `{url, headers}`, or wrappers such as
/// `{streams: [...], subtitles: ...}` / `{sources: [...]}`. The first stream
/// found is the same one the app has always played.
ModuleStreamBundle parseModuleStreams(dynamic value) {
  final streams = <ModuleStream>[];
  final subtitles = <ModuleSubtitle>[];
  final seenStreams = <String>{};
  final seenSubtitles = <String>{};

  void addStream(String url, String label, Map<String, String> headers) {
    if (!seenStreams.add(url)) return;
    streams.add(ModuleStream(
      url: url,
      label: label.isEmpty ? 'Stream ${streams.length + 1}' : label,
      headers: headers,
    ));
  }

  void addSubtitles(dynamic raw) {
    if (raw is String) {
      if (_isHttpUrl(raw) && seenSubtitles.add(raw)) {
        subtitles.add(ModuleSubtitle(url: raw, label: 'Subtitles ${subtitles.length + 1}'));
      }
    } else if (raw is List) {
      for (final item in raw) {
        addSubtitles(item);
      }
    } else if (raw is Map) {
      if ('${raw['kind']}'.toLowerCase() == 'thumbnails') return;
      var url = '';
      for (final key in const ['url', 'file', 'src', 'link']) {
        final candidate = raw[key];
        if (candidate is String && _isHttpUrl(candidate)) {
          url = candidate;
          break;
        }
      }
      if (url.isEmpty || !seenSubtitles.add(url)) return;
      var label = _pick(raw, const ['label', 'lang', 'language', 'name', 'title']);
      if (label.isEmpty) label = 'Subtitles ${subtitles.length + 1}';
      subtitles.add(ModuleSubtitle(url: url, label: label));
    }
  }

  void walk(dynamic v, Map<String, String> headers, String label) {
    if (v is String) {
      if (_isHttpUrl(v)) addStream(v, label, headers);
    } else if (v is List) {
      for (final item in v) {
        walk(item, headers, label);
      }
    } else if (v is Map) {
      final h = _headersOf(v) ?? headers;
      final own = _labelOf(v);
      final l = own.isNotEmpty ? own : label;
      for (final key in const ['subtitles', 'subtitle', 'tracks', 'captions']) {
        if (v.containsKey(key)) addSubtitles(v[key]);
      }
      for (final key in const ['url', 'file', 'src', 'streamUrl', 'stream_url', 'stream', 'link']) {
        final candidate = v[key];
        if (candidate is String && _isHttpUrl(candidate)) {
          addStream(candidate, l, h);
          break;
        }
      }
      for (final key in const ['streams', 'sources', 'data', 'result', 'links', 'qualities']) {
        if (v.containsKey(key)) walk(v[key], h, l);
      }
    }
  }

  walk(value, const {}, '');
  return ModuleStreamBundle(streams: streams, subtitles: subtitles);
}

// ---------------------------------------------------------------------------
// Entry points
// ---------------------------------------------------------------------------

/// Resolves the streams for `episodes[index]` and opens the player.
/// Completes when the player is closed.
Future<void> openModulePlayer(
  BuildContext context, {
  required LuminaModuleRuntime runtime,
  required InstalledModule module,
  required String titleHref,
  required String title,
  required String image,
  required List<dynamic> episodes,
  required int index,
  int resumeAtMs = 0,
  String mode = 'sub',
}) async {
  void notice(String text) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  final href = _pick(episodes[index], const ['href', 'url', 'id']);
  if (href.isEmpty) {
    notice('The selected episode has no playable reference.');
    return;
  }
  try {
    final value = await runtime
        .call(module, 'extractStreamUrl', [href, mode, false])
        .timeout(const Duration(seconds: 45));
    final bundle = parseModuleStreams(value);
    if (bundle.isEmpty) {
      notice('The module did not return a direct playable URL.');
      return;
    }
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ModulePlayerScreen(
        runtime: runtime,
        module: module,
        titleHref: titleHref,
        title: title,
        image: image,
        episodes: episodes,
        episodeIndex: index,
        initial: bundle,
        resumeAtMs: resumeAtMs,
        initialMode: mode,
      ),
    ));
  } catch (e) {
    notice('Could not open title: $e');
  }
}

/// Continues a title from Continue Watching: re-loads the episode list (stream
/// URLs expire, so the stream is always fetched fresh) and seeks to the saved
/// position.
Future<void> resumeModuleTitle(
  BuildContext context,
  LuminaModuleRuntime runtime,
  InstalledModule module,
  ModuleHistoryEntry entry,
) async {
  void notice(String text) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  try {
    final value = await runtime
        .call(module, 'extractEpisodes', [entry.titleHref])
        .timeout(const Duration(seconds: 45));
    final episodes = value is List ? value : const <dynamic>[];
    if (episodes.isEmpty) {
      notice('No episodes were returned for ${entry.title}.');
      return;
    }
    var index = episodes.indexWhere(
      (e) => _pick(e, const ['href', 'url', 'id']) == entry.episodeHref,
    );
    if (index < 0) {
      index = entry.episodeIndex < 0
          ? 0
          : (entry.episodeIndex >= episodes.length
              ? episodes.length - 1
              : entry.episodeIndex);
    }
    if (!context.mounted) return;
    await openModulePlayer(
      context,
      runtime: runtime,
      module: module,
      titleHref: entry.titleHref,
      title: entry.title,
      image: entry.image,
      episodes: episodes,
      index: index,
      resumeAtMs: entry.positionMs,
    );
  } catch (e) {
    notice('Could not resume: $e');
  }
}

// ---------------------------------------------------------------------------
// Player
// ---------------------------------------------------------------------------

class _Option {
  const _Option(this.label, this.selected, this.onTap);
  final String label;
  final bool selected;
  final VoidCallback onTap;
}

class ModulePlayerScreen extends StatefulWidget {
  const ModulePlayerScreen({
    super.key,
    required this.runtime,
    required this.module,
    required this.titleHref,
    required this.title,
    required this.image,
    required this.episodes,
    required this.episodeIndex,
    required this.initial,
    this.resumeAtMs = 0,
    this.initialMode = 'sub',
  });

  final LuminaModuleRuntime runtime;
  final InstalledModule module;
  final String titleHref;
  final String title;
  final String image;
  final List<dynamic> episodes;
  final int episodeIndex;
  final ModuleStreamBundle initial;
  final int resumeAtMs;
  final String initialMode;

  @override
  State<ModulePlayerScreen> createState() => _ModulePlayerScreenState();
}

class _ModulePlayerScreenState extends State<ModulePlayerScreen> {
  static const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  // Kept for the app session so the levels carry over between episodes.
  static double _brightness = 1.0;
  static double _volume = 1.0;

  // Android system media volume, driven through MainActivity (see lumina/volume).
  static const _volumeChannel = MethodChannel('lumina/volume');

  // The last quality and subtitle the user picked. Kept for the app session so
  // the next episode (and the next player) opens with the same choices.
  static String? _lastQualityLabel;
  static String? _lastSubtitleLabel;

  VideoPlayerController? _controller;
  late final ModuleStateService _state;
  late int _episodeIndex;
  late ModuleStreamBundle _bundle;
  // The module/title/episodes can change mid-playback ("Switch module").
  late InstalledModule _module;
  late String _titleHref;
  late List<dynamic> _episodes;
  String? _switching;
  bool _systemVolume = false;
  int _lastPositionMs = 0;
  int _streamIndex = 0;
  int _subIndex = -1;
  String _mode = 'sub';
  double _speed = 1.0;
  bool _controlsVisible = true;
  bool _loading = true;
  bool _opening = false;
  bool _endHandled = false;
  int? _dragMs;
  Object? _error;
  String? _probe;
  Timer? _hideTimer;
  Timer? _saveTimer;
  Offset _doubleTapAt = Offset.zero;

  // Swipe gestures: left half = brightness, right half = volume.
  String? _dragKind;
  double _dragBase = 0;
  double _dragStartY = 0;
  IconData? _hudIcon;
  String? _hudText;
  double? _hudValue;
  bool _hudOnLeft = true;
  Timer? _hudTimer;

  @override
  void initState() {
    super.initState();
    _state = context.read<ModuleStateService>();
    _module = widget.module;
    _titleHref = widget.titleHref;
    _episodes = widget.episodes;
    _mode = widget.initialMode;
    _episodeIndex = widget.episodeIndex;
    _bundle = widget.initial;
    // The player opens in landscape; the Rotate chip still flips to portrait.
    SystemChrome.setPreferredOrientations(
      const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
    );
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    unawaited(_syncSystemVolume());
    _subIndex = _matchSubtitle(_bundle);
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) => _saveProgress());
    _open(_pickStream(_bundle), startAtMs: widget.resumeAtMs);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _hudTimer?.cancel();
    _saveTimer?.cancel();
    _saveProgress();
    final c = _controller;
    c?.removeListener(_onTick);
    c?.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
    super.dispose();
  }

  // ----- helpers ----------------------------------------------------------

  void _notice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  // ----- remembered settings ------------------------------------------------

  int? _heightOf(String label) {
    final m = RegExp(r'(\d{3,4})').firstMatch(label);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// The stream that best matches the quality used last: same label if there
  /// is one, otherwise the closest resolution, otherwise the first stream.
  int _pickStream(ModuleStreamBundle bundle) {
    final wanted = _lastQualityLabel;
    if (wanted == null || bundle.streams.length < 2) return 0;
    final exact = bundle.streams.indexWhere((s) => s.label == wanted);
    if (exact >= 0) return exact;
    final target = _heightOf(wanted);
    if (target == null) return 0;
    var best = 0;
    var bestDiff = 1 << 30;
    for (var i = 0; i < bundle.streams.length; i++) {
      final h = _heightOf(bundle.streams[i].label);
      if (h == null) continue;
      final diff = (h - target).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        best = i;
      }
    }
    return best;
  }

  /// Index of the subtitle track with the label used last, or -1 (off).
  int _matchSubtitle(ModuleStreamBundle bundle) {
    final wanted = _lastSubtitleLabel;
    if (wanted == null) return -1;
    return bundle.subtitles.indexWhere((s) => s.label == wanted);
  }

  // ----- system volume --------------------------------------------------------

  Future<void> _syncSystemVolume() async {
    try {
      final v = await _volumeChannel.invokeMethod<double>('get');
      if (v != null) {
        _volume = v.clamp(0.0, 1.0).toDouble();
        _systemVolume = true;
        // The phone's volume now does the work; keep the player at full gain.
        await _controller?.setVolume(1.0);
      }
    } catch (_) {
      _systemVolume = false;
    }
  }

  Future<void> _setSystemVolume(double value) async {
    try {
      await _volumeChannel.invokeMethod<void>('set', {'value': value});
    } catch (_) {
      _systemVolume = false;
      await _controller?.setVolume(value);
    }
  }

  String _episodeLabel(int index) {
    final ep = _episodes[index];
    final label = _pick(ep, const ['title', 'name']);
    final season = _pick(ep, const ['season']);
    final base = label.isEmpty ? 'Episode ${index + 1}' : label;
    return season.isEmpty ? base : 'S$season · $base';
  }

  String _fmt(Duration d) {
    final total = d.inSeconds < 0 ? 0 : d.inSeconds;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  void _saveProgress() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final duration = c.value.duration.inMilliseconds;
    if (duration <= 0) return;
    final ep = _episodes[_episodeIndex];
    if (c.value.position.inMilliseconds / duration >= 0.9) {
      unawaited(_state.markWatched(
        _module.id,
        _titleHref,
        _pick(ep, const ['href', 'url', 'id']),
      ));
    }
    unawaited(_state.saveProgress(ModuleHistoryEntry(
      moduleId: _module.id,
      titleHref: _titleHref,
      title: widget.title,
      image: widget.image,
      episodeHref: _pick(ep, const ['href', 'url', 'id']),
      episodeTitle: _episodeLabel(_episodeIndex),
      episodeIndex: _episodeIndex,
      positionMs: c.value.position.inMilliseconds,
      durationMs: duration,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    )));
  }

  // ----- loading ----------------------------------------------------------

  Future<void> _open(int streamIndex, {int startAtMs = 0}) async {
    if (_opening) return;
    _opening = true;
    final stream = _bundle.streams[streamIndex];
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _probe = null;
      });
    }
    final next = VideoPlayerController.networkUrl(
      Uri.parse(stream.url),
      httpHeaders: stream.headers,
    );
    try {
      await next.initialize();
      if (!mounted) {
        await next.dispose();
        return;
      }
      if (startAtMs > 0) {
        await next.seekTo(Duration(milliseconds: startAtMs));
      }
      await next.setPlaybackSpeed(_speed);
      await next.setVolume(_systemVolume ? 1.0 : _volume);
      next.addListener(_onTick);
      final old = _controller;
      old?.removeListener(_onTick);
      setState(() {
        _controller = next;
        _streamIndex = streamIndex;
        _loading = false;
        _endHandled = false;
      });
      if (old != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      }
      await next.play();
      if (_subIndex >= 0) unawaited(_setSubtitle(_subIndex));
      _scheduleHide();
    } catch (e) {
      try {
        await next.dispose();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e;
        });
        unawaited(_runProbe(stream));
      }
    } finally {
      _opening = false;
    }
  }

  Future<void> _runProbe(ModuleStream stream) async {
    final lines = <String>['URL: ${stream.url}'];
    try {
      final res = await http
          .get(Uri.parse(stream.url), headers: {...stream.headers, 'Range': 'bytes=0-1023'})
          .timeout(const Duration(seconds: 15));
      final bytes = res.bodyBytes;
      final marker = bytes.length >= 8 ? String.fromCharCodes(bytes.sublist(4, 8)) : '(too short)';
      lines
        ..add('HTTP status: ${res.statusCode}')
        ..add('Content-Type: ${res.headers['content-type']}')
        ..add('Content-Length: ${res.headers['content-length']}')
        ..add('Bytes received: ${bytes.length}')
        ..add('File marker (bytes 4-8; MP4 says "ftyp"): $marker');
    } catch (e) {
      lines.add('Network test failed: $e');
    }
    if (mounted) setState(() => _probe = lines.join('\n'));
  }

  Future<ModuleStreamBundle> _fetchBundle(String episodeHref, String mode) async {
    final value = await widget.runtime
        .call(_module, 'extractStreamUrl', [episodeHref, mode, false])
        .timeout(const Duration(seconds: 45));
    return parseModuleStreams(value);
  }

  Future<void> _changeEpisode(int index) async {
    if (index < 0 || index >= _episodes.length || _opening) return;
    final href = _pick(_episodes[index], const ['href', 'url', 'id']);
    if (href.isEmpty) {
      _notice('That episode has no playable reference.');
      return;
    }
    _saveProgress();
    setState(() => _loading = true);
    try {
      final bundle = await _fetchBundle(href, _mode);
      if (!mounted) return;
      if (bundle.isEmpty) {
        setState(() => _loading = false);
        _notice('The module did not return a playable URL for that episode.');
        return;
      }
      _bundle = bundle;
      _episodeIndex = index;
      _subIndex = _matchSubtitle(bundle);
      _lastPositionMs = 0;
      await _open(_pickStream(bundle));
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _notice('Could not load episode: $e');
    }
  }

  Future<void> _setMode(String mode) async {
    if (mode == _mode || _opening) return;
    final href = _pick(_episodes[_episodeIndex], const ['href', 'url', 'id']);
    final position = _controller?.value.position.inMilliseconds ?? 0;
    setState(() => _loading = true);
    try {
      final bundle = await _fetchBundle(href, mode);
      if (!mounted) return;
      if (bundle.isEmpty) {
        setState(() => _loading = false);
        _notice('This module did not return a $mode stream for this episode.');
        return;
      }
      _mode = mode;
      _bundle = bundle;
      _subIndex = _matchSubtitle(bundle);
      await _open(_pickStream(bundle), startAtMs: position);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _notice('Could not switch to $mode: $e');
    }
  }

  Future<void> _setSubtitle(int index) async {
    final c = _controller;
    if (c == null) return;
    if (index < 0 || index >= _bundle.subtitles.length) {
      await c.setClosedCaptionFile(null);
      _lastSubtitleLabel = null;
      if (mounted) setState(() => _subIndex = -1);
      return;
    }
    final sub = _bundle.subtitles[index];
    final lower = sub.url.toLowerCase();
    if (lower.contains('.ass') || lower.contains('.ssa')) {
      _notice('ASS/SSA subtitles are not supported by this player yet.');
      return;
    }
    try {
      final headers = _bundle.streams[_streamIndex].headers;
      final res = await http
          .get(Uri.parse(sub.url), headers: headers)
          .timeout(const Duration(seconds: 15));
      if (res.statusCode >= 400) throw Exception('HTTP ${res.statusCode}');
      final ClosedCaptionFile file =
          lower.contains('.srt') ? SubRipCaptionFile(res.body) : WebVTTCaptionFile(res.body);
      await c.setClosedCaptionFile(Future<ClosedCaptionFile>.value(file));
      _lastSubtitleLabel = sub.label;
      if (mounted) setState(() => _subIndex = index);
    } catch (e) {
      _notice('Could not load subtitles: $e');
    }
  }

  // ----- playback ---------------------------------------------------------

  void _onTick() {
    if (!mounted) return;
    final c = _controller;
    if (c != null) {
      final v = c.value;
      if (v.isInitialized && v.position.inMilliseconds > 0) {
        _lastPositionMs = v.position.inMilliseconds;
      }
      if (v.isInitialized &&
          v.duration > Duration.zero &&
          v.position >= v.duration &&
          !v.isPlaying &&
          !_endHandled) {
        _endHandled = true;
        unawaited(_onEnded());
      }
    }
    setState(() {});
  }

  Future<void> _onEnded() async {
    await _state.markWatched(
      _module.id,
      _titleHref,
      _pick(_episodes[_episodeIndex], const ['href', 'url', 'id']),
    );
    final key = '${_module.id}|${_titleHref}';
    await _state.removeHistory(key);
    if (_episodeIndex + 1 < _episodes.length) {
      await _changeEpisode(_episodeIndex + 1);
    } else if (mounted) {
      setState(() => _controlsVisible = true);
    }
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      c.pause();
      _hideTimer?.cancel();
    } else {
      c.play();
      _scheduleHide();
    }
  }

  Future<void> _seekBy(int seconds) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final target = c.value.position + Duration(seconds: seconds);
    final max = c.value.duration;
    final clamped = target < Duration.zero ? Duration.zero : (target > max ? max : target);
    await c.seekTo(clamped);
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && (_controller?.value.isPlaying ?? false)) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  Future<void> _toggleRotate() async {
    final portrait = MediaQuery.of(context).orientation == Orientation.portrait;
    if (portrait) {
      await SystemChrome.setPreferredOrientations(
        const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
      );
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
    }
  }

  Future<void> _showSheet(String title, List<_Option> options) {
    _hideTimer?.cancel();
    return showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(title, style: Theme.of(sheetContext).textTheme.titleMedium),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final option in options)
                      ListTile(
                        title: Text(option.label),
                        trailing: option.selected ? const Icon(Icons.check) : null,
                        onTap: () {
                          Navigator.pop(sheetContext);
                          option.onTap();
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ).whenComplete(_scheduleHide);
  }

  void _showAudio() => _showSheet('Audio', [
        _Option('Sub', _mode == 'sub', () => _setMode('sub')),
        _Option('Dub', _mode == 'dub', () => _setMode('dub')),
      ]);

  void _showQuality() => _showSheet('Quality / stream', [
        for (var i = 0; i < _bundle.streams.length; i++)
          _Option(_bundle.streams[i].label, i == _streamIndex, () {
            if (i == _streamIndex) return;
            _lastQualityLabel = _bundle.streams[i].label;
            _open(i, startAtMs: _controller?.value.position.inMilliseconds ?? 0);
          }),
      ]);

  void _showSubtitles() {
    if (_bundle.subtitles.isEmpty) {
      _notice('This module did not return any subtitle files for this episode.');
      return;
    }
    _showSheet('Subtitles', [
      _Option('Off', _subIndex < 0, () => _setSubtitle(-1)),
      for (var i = 0; i < _bundle.subtitles.length; i++)
        _Option(_bundle.subtitles[i].label, i == _subIndex, () => _setSubtitle(i)),
    ]);
  }

  void _showSpeed() => _showSheet('Playback speed', [
        for (final s in _speeds)
          _Option(s == 1.0 ? 'Normal' : '${s}x', s == _speed, () {
            setState(() => _speed = s);
            _controller?.setPlaybackSpeed(s);
          }),
      ]);

  // ----- switch module ------------------------------------------------------

  int _currentPositionMs() {
    final c = _controller;
    if (c != null && c.value.isInitialized) return c.value.position.inMilliseconds;
    return _lastPositionMs;
  }

  void _showModules() {
    final modules = context
        .read<ModulesService>()
        .installed
        .where((m) => m.contentType.toLowerCase() == 'video')
        .toList();
    final at = _fmt(Duration(milliseconds: _currentPositionMs()));
    _showSheet('Switch module · resumes at $at', [
      for (final m in modules)
        _Option(
          m.id == _module.id ? '${m.name} (current, reload)' : m.name,
          m.id == _module.id,
          () => m.id == _module.id ? _reloadEpisode() : _switchModule(m),
        ),
    ]);
  }

  /// Reloads the current episode from the current module, fresh stream URL,
  /// same position.
  Future<void> _reloadEpisode() async {
    if (_opening || _switching != null) return;
    final href = _pick(_episodes[_episodeIndex], const ['href', 'url', 'id']);
    final position = _currentPositionMs();
    _controller?.pause();
    setState(() => _switching = 'Reloading from ${_module.name}…');
    try {
      final bundle = await _fetchBundle(href, _mode);
      if (!mounted) return;
      if (bundle.isEmpty) {
        throw StateError('${_module.name} did not return a playable link.');
      }
      _bundle = bundle;
      _subIndex = _matchSubtitle(bundle);
      setState(() => _switching = null);
      await _open(_pickStream(bundle), startAtMs: position);
    } catch (e) {
      if (!mounted) return;
      setState(() => _switching = null);
      _notice('Could not reload: $e');
    }
  }

  /// Finds this title and episode on [target] and carries on from the same
  /// position. If anything fails the current stream is left as it was.
  Future<void> _switchModule(InstalledModule target) async {
    if (_opening || _switching != null) return;
    final position = _currentPositionMs();
    final current = _controller;
    final wasPlaying = current != null && current.value.isInitialized && current.value.isPlaying;
    final currentInfo = describeEpisodes(_episodes)[_episodeIndex];
    current?.pause();
    _saveProgress();
    setState(() => _switching = 'Finding "${widget.title}" on ${target.name}…');
    try {
      final found = await widget.runtime
          .call(target, 'searchResults', [widget.title])
          .timeout(const Duration(seconds: 30));
      final match = bestTitleMatch(widget.title, found is List ? found : const <dynamic>[]);
      if (match == null) {
        throw StateError('${target.name} has no close match for "${widget.title}".');
      }
      final newTitleHref = _pick(match, const ['href', 'url', 'id', 'link']);
      if (newTitleHref.isEmpty) {
        throw StateError('${target.name} returned a match without a reference.');
      }

      if (mounted) setState(() => _switching = 'Finding episode ${currentInfo.number}…');
      final episodeValue = await widget.runtime
          .call(target, 'extractEpisodes', [newTitleHref])
          .timeout(const Duration(seconds: 30));
      final newEpisodes = episodeValue is List ? episodeValue : const <dynamic>[];
      if (newEpisodes.isEmpty) {
        throw StateError('${target.name} returned no episodes for this title.');
      }
      final index = matchEpisodeIndex(
        describeEpisodes(newEpisodes),
        currentInfo.season,
        currentInfo.number,
      );
      if (index < 0) {
        throw StateError('Episode ${currentInfo.number} was not found on ${target.name}.');
      }

      if (mounted) setState(() => _switching = 'Loading the stream from ${target.name}…');
      final episodeHref = _pick(newEpisodes[index], const ['href', 'url', 'id']);
      final value = await widget.runtime
          .call(target, 'extractStreamUrl', [episodeHref, _mode, false])
          .timeout(const Duration(seconds: 45));
      final bundle = parseModuleStreams(value);
      if (bundle.isEmpty) {
        throw StateError('${target.name} did not return a playable link.');
      }
      if (!mounted) return;

      _module = target;
      _titleHref = newTitleHref;
      _episodes = newEpisodes;
      _episodeIndex = index;
      _bundle = bundle;
      _subIndex = _matchSubtitle(bundle);
      setState(() => _switching = null);
      await _open(_pickStream(bundle), startAtMs: position);
    } catch (e) {
      if (!mounted) return;
      setState(() => _switching = null);
      final reason = e.toString().replaceFirst(RegExp(r'^(Bad state|Exception):\s*'), '');
      _notice('Could not switch to ${target.name}: $reason');
      if (wasPlaying && _error == null) current?.play();
    }
  }

  // ----- brightness / volume gestures ---------------------------------------

  void _onDragStart(DragStartDetails details, Size size) {
    final left = details.localPosition.dx < size.width / 2;
    _dragKind = left ? 'brightness' : 'volume';
    _dragBase = left ? _brightness : _volume;
    _dragStartY = details.localPosition.dy;
    if (!left) {
      // The hardware volume keys may have moved the level since last time.
      _syncSystemVolume().then((_) {
        if (_dragKind == 'volume') _dragBase = _volume;
      });
    }
  }

  void _onDragUpdate(DragUpdateDetails details, Size size) {
    final kind = _dragKind;
    if (kind == null) return;
    final delta = (_dragStartY - details.localPosition.dy) / (size.height * 0.7);
    final value = (_dragBase + delta).clamp(0.0, 1.0).toDouble();
    if (kind == 'brightness') {
      _brightness = value;
    } else {
      _volume = value;
      if (_systemVolume) {
        unawaited(_setSystemVolume(value));
      } else {
        _controller?.setVolume(value);
      }
    }
    _showHud(kind, value);
  }

  void _onDragEnd() {
    _dragKind = null;
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _hudText = null);
    });
  }

  void _showHud(String kind, double value) {
    _hudTimer?.cancel();
    setState(() {
      _hudOnLeft = kind == 'brightness';
      _hudValue = value;
      _hudText = '${(value * 100).round()}%';
      _hudIcon = kind == 'brightness'
          ? (value > 0.5 ? Icons.brightness_high : Icons.brightness_low)
          : (value == 0
              ? Icons.volume_off
              : (value < 0.5 ? Icons.volume_down : Icons.volume_up));
    });
  }

  Widget _hud() {
    return IgnorePointer(
      child: Align(
        alignment: _hudOnLeft ? const Alignment(-0.75, 0) : const Alignment(0.75, 0),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xAA000000),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_hudIcon, color: Colors.white, size: 30),
              const SizedBox(height: 6),
              SizedBox(
                width: 80,
                child: LinearProgressIndicator(
                  value: _hudValue,
                  backgroundColor: Colors.white24,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _hudText ?? '',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _switchingOverlay() {
    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xB3000000),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 14),
                Text(
                  _switching ?? '',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ----- UI ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_error != null) return _errorView();
    final c = _controller;
    final buffering = c != null && c.value.isInitialized && c.value.isBuffering;
    final caption = (c != null && c.value.isInitialized && _subIndex >= 0)
        ? c.value.caption.text
        : '';
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleControls,
          onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
          onDoubleTap: () =>
              _seekBy(_doubleTapAt.dx < constraints.maxWidth / 2 ? -10 : 10),
          onVerticalDragStart: (d) =>
              _onDragStart(d, Size(constraints.maxWidth, constraints.maxHeight)),
          onVerticalDragUpdate: (d) =>
              _onDragUpdate(d, Size(constraints.maxWidth, constraints.maxHeight)),
          onVerticalDragEnd: (_) => _onDragEnd(),
          onVerticalDragCancel: _onDragEnd,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (c != null && c.value.isInitialized)
                Center(
                  child: AspectRatio(
                    aspectRatio: c.value.aspectRatio > 0 ? c.value.aspectRatio : 16 / 9,
                    child: VideoPlayer(c),
                  ),
                ),
              // Brightness: dims the picture (it cannot go brighter than the
              // phone's own brightness).
              if (_brightness < 1.0)
                IgnorePointer(
                  child: ColoredBox(
                    color: Color.fromARGB(
                      ((1 - _brightness) * 0.85 * 255).round(),
                      0,
                      0,
                      0,
                    ),
                  ),
                ),
              if (_loading || buffering)
                const Center(child: CircularProgressIndicator()),
              if (caption.isNotEmpty)
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: _controlsVisible ? 120 : 28,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0x99000000),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        caption,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontSize: 16),
                      ),
                    ),
                  ),
                ),
              AnimatedOpacity(
                opacity: _controlsVisible ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !_controlsVisible,
                  child: _controls((c != null && c.value.isInitialized) ? c : null),
                ),
              ),
              _nextEpisodePill(c),
              if (_hudText != null) _hud(),
              if (_switching != null) _switchingOverlay(),
            ],
          ),
        ),
      ),
    );
  }

  /// "Next episode" button that appears for the last 90 seconds (or once the
  /// episode ends), whether or not the controls are showing.
  Widget _nextEpisodePill(VideoPlayerController? c) {
    final hasNext = _episodeIndex + 1 < _episodes.length;
    if (!hasNext || c == null || !c.value.isInitialized || _switching != null) {
      return const SizedBox.shrink();
    }
    final remaining = c.value.duration - c.value.position;
    if (c.value.duration <= Duration.zero || remaining > const Duration(seconds: 90)) {
      return const SizedBox.shrink();
    }
    return Positioned(
      right: 24,
      bottom: _controlsVisible ? 150 : 56,
      child: FilledButton.icon(
        onPressed: () => _changeEpisode(_episodeIndex + 1),
        icon: const Icon(Icons.skip_next),
        label: const Text('Next episode'),
      ),
    );
  }

  Widget _controls(VideoPlayerController? c) {
    final playing = c?.value.isPlaying ?? false;
    final hasPrev = _episodeIndex > 0;
    final hasNext = _episodeIndex + 1 < _episodes.length;
    return Column(
      children: [
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xCC000000), Color(0x00000000)],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Row(
              children: [
                IconButton(
                  color: Colors.white,
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        _episodeLabel(_episodeIndex),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  color: Colors.white,
                  tooltip: 'Switch module',
                  icon: const Icon(Icons.swap_horiz),
                  onPressed: _showModules,
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  iconSize: 36,
                  color: Colors.white,
                  disabledColor: Colors.white24,
                  icon: const Icon(Icons.skip_previous),
                  onPressed: hasPrev ? () => _changeEpisode(_episodeIndex - 1) : null,
                ),
                IconButton(
                  iconSize: 44,
                  color: Colors.white,
                  icon: const Icon(Icons.replay_10),
                  onPressed: () => _seekBy(-10),
                ),
                IconButton(
                  iconSize: 64,
                  color: Colors.white,
                  icon: Icon(playing ? Icons.pause_circle_filled : Icons.play_circle_fill),
                  onPressed: _togglePlay,
                ),
                IconButton(
                  iconSize: 44,
                  color: Colors.white,
                  icon: const Icon(Icons.forward_10),
                  onPressed: () => _seekBy(10),
                ),
                IconButton(
                  iconSize: 36,
                  color: Colors.white,
                  disabledColor: Colors.white24,
                  icon: const Icon(Icons.skip_next),
                  onPressed: hasNext ? () => _changeEpisode(_episodeIndex + 1) : null,
                ),
              ],
            ),
          ),
        ),
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Color(0xCC000000), Color(0x00000000)],
            ),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _seekBar(c),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Row(
                    children: [
                      if (hasNext)
                        _chip(Icons.skip_next, 'Next episode',
                            () => _changeEpisode(_episodeIndex + 1)),
                      _chip(Icons.record_voice_over, _mode == 'sub' ? 'Sub' : 'Dub', _showAudio),
                      _chip(
                        Icons.hd,
                        _bundle.streams.isEmpty ? 'Quality' : _bundle.streams[_streamIndex].label,
                        _showQuality,
                      ),
                      _chip(
                        Icons.closed_caption,
                        _subIndex < 0 ? 'Subtitles' : _bundle.subtitles[_subIndex].label,
                        _showSubtitles,
                      ),
                      _chip(Icons.speed, _speed == 1.0 ? 'Speed' : '${_speed}x', _showSpeed),
                      _chip(Icons.screen_rotation, 'Rotate', _toggleRotate),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _seekBar(VideoPlayerController? c) {
    final duration = c?.value.duration.inMilliseconds ?? 0;
    final position = _dragMs ?? c?.value.position.inMilliseconds ?? 0;
    final shown = position < 0 ? 0 : (position > duration ? duration : position);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Text(_fmt(Duration(milliseconds: shown)),
              style: const TextStyle(color: Colors.white, fontSize: 12)),
          Expanded(
            child: Slider(
              value: duration <= 0 ? 0 : shown.toDouble(),
              max: duration <= 0 ? 1 : duration.toDouble(),
              onChanged: duration <= 0
                  ? null
                  : (x) {
                      _hideTimer?.cancel();
                      setState(() => _dragMs = x.round());
                    },
              onChangeEnd: duration <= 0
                  ? null
                  : (x) async {
                      _dragMs = null;
                      await c?.seekTo(Duration(milliseconds: x.round()));
                      _scheduleHide();
                    },
            ),
          ),
          Text(_fmt(Duration(milliseconds: duration)),
              style: const TextStyle(color: Colors.white, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _chip(IconData icon, String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ActionChip(
        avatar: Icon(icon, size: 18, color: Colors.white),
        label: Text(label, style: const TextStyle(color: Colors.white)),
        backgroundColor: Colors.white24,
        side: BorderSide.none,
        onPressed: onTap,
      ),
    );
  }

  Widget _errorView() {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                'Playback failed: $_error\n\n${_probe ?? 'Running network test…'}',
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 16),
              if (_switching != null) ...[
                Row(
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(_switching!, style: const TextStyle(color: Colors.white70)),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _switching != null ? null : _showModules,
                    icon: const Icon(Icons.swap_horiz),
                    label: const Text('Switch module'),
                  ),
                  OutlinedButton(
                    onPressed: () => _open(_streamIndex),
                    child: const Text('Retry'),
                  ),
                  if (_bundle.streams.length > 1)
                    OutlinedButton(
                      onPressed: () => _open((_streamIndex + 1) % _bundle.streams.length),
                      child: const Text('Try another stream'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
