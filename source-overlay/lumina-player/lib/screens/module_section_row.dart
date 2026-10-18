import 'package:flutter/material.dart';

import 'module_browse_view.dart' show moduleString;
import 'module_poster_card.dart';

const _imageKeys = ['image', 'poster', 'posterUrl', 'imageUrl', 'cover'];

/// True for rows like "Trending Now" or "Top Anime", which are shown as a
/// numbered ranking.
bool isRankedSection(String title) =>
    RegExp(r'trend|\btop\b|popular|ranking|\bhot\b|most', caseSensitive: false).hasMatch(title);

/// One horizontally scrolling row on a module's home page: a title, an
/// optional "View all", and the cards.
class ModuleSectionRow extends StatelessWidget {
  const ModuleSectionRow({
    super.key,
    required this.title,
    required this.items,
    required this.onOpen,
  });

  final String title;
  final List<dynamic> items;
  final void Function(dynamic card) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ranked = isRankedSection(title) && items.length >= 3;
    final shown = items.take(ranked ? 10 : 20).toList();
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                if (ranked)
                  Container(
                    width: 4,
                    height: 22,
                    margin: const EdgeInsets.only(right: 10),
                    decoration: BoxDecoration(
                      color: Colors.amber,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                if (items.length > shown.length || items.length > 6)
                  TextButton(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => ModuleSectionGridPage(
                        title: title,
                        items: items,
                        onOpen: onOpen,
                      ),
                    )),
                    child: const Text('View all'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: ranked ? 200 : 210,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: shown.length,
              separatorBuilder: (_, __) => SizedBox(width: ranked ? 6 : 12),
              itemBuilder: (context, index) {
                final card = shown[index];
                if (ranked) {
                  return _RankedCard(
                    rank: index + 1,
                    image: moduleString(card, _imageKeys),
                    onTap: () => onOpen(card),
                  );
                }
                return SizedBox(
                  width: 130,
                  child: ModulePosterCard(
                    title: moduleString(card, const ['title', 'name']),
                    image: moduleString(card, _imageKeys),
                    subtitle: moduleString(card, const ['year']),
                    onTap: () => onOpen(card),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// A poster with a big outlined rank number over its lower-left corner.
class _RankedCard extends StatelessWidget {
  const _RankedCard({required this.rank, required this.image, required this.onTap});

  final int rank;
  final String image;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.amber;
    const base = TextStyle(fontSize: 76, fontWeight: FontWeight.w900, height: 1);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 150,
        child: Stack(
          children: [
            Positioned(
              left: 34,
              right: 0,
              top: 0,
              bottom: 0,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: moduleNetworkImage(image),
              ),
            ),
            Positioned(
              left: 0,
              bottom: 0,
              child: Stack(
                children: [
                  Text('$rank', style: base.copyWith(foreground: outline)),
                  Text('$rank', style: base.copyWith(color: Colors.black)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Every title of a section, as a grid ("View all").
class ModuleSectionGridPage extends StatelessWidget {
  const ModuleSectionGridPage({
    super.key,
    required this.title,
    required this.items,
    required this.onOpen,
  });

  final String title;
  final List<dynamic> items;
  final void Function(dynamic card) onOpen;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 14,
          crossAxisSpacing: 12,
          childAspectRatio: 0.55,
        ),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final card = items[index];
          return ModulePosterCard(
            title: moduleString(card, const ['title', 'name']),
            image: moduleString(card, _imageKeys),
            subtitle: moduleString(card, const ['year']),
            onTap: () => onOpen(card),
          );
        },
      ),
    );
  }
}
