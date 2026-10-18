import 'dart:convert';
import 'dart:io';

import 'package:fjs/fjs.dart';

import 'modules_service.dart';

/// Executes a locally installed Lumina-compatible module in an isolated QuickJS
/// context. Each provider gets its own engine so globals/caches do not collide.
class LuminaModuleRuntime {
  static Future<void>? _libraryInit;

  final Map<String, JsEngine> _engines = {};
  final Map<String, Future<JsEngine>> _loading = {};

  Future<JsEngine> _engineFor(InstalledModule module) async {
    final existing = _engines[module.id];
    if (existing != null) return existing;
    final pending = _loading[module.id];
    if (pending != null) return pending;

    final future = _createEngine(module);
    _loading[module.id] = future;
    try {
      final engine = await future;
      _engines[module.id] = engine;
      return engine;
    } finally {
      _loading.remove(module.id);
    }
  }

  Future<JsEngine> _createEngine(InstalledModule module) async {
    final metadataFile = File('${module.directory}${Platform.pathSeparator}module.json');
    final metadata = jsonDecode(await metadataFile.readAsString());
    if (metadata is! Map) throw const FormatException('Module metadata is invalid.');
    final moduleSystem = '${metadata['moduleSystem'] ?? 'synthetiq'}'.toLowerCase();
    final contract = int.tryParse('${metadata['contractVersion'] ?? metadata['formatVersion'] ?? 0}') ?? 0;
    // Lumina-native modules use our small, stable API. Existing legacy module format
    // modules continue to use the published Contract V3+ handler contract.
    if (moduleSystem == 'lumina') {
      if (contract < 1) {
        throw FormatException('Unsupported Lumina module contract $contract. Lumina requires contract V1 or later.');
      }
    } else if (contract < 3) {
      throw FormatException('Unsupported legacy module contract $contract. Lumina requires Synthetiq Contract V3 or later.');
    }
    final contentType = '${metadata['contentType'] ?? 'video'}'.toLowerCase();
    if (!const {'video', 'image', 'text', 'music'}.contains(contentType)) {
      throw FormatException('Unsupported module content type: $contentType');
    }
    final config = metadata['config'] is Map ? metadata['config'] as Map : const {};
    final runtime = config['runtime'] is Map ? config['runtime'] as Map : const {};
    final entry = '${runtime['entry'] ?? 'index.js'}';
    if (entry.contains('..') || entry.startsWith('/') || entry.contains(r'\')) {
      throw const FormatException('Unsafe module entry path.');
    }
    final entryFile = File('${module.directory}${Platform.pathSeparator}$entry');
    if (!await entryFile.exists()) throw FormatException('Module entry file "$entry" was not found.');
    final source = await entryFile.readAsString();
    if (source.length > 2 * 1024 * 1024) {
      throw const FormatException('Module entry exceeds the 2 MB execution limit.');
    }

    await (_libraryInit ??= LibFjs.init());
    final engine = await JsEngine.create(
      builtins: JsBuiltinOptions.web(),
    );
    try {
      await engine.initWithoutBridge();
      // Legacy modules may use fetchv2(url, headers, method, body).
      // Adapt that contract to the runtime's Fetch API.
      await engine.eval(
        source: JsCode.code(r'''
          globalThis.fetchv2 = async function(url, headers, method, body) {
            const options = { method: method || 'GET', headers: headers || {} };
            if (body !== undefined && body !== null) options.body = body;
            const response = await fetch(String(url), options);
            const text = await response.text();
            const outHeaders = {};
            try { response.headers.forEach((v, k) => outHeaders[k] = v); } catch (_) {}
            return { ok: response.ok, status: response.status, body: text,
                     headers: outHeaders, url: response.url || String(url) };
          };
          globalThis.__luminaModuleReady = true;
        '''),
      );
      await engine.eval(source: JsCode.code(source));
      if (moduleSystem == 'lumina') {
        await engine.eval(source: JsCode.code(r'''
          const api = globalThis.LuminaModule;
          if (!api || api.apiVersion !== 1) {
            throw new Error('Lumina module must export globalThis.LuminaModule with apiVersion: 1.');
          }
          if (typeof api.search === 'function') globalThis.searchResults = (...args) => api.search(...args);
          if (typeof api.details === 'function') globalThis.extractDetails = (...args) => api.details(...args);
          if (typeof api.episodes === 'function') globalThis.extractEpisodes = (...args) => api.episodes(...args);
          if (typeof api.stream === 'function') globalThis.extractStreamUrl = (...args) => api.stream(...args);
          if (typeof api.home === 'function') globalThis.discoveryHome = (...args) => api.home(...args);
        '''), options: JsEvalOptions.withPromise());
      }
      final exports = await engine.eval(
        source: JsCode.code(r'''
          JSON.stringify({
            search: typeof globalThis.searchResults === 'function',
            details: typeof globalThis.extractDetails === 'function',
            episodes: typeof globalThis.extractEpisodes === 'function',
            stream: typeof globalThis.extractStreamUrl === 'function',
            chapters: typeof globalThis.extractChapters === 'function',
            images: typeof globalThis.extractImages === 'function',
            text: typeof globalThis.extractText === 'function',
            discoveryHome: typeof globalThis.discoveryHome === 'function',
            discoveryFeed: typeof globalThis.discoveryFeed === 'function'
          })
        '''),
      );
      final flags = jsonDecode('${exports.value}');
      final requiredHandlers = switch (contentType) {
        'video' => const ['search', 'details', 'episodes', 'stream'],
        'music' => const ['search', 'details', 'episodes', 'stream'],
        'image' => const ['search', 'details', 'chapters', 'images'],
        'text' => const ['search', 'details', 'chapters', 'text'],
        _ => const <String>[],
      };
      if (flags is! Map || requiredHandlers.any((name) => flags[name] != true)) {
        throw FormatException('Module does not expose all required handlers for content type "$contentType".');
      }
      return engine;
    } catch (_) {
      await engine.close();
      rethrow;
    }
  }

  Future<dynamic> call(
    InstalledModule module,
    String function, [
    List<dynamic> args = const [],
  ]) async {
    const allowed = {
      'searchResults', 'extractDetails', 'extractEpisodes', 'extractStreamUrl',
      'extractHome', 'discoveryHome', 'discoveryFeed',
      'extractChapters', 'extractImages', 'extractText',
    };
    if (!allowed.contains(function)) throw ArgumentError('Unsupported module function.');
    final engine = await _engineFor(module);
    final argsJson = jsonEncode(args);
    final source = 'JSON.stringify(await globalThis[${jsonEncode(function)}](...$argsJson))';
    final result = await engine.eval(
      source: JsCode.code(source),
      options: JsEvalOptions.withPromise(),
    );
    final value = result.value;
    if (value == null || value == 'undefined') return null;
    if (value is String) {
      try {
        return jsonDecode(value);
      } on FormatException {
        return value;
      }
    }
    return value;
  }

  Future<void> dispose() async {
    final engines = _engines.values.toList();
    _engines.clear();
    for (final engine in engines) {
      try {
        await engine.close();
      } catch (_) {}
    }
  }
}
