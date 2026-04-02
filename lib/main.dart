import 'dart:async';

import 'package:flutter/material.dart';

import 'screens/logs_screen.dart';
import 'screens/maps_screen.dart';
import 'screens/avatar_assistant_screen.dart';
import 'screens/weather_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/lock_screen.dart';

import 'services/app_settings.dart';
import 'services/logs_command_bus.dart' as logsbus;
import 'services/map_command_bus.dart' as mapbus;
import 'services/settings_command_bus.dart' as settingsbus;
import 'services/weather_command_bus.dart' as weatherbus;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settings = await AppSettings.load();

  runApp(RoadDoggApp(settings: settings));
}

class RoadDoggApp extends StatelessWidget {
  const RoadDoggApp({super.key, required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'RoadDogg AI Assist',
          themeMode: settings.darkMode ? ThemeMode.dark : ThemeMode.light,
          theme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.light,
            scaffoldBackgroundColor: const Color(0xFFF4F4F4),
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.black,
              brightness: Brightness.light,
            ),
            snackBarTheme: const SnackBarThemeData(
              behavior: SnackBarBehavior.floating,
            ),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            scaffoldBackgroundColor: const Color(0xFF111111),
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.black,
              brightness: Brightness.dark,
            ),
            snackBarTheme: const SnackBarThemeData(
              behavior: SnackBarBehavior.floating,
            ),
          ),
          home: HomeShell(settings: settings),
          routes: {
            '/lock': (_) => const LockScreen(),
          },
        );
      },
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.settings});

  final AppSettings settings;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int index = 2;

  StreamSubscription<dynamic>? _mapCommandSub;
  StreamSubscription<weatherbus.WeatherCommand>? _weatherCommandSub;
  StreamSubscription<void>? _settingsCommandSub;
  StreamSubscription<void>? _logsCommandSub;

  final GlobalKey<MapsScreenState> _mapsKey = GlobalKey<MapsScreenState>();
  final GlobalKey<WeatherScreenState> _weatherKey =
      GlobalKey<WeatherScreenState>();

  final Set<int> _loadedTabs = {2};

  late final LogsScreen _logsScreen;
  late final MapsScreen _mapsScreen;
  late final AvatarAssistantScreen _assistantScreen;
  late final WeatherScreen _weatherScreen;
  late final SettingsScreen _settingsScreen;

  @override
  void initState() {
    super.initState();

    _logsScreen = const LogsScreen();
    _mapsScreen = MapsScreen(
      key: _mapsKey,
      settings: widget.settings,
    );
    _assistantScreen = AvatarAssistantScreen(settings: widget.settings);
    _weatherScreen = WeatherScreen(key: _weatherKey);
    _settingsScreen = SettingsScreen(settings: widget.settings);

    _mapCommandSub = mapbus.MapCommandBus.instance.stream.listen((command) {
      if (!mounted) return;

      setState(() {
        _loadedTabs.add(1);
        index = 1;
      });

      Future.delayed(const Duration(milliseconds: 150), () async {
        if (!mounted) return;

        await _mapsKey.currentState?.onTabVisible();

        final query = command.query.trim();
        if (query.isEmpty) return;

        final lower = query.toLowerCase();

        if (lower == 'truck stops' ||
            lower == 'truck stop' ||
            lower == 'fuel' ||
            lower == 'food' ||
            lower == 'parking' ||
            lower == 'repairs') {
          await _mapsKey.currentState?.runAssistantNearby(query);
        } else {
          await _mapsKey.currentState?.runAssistantSearch(query);
        }
      });
    });

    _weatherCommandSub =
        weatherbus.WeatherCommandBus.instance.stream.listen((command) {
      if (!mounted) return;

      setState(() {
        _loadedTabs.add(3);
        index = 3;
      });

      Future.delayed(const Duration(milliseconds: 180), () {
        if (!mounted) return;

        switch (command.type) {
          case weatherbus.WeatherCommandType.open:
            _weatherKey.currentState?.onTabVisible();
            break;
          case weatherbus.WeatherCommandType.city:
            final city = (command.city ?? '').trim();
            if (city.isNotEmpty) {
              _weatherKey.currentState?.searchCityFromAssistant(city);
            } else {
              _weatherKey.currentState?.onTabVisible();
            }
            break;
          case weatherbus.WeatherCommandType.radar:
            _weatherKey.currentState?.openRadarFromAssistant();
            break;
          case weatherbus.WeatherCommandType.refresh:
            _weatherKey.currentState?.refreshFromAssistant();
            break;
        }
      });
    });

    _settingsCommandSub =
        settingsbus.SettingsCommandBus.instance.stream.listen((_) {
      if (!mounted) return;
      setState(() {
        _loadedTabs.add(4);
        index = 4;
      });
    });

    _logsCommandSub = logsbus.LogsCommandBus.instance.stream.listen((_) {
      if (!mounted) return;
      setState(() {
        _loadedTabs.add(0);
        index = 0;
      });
    });
  }

  @override
  void dispose() {
    _mapCommandSub?.cancel();
    _weatherCommandSub?.cancel();
    _settingsCommandSub?.cancel();
    _logsCommandSub?.cancel();
    super.dispose();
  }

  void _onTabSelected(int newIndex) {
    setState(() {
      _loadedTabs.add(newIndex);
      index = newIndex;
    });

    if (newIndex == 1) {
      Future.delayed(const Duration(milliseconds: 150), () async {
        if (!mounted) return;
        await _mapsKey.currentState?.onTabVisible();
      });
    }

    if (newIndex == 3) {
      Future.delayed(const Duration(milliseconds: 150), () {
        if (!mounted) return;
        _weatherKey.currentState?.onTabVisible();
      });
    }
  }

  Widget _buildTab(int tabIndex) {
    if (!_loadedTabs.contains(tabIndex)) {
      return const SizedBox.shrink();
    }

    switch (tabIndex) {
      case 0:
        return _logsScreen;
      case 1:
        return _mapsScreen;
      case 2:
        return _assistantScreen;
      case 3:
        return _weatherScreen;
      case 4:
        return _settingsScreen;
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final navBg = isDark ? const Color(0xFF181818) : Colors.black;
    final navIndicator = isDark ? Colors.white10 : Colors.white24;
    final selectedColor = Colors.white;
    final unselectedColor = isDark ? Colors.white60 : Colors.white70;

    return Scaffold(
      body: IndexedStack(
        index: index,
        children: List.generate(5, _buildTab),
      ),
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: navBg,
          indicatorColor: navIndicator,
          iconTheme: WidgetStateProperty.resolveWith((states) {
            final selected = states.contains(WidgetState.selected);
            return IconThemeData(
              color: selected ? selectedColor : unselectedColor,
            );
          }),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            final selected = states.contains(WidgetState.selected);
            return TextStyle(
              color: selected ? selectedColor : unselectedColor,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            );
          }),
        ),
        child: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: _onTabSelected,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.article_outlined),
              label: 'Logs',
            ),
            NavigationDestination(
              icon: Icon(Icons.map_outlined),
              label: 'Maps',
            ),
            NavigationDestination(
              icon: Icon(Icons.mic_none),
              label: 'Assistant',
            ),
            NavigationDestination(
              icon: Icon(Icons.cloud_outlined),
              label: 'Weather',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}