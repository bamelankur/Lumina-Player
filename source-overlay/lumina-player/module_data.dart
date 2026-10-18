import 'package:shared_preferences/shared_preferences.dart';

/// Shared helpers for reading the loosely-typed values that Lumina modules
/// return (search cards, episode lists, stream results).

String moduleString(dynamic value, List<String> keys) {
  if (value is! Map) return value is String ? value : '';
  for (final key in keys) {
    final candidate = value[key];
    if (candidate != null && candidate.toString().trim().isNotEmpty) {
      return candidate.toString();
    }
  }
  return '';
}

/// Accepts a list, or a map that wraps a list under a common key.
List<dynamic> asList(dynamic value) {
  if (value is List) return value;
  if (value is Map) {
    for (final key in ['items', 'results', 'data', 'episodes', 'list']) {
      final candidate = value[key];
      if (candidate is List) return candidate;
    }
  }
  return const <dynamic>[];
}

String findStreamUrl(dynamic value) {
  if (value is String && value.startsWith('http')) return value;
  if (value is List) {
    for (final item in value) {
      final found = findStreamUrl(item);
      if (found.isNotEmpty) return found;
    }
  }
  if (value is Map) {
    for (final key in ['url', 'file', 'src', 'streamUrl', 'stream_url', 'link']) {
      final candidate = value[key];
      if (candidate is String &&
          (candidate.startsWith('http://') || candidate.startsWith('https://'))) {
        return candidate;
      }
    }
    for (final key in ['streams', 'sources', 'data', 'result', 'links']) {
      if (value.containsKey(key)) {
        final found = findStreamUrl(value[key]);
        if (found.isNotEmpty) return found;
      }
    }
  }
  return '';
}

Map<String, String> findHeaders(dynamic value) {
  if (value is Map) {
    final headers = value['headers'] ?? value['streamHeaders'];
    if (headers is Map) {
      return headers.map((key, val) => MapEntry(key.toString(), val.toString()));
    }
    for (final key in ['streams', 'sources', 'data', 'result', 'links']) {
      if (value.containsKey(key)) {
        final found = findHeaders(value[key]);
        if (found.isNotEmpty) return found;
      }
    }
  } else if (value is List) {
    for (final item in value) {
      final found = findHeaders(item);
      if (found.isNotEmpty) return found;
    }
  }
  return {};
}

/// One episode of a title, normalised from whatever the module returned.
class EpisodeEntry {
  const EpisodeEntry({
    required this.href,
    required this.title,
    required this.season,
    required this.number,
  });

  final String href;
  final String title;
  final String season;
  final int number;
}

int? _episodeNumber(dynamic item, String title) {
  if (item is Map) {
    for (final key in ['number', 'episode', 'episodeNumber', 'ep', 'num']) {
      final raw = item[key];
      if (raw == null) continue;
      final parsed = num.tryParse(raw.toString().trim());
      if (parsed != null) return parsed.floor();
    }
  }
  final labelled = RegExp(r'ep(?:isode)?\.?\s*#?\s*(\d+)', caseSensitive: false).firstMatch(title);
  if (labelled != null) return int.tryParse(labelled.group(1)!);
  final anyDigits = RegExp(r'(\d+)').firstMatch(title);
  if (anyDigits != null) return int.tryParse(anyDigits.group(1)!);
  return null;
}

/// Turns a module's `extractEpisodes` result into an ordered list
/// (season first, then episode number).
List<EpisodeEntry> parseEpisodes(dynamic raw) {
  final list = asList(raw);
  final out = <EpisodeEntry>[];
  for (var i = 0; i < list.length; i++) {
    final item = list[i];
    final href = moduleString(item, ['href', 'url', 'id', 'link']);
    if (href.isEmpty) continue;
    final title = moduleString(item, ['title', 'name']);
    var season = moduleString(item, ['season', 'seasonNumber']).trim();
    if (season.isEmpty) season = '1';
    out.add(EpisodeEntry(
      href: href,
      title: title,
      season: season,
      number: _episodeNumber(item, title) ?? (i + 1),
    ));
  }
  return orderEpisodes(out);
}

List<EpisodeEntry> orderEpisodes(List<EpisodeEntry> episodes) {
  final firstSeen = <String, int>{};
  for (final e in episodes) {
    firstSeen.putIfAbsent(e.season, () => firstSeen.length);
  }
  int rank(String season) => int.tryParse(season) ?? (1000 + (firstSeen[season] ?? 0));
  final indexed = <MapEntry<int, EpisodeEntry>>[
    for (var i = 0; i < episodes.length; i++) MapEntry(i, episodes[i]),
  ];
  indexed.sort((a, b) {
    final bySeason = rank(a.value.season).compareTo(rank(b.value.season));
    if (bySeason != 0) return bySeason;
    final byNumber = a.value.number.compareTo(b.value.number);
    if (byNumber != 0) return byNumber;
    return a.key.compareTo(b.key);
  });
  return [for (final entry in indexed) entry.value];
}

/// Groups an already-ordered episode list by season, keeping order.
Map<String, List<EpisodeEntry>> groupBySeason(List<EpisodeEntry> ordered) {
  final seasons = <String, List<EpisodeEntry>>{};
  for (final e in ordered) {
    seasons.putIfAbsent(e.season, () => <EpisodeEntry>[]).add(e);
  }
  return seasons;
}

String seasonLabel(String season) {
  return int.tryParse(season) != null ? 'Season $season' : season;
}

String _normaliseTitle(String value) {
  final cleaned = value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9À-￿]+'), ' ')
      .trim();
  const noise = {'dub', 'sub', 'dubbed', 'subbed', 'english', 'hd'};
  return cleaned.split(' ').where((w) => w.isNotEmpty && !noise.contains(w)).join(' ');
}

/// 0..1 similarity between two titles, used to find the same title on
/// another module.
double titleSimilarity(String a, String b) {
  final na = _normaliseTitle(a);
  final nb = _normaliseTitle(b);
  if (na.isEmpty || nb.isEmpty) return 0;
  if (na == nb) return 1;
  final ta = na.split(' ').toSet();
  final tb = nb.split(' ').toSet();
  final union = ta.union(tb).length;
  var score = union == 0 ? 0.0 : ta.intersection(tb).length / union;
  if ((na.contains(nb) || nb.contains(na)) && score < 0.7) score = 0.7;
  return score;
}

/// Remembers the last episode opened for a title, per module.
class LastWatched {
  static String _key(String moduleId, String titleHref) => 'lumina.last.$moduleId.$titleHref';

  static Future<String?> get(String moduleId, String titleHref) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_key(moduleId, titleHref));
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(String moduleId, String titleHref, String episodeHref) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(moduleId, titleHref), episodeHref);
    } catch (_) {
      // Remembering the last episode is a convenience only.
    }
  }
}

/// Remembers whether the person last picked SUB or DUB.
class AudioPreference {
  static const _key = 'lumina.audio';

  static Future<String> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_key) == 'dub' ? 'dub' : 'sub';
    } catch (_) {
      return 'sub';
    }
  }

  static Future<void> save(String audio) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, audio);
    } catch (_) {
      // Convenience only.
    }
  }
}
