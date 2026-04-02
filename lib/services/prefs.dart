import 'package:shared_preferences/shared_preferences.dart';

class Prefs {
  // keys
  static const kDriverName = 'driverName';
  static const kAutoSpeak = 'autoSpeak';
  static const kVoice = 'voice';
  static const kBackendUrl = 'backendUrl';

  static Future<SharedPreferences> _p() => SharedPreferences.getInstance();

  // Driver Name
  static Future<String> getDriverName() async {
    final p = await _p();
    return p.getString(kDriverName) ?? 'Driver';
  }

  static Future<void> setDriverName(String value) async {
    final p = await _p();
    await p.setString(kDriverName, value.trim().isEmpty ? 'Driver' : value.trim());
  }

  // Auto Speak
  static Future<bool> getAutoSpeak() async {
    final p = await _p();
    return p.getBool(kAutoSpeak) ?? true; // default ON
  }

  static Future<void> setAutoSpeak(bool value) async {
    final p = await _p();
    await p.setBool(kAutoSpeak, value);
  }

  // Voice
  static Future<String> getVoice() async {
    final p = await _p();
    return p.getString(kVoice) ?? 'nova';
  }

  static Future<void> setVoice(String value) async {
    final p = await _p();
    await p.setString(kVoice, value);
  }

  // Backend URL
  static Future<String> getBackendUrl() async {
    final p = await _p();
    return p.getString(kBackendUrl) ?? 'http://localhost:3000';
  }

  static Future<void> setBackendUrl(String value) async {
    final p = await _p();
    await p.setString(kBackendUrl, value.trim());
  }
}