import 'module_data.dart';
import 'modules_service.dart';
import 'synthetiq_module_runtime.dart';

/// The same episode, found on another module and ready to play.
class ModuleMatch {
  const ModuleMatch({
    required this.titleHref,
    required this.episodes,
    required this.index,
    required this.url,
    required this.headers,
  });

  final String titleHref;
  final List<EpisodeEntry> episodes;
  final int index;
  final String url;
  final Map<String, String> headers;
}

/// Finds [animeTitle] on [module], locates the matching episode and asks the
/// module for a playable stream. Throws a [StateError] with a readable message
/// when any step fails.
Future<ModuleMatch> resolveOnModule({
  required LuminaModuleRuntime runtime,
  required InstalledModule module,
  required String animeTitle,
  required String season,
  required int number,
  required String audio,
}) async {
  final results = asList(await runtime.call(module, 'searchResults', [animeTitle]));
  if (results.isEmpty) {
    throw StateError('${module.name} returned no results for "$animeTitle".');
  }

  dynamic best;
  var bestScore = 0.0;
  for (final result in results) {
    final score = titleSimilarity(animeTitle, moduleString(result, ['title', 'name']));
    if (score > bestScore) {
      bestScore = score;
      best = result;
    }
  }
  if (best == null || bestScore < 0.35) {
    throw StateError('${module.name} has no close match for "$animeTitle".');
  }

  final titleHref = moduleString(best, ['href', 'url', 'id', 'link']);
  if (titleHref.isEmpty) {
    throw StateError('${module.name} returned a match without a reference.');
  }

  final episodes = parseEpisodes(await runtime.call(module, 'extractEpisodes', [titleHref]));
  if (episodes.isEmpty) {
    throw StateError('${module.name} returned no episodes for this title.');
  }

  var index = episodes.indexWhere((e) => e.season == season && e.number == number);
  if (index < 0) index = episodes.indexWhere((e) => e.number == number);
  if (index < 0) {
    throw StateError('Episode $number was not found on ${module.name}.');
  }

  final stream = await runtime.call(module, 'extractStreamUrl', [episodes[index].href, audio, false]);
  final url = findStreamUrl(stream);
  if (url.isEmpty) {
    throw StateError('${module.name} did not return a playable link.');
  }

  return ModuleMatch(
    titleHref: titleHref,
    episodes: episodes,
    index: index,
    url: url,
    headers: findHeaders(stream),
  );
}
