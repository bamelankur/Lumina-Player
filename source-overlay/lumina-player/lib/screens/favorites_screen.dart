import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/media_item.dart';
import '../services/favorites_service.dart';
import '../services/library_service.dart';
import '../services/module_state_service.dart';
import '../services/modules_service.dart';
import '../services/synthetiq_module_runtime.dart';
import '../widgets/media_card.dart';
import 'module_poster_card.dart';
import 'module_browse_view.dart';
import 'photo_viewer_screen.dart';
import 'player_screen.dart';

/// Grid of favourites: titles hearted from modules on Home, plus favourited
/// files from the on-device library.
class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  final _runtime = LuminaModuleRuntime();

  @override
  void dispose() {
    _runtime.dispose();
    super.dispose();
  }

  void _openLocal(MediaItem item) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => item.type == MediaType.video
            ? PlayerScreen(item: item)
            : PhotoViewerScreen(item: item),
      ),
    );
  }

  Future<void> _openModuleFavourite(ModuleFavourite fav) async {
    InstalledModule? module;
    for (final m in context.read<ModulesService>().installed) {
      if (m.id == fav.moduleId) module = m;
    }
    if (module == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That module is no longer installed.')),
      );
      return;
    }
    await openModuleTitle(
      context,
      _runtime,
      module,
      {'title': fav.title, 'href': fav.href, 'image': fav.image},
    );
  }

  @override
  Widget build(BuildContext context) {
    final favIds = context.watch<FavoritesService>().ids.toSet();
    final localItems = context
        .watch<LibraryService>()
        .items
        .where((e) => favIds.contains(e.id))
        .toList();
    final moduleFavourites = context.watch<ModuleStateService>().favourites;

    if (localItems.isEmpty && moduleFavourites.isEmpty) {
      return const Center(
        child: Text('Tap the heart on anything to keep it here.'),
      );
    }
    final total = moduleFavourites.length + localItems.length;
    return SafeArea(
      bottom: false,
      child: GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          childAspectRatio: 0.62,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        itemCount: total,
        itemBuilder: (context, i) {
          if (i < moduleFavourites.length) {
            final fav = moduleFavourites[i];
            return ModulePosterCard(
              title: fav.title,
              image: fav.image,
              onTap: () => _openModuleFavourite(fav),
              onLongPress: () {
                context.read<ModuleStateService>().toggleFavourite(fav);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Removed ${fav.title} from favourites.')),
                );
              },
            );
          }
          final item = localItems[i - moduleFavourites.length];
          return MediaCard(item: item, onTap: () => _openLocal(item));
        },
      ),
    );
  }
}
