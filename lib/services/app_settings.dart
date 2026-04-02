import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings extends ChangeNotifier {
  static const _kBackendBaseUrl = 'backendBaseUrl';
  static const _kSpeakReplies = 'speakReplies';
  static const _kTtsEnabled = 'ttsEnabled';
  static const _kHoldToTalk = 'holdToTalk';
  static const _kVoice = 'voice';

  static const _kNotificationsEnabled = 'notificationsEnabled';
  static const _kLocationEnabled = 'locationEnabled';
  static const _kPrivacyMode = 'privacyMode';
  static const _kDarkMode = 'darkMode';

  static const _kTemperatureUnit = 'temperatureUnit';
  static const _kDistanceUnit = 'distanceUnit';

  static const _kTruckRouteMode = 'truckRouteMode';
  static const _kAvoidTolls = 'avoidTolls';
  static const _kAvoidHighways = 'avoidHighways';
  static const _kHazmatMode = 'hazmatMode';
  static const _kRestStopAlerts = 'restStopAlerts';

  static const _kDriverName = 'driverName';
  static const _kDriverEmail = 'driverEmail';
  static const _kDriverPhone = 'driverPhone';
  static const _kCompanyName = 'companyName';
  static const _kTruckName = 'truckName';

  static const _kVehicleHeight = 'vehicleHeight';
  static const _kVehicleWeight = 'vehicleWeight';
  static const _kTrailerType = 'trailerType';

  static const _kSignedIn = 'signedIn';

  AppSettings._(this._prefs);

  final SharedPreferences _prefs;

  static const String _defaultBackend = String.fromEnvironment(
    'BACKEND_BASE_URL',
    defaultValue:
        'https://3ccc-2400-adc5-1a5-7c00-a95e-c561-7f88-8b55.ngrok-free.app',
  );

  static const String _defaultVoice = 'alloy';

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings._(prefs);
  }

  String get backendBaseUrl =>
      _prefs.getString(_kBackendBaseUrl) ?? _defaultBackend;

  set backendBaseUrl(String value) {
    final v = value.trim();
    if (v.isEmpty) return;
    _prefs.setString(_kBackendBaseUrl, v);
    notifyListeners();
  }

  bool get speakReplies => _prefs.getBool(_kSpeakReplies) ?? true;

  set speakReplies(bool value) {
    _prefs.setBool(_kSpeakReplies, value);
    notifyListeners();
  }

  /// Controls whether we ask the backend to generate TTS audio (`tts=true`).
  /// When false, we send `tts=false` to `/chat` and `/voice` to reduce latency/cost.
  bool get ttsEnabled => _prefs.getBool(_kTtsEnabled) ?? true;

  set ttsEnabled(bool value) {
    _prefs.setBool(_kTtsEnabled, value);
    notifyListeners();
  }

  bool get holdToTalk => _prefs.getBool(_kHoldToTalk) ?? true;

  set holdToTalk(bool value) {
    _prefs.setBool(_kHoldToTalk, value);
    notifyListeners();
  }

  String get voice => (_prefs.getString(_kVoice) ?? _defaultVoice).trim();

  set voice(String value) {
    final v = value.trim().toLowerCase();
    if (v.isEmpty) return;
    _prefs.setString(_kVoice, v);
    notifyListeners();
  }

  bool get notificationsEnabled =>
      _prefs.getBool(_kNotificationsEnabled) ?? true;

  set notificationsEnabled(bool value) {
    _prefs.setBool(_kNotificationsEnabled, value);
    notifyListeners();
  }

  bool get locationEnabled => _prefs.getBool(_kLocationEnabled) ?? true;

  set locationEnabled(bool value) {
    _prefs.setBool(_kLocationEnabled, value);
    notifyListeners();
  }

  bool get privacyMode => _prefs.getBool(_kPrivacyMode) ?? false;

  set privacyMode(bool value) {
    _prefs.setBool(_kPrivacyMode, value);
    notifyListeners();
  }

  bool get darkMode => _prefs.getBool(_kDarkMode) ?? false;

  set darkMode(bool value) {
    _prefs.setBool(_kDarkMode, value);
    notifyListeners();
  }

  String get temperatureUnit =>
      _prefs.getString(_kTemperatureUnit) ?? 'Fahrenheit';

  set temperatureUnit(String value) {
    final v = value.trim();
    if (v.isEmpty) return;
    _prefs.setString(_kTemperatureUnit, v);
    notifyListeners();
  }

  String get distanceUnit => _prefs.getString(_kDistanceUnit) ?? 'Miles';

  set distanceUnit(String value) {
    final v = value.trim();
    if (v.isEmpty) return;
    _prefs.setString(_kDistanceUnit, v);
    notifyListeners();
  }

  bool get truckRouteMode => _prefs.getBool(_kTruckRouteMode) ?? true;

  set truckRouteMode(bool value) {
    _prefs.setBool(_kTruckRouteMode, value);
    notifyListeners();
  }

  bool get avoidTolls => _prefs.getBool(_kAvoidTolls) ?? false;

  set avoidTolls(bool value) {
    _prefs.setBool(_kAvoidTolls, value);
    notifyListeners();
  }

  bool get avoidHighways => _prefs.getBool(_kAvoidHighways) ?? false;

  set avoidHighways(bool value) {
    _prefs.setBool(_kAvoidHighways, value);
    notifyListeners();
  }

  bool get hazmatMode => _prefs.getBool(_kHazmatMode) ?? false;

  set hazmatMode(bool value) {
    _prefs.setBool(_kHazmatMode, value);
    notifyListeners();
  }

  bool get restStopAlerts => _prefs.getBool(_kRestStopAlerts) ?? true;

  set restStopAlerts(bool value) {
    _prefs.setBool(_kRestStopAlerts, value);
    notifyListeners();
  }

  String get driverName => _prefs.getString(_kDriverName) ?? 'Gabriel';

  set driverName(String value) {
    _prefs.setString(_kDriverName, value.trim());
    notifyListeners();
  }

  String get driverEmail =>
      _prefs.getString(_kDriverEmail) ?? 'gabriel@example.com';

  set driverEmail(String value) {
    _prefs.setString(_kDriverEmail, value.trim());
    notifyListeners();
  }

  String get driverPhone => _prefs.getString(_kDriverPhone) ?? '(555) 000-0000';

  set driverPhone(String value) {
    _prefs.setString(_kDriverPhone, value.trim());
    notifyListeners();
  }

  String get companyName =>
      _prefs.getString(_kCompanyName) ?? 'RoadDogg Logistics';

  set companyName(String value) {
    _prefs.setString(_kCompanyName, value.trim());
    notifyListeners();
  }

  String get truckName => _prefs.getString(_kTruckName) ?? '2022 Peterbilt 579';

  set truckName(String value) {
    _prefs.setString(_kTruckName, value.trim());
    notifyListeners();
  }

  String get vehicleHeight => _prefs.getString(_kVehicleHeight) ?? '13 ft 6 in';

  set vehicleHeight(String value) {
    _prefs.setString(_kVehicleHeight, value.trim());
    notifyListeners();
  }

  String get vehicleWeight => _prefs.getString(_kVehicleWeight) ?? '80,000 lb';

  set vehicleWeight(String value) {
    _prefs.setString(_kVehicleWeight, value.trim());
    notifyListeners();
  }

  String get trailerType => _prefs.getString(_kTrailerType) ?? 'Dry Van';

  set trailerType(String value) {
    _prefs.setString(_kTrailerType, value.trim());
    notifyListeners();
  }

  bool get signedIn => _prefs.getBool(_kSignedIn) ?? false;

  set signedIn(bool value) {
    _prefs.setBool(_kSignedIn, value);
    notifyListeners();
  }
}
