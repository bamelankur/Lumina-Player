import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../services/module_data.dart';
import '../services/module_resolver.dart';
import '../services/modules_service.dart';
import '../services/synthetiq_module_runtime.dart';

/// Full-screen player for module streams.
///
/// Gestures: swipe up/down on the left for brightness, on the right for
/// volume, swipe sideways to seek, double-tap the sides to skip 10 seconds.
/// The module can be switched mid-playback; the same episode is found on the
/// new module and playback resumes from the same position.
class LuminaPlayerScreen extends StatefulWidget {
  const LuminaPlayerScreen({
    super.key,
    required this.runtime,
    required this.module,
    required this.modules,
    required this.animeTitle,
    required this.titleHref,
    required this.episodes,
    required this.startIndex,
    required this.audio,
  });

  final LuminaModuleRuntime runtime;
  final InstalledModule module;

  /// Every installed video module, offered in the "Switch module" sheet.
  final List<InstalledModule> modules;
  final String animeTitle;
  final String titleHref;
  final List<EpisodeEntry> episodes;
  final int startIndex;
  final String audio;

  @override
  State<LuminaPlayerScreen> createState() => _LuminaPlayerScreenState();
}

class _LuminaPlayerScreenState extends State<LuminaPlayerScreen> {
  // Kept for the app session so the level carries over between episodes.
  static double _brightness = 1.0;
  static double _volume = 1.0;

  late InstalledModule _module;
  late List<EpisodeEntry> _episodes;
  late String _titleHref;
  late int _index;
  late String _audio;

  VideoPlayerController? _controller;
  String? _error;
  String? _busy;
  int _loadToken = 0;
  bool _advancing = false;

  bool _showControls = true;
  bool _locked = false;
  bool _showUnlock = false;
  bool _fill = false;
  double _speed = 1.0;
  Duration _lastPosition = Duration.zero;
  Timer? _hideTimer;
  Timer? _indicatorTimer;

  // Slider scrubbing.
  bool _scrubbing = false;
  double _scrubMs = 0;

  // Gesture state.
  Offset _doubleTapPos = Offset.zero;
  String? _gestureKind;
  double _gestureBase = 0;
  double _verticalStartY = 0;
  double _horizontalAccum = 0;
  Duration _seekBase = Duration.zero;
  Duration _seekTarget = Duration.zero;

  // On-screen indicator (brightness / volume / seek).
  String? _indicatorText;
  IconData? _indicatorIcon;
  double? _indicatorValue;
  Alignment _indicatorAlign = Alignment.center;

  @override
  void initState() {
    super.initState();
    _module = widget.module;
    _episodes = widget.episodes;
    _titleHref = widget.titleHref;
    _index = widget.startIndex;
    _audio = widget.audio;
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _keepAwake(true);
    _startEpisode(_index);
  }

  @override
  void dispose() {
    _loadToken++;
    _hideTimer?.cancel();
    _indicatorTimer?.cancel();
    final controller = _controller;
    controller?.removeListener(_onVideoTick);
    controller?.dispose();
    _keepAwake(false);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _keepAwake(bool on) async {
    try {
      if (on) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (_) {
      // Keeping the screen awake is a convenience only.
    }
  }

  // ---------------------------------------------------------------- loading

  EpisodeEntry get _episode => _episodes[_index];

  String _episodeLabel(EpisodeEntry e) => 'Episode ${e.number}';

  String _cleanError(Object e) {
    return e
        .toString()
        .replaceFirst(RegExp(r'^(Bad state|Exception|StateError|FormatException):\s*'), '');
  }

  Future<void> _startEpisode(int index, {Duration start = Duration.zero}) async {
    final token = ++_loadToken;
    final episode = _episodes[index];
    setState(() {
      _index = index;
      _error = null;
      _busy = 'Loading ${_episodeLabel(episode)}…';
    });
    _controller?.pause();
    try {
      final stream = await widget.runtime.call(_module, 'extractStreamUrl', [episode.href, _audio, false]);
      final url = findStreamUrl(stream);
      if (url.isEmpty) {
        throw StateError(
          '${_module.name} did not return a playable link${_audio == 'dub' ? ' for DUB' : ''}.',
        );
      }
      if (token != _loadToken || !mounted) return;
      final ok = await _swapController(url, findHeaders(stream), start, token);
      if (ok) LastWatched.save(_module.id, _titleHref, episode.href);
    } catch (e) {
      if (token != _loadToken || !mounted) return;
      setState(() {
        _busy = null;
        _error = _cleanError(e);
      });
    }
  }

  /// Creates a controller for [url], and swaps it in once it is ready so the
  /// previous picture stays on screen until then. Returns false if the load
  /// was superseded.
  Future<bool> _swapController(
    String url,
    Map<String, String> headers,
    Duration start,
    int token,
  ) async {
    final next = VideoPlayerController.networkUrl(Uri.parse(url), httpHeaders: headers);
    try {
      await next.initialize();
    } catch (e) {
      await next.dispose();
      rethrow;
    }
    if (token != _loadToken || !mounted) {
      await next.dispose();
      return false;
    }
    await next.setVolume(_volume);
    await next.setPlaybackSpeed(_speed);
    if (start > Duration.zero) await next.seekTo(start);
    next.addListener(_onVideoTick);

    final old = _controller;
    setState(() {
      _controller = next;
      _busy = null;
      _error = null;
      _advancing = false;
      _showControls = true;
    });
    old?.removeListener(_onVideoTick);
    // Dispose after the frame so the widget tree never touches a dead controller.
    WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
    await next.play();
    _scheduleHide();
    return true;
  }

  void _onVideoTick() {
    final controller = _controller;
    if (controller == null || !mounted) return;
    final value = controller.value;
    if (value.hasError && _error == null) {
      setState(() => _error = value.errorDescription ?? 'Playback error.');
      return;
    }
    if (!_scrubbing && value.isInitialized) _lastPosition = value.position;
    final finished = value.isInitialized &&
        value.duration > Duration.zero &&
        value.position >= value.duration - const Duration(milliseconds: 300) &&
        !value.isPlaying;
    if (finished && !_advancing && _index < _episodes.length - 1) {
      _advancing = true;
      _startEpisode(_index + 1);
      return;
    }
    setState(() {});
  }

  void _cancelLoad() {
    _loadToken++;
    final controller = _controller;
    if (controller != null && controller.value.isInitialized) {
      setState(() => _busy = null);
      controller.play();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  // ------------------------------------------------------- module switching

  Future<void> _pickModule() async {
    _hideTimer?.cancel();
    final controller = _controller;
    final position = controller != null && controller.value.isInitialized
        ? controller.value.position
        : _lastPosition;
    final chosen = await showModalBottomSheet<InstalledModule>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(sheetContext).size.height * 0.85),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Text('Switch module', style: Theme.of(sheetContext).textTheme.titleLarge),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  'Lumina will find ${_episodeLabel(_episode)} on the module you pick and '
                  'resume from ${_formatDuration(position)}.',
                  style: Theme.of(sheetContext).textTheme.bodySmall,
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final module in widget.modules)
                      ListTile(
                        leading: Icon(
                          module.id == _module.id
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                        ),
                        title: Text(module.name),
                        subtitle: Text(
                          module.id == _module.id ? 'Current module · reload' : 'v${module.version}',
                        ),
                        onTap: () => Navigator.pop(sheetContext, module),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted) return;
    if (chosen == null) {
      _scheduleHide();
      return;
    }
    if (chosen.id == _module.id) {
      _startEpisode(_index, start: position);
    } else {
      _switchTo(chosen, position);
    }
  }

  Future<void> _switchTo(InstalledModule target, Duration resume) async {
    final token = ++_loadToken;
    final previous = _controller;
    final previousError = _error;
    previous?.pause();
    setState(() {
      _error = null;
      _busy = 'Finding "${widget.animeTitle}" on ${target.name}…';
    });
    try {
      final match = await resolveOnModule(
        runtime: widget.runtime,
        module: target,
        animeTitle: widget.animeTitle,
        season: _episode.season,
        number: _episode.number,
        audio: _audio,
      );
      if (token != _loadToken || !mounted) return;
      final ok = await _swapController(match.url, match.headers, resume, token);
      if (!ok || !mounted) return;
      setState(() {
        _module = target;
        _episodes = match.episodes;
        _titleHref = match.titleHref;
        _index = match.index;
      });
      LastWatched.save(target.id, match.titleHref, match.episodes[match.index].href);
    } catch (e) {
      if (token != _loadToken || !mounted) return;
      setState(() {
        _busy = null;
        _error = previousError;
      });
      if (previousError == null && previous != null && previous.value.isInitialized) {
        previous.play();
      }
      _toast('Could not switch to ${target.name}: ${_cleanError(e)}');
    }
  }

  void _toggleAudio() {
    _audio = _audio == 'sub' ? 'dub' : 'sub';
    AudioPreference.save(_audio);
    final controller = _controller;
    final position = controller != null && controller.value.isInitialized
        ? controller.value.position
        : _lastPosition;
    _startEpisode(_index, start: position);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ------------------------------------------------------------- controls

  void _scheduleHide() {
    _hideTimer?.cancel();
    final controller = _controller;
    if (controller == null || !controller.value.isPlaying) return;
    _hideTimer = Timer(const Duration(milliseconds: 3500), () {
      if (mounted && !_scrubbing) setState(() => _showControls = false);
    });
  }

  void _togglePlay() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      controller.pause();
      _hideTimer?.cancel();
    } else {
      controller.play();
      _scheduleHide();
    }
    setState(() {});
  }

  void _seekBy(Duration delta) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final duration = controller.value.duration;
    var target = controller.value.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > duration) target = duration;
    controller.seekTo(target);
    final seconds = delta.inSeconds;
    _showIndicator(
      icon: seconds < 0 ? Icons.replay_10 : Icons.forward_10,
      text: '${seconds < 0 ? '−' : '+'}${seconds.abs()}s',
      align: seconds < 0 ? const Alignment(-0.6, 0) : const Alignment(0.6, 0),
    );
  }

  void _showIndicator({
    required IconData icon,
    required String text,
    double? value,
    required Alignment align,
    bool autoHide = true,
  }) {
    _indicatorTimer?.cancel();
    setState(() {
      _indicatorIcon = icon;
      _indicatorText = text;
      _indicatorValue = value;
      _indicatorAlign = align;
    });
    if (autoHide) _hideIndicatorSoon();
  }

  void _hideIndicatorSoon() {
    _indicatorTimer?.cancel();
    _indicatorTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _indicatorText = null);
    });
  }

  // -------------------------------------------------------------- gestures

  void _onTap() {
    if (_locked) {
      setState(() => _showUnlock = !_showUnlock);
      if (_showUnlock) {
        _hideTimer?.cancel();
        _hideTimer = Timer(const Duration(seconds: 2), () {
          if (mounted) setState(() => _showUnlock = false);
        });
      }
      return;
    }
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHide();
  }

  void _onDoubleTap(Size size) {
    if (_locked) return;
    final x = _doubleTapPos.dx;
    if (x < size.width / 3) {
      _seekBy(const Duration(seconds: -10));
    } else if (x > size.width * 2 / 3) {
      _seekBy(const Duration(seconds: 10));
    } else {
      _togglePlay();
    }
  }

  void _onHorizontalStart() {
    final controller = _controller;
    if (_locked || controller == null || !controller.value.isInitialized) return;
    _gestureKind = 'seek';
    _horizontalAccum = 0;
    _seekBase = controller.value.position;
    _seekTarget = _seekBase;
  }

  void _onHorizontalUpdate(DragUpdateDetails details, Size size) {
    final controller = _controller;
    if (_gestureKind != 'seek' || controller == null) return;
    _horizontalAccum += details.delta.dx;
    final seconds = (_horizontalAccum / size.width * 120).round();
    var target = _seekBase + Duration(seconds: seconds);
    final duration = controller.value.duration;
    if (target < Duration.zero) target = Duration.zero;
    if (target > duration) target = duration;
    _seekTarget = target;
    final shown = (target - _seekBase).inSeconds;
    _showIndicator(
      icon: shown < 0 ? Icons.fast_rewind : Icons.fast_forward,
      text: '${_formatDuration(target)}  (${shown >= 0 ? '+' : '−'}${shown.abs()}s)',
      align: const Alignment(0, -0.3),
      autoHide: false,
    );
  }

  void _onHorizontalEnd() {
    if (_gestureKind == 'seek') {
      _controller?.seekTo(_seekTarget);
      _hideIndicatorSoon();
    }
    _gestureKind = null;
  }

  void _onVerticalStart(DragStartDetails details, Size size) {
    if (_locked) return;
    final left = details.localPosition.dx < size.width / 2;
    _gestureKind = left ? 'brightness' : 'volume';
    _gestureBase = left ? _brightness : _volume;
    _verticalStartY = details.localPosition.dy;
  }

  void _onVerticalUpdate(DragUpdateDetails details, Size size) {
    final kind = _gestureKind;
    if (kind != 'brightness' && kind != 'volume') return;
    final delta = (_verticalStartY - details.localPosition.dy) / (size.height * 0.7);
    final value = (_gestureBase + delta).clamp(0.0, 1.0).toDouble();
    if (kind == 'brightness') {
      _brightness = value;
      _showIndicator(
        icon: value > 0.5 ? Icons.brightness_high : Icons.brightness_low,
        text: '${(value * 100).round()}%',
        value: value,
        align: const Alignment(-0.75, 0),
        autoHide: false,
      );
    } else {
      _volume = value;
      _controller?.setVolume(value);
      _showIndicator(
        icon: value == 0
            ? Icons.volume_off
            : value < 0.5
                ? Icons.volume_down
                : Icons.volume_up,
        text: '${(value * 100).round()}%',
        value: value,
        align: const Alignment(0.75, 0),
        autoHide: false,
      );
    }
  }

  void _onVerticalEnd() {
    if (_gestureKind == 'brightness' || _gestureKind == 'volume') {
      _hideIndicatorSoon();
    }
    _gestureKind = null;
  }

  // ----------------------------------------------------------------- build

  static String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  bool get _ready {
    final controller = _controller;
    return controller != null && controller.value.isInitialized && _error == null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          final dim = ((1 - _brightness) * 0.85 * 255).round();
          return Stack(
            fit: StackFit.expand,
            children: [
              _buildVideo(),
              // Software brightness: dims the picture (never brighter than the
              // system brightness).
              IgnorePointer(child: ColoredBox(color: Colors.black.withAlpha(dim))),
              if (_ready && _busy == null) _buildGestureLayer(size),
              if (_ready && _busy == null && _showControls && !_locked) ..._buildControls(),
              if (_ready && _busy == null && _locked && _showUnlock) _buildUnlockButton(),
              if (_ready && _controller!.value.isBuffering && _busy == null)
                const IgnorePointer(child: Center(child: CircularProgressIndicator())),
              if (_indicatorText != null) _buildIndicator(),
              if (_busy != null) _buildBusyOverlay(),
              if (_error != null && _busy == null) _buildErrorOverlay(),
            ],
          );
        },
      ),
    );
  }

  Widget _buildVideo() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.expand();
    }
    final videoSize = controller.value.size;
    if (_fill && videoSize.width > 0 && videoSize.height > 0) {
      return SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: videoSize.width,
            height: videoSize.height,
            child: VideoPlayer(controller),
          ),
        ),
      );
    }
    return Center(
      child: AspectRatio(
        aspectRatio: controller.value.aspectRatio,
        child: VideoPlayer(controller),
      ),
    );
  }

  Widget _buildGestureLayer(Size size) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _onTap,
        onDoubleTapDown: (details) => _doubleTapPos = details.localPosition,
        onDoubleTap: () => _onDoubleTap(size),
        onHorizontalDragStart: (_) => _onHorizontalStart(),
        onHorizontalDragUpdate: (details) => _onHorizontalUpdate(details, size),
        onHorizontalDragEnd: (_) => _onHorizontalEnd(),
        onVerticalDragStart: (details) => _onVerticalStart(details, size),
        onVerticalDragUpdate: (details) => _onVerticalUpdate(details, size),
        onVerticalDragEnd: (_) => _onVerticalEnd(),
      ),
    );
  }

  List<Widget> _buildControls() {
    final controller = _controller!;
    final value = controller.value;
    final durationMs = value.duration.inMilliseconds.toDouble();
    final maxMs = durationMs <= 0 ? 1.0 : durationMs;
    final positionMs = (_scrubbing ? _scrubMs : value.position.inMilliseconds.toDouble())
        .clamp(0.0, maxMs)
        .toDouble();
    final hasPrevious = _index > 0;
    final hasNext = _index < _episodes.length - 1;
    const iconColor = Colors.white;

    final top = Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 16),
            child: Row(
              children: [
                IconButton(
                  color: iconColor,
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.animeTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                      Text(
                        '${seasonLabel(_episode.season)} · ${_episodeLabel(_episode)} · ${_module.name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  color: iconColor,
                  tooltip: 'Lock controls',
                  icon: const Icon(Icons.lock_outline),
                  onPressed: () => setState(() {
                    _locked = true;
                    _showUnlock = false;
                    _showControls = false;
                  }),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final center = Positioned.fill(
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              iconSize: 40,
              color: iconColor,
              disabledColor: Colors.white24,
              icon: const Icon(Icons.skip_previous),
              onPressed: hasPrevious ? () => _startEpisode(_index - 1) : null,
            ),
            const SizedBox(width: 24),
            IconButton.filledTonal(
              iconSize: 48,
              icon: Icon(value.isPlaying ? Icons.pause : Icons.play_arrow),
              onPressed: _togglePlay,
            ),
            const SizedBox(width: 24),
            IconButton(
              iconSize: 40,
              color: iconColor,
              disabledColor: Colors.white24,
              icon: const Icon(Icons.skip_next),
              onPressed: hasNext ? () => _startEpisode(_index + 1) : null,
            ),
          ],
        ),
      ),
    );

    final bottom = Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      _formatDuration(Duration(milliseconds: positionMs.round())),
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                        ),
                        child: Slider(
                          min: 0,
                          max: maxMs,
                          value: positionMs,
                          onChangeStart: (v) {
                            _hideTimer?.cancel();
                            setState(() {
                              _scrubbing = true;
                              _scrubMs = v;
                            });
                          },
                          onChanged: (v) => setState(() => _scrubMs = v),
                          onChangeEnd: (v) {
                            controller.seekTo(Duration(milliseconds: v.round()));
                            setState(() => _scrubbing = false);
                            _scheduleHide();
                          },
                        ),
                      ),
                    ),
                    Text(
                      _formatDuration(value.duration),
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        PopupMenuButton<double>(
                          tooltip: 'Playback speed',
                          initialValue: _speed,
                          onOpened: () => _hideTimer?.cancel(),
                          onCanceled: _scheduleHide,
                          onSelected: (speed) {
                            setState(() => _speed = speed);
                            controller.setPlaybackSpeed(speed);
                            _scheduleHide();
                          },
                          itemBuilder: (context) => [
                            for (final speed in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
                              PopupMenuItem<double>(value: speed, child: Text('${speed}x')),
                          ],
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.speed, color: iconColor, size: 20),
                                const SizedBox(width: 6),
                                Text('${_speed}x', style: const TextStyle(color: Colors.white)),
                              ],
                            ),
                          ),
                        ),
                        TextButton.icon(
                          style: TextButton.styleFrom(foregroundColor: Colors.white),
                          onPressed: () => setState(() => _fill = !_fill),
                          icon: Icon(_fill ? Icons.fit_screen : Icons.crop_free, size: 20),
                          label: Text(_fill ? 'Fill' : 'Fit'),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton.icon(
                          style: TextButton.styleFrom(foregroundColor: Colors.white),
                          onPressed: _toggleAudio,
                          icon: Icon(_audio == 'sub' ? Icons.closed_caption : Icons.mic, size: 20),
                          label: Text(_audio.toUpperCase()),
                        ),
                        TextButton.icon(
                          style: TextButton.styleFrom(foregroundColor: Colors.white),
                          onPressed: _pickModule,
                          icon: const Icon(Icons.swap_horiz, size: 20),
                          label: const Text('Switch module'),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return [top, center, bottom];
  }

  Widget _buildUnlockButton() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 24,
      child: Center(
        child: FilledButton.tonalIcon(
          onPressed: () => setState(() {
            _locked = false;
            _showUnlock = false;
            _showControls = true;
            _scheduleHide();
          }),
          icon: const Icon(Icons.lock_open),
          label: const Text('Unlock'),
        ),
      ),
    );
  }

  Widget _buildIndicator() {
    return IgnorePointer(
      child: Align(
        alignment: _indicatorAlign,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black.withAlpha(170),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_indicatorIcon, color: Colors.white, size: 30),
              const SizedBox(height: 6),
              if (_indicatorValue != null)
                SizedBox(
                  width: 80,
                  child: LinearProgressIndicator(
                    value: _indicatorValue,
                    backgroundColor: Colors.white24,
                  ),
                ),
              if (_indicatorValue != null) const SizedBox(height: 6),
              Text(
                _indicatorText ?? '',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBusyOverlay() {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withAlpha(190),
        child: SafeArea(
          child: Stack(
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: IconButton(
                  color: Colors.white,
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(
                      _busy ?? '',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white),
                    ),
                    const SizedBox(height: 8),
                    TextButton(onPressed: _cancelLoad, child: const Text('Cancel')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildErrorOverlay() {
    final otherAudio = _audio == 'sub' ? 'DUB' : 'SUB';
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withAlpha(220),
        child: SafeArea(
          child: Stack(
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: IconButton(
                  color: Colors.white,
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, color: Colors.white70, size: 40),
                        const SizedBox(height: 12),
                        Text(
                          '${_module.name} could not play ${_episodeLabel(_episode)}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _error ?? '',
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                        const SizedBox(height: 20),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              onPressed: _pickModule,
                              icon: const Icon(Icons.swap_horiz),
                              label: const Text('Switch module'),
                            ),
                            OutlinedButton(
                              style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                              onPressed: () => _startEpisode(_index, start: _lastPosition),
                              child: const Text('Retry'),
                            ),
                            OutlinedButton(
                              style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                              onPressed: _toggleAudio,
                              child: Text('Try $otherAudio'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
