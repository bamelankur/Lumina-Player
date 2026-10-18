import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kModuleStateKey = 'lumina.module_state.v1';
const _kMaxHistory = 30;

/// A title returned by a module that the user hearted.
class ModuleFavourite {
  const ModuleFavourite({
    required this.moduleId,
    required this.href,
    required this.title,
    required this.image,
  });

  final String moduleId;
  final String href;
  final String title;
  final String image;

  String get key => '$moduleId|$href';

  Map<String, dynamic> toJson() => {
        'moduleId': moduleId,
        'href': href,
        'title': title,
        'image': image,
      };

  factory ModuleFavourite.fromJson(Map<String, dynamic> json) => ModuleFavourite(
        moduleId: '${json['moduleId'] ?? ''}',
        href: '${json['href'] ?? ''}',
        title: '${json['title'] ?? ''}',
        image: '${json['image'] ?? ''}',
      );
}

/// Where the user stopped watching a module title.
class ModuleHistoryEntry {
  const ModuleHistoryEntry({
    required this.moduleId,
    required this.titleHref,
    required this.title,
    required this.image,
    required this.episodeHref,
    required this.episodeTitle,
    required this.episodeIndex,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAt,
  });

  final String moduleId;
  final String titleHref;
  final String title;
  final String image;
  final String episodeHref;
  final String episodeTitle;
  final int episodeIndex;
  final int positionMs;
  final int durationMs;
  final int updatedAt;

  String get key => '$moduleId|$titleHref';

  double get fraction {
    if (durationMs <= 0) return 0;
    final f = positionMs / durationMs;
    if (f < 0) return 0;
    if (f > 1) return 1;
    return f;
  }

  Map<String, dynamic> toJson() => {
        'moduleId': moduleId,
        'titleHref': titleHref,
        'title': title,
        'image': image,
        'episodeHref': episodeHref,
        'episodeTitle': episodeTitle,
        'episodeIndex': episodeIndex,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'updatedAt': updatedAt,
      };

  factory ModuleHistoryEntry.fromJson(Map<String, dynamic> json) => ModuleHistoryEntry(
        moduleId: '${json['moduleId'] ?? ''}',
        titleHref: '${json['titleHref'] ?? ''}',
        title: '${json['title'] ?? ''}',
        image: '${json['image'] ?? ''}',
        episodeHref: '${json['episodeHref'] ?? ''}',
        episodeTitle: '${json['episodeTitle'] ?? ''}',
        episodeIndex: int.tryParse('${json['episodeIndex'] ?? 0}') ?? 0,
        positionMs: int.tryParse('${json['positionMs'] ?? 0}') ?? 0,
        durationMs: int.tryParse('${json['durationMs'] ?? 0}') ?? 0,
        updatedAt: int.tryParse('${json['updatedAt'] ?? 0}') ?? 0,
      );
}

/// Remembers, for module (provider) content: the module chosen on Home,
/// favourite titles and watch progress for "Continue Watching".
class ModuleStateService extends ChangeNotifier {
  final Map<String, ModuleFavourite> _favourites = {};
  final Map<String, ModuleHistoryEntry> _history = {};
  String? _selectedModuleId;
  bool _loaded = false;
  bool _disposed = false;

  bool get isLoaded => _loaded;
  String? get selectedModuleId => _selectedModuleId;

  /// Newest favourite first.
  List<ModuleFavourite> get favourites =>
      _favourites.values.toList().reversed.toList();

  /// In-progress titles (watched past 2 % and under 95 %), newest first.
  List<ModuleHistoryEntry> get continueWatching {
    final list = _history.values
        .where((e) => e.fraction > 0.02 && e.fraction < 0.95)
        .toList();
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  bool isFavourite(String moduleId, String href) =>
      _favourites.containsKey('$moduleId|$href');

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 8));
      final raw = prefs.getString(_kModuleStateKey);
      if (raw != null) {
        final data = jsonDecode(raw);
        if (data is Map) {
          final selected = data['selected'];
          if (selected is String && selected.isNotEmpty) {
            _selectedModuleId = selected;
          }
          final favs = data['favourites'];
          if (favs is List) {
            for (final f in favs) {
              if (f is Map) {
                final fav = ModuleFavourite.fromJson(Map<String, dynamic>.from(f));
                _favourites[fav.key] = fav;
              }
            }
          }
          final hist = data['history'];
          if (hist is List) {
            for (final h in hist) {
              if (h is Map) {
                final entry =
                    ModuleHistoryEntry.fromJson(Map<String, dynamic>.from(h));
                _history[entry.key] = entry;
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Lumina: could not read saved module state: $e');
    }
    _loaded = true;
    _notify();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kModuleStateKey,
        jsonEncode({
          'selected': _selectedModuleId,
          'favourites': _favourites.values.map((e) => e.toJson()).toList(),
          'history': _history.values.map((e) => e.toJson()).toList(),
        }),
      );
    } catch (e) {
      debugPrint('Lumina: could not save module state: $e');
    }
  }

  /// Notifications are deferred to a microtask so this is safe to call from
  /// widget dispose methods (the player saves progress while closing).
  void _notify() {
    scheduleMicrotask(() {
      if (!_disposed) notifyListeners();
    });
  }

  Future<void> selectModule(String id) async {
    if (_selectedModuleId == id) return;
    _selectedModuleId = id;
    _notify();
    await _persist();
  }

  Future<void> toggleFavourite(ModuleFavourite fav) async {
    if (_favourites.containsKey(fav.key)) {
      _favourites.remove(fav.key);
    } else {
      _favourites[fav.key] = fav;
    }
    _notify();
    await _persist();
  }

  Future<void> saveProgress(ModuleHistoryEntry entry) async {
    _history.remove(entry.key);
    if (entry.durationMs > 0 && entry.fraction >= 0.95) {
      // Finished: drop it from Continue Watching.
      _notify();
      await _persist();
      return;
    }
    _history[entry.key] = entry;
    if (_history.length > _kMaxHistory) {
      final oldest = _history.values.toList()
        ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
      _history.remove(oldest.first.key);
    }
    _notify();
    await _persist();
  }

  Future<void> removeHistory(String key) async {
    if (_history.remove(key) == null) return;
    _notify();
    await _persist();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
