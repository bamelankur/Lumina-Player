import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/modules_service.dart';
import 'module_browse_view.dart';

class ModulesScreen extends StatefulWidget {
  const ModulesScreen({super.key});

  @override
  State<ModulesScreen> createState() => _ModulesScreenState();
}

class _ModulesScreenState extends State<ModulesScreen> {
  int _tab = 0;
  final Set<String> _installing = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final service = context.read<ModulesService>();
      service.load();
      service.loadRepository();
    });
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _importZip() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['zip'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final bytes = result.files.single.bytes;
      if (bytes == null) {
        _message('Could not read that ZIP file. Try selecting it again.');
        return;
      }
      await context.read<ModulesService>().installFromFile(bytes);
      _message('Module ZIP imported. Check its compatibility before expecting playback.');
    } catch (e) {
      _message('Import failed: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  Future<void> _install(RepositoryModule module) async {
    setState(() => _installing.add(module.id));
    try {
      await context.read<ModulesService>().installFromRepository(module);
      _message('${module.name} ${module.version} installed and checksum verified.');
    } catch (e) {
      _message('Install failed: ${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _installing.remove(module.id));
    }
  }

  Future<void> _remove(InstalledModule module) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove module?'),
        content: Text('Remove ${module.name} from this device?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await context.read<ModulesService>().remove(module);
      _message('${module.name} removed.');
    } catch (e) {
      _message('Remove failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<ModulesService>();
    final installedIds = service.installed.map((m) => m.id).toSet();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('Installed')),
                    ButtonSegment(value: 1, label: Text('Repository')),
                    ButtonSegment(value: 2, label: Text('Browse')),
                  ],
                  selected: {_tab},
                  onSelectionChanged: (value) => setState(() => _tab = value.first),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: 'Import module ZIP',
                onPressed: _importZip,
                icon: const Icon(Icons.file_open_outlined),
              ),
              IconButton(
                tooltip: 'Refresh repository',
                onPressed: service.loading ? null : () {
                  service.load();
                  service.loadRepository();
                },
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Text(
            _tab == 2
                ? 'Browse executes installed Contract V4 video modules for search, details, episodes and stream resolution.'
                : 'Install modules from the repository or import a compatible ZIP. Contract V4 video modules can be searched from Browse.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        if (service.error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(service.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        Expanded(
          child: service.loading && service.installed.isEmpty && service.catalogue.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _tab == 0
                  ? _installedList(service)
                  : _tab == 1
                      ? _repositoryList(service, installedIds)
                      : const ModuleBrowseView(),
        ),
      ],
    );
  }

  Widget _installedList(ModulesService service) {
    if (service.installed.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.extension_outlined, size: 48),
              const SizedBox(height: 12),
              const Text('No modules installed yet.'),
              const SizedBox(height: 8),
              FilledButton.icon(onPressed: _importZip, icon: const Icon(Icons.upload_file), label: const Text('Import ZIP')),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: service.installed.length,
      itemBuilder: (context, index) {
        final module = service.installed[index];
        return ListTile(
          leading: const CircleAvatar(child: Icon(Icons.extension)),
          title: Text(module.name),
          subtitle: Text('${module.contentType} • v${module.version}\n${module.id}'),
          isThreeLine: true,
          trailing: IconButton(tooltip: 'Remove', onPressed: () => _remove(module), icon: const Icon(Icons.delete_outline)),
        );
      },
    );
  }

  Widget _repositoryList(ModulesService service, Set<String> installedIds) {
    if (service.catalogue.isEmpty && service.error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(service.error!)));
    }
    if (service.catalogue.isEmpty) return const Center(child: Text('No repository entries loaded. Tap refresh to retry.'));
    return ListView.builder(
      itemCount: service.catalogue.length,
      itemBuilder: (context, index) {
        final module = service.catalogue[index];
        final busy = _installing.contains(module.id);
        final installed = installedIds.contains(module.id);
        return ListTile(
          leading: const CircleAvatar(child: Icon(Icons.cloud_download_outlined)),
          title: Text(module.name),
          subtitle: Text('${module.contentType} • v${module.version}\n${module.id}'),
          isThreeLine: true,
          trailing: installed
              ? const Icon(Icons.check_circle_outline)
              : busy
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                  : IconButton(tooltip: 'Download and install', onPressed: () => _install(module), icon: const Icon(Icons.download)),
        );
      },
    );
  }
}
