import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kDownloadsKey = 'lumina.downloads.v1';

enum DownloadState { downloading, done, failed }

/// One quality listed by an HLS master playlist.
class HlsVariant {
  const HlsVariant({
    required this.label,
    required this.url,
    required this.bandwidth,
    this.separateAudio = false,
  });

  final String label;
  final String url;
  final int bandwidth;

  /// The audio of this quality lives in its own playlist, which a plain
  /// segment download cannot merge into the video.
  final bool separateAudio;
}

/// Reads an HLS master playlist: the qualities it offers, best first.
/// Empty when [url] is not a master playlist (or cannot be read).
List<HlsVariant> parseHlsVariants(String text, Uri base) {
  if (!text.contains('#EXT-X-STREAM-INF')) return const [];
  final lines = LineSplitter.split(text).map((l) => l.trim()).toList();

  // Audio groups that point at their own playlist.
  final separateAudioGroups = <String>{};
  for (final l in lines) {
    if (!l.startsWith('#EXT-X-MEDIA') || !l.contains('TYPE=AUDIO') || !l.contains('URI=')) continue;
    final group = RegExp(r'GROUP-ID="([^"]+)"').firstMatch(l)?.group(1);
    if (group != null) separateAudioGroups.add(group);
  }

  final byLabel = <String, HlsVariant>{};
  final heights = <String, int>{};
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (!line.startsWith('#EXT-X-STREAM-INF')) continue;
    String? uri;
    for (var j = i + 1; j < lines.length; j++) {
      if (lines[j].isEmpty || lines[j].startsWith('#')) continue;
      uri = lines[j];
      break;
    }
    if (uri == null) continue;
    final bandwidth = int.tryParse(
          RegExp(r'(?:^|[:,])BANDWIDTH=(\d+)').firstMatch(line)?.group(1) ?? '',
        ) ??
        0;
    final resolution = RegExp(r'RESOLUTION=(\d+)x(\d+)').firstMatch(line);
    final height = resolution == null ? 0 : int.tryParse(resolution.group(2) ?? '') ?? 0;
    final label = height > 0
        ? '${height}p'
        : (bandwidth > 0 ? '${(bandwidth / 1000000).toStringAsFixed(1)} Mbps' : 'Stream ${byLabel.length + 1}');
    final audioGroup = RegExp(r'AUDIO="([^"]+)"').firstMatch(line)?.group(1);
    final variant = HlsVariant(
      label: label,
      url: base.resolve(uri).toString(),
      bandwidth: bandwidth,
      separateAudio: audioGroup != null && separateAudioGroups.contains(audioGroup),
    );
    final existing = byLabel[label];
    if (existing == null || bandwidth > existing.bandwidth) {
      byLabel[label] = variant;
      heights[label] = height;
    }
  }
  final list = byLabel.values.toList();
  list.sort((a, b) {
    final byHeight = (heights[b.label] ?? 0).compareTo(heights[a.label] ?? 0);
    return byHeight != 0 ? byHeight : b.bandwidth.compareTo(a.bandwidth);
  });
  return list;
}

/// One downloaded (or downloading) episode.
class DownloadItem {
  DownloadItem({
    required this.id,
    required this.moduleId,
    required this.titleHref,
    required this.title,
    required this.image,
    required this.episodeHref,
    required this.episodeTitle,
    required this.episodeNumber,
    required this.mode,
    required this.quality,
    required this.createdAt,
    this.filePath = '',
    this.bytes = 0,
    this.state = DownloadState.downloading,
    this.progress,
    this.error,
  });

  final String id;
  final String moduleId;
  final String titleHref;
  final String title;
  final String image;
  final String episodeHref;
  final String episodeTitle;
  final int episodeNumber;
  final String mode;
  final String quality;
  final int createdAt;

  String filePath;
  int bytes;
  DownloadState state;

  /// 0..1 while downloading, or null when the size is not known.
  double? progress;
  String? error;

  Map<String, dynamic> toJson() => {
        'id': id,
        'moduleId': moduleId,
        'titleHref': titleHref,
        'title': title,
        'image': image,
        'episodeHref': episodeHref,
        'episodeTitle': episodeTitle,
        'episodeNumber': episodeNumber,
        'mode': mode,
        'quality': quality,
        'createdAt': createdAt,
        'filePath': filePath,
        'bytes': bytes,
        'state': state.name,
        'error': error,
      };

  factory DownloadItem.fromJson(Map<String, dynamic> json) {
    var state = DownloadState.values.firstWhere(
      (s) => s.name == '${json['state']}',
      orElse: () => DownloadState.failed,
    );
    String? error = json['error'] as String?;
    if (state == DownloadState.downloading) {
      // The app was closed mid-download; the partial file is not resumable.
      state = DownloadState.failed;
      error = 'Interrupted. Remove it and download again.';
    }
    return DownloadItem(
      id: '${json['id']}',
      moduleId: '${json['moduleId'] ?? ''}',
      titleHref: '${json['titleHref'] ?? ''}',
      title: '${json['title'] ?? ''}',
      image: '${json['image'] ?? ''}',
      episodeHref: '${json['episodeHref'] ?? ''}',
      episodeTitle: '${json['episodeTitle'] ?? ''}',
      episodeNumber: int.tryParse('${json['episodeNumber'] ?? 0}') ?? 0,
      mode: '${json['mode'] ?? 'sub'}',
      quality: '${json['quality'] ?? ''}',
      createdAt: int.tryParse('${json['createdAt'] ?? 0}') ?? 0,
      filePath: '${json['filePath'] ?? ''}',
      bytes: int.tryParse('${json['bytes'] ?? 0}') ?? 0,
      state: state,
      error: error,
    );
  }
}

class _Cancel {
  bool cancelled = false;
  http.Client? client;

  void cancel() {
    cancelled = true;
    client?.close();
  }
}

const _separateAudioMessage =
    'This stream keeps its audio in a separate track, which downloads cannot merge yet.';

/// How many HLS segments are fetched at the same time.
const _hlsParallelSegments = 8;

class _Cancelled implements Exception {}

class _Unsupported implements Exception {
  _Unsupported(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Downloads module episodes to the app's private storage so they can be
/// played offline from the Downloads tab.
///
/// Supports direct files (MP4/WebM/...) and plain HLS (.m3u8) playlists, which
/// are joined into a single file. Encrypted HLS (AES-128) is not supported.
class DownloadService extends ChangeNotifier {
  final Map<String, DownloadItem> _items = {};
  final Map<String, _Cancel> _cancels = {};
  bool _loaded = false;
  bool _disposed = false;
  int _lastNotifyMs = 0;

  bool get isLoaded => _loaded;

  /// Newest first.
  List<DownloadItem> get items {
    final list = _items.values.toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  /// The qualities offered by the playlist at [url], best first. Empty when it
  /// is not an HLS master playlist (single quality, or a direct file).
  static Future<List<HlsVariant>> fetchHlsVariants(
    String url,
    Map<String, String> headers,
  ) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.path.toLowerCase().endsWith('.m3u8')) return const [];
    try {
      final res = await http
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) return const [];
      return parseHlsVariants(res.body, uri);
    } catch (_) {
      return const [];
    }
  }

  static String keyFor(String moduleId, String episodeHref, String mode) =>
      '$moduleId|$episodeHref|$mode';

  DownloadItem? find(String moduleId, String episodeHref, String mode) =>
      _items[keyFor(moduleId, episodeHref, mode)];

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 8));
      final raw = prefs.getString(_kDownloadsKey);
      if (raw != null) {
        final data = jsonDecode(raw);
        if (data is List) {
          for (final entry in data) {
            if (entry is Map) {
              final item = DownloadItem.fromJson(Map<String, dynamic>.from(entry));
              // A "done" entry whose file vanished is no longer usable.
              if (item.state == DownloadState.done && !File(item.filePath).existsSync()) {
                continue;
              }
              _items[item.id] = item;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Lumina: could not read downloads: $e');
    }
    _loaded = true;
    _notify();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kDownloadsKey,
        jsonEncode(_items.values.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('Lumina: could not save downloads: $e');
    }
  }

  void _notify() {
    if (_disposed) return;
    scheduleMicrotask(() {
      if (!_disposed) notifyListeners();
    });
  }

  /// Progress ticks arrive very often; only repaint a few times per second.
  void _notifyThrottled() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastNotifyMs < 400) return;
    _lastNotifyMs = now;
    _notify();
  }

  Future<Directory> _downloadDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'downloads'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _safeName(String value) {
    final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    final trimmed = cleaned.length > 60 ? cleaned.substring(0, 60) : cleaned;
    return trimmed.isEmpty ? 'download' : trimmed;
  }

  /// Starts downloading [url]. Returns immediately; watch [find] / the
  /// notifier for progress.
  Future<void> start({
    required String moduleId,
    required String titleHref,
    required String title,
    required String image,
    required String episodeHref,
    required String episodeTitle,
    required int episodeNumber,
    required String mode,
    required String quality,
    required String url,
    Map<String, String> headers = const {},
  }) async {
    final key = keyFor(moduleId, episodeHref, mode);
    final existing = _items[key];
    if (existing != null && existing.state == DownloadState.downloading) return;
    if (existing != null &&
        existing.state == DownloadState.done &&
        File(existing.filePath).existsSync()) {
      return;
    }
    final item = DownloadItem(
      id: key,
      moduleId: moduleId,
      titleHref: titleHref,
      title: title,
      image: image,
      episodeHref: episodeHref,
      episodeTitle: episodeTitle,
      episodeNumber: episodeNumber,
      mode: mode,
      quality: quality,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      progress: 0,
    );
    _items[key] = item;
    final cancel = _Cancel();
    _cancels[key] = cancel;
    _notify();
    unawaited(_run(item, url, headers, cancel));
  }

  Future<void> cancel(String id) async {
    _cancels[id]?.cancel();
  }

  /// Stops it if running, deletes the file and forgets the entry.
  Future<void> remove(String id) async {
    _cancels[id]?.cancel();
    final item = _items.remove(id);
    if (item != null && item.filePath.isNotEmpty) {
      try {
        final f = File(item.filePath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    _notify();
    await _persist();
  }

  Future<void> _run(
    DownloadItem item,
    String url,
    Map<String, String> headers,
    _Cancel cancel,
  ) async {
    final client = http.Client();
    cancel.client = client;
    try {
      final File file;
      final dir = await _downloadDir();
      final base = _safeName(
        '${item.title}_ep${item.episodeNumber}_${item.mode}_${item.createdAt}',
      );
      final isHls = Uri.tryParse(url)?.path.toLowerCase().endsWith('.m3u8') ?? false;
      if (isHls) {
        file = await _downloadHls(client, Uri.parse(url), headers, dir, base, item, cancel);
      } else {
        file = await _downloadFile(client, Uri.parse(url), headers, dir, base, item, cancel);
      }
      item.filePath = file.path;
      item.bytes = await file.length();
      item.progress = 1;
      item.state = DownloadState.done;
      item.error = null;
    } on _Cancelled {
      await _discardPartial(item);
      _items.remove(item.id);
    } on _Unsupported catch (e) {
      await _discardPartial(item);
      item.state = DownloadState.failed;
      item.error = e.message;
    } catch (e) {
      await _discardPartial(item);
      if (cancel.cancelled) {
        // Closing the client to stop the transfer surfaces as an error here.
        _items.remove(item.id);
      } else {
        item.state = DownloadState.failed;
        item.error = '$e';
      }
    } finally {
      client.close();
      _cancels.remove(item.id);
    }
    _notify();
    await _persist();
  }

  /// Deletes the half-written file of a download that did not finish.
  Future<void> _discardPartial(DownloadItem item) async {
    final path = item.filePath;
    item.filePath = '';
    item.bytes = 0;
    if (path.isEmpty) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  String _extensionOf(Uri uri) {
    final ext = p.extension(uri.path).toLowerCase().replaceFirst('.', '');
    const known = {'mp4', 'mkv', 'webm', 'mov', 'm4v', 'avi', 'ts'};
    return known.contains(ext) ? ext : 'mp4';
  }

  Future<File> _downloadFile(
    http.Client client,
    Uri uri,
    Map<String, String> headers,
    Directory dir,
    String base,
    DownloadItem item,
    _Cancel cancel,
  ) async {
    final file = File(p.join(dir.path, '$base.${_extensionOf(uri)}'));
    item.filePath = file.path;
    final request = http.Request('GET', uri)..headers.addAll(headers);
    final response = await client.send(request).timeout(const Duration(seconds: 30));
    if (response.statusCode >= 400) {
      throw Exception('The server answered HTTP ${response.statusCode}.');
    }
    final total = response.contentLength ?? 0;
    var received = 0;
    final sink = file.openWrite();
    try {
      await for (final chunk in response.stream) {
        if (cancel.cancelled) throw _Cancelled();
        sink.add(chunk);
        received += chunk.length;
        item.progress = total > 0 ? received / total : null;
        item.bytes = received;
        _notifyThrottled();
      }
    } finally {
      await sink.close();
    }
    if (received == 0) throw Exception('The server sent an empty file.');
    return file;
  }

  Future<String> _getText(http.Client client, Uri uri, Map<String, String> headers) async {
    final res = await client.get(uri, headers: headers).timeout(const Duration(seconds: 30));
    if (res.statusCode >= 400) throw Exception('HTTP ${res.statusCode} for the playlist.');
    return res.body;
  }

  Future<File> _downloadHls(
    http.Client client,
    Uri playlistUri,
    Map<String, String> headers,
    Directory dir,
    String base,
    DownloadItem item,
    _Cancel cancel,
  ) async {
    var uri = playlistUri;
    var text = await _getText(client, uri, headers);

    // A master playlist lists several qualities: take the highest bandwidth.
    if (text.contains('#EXT-X-STREAM-INF')) {
      final variants = parseHlsVariants(text, uri);
      if (variants.isEmpty) throw _Unsupported('The playlist had no playable variant.');
      final best = variants.first;
      if (best.separateAudio) throw _Unsupported(_separateAudioMessage);
      uri = Uri.parse(best.url);
      text = await _getText(client, uri, headers);
    }

    final lines = LineSplitter.split(text).map((l) => l.trim()).toList();
    final encrypted = lines.any(
      (l) => l.startsWith('#EXT-X-KEY') && !l.contains('METHOD=NONE'),
    );
    if (encrypted) {
      throw _Unsupported(
        'This stream is encrypted (HLS AES), which downloads do not support yet.',
      );
    }

    // fMP4 playlists start with an init segment; joined with the segments they
    // form a playable .mp4. Plain playlists are MPEG-TS.
    Uri? initUri;
    for (final l in lines) {
      if (l.startsWith('#EXT-X-MAP')) {
        final m = RegExp(r'URI="([^"]+)"').firstMatch(l);
        if (m != null) initUri = uri.resolve(m.group(1)!);
      }
    }
    final segments = <Uri>[
      for (final l in lines)
        if (l.isNotEmpty && !l.startsWith('#')) uri.resolve(l),
    ];
    if (segments.isEmpty) throw _Unsupported('The playlist contained no video segments.');

    final file = File(p.join(dir.path, '$base.${initUri != null ? 'mp4' : 'ts'}'));
    item.filePath = file.path;
    final sink = file.openWrite();
    var written = 0;
    try {
      Future<List<int>> fetch(Uri u) async {
        Object? lastError;
        for (var attempt = 0; attempt < 3; attempt++) {
          if (cancel.cancelled) throw _Cancelled();
          try {
            final res = await client
                .get(u, headers: headers)
                .timeout(const Duration(seconds: 60));
            if (res.statusCode >= 400) throw Exception('HTTP ${res.statusCode}');
            return res.bodyBytes;
          } catch (e) {
            if (cancel.cancelled) throw _Cancelled();
            lastError = e;
          }
        }
        throw Exception('A video segment failed to download: $lastError');
      }

      if (initUri != null) {
        final init = await fetch(initUri);
        sink.add(init);
        written += init.length;
      }
      // Fetch several segments at once but write them in order. One at a time
      // is limited by round-trip latency and is far slower.
      final inFlight = <int, Future<List<int>>>{};
      var started = 0;
      for (var i = 0; i < segments.length; i++) {
        while (started < segments.length && started < i + _hlsParallelSegments) {
          final future = fetch(segments[started]);
          future.ignore(); // errors are raised below, when it is awaited in order
          inFlight[started] = future;
          started++;
        }
        final bytes = await inFlight.remove(i)!;
        sink.add(bytes);
        written += bytes.length;
        item.progress = (i + 1) / segments.length;
        item.bytes = written;
        _notifyThrottled();
      }
    } finally {
      await sink.close();
    }
    return file;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final c in _cancels.values) {
      c.cancel();
    }
    super.dispose();
  }
}
