import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../services/app_settings.dart';

class WeatherScreen extends StatefulWidget {
  const WeatherScreen({super.key});

  @override
  State<WeatherScreen> createState() => WeatherScreenState();
}

class WeatherScreenState extends State<WeatherScreen> {
  final TextEditingController _searchController = TextEditingController();
  final MapController _radarSheetController = MapController();

  AppSettings? _settings;

  bool _loading = true;
  bool _isSearchingCity = false;
  bool _radarLoading = false;

  String? _error;

  String _locationName = 'Current Location';
  String _currentTemp = '--';
  String _currentCondition = '--';
  String _feelsLike = '--';
  String _wind = '--';
  String _humidity = '--';
  String _visibility = '--';
  String _roadOutlook = '--';
  String _lastUpdated = '--';

  double? _currentLatitude;
  double? _currentLongitude;

  String? _radarTileTemplate;
  DateTime? _radarFrameTime;
  List<_RadarFrame> _radarFrames = const [];
  int _selectedRadarFrameIndex = 0;

  List<ForecastDayItem> _forecast = const [];
  List<HourlyForecastItem> _hourly = const [];
  List<AlertItem> _alerts = const [];

  static const Map<String, IconData> _iconMap = {
    'sunny': Icons.wb_sunny_outlined,
    'clear': Icons.wb_sunny_outlined,
    'mostly sunny': Icons.wb_sunny_outlined,
    'partly sunny': Icons.wb_sunny_outlined,
    'partly cloudy': Icons.wb_cloudy_outlined,
    'mostly cloudy': Icons.wb_cloudy_outlined,
    'cloudy': Icons.cloud_outlined,
    'rain': Icons.grain,
    'showers': Icons.grain,
    'drizzle': Icons.grain,
    'thunder': Icons.thunderstorm_outlined,
    'storm': Icons.thunderstorm_outlined,
    'snow': Icons.ac_unit,
    'sleet': Icons.ac_unit,
    'fog': Icons.blur_on,
    'mist': Icons.blur_on,
    'haze': Icons.blur_on,
  };

  bool get _useCelsius => (_settings?.temperatureUnit ?? 'Fahrenheit') == 'Celsius';
  bool get _useKilometers => (_settings?.distanceUnit ?? 'Miles') == 'Kilometers';

  @override
  void initState() {
    super.initState();
    _initSettingsAndWeather();
  }

  Future<void> _initSettingsAndWeather() async {
    final settings = await AppSettings.load();
    settings.addListener(_handleSettingsChanged);
    if (!mounted) return;
    setState(() => _settings = settings);
    await _loadWeatherFromCurrentLocation();
  }

  void _handleSettingsChanged() {
    if (!mounted) return;
    setState(() {});
    if (_currentLatitude != null && _currentLongitude != null) {
      _loadWeatherForCoordinates(
        latitude: _currentLatitude!,
        longitude: _currentLongitude!,
        customLocationName: _locationName,
      );
    }
  }

  @override
  void dispose() {
    _settings?.removeListener(_handleSettingsChanged);
    _searchController.dispose();
    super.dispose();
  }

  void onTabVisible() {}

  Future<void> searchCityFromAssistant(String city) async {
    final trimmed = city.trim();
    if (trimmed.isEmpty) return;
    _searchController.text = trimmed;
    await _searchSpecificCity(trimmed);
  }

  Future<void> refreshFromAssistant() async {
    await _loadWeatherFromCurrentLocation();
  }

  void openRadarFromAssistant() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _showRadarSheet();
    });
  }

  Color _bg(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF111111)
          : const Color(0xFFF4F4F4);

  Color _card(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF1A1A1A)
          : Colors.white;

  Color _softCard(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF222222)
          : const Color(0xFFF7F7F7);

  Color _border(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF2D2D2D)
          : const Color(0xFFEAEAEA);

  Color _text(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? Colors.white
          : Colors.black87;

  Color _subtext(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? Colors.white70
          : Colors.black54;

  Future<void> _loadWeatherFromCurrentLocation() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw Exception('Location services are off.');
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw Exception('Location permission not granted.');
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      await _loadWeatherForCoordinates(
        latitude: position.latitude,
        longitude: position.longitude,
        customLocationName: null,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _searchCityWeather() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;
    await _searchSpecificCity(query);
  }

  Future<void> _searchSpecificCity(String query) async {
    FocusScope.of(context).unfocus();

    setState(() {
      _isSearchingCity = true;
      _error = null;
    });

    try {
      final encoded = Uri.encodeQueryComponent(query);
      final url =
          'https://geocoding-api.open-meteo.com/v1/search?name=$encoded&count=1&language=en&format=json';

      final res = await http.get(Uri.parse(url));

      if (res.statusCode != 200) {
        throw Exception('City search failed.');
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final results = (data['results'] as List<dynamic>? ?? []);

      if (results.isEmpty) {
        throw Exception('No city found for "$query".');
      }

      final first = results.first as Map<String, dynamic>;
      final lat = (first['latitude'] as num).toDouble();
      final lon = (first['longitude'] as num).toDouble();
      final name = first['name']?.toString() ?? query;
      final admin1 = first['admin1']?.toString() ?? '';
      final country = first['country']?.toString() ?? '';

      final customName = [
        name,
        if (admin1.isNotEmpty) admin1,
        if (country.isNotEmpty) country,
      ].join(', ');

      if (!mounted) return;
      setState(() {
        _loading = true;
        _isSearchingCity = false;
      });

      await _loadWeatherForCoordinates(
        latitude: lat,
        longitude: lon,
        customLocationName: customName,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSearchingCity = false;
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _loadWeatherForCoordinates({
    required double latitude,
    required double longitude,
    String? customLocationName,
  }) async {
    try {
      const headers = {
        'Accept': 'application/geo+json',
        'User-Agent': 'RoadDogg AI Assist (support@roaddogg.local)',
      };

      final pointsRes = await http.get(
        Uri.parse('https://api.weather.gov/points/$latitude,$longitude'),
        headers: headers,
      );

      if (pointsRes.statusCode != 200) {
        throw Exception('NOAA points lookup failed.');
      }

      final pointsData = jsonDecode(pointsRes.body) as Map<String, dynamic>;
      final props = pointsData['properties'] as Map<String, dynamic>;

      final forecastUrl = props['forecast']?.toString() ?? '';
      final hourlyUrl = props['forecastHourly']?.toString() ?? '';
      final forecastZoneUrl = props['forecastZone']?.toString() ?? '';
      final stationsUrl = props['observationStations']?.toString() ?? '';
      final relativeLocation =
          props['relativeLocation']?['properties'] as Map<String, dynamic>?;

      String resolvedLocation;
      if (customLocationName != null && customLocationName.isNotEmpty) {
        resolvedLocation = customLocationName;
      } else {
        final city = relativeLocation?['city']?.toString() ?? 'Current Location';
        final state = relativeLocation?['state']?.toString() ?? '';
        resolvedLocation = state.isEmpty ? city : '$city, $state';
      }

      if (forecastUrl.isEmpty || hourlyUrl.isEmpty) {
        throw Exception('Forecast links missing from NOAA response.');
      }

      final forecastRes =
          await http.get(Uri.parse(forecastUrl), headers: headers);
      final hourlyRes = await http.get(Uri.parse(hourlyUrl), headers: headers);

      if (forecastRes.statusCode != 200 || hourlyRes.statusCode != 200) {
        throw Exception('NOAA forecast request failed.');
      }

      http.Response? alertsRes;
      if (forecastZoneUrl.isNotEmpty) {
        final zoneId = forecastZoneUrl.split('/').last;
        alertsRes = await http.get(
          Uri.parse('https://api.weather.gov/alerts/active?zone=$zoneId'),
          headers: headers,
        );
      }

      final forecastData = jsonDecode(forecastRes.body) as Map<String, dynamic>;
      final hourlyData = jsonDecode(hourlyRes.body) as Map<String, dynamic>;

      final dailyPeriods =
          (((forecastData['properties'] as Map<String, dynamic>)['periods'])
                      as List<dynamic>? ??
                  [])
              .cast<Map<String, dynamic>>();

      final hourlyPeriods =
          (((hourlyData['properties'] as Map<String, dynamic>)['periods'])
                      as List<dynamic>? ??
                  [])
              .cast<Map<String, dynamic>>();

      if (dailyPeriods.isEmpty || hourlyPeriods.isEmpty) {
        throw Exception('NOAA returned no forecast periods.');
      }

      final latestObservation = await _loadLatestObservation(
        stationsUrl: stationsUrl,
        headers: headers,
      );

      final currentFallback = hourlyPeriods.first;

      if (!mounted) return;
      setState(() {
        _currentLatitude = latitude;
        _currentLongitude = longitude;
        _locationName = resolvedLocation;
        _currentTemp = latestObservation.temperature ??
            _formatDisplayTemp(
              value: (currentFallback['temperature'] as num?)?.toDouble(),
              sourceUnit: (currentFallback['temperatureUnit'] ?? 'F').toString(),
            );
        _currentCondition = latestObservation.condition ??
            currentFallback['shortForecast']?.toString() ??
            '--';
        _feelsLike = latestObservation.feelsLike ?? _currentTemp;
        _wind = latestObservation.wind ?? _buildWind(currentFallback);
        _humidity = latestObservation.humidity ??
            _extractPercent(
              currentFallback['relativeHumidity'] as Map<String, dynamic>?,
            );
        _visibility = latestObservation.visibility ??
            _extractVisibility(
              currentFallback['visibility'] as Map<String, dynamic>?,
            );
        _roadOutlook =
            (dailyPeriods.first['detailedForecast']?.toString() ?? '--').trim();
        _forecast = _buildForecastDays(dailyPeriods);
        _hourly = _buildHourly(hourlyPeriods);
        _alerts = _buildAlerts(alertsRes);
        _lastUpdated = _formatNow(DateTime.now());
        _loading = false;
        _error = null;
      });

      await _loadRadarFrame();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _loadRadarFrame() async {
    if (!mounted) return;

    setState(() {
      _radarLoading = true;
    });

    try {
      final res = await http.get(
        Uri.parse('https://api.rainviewer.com/public/weather-maps.json'),
      );

      if (res.statusCode != 200) {
        throw Exception('Radar feed unavailable.');
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final host = data['host']?.toString() ?? '';
      final radar = data['radar'] as Map<String, dynamic>? ?? {};
      final past = (radar['past'] as List<dynamic>? ?? []);
      final nowcast = (radar['nowcast'] as List<dynamic>? ?? []);

      final combined = <Map<String, dynamic>>[
        ...past.cast<Map<String, dynamic>>(),
        ...nowcast.cast<Map<String, dynamic>>(),
      ];

      if (host.isEmpty || combined.isEmpty) {
        throw Exception('Radar frames unavailable.');
      }

      final frames = combined.map((frame) {
        final path = frame['path']?.toString() ?? '';
        final timeUnix = frame['time'];

        return _RadarFrame(
          tileTemplate: '$host$path/256/{z}/{x}/{y}/6/1_1.png',
          time: timeUnix is num
              ? DateTime.fromMillisecondsSinceEpoch(timeUnix.toInt() * 1000)
              : DateTime.now(),
        );
      }).where((f) => f.tileTemplate.isNotEmpty).toList();

      if (frames.isEmpty) {
        throw Exception('Radar frames unavailable.');
      }

      if (!mounted) return;
      setState(() {
        _radarFrames = frames;
        _selectedRadarFrameIndex = frames.length - 1;
        _radarTileTemplate = frames.last.tileTemplate;
        _radarFrameTime = frames.last.time;
        _radarLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _radarLoading = false;
      });
    }
  }

  Future<_LatestObservation> _loadLatestObservation({
    required String stationsUrl,
    required Map<String, String> headers,
  }) async {
    try {
      if (stationsUrl.isEmpty) return const _LatestObservation();

      final stationsRes =
          await http.get(Uri.parse(stationsUrl), headers: headers);
      if (stationsRes.statusCode != 200) {
        return const _LatestObservation();
      }

      final stationsData = jsonDecode(stationsRes.body) as Map<String, dynamic>;
      final features =
          (stationsData['features'] as List<dynamic>? ?? [])
              .cast<Map<String, dynamic>>();

      if (features.isEmpty) return const _LatestObservation();

      final stationId =
          (features.first['properties'] as Map<String, dynamic>)[
                      'stationIdentifier']
                  ?.toString() ??
              '';

      if (stationId.isEmpty) return const _LatestObservation();

      final latestRes = await http.get(
        Uri.parse(
          'https://api.weather.gov/stations/$stationId/observations/latest',
        ),
        headers: headers,
      );

      if (latestRes.statusCode != 200) {
        return const _LatestObservation();
      }

      final latestData = jsonDecode(latestRes.body) as Map<String, dynamic>;
      final props = latestData['properties'] as Map<String, dynamic>? ?? {};

      final tempC = _numValue(props['temperature']);
      final feelsC =
          _numValue(props['heatIndex']) ?? _numValue(props['windChill']);
      final humidity = _numValue(props['relativeHumidity']);
      final visibilityM = _numValue(props['visibility']);
      final windSpeedMs = _numValue(props['windSpeed']);
      final windDir = _numValue(props['windDirection']);
      final textDescription = props['textDescription']?.toString();

      return _LatestObservation(
        temperature: tempC == null ? null : _formatTempFromC(tempC),
        feelsLike: feelsC == null ? null : _formatTempFromC(feelsC),
        humidity: humidity == null ? null : '${humidity.round()}%',
        visibility: visibilityM == null ? null : _metersToDistanceText(visibilityM),
        wind: _buildObservationWind(windSpeedMs, windDir),
        condition: textDescription,
      );
    } catch (_) {
      return const _LatestObservation();
    }
  }

  num? _numValue(dynamic mapLike) {
    if (mapLike is Map<String, dynamic>) {
      final value = mapLike['value'];
      if (value is num) return value;
    }
    return null;
  }

  String _formatTempFromC(num c) {
    if (_useCelsius) return '${c.round()}°C';
    final f = ((c * 9 / 5) + 32).round();
    return '$f°F';
  }

  String _formatDisplayTemp({
    required double? value,
    required String sourceUnit,
  }) {
    if (value == null) return '--';
    final upper = sourceUnit.toUpperCase();
    if (_useCelsius) {
      if (upper == 'C') return '${value.round()}°C';
      final c = ((value - 32) * 5 / 9).round();
      return '$c°C';
    } else {
      if (upper == 'F') return '${value.round()}°F';
      final f = ((value * 9 / 5) + 32).round();
      return '$f°F';
    }
  }

  String _metersToDistanceText(num meters) {
    if (_useKilometers) {
      final km = meters / 1000;
      return '${km.toStringAsFixed(km >= 10 ? 0 : 1)} km';
    }
    final miles = meters / 1609.344;
    if (miles >= 9.5) return '10 mi';
    return '${miles.toStringAsFixed(1)} mi';
  }

  String? _buildObservationWind(num? speedMs, num? directionDeg) {
    if (speedMs == null) return null;
    final mph = (speedMs * 2.23694).round();
    final kph = (speedMs * 3.6).round();
    final speedText = _useKilometers ? '$kph km/h' : '$mph mph';
    final dir =
        directionDeg == null ? '' : _compassDirection(directionDeg.toDouble());
    if (dir.isEmpty) return speedText;
    return '$speedText $dir';
  }

  String _compassDirection(double degrees) {
    const dirs = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    final index = (((degrees % 360) / 45).round()) % 8;
    return dirs[index];
  }

  String _buildWind(Map<String, dynamic> period) {
    final speed = period['windSpeed']?.toString() ?? '--';
    final dir = period['windDirection']?.toString() ?? '';
    if (dir.isEmpty) return speed;
    return '$speed $dir';
  }

  String _extractPercent(Map<String, dynamic>? data) {
    final value = data?['value'];
    if (value is num) return '${value.round()}%';
    return '--';
  }

  String _extractVisibility(Map<String, dynamic>? data) {
    final value = data?['value'];
    if (value is! num) return '--';
    return _metersToDistanceText(value);
  }

  List<HourlyForecastItem> _buildHourly(List<Map<String, dynamic>> periods) {
    return periods.take(12).map((p) {
      final dt = DateTime.tryParse(p['startTime']?.toString() ?? '');
      final temp = _formatDisplayTemp(
        value: (p['temperature'] as num?)?.toDouble(),
        sourceUnit: (p['temperatureUnit'] ?? 'F').toString(),
      );
      final condition = p['shortForecast']?.toString() ?? '--';
      final detail = p['detailedForecast']?.toString() ?? condition;
      final precip = _extractPercent(
        p['probabilityOfPrecipitation'] as Map<String, dynamic>?,
      );

      return HourlyForecastItem(
        label: _formatHour(dt),
        temp: temp,
        condition: condition,
        detail: detail,
        precip: precip,
        icon: _iconForForecast(condition),
        startTime: dt,
      );
    }).toList();
  }

  List<ForecastDayItem> _buildForecastDays(List<Map<String, dynamic>> periods) {
    final result = <ForecastDayItem>[];

    for (final period in periods) {
      if (period['isDaytime'] != true) continue;

      final int? number = period['number'] as int?;
      Map<String, dynamic>? nightMatch;

      if (number != null) {
        for (final p in periods) {
          if (p['number'] == number + 1) {
            nightMatch = p;
            break;
          }
        }
      }

      final dayName = _shortDay(period['name']?.toString() ?? 'Day');
      final high = _formatDisplayTemp(
        value: (period['temperature'] as num?)?.toDouble(),
        sourceUnit: (period['temperatureUnit'] ?? 'F').toString(),
      );
      final low = nightMatch == null
          ? '--'
          : _formatDisplayTemp(
              value: (nightMatch['temperature'] as num?)?.toDouble(),
              sourceUnit: (nightMatch['temperatureUnit'] ?? 'F').toString(),
            );

      result.add(
        ForecastDayItem(
          day: dayName,
          fullLabel: period['name']?.toString() ?? 'Day',
          condition: period['shortForecast']?.toString() ?? '--',
          high: high,
          low: low,
          detail: period['detailedForecast']?.toString() ?? '--',
          icon: _iconForForecast(period['shortForecast']?.toString() ?? '--'),
        ),
      );

      if (result.length == 5) break;
    }

    return result;
  }

  List<AlertItem> _buildAlerts(http.Response? res) {
    if (res == null || res.statusCode != 200) return const [];

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final features =
        (data['features'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();

    return features.take(5).map((f) {
      final props = (f['properties'] as Map<String, dynamic>? ?? {});
      return AlertItem(
        headline: props['headline']?.toString() ?? 'Weather Alert',
        event: props['event']?.toString() ?? 'Alert',
        severity: props['severity']?.toString() ?? 'Unknown',
        urgency: props['urgency']?.toString() ?? 'Unknown',
        areaDesc: props['areaDesc']?.toString() ?? '',
        description: props['description']?.toString() ?? 'No details available.',
        instruction: props['instruction']?.toString() ?? '',
      );
    }).toList();
  }

  String _formatHour(DateTime? dt) {
    if (dt == null) return '--';
    final hour = dt.hour;
    final suffix = hour >= 12 ? 'PM' : 'AM';
    final display = hour % 12 == 0 ? 12 : hour % 12;
    return '$display$suffix';
  }

  String _formatNow(DateTime dt) {
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final suffix = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $suffix';
  }

  String _formatRadarTime(DateTime? dt) {
    if (dt == null) return '--';
    final local = dt.toLocal();
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final suffix = local.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $suffix';
  }

  String _shortDay(String input) {
    const map = {
      'monday': 'Mon',
      'tuesday': 'Tue',
      'wednesday': 'Wed',
      'thursday': 'Thu',
      'friday': 'Fri',
      'saturday': 'Sat',
      'sunday': 'Sun',
      'tonight': 'Tonight',
      'today': 'Today',
      'this afternoon': 'Today',
      'overnight': 'Overnight',
    };

    final lower = input.toLowerCase().trim();
    return map[lower] ?? input;
  }

  IconData _iconForForecast(String text) {
    final lower = text.toLowerCase();
    for (final entry in _iconMap.entries) {
      if (lower.contains(entry.key)) return entry.value;
    }
    return Icons.cloud_outlined;
  }

  List<HourlyForecastItem> _hourlyForDay(ForecastDayItem day) {
    if (_hourly.isEmpty) return const [];

    if (day.day == 'Today') {
      return _hourly.take(8).toList();
    }

    final target = day.fullLabel.toLowerCase();
    final filtered = _hourly.where((item) {
      final dt = item.startTime;
      if (dt == null) return false;
      final weekday = _weekdayName(dt.weekday).toLowerCase();
      return target.contains(weekday);
    }).toList();

    return filtered.isEmpty ? _hourly.take(8).toList() : filtered.take(8).toList();
  }

  String _weekdayName(int weekday) {
    const names = [
      'monday',
      'tuesday',
      'wednesday',
      'thursday',
      'friday',
      'saturday',
      'sunday',
    ];
    return names[weekday - 1];
  }

  int? _parseTempNumber(String text) {
    final match = RegExp(r'-?\d+').firstMatch(text);
    return match == null ? null : int.tryParse(match.group(0)!);
  }

  int? _parsePercentNumber(String text) {
    final match = RegExp(r'\d+').firstMatch(text);
    return match == null ? null : int.tryParse(match.group(0)!);
  }

  void _showTodaySheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Icon(
                      _iconForForecast(_currentCondition),
                      size: 30,
                      color: _text(context),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Today • $_locationName',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: _text(context),
                        ),
                      ),
                    ),
                    Text(
                      _currentTemp,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: _text(context),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _currentCondition,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: _text(context),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Feels like $_feelsLike • Updated $_lastUpdated',
                    style: TextStyle(
                      fontSize: 13,
                      color: _subtext(context),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: _MiniMetricCard(
                        label: 'Wind',
                        value: _wind,
                        dark: Theme.of(context).brightness == Brightness.dark,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _MiniMetricCard(
                        label: 'Humidity',
                        value: _humidity,
                        dark: Theme.of(context).brightness == Brightness.dark,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _MiniMetricCard(
                        label: 'Visibility',
                        value: _visibility,
                        dark: Theme.of(context).brightness == Brightness.dark,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _InfoBox(
                  title: 'Today\'s Road Outlook',
                  value: _roadOutlook,
                  dark: Theme.of(context).brightness == Brightness.dark,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showHourlySheet(HourlyForecastItem item) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 42,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Icon(item.icon, size: 30, color: _text(context)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${item.label} • ${item.temp}',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: _text(context),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  item.condition,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: _text(context),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _MiniMetricCard(
                      label: 'Temp',
                      value: item.temp,
                      dark: Theme.of(context).brightness == Brightness.dark,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _MiniMetricCard(
                      label: 'Rain Chance',
                      value: item.precip,
                      dark: Theme.of(context).brightness == Brightness.dark,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _softCard(context),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: _border(context)),
                ),
                child: Text(
                  item.detail,
                  style: TextStyle(
                    color: _text(context),
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDailySheet(ForecastDayItem item) {
    final dayHours = _hourlyForDay(item);

    final temps =
        dayHours.map((e) => _parseTempNumber(e.temp)).whereType<int>().toList();

    final precips =
        dayHours.map((e) => _parsePercentNumber(e.precip)).whereType<int>().toList();

    final maxTemp =
        temps.isEmpty ? '--' : '${temps.reduce((a, b) => a > b ? a : b)}°';
    final minTemp =
        temps.isEmpty ? '--' : '${temps.reduce((a, b) => a < b ? a : b)}°';
    final maxPrecip =
        precips.isEmpty ? '--' : '${precips.reduce((a, b) => a > b ? a : b)}%';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Icon(item.icon, size: 30, color: _text(context)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        item.fullLabel,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: _text(context),
                        ),
                      ),
                    ),
                    Text(
                      '${item.high} / ${item.low}',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: _text(context),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    item.condition,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: _text(context),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _MiniMetricCard(
                        label: 'High',
                        value: maxTemp,
                        dark: Theme.of(context).brightness == Brightness.dark,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _MiniMetricCard(
                        label: 'Low',
                        value: minTemp,
                        dark: Theme.of(context).brightness == Brightness.dark,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _MiniMetricCard(
                        label: 'Rain',
                        value: maxPrecip,
                        dark: Theme.of(context).brightness == Brightness.dark,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: _softCard(context),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: _border(context)),
                  ),
                  child: Text(
                    item.detail,
                    style: TextStyle(
                      color: _text(context),
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showAlertSheet(AlertItem item) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 24),
          child: SingleChildScrollView(
            child: Column(
              children: [
                Container(
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.orange,
                      size: 28,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Weather Alert',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: _text(context),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _AlertDetailRow(
                  label: 'Event',
                  value: item.event,
                  dark: Theme.of(context).brightness == Brightness.dark,
                ),
                const SizedBox(height: 8),
                _AlertDetailRow(
                  label: 'Severity',
                  value: item.severity,
                  dark: Theme.of(context).brightness == Brightness.dark,
                ),
                const SizedBox(height: 8),
                _AlertDetailRow(
                  label: 'Urgency',
                  value: item.urgency,
                  dark: Theme.of(context).brightness == Brightness.dark,
                ),
                const SizedBox(height: 8),
                _AlertDetailRow(
                  label: 'Area',
                  value: item.areaDesc,
                  dark: Theme.of(context).brightness == Brightness.dark,
                ),
                const SizedBox(height: 14),
                _InfoBox(
                  title: 'Headline',
                  value: item.headline,
                  dark: Theme.of(context).brightness == Brightness.dark,
                ),
                const SizedBox(height: 12),
                _InfoBox(
                  title: 'Details',
                  value: item.description,
                  dark: Theme.of(context).brightness == Brightness.dark,
                ),
                if (item.instruction.trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _InfoBox(
                    title: 'Instructions',
                    value: item.instruction,
                    dark: Theme.of(context).brightness == Brightness.dark,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showRadarSheet() {
    if (_currentLatitude == null || _currentLongitude == null) return;

    Timer? playTimer;
    bool isPlaying = false;
    bool sheetClosed = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => SafeArea(
        top: false,
        child: StatefulBuilder(
          builder: (context, modalSetState) {
            void repaint() {
              if (!sheetClosed) modalSetState(() {});
            }

            void stopPlayback() {
              playTimer?.cancel();
              playTimer = null;
              isPlaying = false;
              repaint();
            }

            void setFrame(int index) {
              if (_radarFrames.isEmpty) return;
              final safeIndex = index.clamp(0, _radarFrames.length - 1);
              setState(() {
                _selectedRadarFrameIndex = safeIndex;
                _radarTileTemplate = _radarFrames[safeIndex].tileTemplate;
                _radarFrameTime = _radarFrames[safeIndex].time;
              });
              repaint();
            }

            void startPlayback() {
              if (_radarFrames.length <= 1) return;

              playTimer?.cancel();
              isPlaying = true;
              repaint();

              playTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
                if (!mounted || sheetClosed) {
                  playTimer?.cancel();
                  playTimer = null;
                  return;
                }

                final next = _selectedRadarFrameIndex + 1;
                if (next >= _radarFrames.length) {
                  stopPlayback();
                  return;
                }

                setFrame(next);
              });
            }

            return PopScope(
              onPopInvokedWithResult: (_, __) {
                sheetClosed = true;
                playTimer?.cancel();
                playTimer = null;
              },
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.82,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
                  child: Column(
                    children: [
                      Container(
                        width: 42,
                        height: 5,
                        decoration: BoxDecoration(
                          color: Colors.black26,
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Icon(Icons.radar, color: _text(context)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Radar',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                color: _text(context),
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: _radarLoading ? null : _loadRadarFrame,
                            icon: _radarLoading
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : Icon(Icons.refresh, color: _text(context)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(24),
                          child: Stack(
                            children: [
                              FlutterMap(
                                mapController: _radarSheetController,
                                options: MapOptions(
                                  initialCenter: LatLng(
                                    _currentLatitude!,
                                    _currentLongitude!,
                                  ),
                                  initialZoom: 5.8,
                                  interactionOptions: const InteractionOptions(
                                    flags: InteractiveFlag.all,
                                  ),
                                ),
                                children: [
                                  TileLayer(
                                    urlTemplate:
                                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                    userAgentPackageName: 'com.roaddogg.aiassist',
                                  ),
                                  if (_radarTileTemplate != null)
                                    TileLayer(
                                      urlTemplate: _radarTileTemplate!,
                                      userAgentPackageName: 'com.roaddogg.aiassist',
                                      tileDisplay: TileDisplay.fadeIn(),
                                    ),
                                  MarkerLayer(
                                    markers: [
                                      Marker(
                                        point: LatLng(
                                          _currentLatitude!,
                                          _currentLongitude!,
                                        ),
                                        width: 22,
                                        height: 22,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: Colors.black,
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: Colors.white,
                                              width: 2,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              Positioned(
                                left: 12,
                                right: 12,
                                bottom: 12,
                                child: Container(
                                  padding:
                                      const EdgeInsets.fromLTRB(12, 10, 12, 10),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).brightness == Brightness.dark
                                        ? const Color(0xFF1E1E1E).withOpacity(0.96)
                                        : Colors.white.withOpacity(0.96),
                                    borderRadius: BorderRadius.circular(18),
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Row(
                                        children: [
                                          InkWell(
                                            onTap: () {
                                              if (isPlaying) {
                                                stopPlayback();
                                              } else {
                                                startPlayback();
                                              }
                                            },
                                            borderRadius:
                                                BorderRadius.circular(999),
                                            child: Container(
                                              width: 36,
                                              height: 36,
                                              decoration: BoxDecoration(
                                                color: Colors.black,
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                              ),
                                              child: Icon(
                                                isPlaying
                                                    ? Icons.pause
                                                    : Icons.play_arrow,
                                                color: Colors.white,
                                                size: 20,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Icon(
                                            Icons.access_time,
                                            size: 16,
                                            color: _subtext(context),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            _formatRadarTime(_radarFrameTime),
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                              color: _text(context),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      SliderTheme(
                                        data: SliderTheme.of(context).copyWith(
                                          trackHeight: 4,
                                          thumbShape: const RoundSliderThumbShape(
                                            enabledThumbRadius: 7,
                                          ),
                                        ),
                                        child: Slider(
                                          value: _radarFrames.isEmpty
                                              ? 0
                                              : _selectedRadarFrameIndex.toDouble(),
                                          min: 0,
                                          max: _radarFrames.isEmpty
                                              ? 1
                                              : (_radarFrames.length - 1).toDouble(),
                                          divisions: _radarFrames.length <= 1
                                              ? 1
                                              : _radarFrames.length - 1,
                                          onChanged: _radarFrames.isEmpty
                                              ? null
                                              : (value) {
                                                  stopPlayback();
                                                  setFrame(value.round());
                                                },
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasSearchText = _searchController.text.trim().isNotEmpty;
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: _bg(context),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: Material(
                elevation: dark ? 0 : 3,
                borderRadius: BorderRadius.circular(18),
                color: _card(context),
                child: Container(
                  height: 58,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: _border(context)),
                  ),
                  child: Row(
                    children: [
                      SizedBox(width: 12),
                      Icon(Icons.search, color: _text(context)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          textInputAction: TextInputAction.search,
                          style: TextStyle(color: _text(context)),
                          decoration: InputDecoration(
                            hintText: 'Search city weather...',
                            hintStyle: TextStyle(color: _subtext(context)),
                            border: InputBorder.none,
                          ),
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (_) => _searchCityWeather(),
                        ),
                      ),
                      if (hasSearchText)
                        IconButton(
                          icon: Icon(Icons.close, color: _text(context)),
                          onPressed: () {
                            _searchController.clear();
                            setState(() {});
                          },
                        ),
                      IconButton(
                        tooltip: 'Current location',
                        icon: Icon(
                          Icons.my_location_outlined,
                          color: _text(context),
                        ),
                        onPressed:
                            _loading ? null : _loadWeatherFromCurrentLocation,
                      ),
                      if (_isSearchingCity)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      const SizedBox(width: 4),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_loading)
              Expanded(
                child: Center(
                  child: CircularProgressIndicator(
                    color: dark ? Colors.white : Colors.black,
                  ),
                ),
              )
            else if (_error != null)
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Material(
                      elevation: dark ? 0 : 2,
                      borderRadius: BorderRadius.circular(18),
                      color: _card(context),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: _border(context)),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.warning_amber_rounded,
                                size: 40,
                                color: _text(context),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: _text(context),
                                ),
                              ),
                              const SizedBox(height: 14),
                              FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor: Colors.black,
                                  foregroundColor: Colors.white,
                                ),
                                onPressed: _loadWeatherFromCurrentLocation,
                                child: const Text('Try Again'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              )
            else
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(26),
                        onTap: _showTodaySheet,
                        child: Ink(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(26),
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: dark
                                  ? const [
                                      Color(0xFF151515),
                                      Color(0xFF1C1C1C),
                                      Color(0xFF101010),
                                    ]
                                  : const [
                                      Color(0xFF111111),
                                      Color(0xFF1A1A1A),
                                      Color(0xFF090909),
                                    ],
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x22000000),
                                blurRadius: 18,
                                offset: Offset(0, 8),
                              ),
                            ],
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      width: 58,
                                      height: 58,
                                      decoration: BoxDecoration(
                                        color: Colors.white.withOpacity(0.08),
                                        borderRadius: BorderRadius.circular(18),
                                        border: Border.all(
                                          color: Colors.white.withOpacity(0.08),
                                        ),
                                      ),
                                      child: Icon(
                                        _iconForForecast(_currentCondition),
                                        color: Colors.white,
                                        size: 32,
                                      ),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            _locationName,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 21,
                                              fontWeight: FontWeight.w800,
                                              letterSpacing: 0.2,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            _currentCondition,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      _currentTemp,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 38,
                                        fontWeight: FontWeight.w900,
                                        height: 1,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                Row(
                                  children: [
                                    Expanded(
                                      child: _CurrentStripItem(
                                        label: 'Feels Like',
                                        value: _feelsLike,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: _CurrentStripItem(
                                        label: 'Wind',
                                        value: _wind,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Text(
                                      'Updated $_lastUpdated',
                                      style: const TextStyle(
                                        color: Colors.white60,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const Spacer(),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 7,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withOpacity(0.08),
                                        borderRadius: BorderRadius.circular(999),
                                        border: Border.all(
                                          color: Colors.white.withOpacity(0.07),
                                        ),
                                      ),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            'View details',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 11,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          SizedBox(width: 4),
                                          Icon(
                                            Icons.chevron_right,
                                            color: Colors.white,
                                            size: 15,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (_alerts.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Material(
                          elevation: dark ? 0 : 2,
                          borderRadius: BorderRadius.circular(18),
                          color: _card(context),
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(color: _border(context)),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.warning_amber_rounded,
                                        color: Colors.orange,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Active Alerts',
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w800,
                                          color: _text(context),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  ..._alerts.map(
                                    (alert) => Padding(
                                      padding: const EdgeInsets.only(bottom: 10),
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(14),
                                        onTap: () => _showAlertSheet(alert),
                                        child: Container(
                                          padding: const EdgeInsets.all(14),
                                          decoration: BoxDecoration(
                                            color: dark
                                                ? const Color(0xFF2A1D1D)
                                                : const Color(0xFFFCEAEA),
                                            borderRadius: BorderRadius.circular(14),
                                            border: Border.all(
                                              color: dark
                                                  ? const Color(0xFF5A2B2B)
                                                  : const Color(0xFFE7B5B5),
                                            ),
                                          ),
                                          child: Row(
                                            children: [
                                              const Icon(
                                                Icons.notification_important_outlined,
                                                color: Colors.redAccent,
                                              ),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      alert.event,
                                                      style: const TextStyle(
                                                        fontWeight: FontWeight.w800,
                                                        color: Colors.redAccent,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 4),
                                                    Text(
                                                      alert.headline,
                                                      maxLines: 2,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        color: dark
                                                            ? Colors.white70
                                                            : const Color(0xFF7A1A1A),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              const Icon(
                                                Icons.chevron_right,
                                                color: Colors.redAccent,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Material(
                        elevation: dark ? 0 : 2,
                        borderRadius: BorderRadius.circular(20),
                        color: _card(context),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: _border(context)),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Radar',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                    color: _text(context),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                InkWell(
                                  borderRadius: BorderRadius.circular(20),
                                  onTap: _showRadarSheet,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(20),
                                    child: SizedBox(
                                      height: 190,
                                      child: (_currentLatitude == null ||
                                              _currentLongitude == null)
                                          ? Container(
                                              color: _softCard(context),
                                              child: Center(
                                                child: Text(
                                                  'Radar unavailable',
                                                  style: TextStyle(
                                                    color: _subtext(context),
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                              ),
                                            )
                                          : Stack(
                                              children: [
                                                FlutterMap(
                                                  options: MapOptions(
                                                    initialCenter: LatLng(
                                                      _currentLatitude!,
                                                      _currentLongitude!,
                                                    ),
                                                    initialZoom: 5.2,
                                                    interactionOptions:
                                                        const InteractionOptions(
                                                      flags: InteractiveFlag.none,
                                                    ),
                                                  ),
                                                  children: [
                                                    TileLayer(
                                                      urlTemplate:
                                                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                                      userAgentPackageName:
                                                          'com.roaddogg.aiassist',
                                                    ),
                                                    MarkerLayer(
                                                      markers: [
                                                        Marker(
                                                          point: LatLng(
                                                            _currentLatitude!,
                                                            _currentLongitude!,
                                                          ),
                                                          width: 18,
                                                          height: 18,
                                                          child: Container(
                                                            decoration: BoxDecoration(
                                                              color: Colors.black,
                                                              shape:
                                                                  BoxShape.circle,
                                                              border: Border.all(
                                                                color: Colors.white,
                                                                width: 2,
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ],
                                                ),
                                                Positioned.fill(
                                                  child: Container(
                                                    decoration: BoxDecoration(
                                                      gradient: LinearGradient(
                                                        begin: Alignment.topCenter,
                                                        end: Alignment.bottomCenter,
                                                        colors: [
                                                          Colors.black.withOpacity(0.03),
                                                          Colors.black.withOpacity(0.14),
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                Positioned(
                                                  right: 10,
                                                  bottom: 10,
                                                  child: Container(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                      horizontal: 10,
                                                      vertical: 6,
                                                    ),
                                                    decoration: BoxDecoration(
                                                      color: dark
                                                          ? const Color(0xFF1E1E1E)
                                                          : Colors.white,
                                                      borderRadius:
                                                          BorderRadius.circular(999),
                                                    ),
                                                    child: Row(
                                                      children: [
                                                        Text(
                                                          'Open radar',
                                                          style: TextStyle(
                                                            color: _text(context),
                                                            fontSize: 11,
                                                            fontWeight:
                                                                FontWeight.w700,
                                                          ),
                                                        ),
                                                        const SizedBox(width: 4),
                                                        Icon(
                                                          Icons.chevron_right,
                                                          size: 15,
                                                          color: _text(context),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Material(
                        elevation: dark ? 0 : 2,
                        borderRadius: BorderRadius.circular(20),
                        color: _card(context),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: _border(context)),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Hourly Forecast',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                    color: _text(context),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                SizedBox(
                                  height: 102,
                                  child: ListView.separated(
                                    scrollDirection: Axis.horizontal,
                                    itemCount: _hourly.length,
                                    separatorBuilder: (_, __) =>
                                        const SizedBox(width: 10),
                                    itemBuilder: (_, i) {
                                      final item = _hourly[i];
                                      return InkWell(
                                        borderRadius: BorderRadius.circular(18),
                                        onTap: () => _showHourlySheet(item),
                                        child: Ink(
                                          width: 88,
                                          decoration: BoxDecoration(
                                            color: _softCard(context),
                                            borderRadius:
                                                BorderRadius.circular(18),
                                            border: Border.all(
                                              color: _border(context),
                                            ),
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.fromLTRB(
                                              8,
                                              10,
                                              8,
                                              8,
                                            ),
                                            child: Column(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.spaceBetween,
                                              children: [
                                                Text(
                                                  item.label,
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.w800,
                                                    fontSize: 12,
                                                    color: _text(context),
                                                  ),
                                                ),
                                                Container(
                                                  width: 30,
                                                  height: 30,
                                                  decoration: BoxDecoration(
                                                    color: dark
                                                        ? const Color(0xFF2A2A2A)
                                                        : Colors.white,
                                                    borderRadius:
                                                        BorderRadius.circular(10),
                                                  ),
                                                  child: Icon(
                                                    item.icon,
                                                    color: _text(context),
                                                    size: 18,
                                                  ),
                                                ),
                                                Text(
                                                  item.temp,
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.w900,
                                                    fontSize: 15,
                                                    color: _text(context),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Material(
                        elevation: dark ? 0 : 2,
                        borderRadius: BorderRadius.circular(18),
                        color: _card(context),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: _border(context)),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '5-Day Forecast',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                    color: _text(context),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                ..._forecast.map(
                                  (item) => Padding(
                                    padding: const EdgeInsets.only(bottom: 10),
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(14),
                                      onTap: () => _showDailySheet(item),
                                      child: _ForecastRow(
                                        item: item,
                                        dark: dark,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CurrentStripItem extends StatelessWidget {
  const _CurrentStripItem({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withOpacity(0.07),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white60,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _ForecastRow extends StatelessWidget {
  const _ForecastRow({
    required this.item,
    required this.dark,
  });

  final ForecastDayItem item;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final textColor = dark ? Colors.white : Colors.black87;
    final subColor = dark ? Colors.white70 : Colors.black87;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF222222) : const Color(0xFFF7F7F7),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: dark ? const Color(0xFF2D2D2D) : const Color(0xFFEAEAEA),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 46,
            child: Text(
              item.day,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 14,
                color: textColor,
              ),
            ),
          ),
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: dark ? const Color(0xFF2A2A2A) : Colors.white,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              item.icon,
              color: textColor,
              size: 19,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              item.condition,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: subColor,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${item.high} / ${item.low}',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: textColor,
              fontSize: 13,
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            Icons.chevron_right,
            color: dark ? Colors.white30 : Colors.black38,
            size: 18,
          ),
        ],
      ),
    );
  }
}

class _AlertDetailRow extends StatelessWidget {
  const _AlertDetailRow({
    required this.label,
    required this.value,
    required this.dark,
  });

  final String label;
  final String value;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 78,
          child: Text(
            label,
            style: TextStyle(
              color: dark ? Colors.white60 : Colors.black54,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: dark ? Colors.white : Colors.black87,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }
}

class _InfoBox extends StatelessWidget {
  const _InfoBox({
    required this.title,
    required this.value,
    required this.dark,
  });

  final String title;
  final String value;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF222222) : const Color(0xFFF7F7F7),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: dark ? const Color(0xFF2D2D2D) : const Color(0xFFEAEAEA),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: dark ? Colors.white : Colors.black87,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              color: dark ? Colors.white70 : Colors.black87,
              height: 1.5,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniMetricCard extends StatelessWidget {
  const _MiniMetricCard({
    required this.label,
    required this.value,
    required this.dark,
  });

  final String label;
  final String value;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF222222) : const Color(0xFFF7F7F7),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: dark ? const Color(0xFF2D2D2D) : const Color(0xFFEAEAEA),
        ),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: TextStyle(
              color: dark ? Colors.white60 : Colors.black54,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: dark ? Colors.white : Colors.black87,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class ForecastDayItem {
  final String day;
  final String fullLabel;
  final String condition;
  final String high;
  final String low;
  final String detail;
  final IconData icon;

  const ForecastDayItem({
    required this.day,
    required this.fullLabel,
    required this.condition,
    required this.high,
    required this.low,
    required this.detail,
    required this.icon,
  });
}

class HourlyForecastItem {
  final String label;
  final String temp;
  final String condition;
  final String detail;
  final String precip;
  final IconData icon;
  final DateTime? startTime;

  const HourlyForecastItem({
    required this.label,
    required this.temp,
    required this.condition,
    required this.detail,
    required this.precip,
    required this.icon,
    required this.startTime,
  });
}

class AlertItem {
  final String headline;
  final String event;
  final String severity;
  final String urgency;
  final String areaDesc;
  final String description;
  final String instruction;

  const AlertItem({
    required this.headline,
    required this.event,
    required this.severity,
    required this.urgency,
    required this.areaDesc,
    required this.description,
    required this.instruction,
  });
}

class _LatestObservation {
  final String? temperature;
  final String? condition;
  final String? feelsLike;
  final String? wind;
  final String? humidity;
  final String? visibility;

  const _LatestObservation({
    this.temperature,
    this.condition,
    this.feelsLike,
    this.wind,
    this.humidity,
    this.visibility,
  });
}

class _RadarFrame {
  final String tileTemplate;
  final DateTime time;

  const _RadarFrame({
    required this.tileTemplate,
    required this.time,
  });
}