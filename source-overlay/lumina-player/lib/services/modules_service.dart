import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const synthetiqRepositoryUrl =
    'https://raw.githubusercontent.com/kas021/Synthetiq-Modules/main/repository.json';

class InstalledModule {
  const InstalledModule({
    required this.id,
    required this.name,
    required this.version,
    required this.contentType,
    required this.description,
    required this.directory,
    required this.hasEntryPoint,
  });

  final String id;
  final String name;
  final String version;
  final String contentType;
  final String description;
  final String directory;
  final bool hasEntryPoint;

  factory InstalledModule.fromJson(Map<String, dynamic> json, String directory) {
    return InstalledModule(
      id: (json['id'] ?? json['moduleId'] ?? '').toString(),
      name: (json['name'] ?? json['moduleId'] ?? 'Unknown module').toString(),
      version: (json['moduleVersion'] ?? json['version'] ?? 'unknown').toString(),
      contentType: (json['contentType'] ?? 'unknown').toString(),
      description: (json['description'] ?? '').toString(),
      directory: directory,
      hasEntryPoint: true,
    );
  }
}

class RepositoryModule {
  const RepositoryModule({
    required this.id,
    required this.name,
    required this.version,
    required this.contentType,
    required this.description,
    required this.packageUrl,
    required this.sha256,
  });

  final String id;
  final String name;
  final String version;
  final String contentType;
  final String description;
  final String packageUrl;
  final String sha256;

  factory RepositoryModule.fromJson(Map<String, dynamic> json) {
    return RepositoryModule(
      id: (json['moduleId'] ?? json['id'] ?? '').toString(),
      name: (json['moduleId'] ?? json['id'] ?? 'Module').toString(),
      version: (json['version'] ?? 'unknown').toString(),
      contentType: (json['contentType'] ?? 'unknown').toString(),
      description: (json['description'] ?? '').toString(),
      packageUrl: (json['packageUrl'] ?? '').toString(),
      sha256: (json['sha256'] ?? '').toString().toLowerCase(),
    );
  }
}

/// ZIP installer and read-only catalogue client. This installs module files and
/// validates packages; it does not execute untrusted JavaScript.
class ModulesService extends ChangeNotifier {
  List<InstalledModule> installed = [];
  List<RepositoryModule> catalogue = [];
  bool loading = false;
  String? error;

  Future<Directory> _root() async {
    final support = await getApplicationSupportDirectory();
    final root = Directory(p.join(support.path, 'lumina', 'modules'));
    if (!await root.exists()) await root.create(recursive: true);
    return root;
  }

  Future<void> load() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final root = await _root();
      final modules = <InstalledModule>[];
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final metadata = File(p.join(entity.path, 'module.json'));
        if (!await metadata.exists()) continue;
        try {
          final json = jsonDecode(await metadata.readAsString());
          if (json is Map<String, dynamic>) {
            modules.add(InstalledModule.fromJson(json, entity.path));
          }
        } catch (_) {
          // Ignore incomplete or malformed module folders.
        }
      }
      modules.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      installed = modules;
    } catch (e) {
      error = 'Could not read installed modules: $e';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> loadRepository() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      dynamic decoded;
      Object? rawFailure;
      try {
        final response = await http.get(Uri.parse(synthetiqRepositoryUrl)).timeout(
          const Duration(seconds: 20),
        );
        if (response.statusCode != 200) {
          throw HttpException('Raw repository returned HTTP ${response.statusCode}');
        }
        decoded = jsonDecode(response.body);
      } catch (e) {
        rawFailure = e;
        // Some networks can resolve github.com but fail to resolve
        // raw.githubusercontent.com. Use GitHub's Contents API as a fallback.
        try {
          final apiUri = Uri.parse(
            'https://api.github.com/repos/kas021/Synthetiq-Modules/contents/repository.json?ref=main',
          );
          final response = await http.get(apiUri, headers: const {
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
          }).timeout(const Duration(seconds: 25));
          if (response.statusCode != 200) {
            throw HttpException('GitHub API returned HTTP ${response.statusCode}');
          }
          final envelope = jsonDecode(response.body);
          if (envelope is! Map || envelope['content'] is! String) {
            throw const FormatException('GitHub API did not return repository file content.');
          }
          final encoded = (envelope['content'] as String).replaceAll(RegExp(r'\s'), '');
          decoded = jsonDecode(utf8.decode(base64Decode(encoded)));
        } catch (fallbackError) {
          throw HttpException(
            'Could not reach the module repository. Raw host error: $rawFailure. GitHub API fallback: $fallbackError',
          );
        }
      }
      if (decoded is! Map || decoded['modules'] is! List) {
        throw const FormatException('Repository catalogue format is not supported.');
      }
      final items = <RepositoryModule>[];
      for (final item in decoded['modules'] as List) {
        if (item is! Map) continue;
        final module = RepositoryModule.fromJson(Map<String, dynamic>.from(item));
        if (module.id.isNotEmpty && module.packageUrl.startsWith('https://') &&
            RegExp(r'^[a-f0-9]{64}$').hasMatch(module.sha256)) {
          items.add(module);
        }
      }
      items.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      catalogue = items;
    } catch (e) {
      error = 'Could not load module repository: $e';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> installFromFile(Uint8List bytes) async {
    await _installZip(bytes, expectedSha256: null);
  }

  Future<void> installFromRepository(RepositoryModule module) async {
    final response = await http.get(Uri.parse(module.packageUrl)).timeout(
      const Duration(seconds: 45),
    );
    if (response.statusCode != 200) {
      throw HttpException('Module download returned HTTP ${response.statusCode}');
    }
    final bytes = response.bodyBytes;
    final actual = sha256.convert(bytes).toString();
    if (actual != module.sha256) {
      throw const FormatException('SHA-256 verification failed; package was not installed.');
    }
    await _installZip(bytes, expectedSha256: module.sha256);
  }

  Future<void> _installZip(Uint8List bytes, {required String? expectedSha256}) async {
    if (bytes.isEmpty || bytes.length > 50 * 1024 * 1024) {
      throw const FormatException('ZIP is empty or exceeds the 50 MB safety limit.');
    }
    if (expectedSha256 != null && sha256.convert(bytes).toString() != expectedSha256) {
      throw const FormatException('SHA-256 verification failed.');
    }
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    if (archive.files.length > 1000) {
      throw const FormatException('ZIP contains too many files.');
    }
    final extracted = <String, List<int>>{};
    for (final file in archive.files) {
      if (file.isFile != true) continue;
      final name = file.name.replaceAll('\\', '/');
      final normalized = p.normalize(name);
      if (name.startsWith('/') || normalized == '..' || normalized.startsWith('../') ||
          normalized.contains('/../')) {
        throw const FormatException('ZIP contains an unsafe file path.');
      }
      if (file.size > 20 * 1024 * 1024) {
        throw const FormatException('A ZIP entry exceeds the 20 MB safety limit.');
      }
      final content = file.content;
      if (content is Uint8List) {
        extracted[normalized] = content;
      } else if (content is List<int>) {
        extracted[normalized] = content;
      }
    }
    // Synthetiq packages may name the manifest after the module, e.g.
    // example-module.json. The public contract expects one JSON manifest.
    final manifests = extracted.keys
        .where((key) => p.extension(key).toLowerCase() == '.json')
        .toList();
    if (manifests.length != 1) {
      throw FormatException('Expected exactly one JSON module manifest; found ${manifests.length}.');
    }
    final metadataPath = manifests.single;
    final metadata = jsonDecode(utf8.decode(extracted[metadataPath]!));
    if (metadata is! Map) throw const FormatException('module.json must be a JSON object.');
    final moduleJson = Map<String, dynamic>.from(metadata);
    final id = (moduleJson['id'] ?? moduleJson['moduleId'] ?? '').toString();
    final name = (moduleJson['name'] ?? id).toString();
    if (id.isEmpty || !RegExp(r'^[A-Za-z0-9._-]{1,100}$').hasMatch(id)) {
      throw const FormatException('module.json has a missing or invalid module id.');
    }
    final config = moduleJson['config'] is Map
        ? Map<String, dynamic>.from(moduleJson['config'] as Map)
        : <String, dynamic>{};
    final runtime = config['runtime'] is Map
        ? Map<String, dynamic>.from(config['runtime'] as Map)
        : <String, dynamic>{};
    final entry = (runtime['entry'] ?? 'index.js').toString();
    if (entry.isEmpty || entry.startsWith('/') || entry.contains('..') || entry.contains(r'\\')) {
      throw const FormatException('Module entry path is unsafe.');
    }
    final manifestPrefix = p.dirname(metadataPath);
    final normalizedEntry = p.normalize(p.join(manifestPrefix == '.' ? '' : manifestPrefix, entry));
    final hasEntry = extracted.containsKey(normalizedEntry);
    if (!hasEntry) throw FormatException('Module entry file "$entry" was not found in ZIP.');
    moduleJson['id'] = id;
    moduleJson['name'] = name.isEmpty ? id : name;
    moduleJson['moduleVersion'] ??= moduleJson['version'] ?? 'unknown';

    final root = await _root();
    final destination = Directory(p.join(root.path, id));
    final staging = Directory(p.join(root.path, '.install-$id-${DateTime.now().microsecondsSinceEpoch}'));
    final metadataSlash = metadataPath.indexOf('/');
    final zipRootPrefix = metadataSlash >= 0 ? metadataPath.substring(0, metadataSlash + 1) : '';
    await staging.create(recursive: true);
    try {
      for (final entry in extracted.entries) {
        final relative = entry.key.startsWith(zipRootPrefix)
            ? entry.key.substring(zipRootPrefix.length)
            : entry.key;
        if (relative.isEmpty || relative == '.' || relative.startsWith('../') || p.isAbsolute(relative)) continue;
        final out = File(p.join(staging.path, relative));
        await out.parent.create(recursive: true);
        await out.writeAsBytes(entry.value, flush: true);
      }
      await File(p.join(staging.path, 'module.json')).writeAsString(jsonEncode(moduleJson), flush: true);
      if (await destination.exists()) await destination.delete(recursive: true);
      await staging.rename(destination.path);
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
    await load();
  }

  Future<void> remove(InstalledModule module) async {
    final root = await _root();
    final normalizedRoot = p.normalize(root.path) + p.separator;
    final normalizedTarget = p.normalize(module.directory);
    if (!normalizedTarget.startsWith(normalizedRoot)) {
      throw const FormatException('Refusing to remove a module outside Lumina storage.');
    }
    final directory = Directory(normalizedTarget);
    if (await directory.exists()) await directory.delete(recursive: true);
    await load();
  }
}
