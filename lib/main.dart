import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter/services.dart';

import 'screens/logs_screen.dart';
import 'screens/maps_screen.dart';
import 'screens/avatar_assistant_screen.dart';
import 'screens/weather_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/lock_screen.dart';

import 'services/app_settings.dart';
import 'services/logs_command_bus.dart' as logsbus;
import 'services/map_command_bus.dart' as mapbus;
import 'services/map_navigation_command_bus.dart' as mapnavbus;
import 'services/settings_command_bus.dart' as settingsbus;
import 'services/weather_command_bus.dart' as weatherbus;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await dotenv.load(fileName: '.env');

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
          builder: (context, child) {
            final theme = Theme.of(context);
            final isDark = theme.brightness == Brightness.dark;
            final bg = theme.scaffoldBackgroundColor;

            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: SystemUiOverlayStyle(
                statusBarColor: bg,
                statusBarIconBrightness:
                    isDark ? Brightness.light : Brightness.dark,
                statusBarBrightness:
                    isDark ? Brightness.dark : Brightness.light,
              ),
              child: child ?? const SizedBox.shrink(),
            );
          },
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

class _HomeShellState extends State<HomeShell>
    with SingleTickerProviderStateMixin {
  int index = 2;

  StreamSubscription<dynamic>? _mapCommandSub;
  StreamSubscription<mapnavbus.MapNavigateCommand>? _mapNavSub;
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

  late final AnimationController _tabFxCtrl;
  late final Animation<double> _tabFxOpacity;

  @override
  void initState() {
    super.initState();

    _tabFxCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _tabFxOpacity = CurvedAnimation(
      parent: _tabFxCtrl,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

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

    _mapNavSub =
        mapnavbus.MapNavigationCommandBus.instance.stream.listen((command) {
      if (!mounted) return;

      setState(() {
        _loadedTabs.add(1);
        index = 1;
      });

      Future.delayed(const Duration(milliseconds: 180), () async {
        if (!mounted) return;

        await _mapsKey.currentState?.onTabVisible();
        final state = _mapsKey.currentState;
        if (state == null) {
          command.reply?.complete(
            const mapnavbus.MapNavigationReply(
              ok: false,
              message: 'Maps is not ready yet.',
            ),
          );
          return;
        }

        final reply = await state.runAssistantNavigationCommand(command);
        if (command.reply != null && !command.reply!.isCompleted) {
          command.reply!.complete(reply);
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
    _mapNavSub?.cancel();
    _weatherCommandSub?.cancel();
    _settingsCommandSub?.cancel();
    _logsCommandSub?.cancel();
    _tabFxCtrl.dispose();
    super.dispose();
  }

  void _onTabSelected(int newIndex) {
    if (newIndex == index) return;

    setState(() {
      _loadedTabs.add(newIndex);
      index = newIndex;
    });

    _tabFxCtrl.forward(from: 0).then((_) {
      if (!mounted) return;
      _tabFxCtrl.reverse();
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
    final navSurface =
        isDark ? const Color(0xFF161616) : const Color(0xFF0F0F0F);
    final navBorder =
        isDark ? const Color(0xFF2A2A2A) : const Color(0x22FFFFFF);
    final navIndicator = isDark ? Colors.white10 : Colors.white12;
    const selectedColor = Colors.white;
    final unselectedColor = isDark ? Colors.white54 : Colors.white70;

    return Scaffold(
      body: Stack(
        children: [
          IndexedStack(
            index: index,
            children: List.generate(5, _buildTab),
          ),
          IgnorePointer(
            child: FadeTransition(
              opacity: Tween<double>(begin: 0, end: 1).animate(_tabFxOpacity),
              child: Container(
                color: (isDark ? Colors.white : Colors.black)
                    .withValues(alpha: 0.035),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: navSurface.withValues(alpha: isDark ? 0.92 : 0.88),
                borderRadius: BorderRadius.circular(26),
                border: Border.all(color: navBorder),
                boxShadow: isDark
                    ? const []
                    : const [
                        BoxShadow(
                          blurRadius: 24,
                          offset: Offset(0, 10),
                          color: Color(0x33000000),
                        ),
                      ],
              ),
              child: NavigationBarTheme(
                data: NavigationBarThemeData(
                  backgroundColor: Colors.transparent,
                  indicatorColor: navIndicator,
                  height: 72,
                  iconTheme: WidgetStateProperty.resolveWith((states) {
                    final selected = states.contains(WidgetState.selected);
                    return IconThemeData(
                      color: selected ? selectedColor : unselectedColor,
                      size: selected ? 26 : 24,
                    );
                  }),
                  labelTextStyle: WidgetStateProperty.resolveWith((states) {
                    final selected = states.contains(WidgetState.selected);
                    return TextStyle(
                      color: selected ? selectedColor : unselectedColor,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                      letterSpacing: 0.2,
                    );
                  }),
                ),
                child: NavigationBar(
                  selectedIndex: index,
                  onDestinationSelected: _onTabSelected,
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.article_outlined),
                      selectedIcon: Icon(Icons.article),
                      label: 'Logs',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.map_outlined),
                      selectedIcon: Icon(Icons.map),
                      label: 'Maps',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.mic_none),
                      selectedIcon: Icon(Icons.mic),
                      label: 'Assistant',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.cloud_outlined),
                      selectedIcon: Icon(Icons.cloud),
                      label: 'Weather',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.settings_outlined),
                      selectedIcon: Icon(Icons.settings),
                      label: 'Settings',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
