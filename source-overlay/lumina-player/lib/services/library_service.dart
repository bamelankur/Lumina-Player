import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';

const _kLibraryKey = 'lumina.library.v1';
const _videoExts = {'mp4', 'mkv', 'avi', 'mov', 'webm', 'm4v', '3gp'};
const _photoExts = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'};

/// Owns the on-device media library: scanning, importing and persistence.
class LibraryService extends ChangeNotifier {
  final List<MediaItem> _items = [];
  bool _loaded = false;

  List<MediaItem> get items => List.unmodifiable(_items);
  List<MediaItem> get videos =>
      _items.where((e) => e.type == MediaType.video).toList();
  List<MediaItem> get photos =>
      _items.where((e) => e.type == MediaType.photo).toList();
  bool get isLoaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;
    try {
      // A stalled or failing preferences read must never leave the UI on a
      // loading spinner forever: give up after a few seconds and start empty.
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 8));
      final raw = prefs.getString(_kLibraryKey);
      if (raw != null) {
        try {
          final list = jsonDecode(raw) as List;
          _items.addAll(
            list.map((e) => MediaItem.fromJson(e as Map<String, dynamic>)),
          );
        } catch (_) {
          // Corrupt cache: start fresh rather than crash.
        }
      }
    } catch (e) {
      debugPrint('Lumina: could not read the saved library: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kLibraryKey,
      jsonEncode(_items.map((e) => e.toJson()).toList()),
    );
  }

  MediaType? _typeFor(String path) {
    final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
    if (_videoExts.contains(ext)) return MediaType.video;
    if (_photoExts.contains(ext)) return MediaType.photo;
    return null;
  }

  /// Imports files picked by the user, skipping duplicates by path.
  Future<int> importFiles(List<String> paths) async {
    var added = 0;
    final known = _items.map((e) => e.path).toSet();
    for (final path in paths) {
      if (known.contains(path)) continue;
      final type = _typeFor(path);
      if (type == null) continue;
      _items.add(MediaItem(
        id: 'local:${DateTime.now().microsecondsSinceEpoch}:$added',
        title: p.basenameWithoutExtension(path),
        path: path,
        type: type,
        dateAdded: DateTime.now(),
      ));
      known.add(path);
      added++;
    }
    if (added > 0) {
      await _persist();
      notifyListeners();
    }
    return added;
  }

  /// Recursively scans a directory for media files.
  Future<int> scanDirectory(Directory dir) async {
    final found = <String>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File && _typeFor(entity.path) != null) {
        found.add(entity.path);
      }
    }
    return importFiles(found);
  }

  Future<void> removeItem(String id) async {
    _items.removeWhere((e) => e.id == id);
    await _persist();
    notifyListeners();
  }

  /// Merges items coming from a connected media server, replacing that
  /// server's previous listing wholesale.
  Future<void> mergeServerItems(List<MediaItem> serverItems, String serverId) async {
    _items.removeWhere(
      (e) => e.source == MediaSource.server && e.serverId == serverId,
    );
    _items.addAll(serverItems);
    await _persist();
    notifyListeners();
  }

  /// Drops every item that came from [serverId] (on disconnect).
  Future<void> clearServerItems(String serverId) async {
    _items.removeWhere(
      (e) => e.source == MediaSource.server && e.serverId == serverId,
    );
    await _persist();
    notifyListeners();
  }
}
