import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/downloads_screen.dart';
import 'screens/favorites_screen.dart';
import 'screens/home_screen.dart';
import 'screens/modules_page.dart';
import 'screens/settings_screen.dart';
import 'services/download_service.dart';
import 'services/favorites_service.dart';
import 'services/library_service.dart';
import 'services/module_state_service.dart';
import 'services/modules_service.dart';
import 'services/progress_service.dart';
import 'services/server_service.dart';
import 'services/sync_service.dart';

/// Root widget: provides services and holds the bottom navigation.
class LuminaApp extends StatelessWidget {
  const LuminaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => LibraryService()..load()),
        ChangeNotifierProvider(create: (_) => DownloadService()..load()),
        ChangeNotifierProvider(create: (_) => FavoritesService()..load()),
        ChangeNotifierProvider(create: (_) => ProgressService()..load()),
        ChangeNotifierProvider(create: (_) => SyncService()..load()),
        ChangeNotifierProvider(create: (_) => ServerService()..load()),
        ChangeNotifierProvider(create: (_) => ModulesService()..load()),
        ChangeNotifierProvider(create: (_) => ModuleStateService()..load()),
      ],
      child: MaterialApp(
        title: 'Lumina',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: Colors.deepPurple,
          brightness: Brightness.light,
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorSchemeSeed: Colors.deepPurple,
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        home: const _Shell(),
      ),
    );
  }
}

class _Shell extends StatefulWidget {
  const _Shell();

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  int _index = 0;

  static const _titles = ['Home', 'Downloads', 'Favourites', 'Modules', 'Settings'];

  static const _screens = [
    HomeScreen(),
    DownloadsScreen(),
    FavoritesScreen(),
    ModulesScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Home draws its own header (module picker + search), so no app bar there.
      appBar: _index == 0 ? null : AppBar(title: Text(_titles[_index])),
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'Home'),
          NavigationDestination(
              icon: Icon(Icons.download_outlined),
              selectedIcon: Icon(Icons.download),
              label: 'Downloads'),
          NavigationDestination(
              icon: Icon(Icons.favorite_border),
              selectedIcon: Icon(Icons.favorite),
              label: 'Favourites'),
          NavigationDestination(
              icon: Icon(Icons.extension_outlined),
              selectedIcon: Icon(Icons.extension),
              label: 'Modules'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings'),
        ],
      ),
    );
  }
}
