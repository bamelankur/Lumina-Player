import 'dart:convert';
import 'dart:io';

import 'modules_service.dart';

// Helpers for the loosely-typed episode and title cards that modules return.
//
// Used by the episode grid (title page) and by the player's "Switch module".


// ---------------------------------------------------------------------------
// Languages
// ---------------------------------------------------------------------------

/// One audio / subtitle language a module can serve. [id] is what gets passed
/// to the module's stream function (the same slot that used to carry
/// "sub" / "dub"), so existing modules keep working unchanged.
class ModuleLanguage {
  const ModuleLanguage(this.id, this.label);
  final String id;
  final String label;
}

const _languageNames = <String, String>{
  'sub': 'Sub',
  'subbed': 'Sub',
  'dub': 'Dub',
  'dubbed': 'Dub',
  'raw': 'Original',
  'original': 'Original',
  'en': 'English',
  'eng': 'English',
  'ja': 'Japanese',
  'jp': 'Japanese',
  'jpn': 'Japanese',
  'hi': 'Hindi',
  'hin': 'Hindi',
  'ta': 'Tamil',
  'tam': 'Tamil',
  'te': 'Telugu',
  'tel': 'Telugu',
  'ml': 'Malayalam',
  'kn': 'Kannada',
  'bn': 'Bengali',
  'mr': 'Marathi',
  'pa': 'Punjabi',
  'ur': 'Urdu',
  'es': 'Spanish',
  'spa': 'Spanish',
  'fr': 'French',
  'fra': 'French',
  'de': 'German',
  'ger': 'German',
  'it': 'Italian',
  'pt': 'Portuguese',
  'ptbr': 'Portuguese (Brazil)',
  'pt-br': 'Portuguese (Brazil)',
  'ru': 'Russian',
  'ko': 'Korean',
  'zh': 'Chinese',
  'cn': 'Chinese',
  'ar': 'Arabic',
  'tr': 'Turkish',
  'id': 'Indonesian',
  'th': 'Thai',
  'vi': 'Vietnamese',
  'pl': 'Polish',
  'nl': 'Dutch',
};

String languageLabel(String id) {
  final key = id.trim().toLowerCase();
  final known = _languageNames[key];
  if (known != null) return known;
  if (key.isEmpty) return id;
  return key
      .split(RegExp(r'[\s_\-]+'))
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1))
      .join(' ');
}

const _defaultLanguages = [ModuleLanguage('sub', 'Sub'), ModuleLanguage('dub', 'Dub')];

final Map<String, List<ModuleLanguage>?> _manifestLanguageCache = {};

ModuleLanguage? _languageFrom(dynamic raw) {
  if (raw is String) {
    final id = raw.trim();
    if (id.isEmpty) return null;
    return ModuleLanguage(id.toLowerCase(), languageLabel(id));
  }
  if (raw is Map) {
    var id = '';
    for (final key in const ['id', 'code', 'lang', 'language', 'value', 'name']) {
      final v = raw[key];
      if (v != null && v.toString().trim().isNotEmpty) {
        id = v.toString().trim();
        break;
      }
    }
    if (id.isEmpty) return null;
    var label = '';
    for (final key in const ['label', 'name', 'title']) {
      final v = raw[key];
      if (v != null && v.toString().trim().isNotEmpty) {
        label = v.toString().trim();
        break;
      }
    }
    return ModuleLanguage(id.toLowerCase(), label.isEmpty ? languageLabel(id) : label);
  }
  return null;
}

List<ModuleLanguage> _languagesFromList(dynamic raw) {
  final out = <ModuleLanguage>[];
  final seen = <String>{};
  Iterable<dynamic> items;
  if (raw is List) {
    items = raw;
  } else if (raw is String) {
    items = raw.split(RegExp(r'[,/|]'));
  } else {
    return out;
  }
  for (final item in items) {
    final lang = _languageFrom(item);
    if (lang != null && seen.add(lang.id)) out.add(lang);
  }
  return out;
}

/// Languages a module declares in its module.json, under `languages` (top
/// level or inside `config`). Read once per module.
List<ModuleLanguage>? _manifestLanguages(InstalledModule module) {
  final key = '${module.id}|${module.directory}';
  if (_manifestLanguageCache.containsKey(key)) return _manifestLanguageCache[key];
  List<ModuleLanguage>? result;
  try {
    final file = File('${module.directory}${Platform.pathSeparator}module.json');
    final data = jsonDecode(file.readAsStringSync());
    if (data is Map) {
      dynamic raw = data['languages'];
      if (raw == null && data['config'] is Map) raw = (data['config'] as Map)['languages'];
      final list = _languagesFromList(raw);
      if (list.isNotEmpty) result = list;
    }
  } catch (_) {
    result = null;
  }
  _manifestLanguageCache[key] = result;
  return result;
}

const _episodeLanguageKeys = ['languages', 'audios', 'audio', 'langs'];

/// The language ids/labels an episode says it is available in, if it says.
Set<String>? _episodeLanguages(dynamic episode) {
  if (episode is! Map) return null;
  for (final key in _episodeLanguageKeys) {
    final raw = episode[key];
    if (raw == null) continue;
    final list = _languagesFromList(raw);
    if (list.isEmpty) continue;
    return {
      for (final l in list) ...[l.id, l.label.toLowerCase()],
    };
  }
  return null;
}

/// The languages to offer for a title: the module's own declaration if it has
/// one, otherwise whatever the episodes advertise, otherwise Sub / Dub.
List<ModuleLanguage> languagesFor(InstalledModule module, List<dynamic> episodes) {
  final declared = _manifestLanguages(module);
  if (declared != null) return declared;

  final found = <ModuleLanguage>[];
  final seen = <String>{};
  for (final episode in episodes) {
    if (episode is! Map) continue;
    for (final key in _episodeLanguageKeys) {
      final raw = episode[key];
      if (raw == null) continue;
      for (final lang in _languagesFromList(raw)) {
        if (seen.add(lang.id)) found.add(lang);
      }
      break;
    }
  }
  final onlySubDub = found.every((l) => l.id == 'sub' || l.id == 'dub');
  if (found.isEmpty || onlySubDub) return _defaultLanguages;
  return found;
}

/// true / false when the episode itself says whether [languageId] exists for
/// it, null when it says nothing.
bool? episodeHasLanguage(dynamic episode, String languageId) {
  if (episode is! Map) return null;
  final id = languageId.toLowerCase();
  if (id == 'dub') {
    for (final key in const ['hasDub', 'dubbed', 'isDubbed', 'dubAvailable', 'dub']) {
      final raw = episode[key];
      if (raw is bool) return raw;
      if (raw is num) return raw != 0;
      if (raw is String) {
        final t = raw.trim().toLowerCase();
        if (t == 'true' || t == 'yes' || t == '1') return true;
        if (t == 'false' || t == 'no' || t == '0') return false;
      }
    }
  }
  final langs = _episodeLanguages(episode);
  if (langs == null) return null;
  return langs.contains(id) || langs.contains(languageLabel(id).toLowerCase());
}

String moduleText(dynamic value, List<String> keys) {
  if (value is! Map) return value is String ? value : '';
  for (final key in keys) {
    final candidate = value[key];
    if (candidate != null && candidate.toString().trim().isNotEmpty) {
      return candidate.toString();
    }
  }
  return '';
}

/// One entry of a module's episode list, with the season and number worked out.
/// [index] is the position in the module's own list (what the player uses).
class EpisodeInfo {
  const EpisodeInfo({
    required this.index,
    required this.href,
    required this.season,
    required this.number,
  });

  final int index;
  final String href;
  final String season;
  final int number;
}

int? _explicitNumber(dynamic episode) {
  if (episode is Map) {
    for (final key in const ['number', 'episode', 'episodeNumber', 'ep', 'num']) {
      final raw = episode[key];
      if (raw == null) continue;
      final parsed = num.tryParse(raw.toString().trim());
      if (parsed != null) return parsed.floor();
    }
  }
  final title = moduleText(episode, const ['title', 'name']).trim();
  final labelled = RegExp(r'ep(?:isode)?\.?\s*#?\s*(\d+)', caseSensitive: false).firstMatch(title);
  if (labelled != null) return int.tryParse(labelled.group(1)!);
  if (RegExp(r'^\d+$').hasMatch(title)) return int.tryParse(title);
  return null;
}

/// Works out season and number for every episode, keeping the module's order.
/// When a module gives no number, the position within its season is used.
List<EpisodeInfo> describeEpisodes(List<dynamic> episodes) {
  final out = <EpisodeInfo>[];
  final counters = <String, int>{};
  for (var i = 0; i < episodes.length; i++) {
    final episode = episodes[i];
    var season = moduleText(episode, const ['season', 'seasonNumber']).trim();
    if (season.isEmpty) season = '1';
    final position = (counters[season] ?? 0) + 1;
    counters[season] = position;
    out.add(EpisodeInfo(
      index: i,
      href: moduleText(episode, const ['href', 'url', 'id', 'link']),
      season: season,
      number: _explicitNumber(episode) ?? position,
    ));
  }
  return out;
}

/// Finds the same episode in another module's list: season and number first,
/// then number alone. Returns -1 when there is no match.
int matchEpisodeIndex(List<EpisodeInfo> episodes, String season, int number) {
  for (final e in episodes) {
    if (e.season == season && e.number == number && e.href.isNotEmpty) return e.index;
  }
  for (final e in episodes) {
    if (e.number == number && e.href.isNotEmpty) return e.index;
  }
  return -1;
}

String seasonLabel(String season) =>
    int.tryParse(season) != null ? 'Season $season' : season;

String _normalise(String value) {
  final cleaned = value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9À-￿]+'), ' ')
      .trim();
  const noise = {'dub', 'sub', 'dubbed', 'subbed', 'english', 'hd'};
  return cleaned.split(' ').where((w) => w.isNotEmpty && !noise.contains(w)).join(' ');
}

/// 0..1 similarity between two titles (word overlap, with a bonus when one
/// contains the other).
double titleSimilarity(String a, String b) {
  final na = _normalise(a);
  final nb = _normalise(b);
  if (na.isEmpty || nb.isEmpty) return 0;
  if (na == nb) return 1;
  final ta = na.split(' ').toSet();
  final tb = nb.split(' ').toSet();
  final union = ta.union(tb).length;
  var score = union == 0 ? 0.0 : ta.intersection(tb).length / union;
  if ((na.contains(nb) || nb.contains(na)) && score < 0.7) score = 0.7;
  return score;
}

/// The search result whose title is closest to [title], or null if none is
/// close enough to trust.
dynamic bestTitleMatch(String title, List<dynamic> results) {
  dynamic best;
  var bestScore = 0.0;
  for (final result in results) {
    final score = titleSimilarity(title, moduleText(result, const ['title', 'name']));
    if (score > bestScore) {
      bestScore = score;
      best = result;
    }
  }
  return bestScore >= 0.35 ? best : null;
}
