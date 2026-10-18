// Helpers for the loosely-typed episode and title cards that modules return.
//
// Used by the episode grid (title page) and by the player's "Switch module".

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
