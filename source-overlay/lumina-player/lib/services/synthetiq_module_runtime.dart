import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_js/flutter_js.dart';

import 'modules_service.dart';

/// Executes installed JavaScript modules in an isolated JavaScript context.
///
/// The module ZIP installer remains responsible for downloading and validating
/// packages. This class only loads the already-installed entry point and calls
/// the public handler functions exported on globalThis.
class LuminaModuleRuntime {
  final Map<String, _ModuleContext> _contexts = <String, _ModuleContext>{};
  bool _disposed = false;

  Future<dynamic> call(
    InstalledModule module,
    String handler, [
    List<dynamic> args = const <dynamic>[],
  ]) async {
    if (_disposed) {
      throw StateError('The module runtime has been disposed.');
    }
    if (!RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(handler)) {
      throw ArgumentError.value(handler, 'handler', 'Invalid JavaScript handler name.');
    }

    final context = await _contextFor(module);
    final argsJson = jsonEncode(args);
    final handlerJson = jsonEncode(handler);
    final result = await context.engine.evaluateAsync('''
      (async function() {
        const __luminaHandlerName = $handlerJson;
        const __luminaHandler = globalThis[__luminaHandlerName];
        if (typeof __luminaHandler !== 'function') {
          throw new Error('Module handler not found: ' + __luminaHandlerName);
        }
        const __luminaArgs = $argsJson;
        const __luminaValue = await __luminaHandler.apply(globalThis, __luminaArgs);
        return JSON.stringify(__luminaValue === undefined ? null : __luminaValue);
      })()
    ''');

    if (result.isError) {
      throw StateError('Module "${module.name}" handler "$handler" failed: ${result.stringResult}');
    }

    final raw = result.stringResult.trim();
    if (raw.isEmpty || raw == 'undefined') return null;
    try {
      final decoded = jsonDecode(raw);
      // Some JS engines expose the JSON.stringify result as a JSON string.
      if (decoded is String) {
        try {
          return jsonDecode(decoded);
        } on FormatException {
          return decoded;
        }
      }
      return decoded;
    } on FormatException {
      return raw;
    }
  }

  Future<_ModuleContext> _contextFor(InstalledModule module) async {
    final existing = _contexts[module.id];
    if (existing != null) return existing;

    final metadataFile = File('${module.directory}${Platform.pathSeparator}module.json');
    if (!await metadataFile.exists()) {
      throw FileSystemException('Installed module is missing module.json', metadataFile.path);
    }

    final metadataValue = jsonDecode(await metadataFile.readAsString());
    if (metadataValue is! Map) {
      throw FormatException('module.json for "${module.name}" must be a JSON object.');
    }
    final metadata = Map<String, dynamic>.from(metadataValue);
    final config = metadata['config'] is Map
        ? Map<String, dynamic>.from(metadata['config'] as Map)
        : <String, dynamic>{};
    final runtimeConfig = config['runtime'] is Map
        ? Map<String, dynamic>.from(config['runtime'] as Map)
        : <String, dynamic>{};
    final entry = (runtimeConfig['entry'] ?? 'index.js').toString();
    if (entry.isEmpty || entry.contains('..') || entry.startsWith('/') || entry.contains(r'\\')) {
      throw FormatException('Module "${module.name}" has an unsafe runtime entry path.');
    }

    final moduleRoot = Directory(module.directory).absolute;
    final entryFile = File('${moduleRoot.path}${Platform.pathSeparator}${entry.replaceAll('/', Platform.pathSeparator)}').absolute;
    final normalizedRoot = moduleRoot.path.endsWith(Platform.pathSeparator)
        ? moduleRoot.path
        : '${moduleRoot.path}${Platform.pathSeparator}';
    if (!entryFile.path.startsWith(normalizedRoot) || !await entryFile.exists()) {
      throw FileSystemException('Module entry file "$entry" was not found', entryFile.path);
    }

    final engine = getJavascriptRuntime();
    final source = await entryFile.readAsString();
    final loaded = await engine.evaluateAsync(source);
    if (loaded.isError) {
      engine.dispose();
      throw StateError('Could not load JavaScript for "${module.name}": ${loaded.stringResult}');
    }

    final context = _ModuleContext(engine);
    _contexts[module.id] = context;
    return context;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final context in _contexts.values) {
      context.engine.dispose();
    }
    _contexts.clear();
  }
}

class _ModuleContext {
  const _ModuleContext(this.engine);

  final JavascriptRuntime engine;
}
