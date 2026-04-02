import 'package:flutter/material.dart';
import '../services/app_settings.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.settings});
  final AppSettings settings;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const allowedVoices = <String>['alloy', 'nova', 'verse', 'coral'];

  late final TextEditingController _backendCtrl;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _companyCtrl;
  late final TextEditingController _truckCtrl;

  @override
  void initState() {
    super.initState();

    final s = widget.settings;
    _backendCtrl = TextEditingController(text: s.backendBaseUrl);
    _nameCtrl = TextEditingController(text: s.driverName);
    _emailCtrl = TextEditingController(text: s.driverEmail);
    _phoneCtrl = TextEditingController(text: s.driverPhone);
    _companyCtrl = TextEditingController(text: s.companyName);
    _truckCtrl = TextEditingController(text: s.truckName);

    if (!allowedVoices.contains(s.voice)) {
      s.voice = 'alloy';
    }
  }

  @override
  void dispose() {
    _backendCtrl.dispose();
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _companyCtrl.dispose();
    _truckCtrl.dispose();
    super.dispose();
  }

  void _showSaved(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  void _saveBackendUrl() {
    widget.settings.backendBaseUrl = _backendCtrl.text.trim();
    _showSaved('Backend URL saved');
  }

  void _saveAccount() {
    final s = widget.settings;
    s.driverName = _nameCtrl.text.trim();
    s.driverEmail = _emailCtrl.text.trim();
    s.driverPhone = _phoneCtrl.text.trim();
    s.companyName = _companyCtrl.text.trim();
    s.truckName = _truckCtrl.text.trim();
    _showSaved('Account updated');
  }

  void _showAccountSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _sheetBg(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return _ThemedSheet(
          builder: (context, isDark, cardBg, softBg, borderColor, textColor,
              subtextColor) {
            final s = widget.settings;

            return StatefulBuilder(
              builder: (context, modalSetState) {
                return SafeArea(
                  top: false,
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        16,
                        10,
                        16,
                        24 + MediaQuery.of(context).viewInsets.bottom,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _SheetHandle(isDark: isDark),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Container(
                                width: 58,
                                height: 58,
                                decoration: BoxDecoration(
                                  color: Colors.black,
                                  borderRadius: BorderRadius.circular(18),
                                  border: Border.all(
                                    color: isDark
                                        ? const Color(0xFF353535)
                                        : Colors.black,
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  _nameCtrl.text.trim().isEmpty
                                      ? 'R'
                                      : _nameCtrl.text.trim()[0].toUpperCase(),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _nameCtrl.text.trim().isEmpty
                                          ? 'Driver Profile'
                                          : _nameCtrl.text.trim(),
                                      style: TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w800,
                                        color: textColor,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      s.signedIn ? 'Signed in' : 'Not signed in',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: s.signedIn
                                            ? Colors.green.shade700
                                            : subtextColor,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          Text(
                            'Account',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: textColor,
                            ),
                          ),
                          const SizedBox(height: 12),
                          _ProfileField(
                            controller: _nameCtrl,
                            label: 'Full Name',
                            icon: Icons.person_outline,
                            isDark: isDark,
                            onChanged: (_) => modalSetState(() {}),
                          ),
                          const SizedBox(height: 10),
                          _ProfileField(
                            controller: _emailCtrl,
                            label: 'Email',
                            icon: Icons.mail_outline,
                            isDark: isDark,
                          ),
                          const SizedBox(height: 10),
                          _ProfileField(
                            controller: _phoneCtrl,
                            label: 'Phone',
                            icon: Icons.phone_outlined,
                            isDark: isDark,
                          ),
                          const SizedBox(height: 10),
                          _ProfileField(
                            controller: _companyCtrl,
                            label: 'Company',
                            icon: Icons.business_outlined,
                            isDark: isDark,
                          ),
                          const SizedBox(height: 10),
                          _ProfileField(
                            controller: _truckCtrl,
                            label: 'Truck',
                            icon: Icons.local_shipping_outlined,
                            isDark: isDark,
                          ),
                          const SizedBox(height: 14),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.black,
                                foregroundColor: Colors.white,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              onPressed: () {
                                _saveAccount();
                                modalSetState(() {});
                              },
                              child: const Text('Save Account'),
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: textColor,
                                side: BorderSide(color: borderColor),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              onPressed: () {
                                s.signedIn = !s.signedIn;
                                modalSetState(() {});
                                _showSaved(
                                  s.signedIn ? 'Signed in' : 'Signed out',
                                );
                              },
                              child:
                                  Text(s.signedIn ? 'Sign Out' : 'Sign In'),
                            ),
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            child: TextButton(
                              onPressed: () =>
                                  _showSaved('Delete account coming soon'),
                              child: const Text(
                                'Delete Account',
                                style: TextStyle(color: Colors.redAccent),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  void _showAssistantVoiceSheet() {
    final s = widget.settings;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _sheetBg(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return _ThemedSheet(
          builder: (context, isDark, cardBg, softBg, borderColor, textColor,
              subtextColor) {
            return StatefulBuilder(
              builder: (context, modalSetState) {
                return SafeArea(
                  top: false,
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _SheetHandle(isDark: isDark),
                          const SizedBox(height: 16),
                          Text(
                            'Assistant & Voice',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: textColor,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Control how your assistant talks and responds',
                            style: TextStyle(
                              fontSize: 13,
                              color: subtextColor,
                            ),
                          ),
                          const SizedBox(height: 16),
                          _ToggleRow(
                            icon: Icons.volume_up_outlined,
                            title: 'Speak replies',
                            subtitle: 'Play assistant voice audio',
                            value: s.speakReplies,
                            isDark: isDark,
                            onChanged: (v) {
                              s.speakReplies = v;
                              modalSetState(() {});
                            },
                          ),
                          const SizedBox(height: 10),
                          _ToggleRow(
                            icon: Icons.graphic_eq_outlined,
                            title: 'Text-to-speech (TTS)',
                            subtitle: 'Generate voice audio for chat and voice',
                            value: s.ttsEnabled,
                            isDark: isDark,
                            onChanged: (v) {
                              s.ttsEnabled = v;
                              modalSetState(() {});
                            },
                          ),
                          const SizedBox(height: 10),
                          _ToggleRow(
                            icon: Icons.mic_none_outlined,
                            title: 'Hold to talk',
                            subtitle: 'Use hold-to-talk on assistant screen',
                            value: s.holdToTalk,
                            isDark: isDark,
                            onChanged: (v) {
                              s.holdToTalk = v;
                              modalSetState(() {});
                            },
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Voice',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: textColor,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: allowedVoices.map((voice) {
                              final selected = s.voice == voice;
                              return GestureDetector(
                                onTap: () {
                                  s.voice = voice;
                                  modalSetState(() {});
                                },
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 180),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? Colors.black
                                        : (isDark
                                            ? const Color(0xFF222222)
                                            : Colors.white),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: selected
                                          ? Colors.black
                                          : (isDark
                                              ? const Color(0xFF343434)
                                              : Colors.black12),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        selected
                                            ? Icons.radio_button_checked
                                            : Icons.radio_button_off,
                                        size: 18,
                                        color: selected
                                            ? Colors.white
                                            : (isDark
                                                ? Colors.white70
                                                : Colors.black54),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        voice[0].toUpperCase() +
                                            voice.substring(1),
                                        style: TextStyle(
                                          color:
                                              selected ? Colors.white : textColor,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                          const SizedBox(height: 14),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: textColor,
                                side: BorderSide(color: borderColor),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              onPressed: () =>
                                  _showSaved('Voice test coming soon'),
                              child: const Text('Test Voice'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  void _showAppPreferencesSheet() {
    final s = widget.settings;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _sheetBg(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return _ThemedSheet(
          builder: (context, isDark, cardBg, softBg, borderColor, textColor,
              subtextColor) {
            return StatefulBuilder(
              builder: (context, modalSetState) {
                return SafeArea(
                  top: false,
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _SheetHandle(isDark: isDark),
                          const SizedBox(height: 16),
                          Text(
                            'App Preferences',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: textColor,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Backend, permissions, display, and privacy',
                            style: TextStyle(
                              fontSize: 13,
                              color: subtextColor,
                            ),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _backendCtrl,
                            keyboardType: TextInputType.url,
                            style: TextStyle(color: textColor),
                            decoration: InputDecoration(
                              labelText: 'Backend Base URL',
                              labelStyle: TextStyle(color: subtextColor),
                              hintText: 'http://127.0.0.1:8787',
                              hintStyle: TextStyle(color: subtextColor),
                              filled: true,
                              fillColor: softBg,
                              prefixIcon:
                                  Icon(Icons.link, color: subtextColor),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: BorderSide.none,
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: BorderSide(color: borderColor),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide:
                                    const BorderSide(color: Colors.black),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.black,
                                foregroundColor: Colors.white,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              onPressed: () {
                                _saveBackendUrl();
                                modalSetState(() {});
                              },
                              child: const Text('Save Backend URL'),
                            ),
                          ),
                          const SizedBox(height: 14),
                          _ToggleRow(
                            icon: Icons.notifications_none,
                            title: 'Notifications',
                            subtitle: 'Trip reminders, alerts, and updates',
                            value: s.notificationsEnabled,
                            isDark: isDark,
                            onChanged: (v) {
                              s.notificationsEnabled = v;
                              modalSetState(() {});
                            },
                          ),
                          const SizedBox(height: 10),
                          _ToggleRow(
                            icon: Icons.location_on_outlined,
                            title: 'Location Permission',
                            subtitle:
                                'Allow maps and weather to use your location',
                            value: s.locationEnabled,
                            isDark: isDark,
                            onChanged: (v) {
                              s.locationEnabled = v;
                              modalSetState(() {});
                            },
                          ),
                          const SizedBox(height: 10),
                          _ToggleRow(
                            icon: Icons.dark_mode_outlined,
                            title: 'Dark Mode',
                            subtitle: 'Use a darker app appearance',
                            value: s.darkMode,
                            isDark: isDark,
                            onChanged: (v) {
                              s.darkMode = v;
                              modalSetState(() {});
                              Navigator.of(context).pop();
                            },
                          ),
                          const SizedBox(height: 10),
                          _ToggleRow(
                            icon: Icons.lock_outline,
                            title: 'Privacy Mode',
                            subtitle:
                                'Reduce app data visibility where possible',
                            value: s.privacyMode,
                            isDark: isDark,
                            onChanged: (v) {
                              s.privacyMode = v;
                              modalSetState(() {});
                            },
                          ),
                          const SizedBox(height: 14),
                          Text(
                            'Units',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: textColor,
                            ),
                          ),
                          const SizedBox(height: 12),
                          _SegmentChoiceRow(
                            title: 'Temperature',
                            values: const ['Fahrenheit', 'Celsius'],
                            selected: s.temperatureUnit,
                            isDark: isDark,
                            onSelected: (value) {
                              s.temperatureUnit = value;
                              modalSetState(() {});
                            },
                          ),
                          const SizedBox(height: 10),
                          _SegmentChoiceRow(
                            title: 'Distance',
                            values: const ['Miles', 'Kilometers'],
                            selected: s.distanceUnit,
                            isDark: isDark,
                            onSelected: (value) {
                              s.distanceUnit = value;
                              modalSetState(() {});
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  void _showDrivingPreferencesSheet() {
    final s = widget.settings;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _sheetBg(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return _ThemedSheet(
          builder: (context, isDark, cardBg, softBg, borderColor, textColor,
              subtextColor) {
            return StatefulBuilder(
              builder: (context, modalSetState) {
                return SafeArea(
                  top: false,
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _SheetHandle(isDark: isDark),
                          const SizedBox(height: 16),
                          Text(
                            'Driving Preferences',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: textColor,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Truck-specific routing and driving options',
                            style: TextStyle(
                              fontSize: 13,
                              color: subtextColor,
                            ),
                          ),
                          const SizedBox(height: 16),
                          _ToggleRow(
                            icon: Icons.local_shipping_outlined,
                            title: 'Truck Route Mode',
                            subtitle: 'Prefer truck-safe roads and routes',
                            value: s.truckRouteMode,
                            isDark: isDark,
                            onChanged: (v) {
                              s.truckRouteMode = v;
                              modalSetState(() {});
                            },
                          ),
                          const SizedBox(height: 10),
                          _ToggleRow(
                            icon: Icons.receipt_long_outlined,
                            title: 'Avoid Tolls',
                            subtitle:
                                'Try to avoid toll roads when possible',
                            value: s.avoidTolls,
                            isDark: isDark,
                            onChanged: (v) {
                              s.avoidTolls = v;
                              modalSetState(() {});
                            },
                          ),
                          const SizedBox(height: 10),
                          _ToggleRow(
                            icon: Icons.route_outlined,
                            title: 'Avoid Highways',
                            subtitle:
                                'Prefer alternate roads where possible',
                            value: s.avoidHighways,
                            isDark: isDark,
                            onChanged: (v) {
                              s.avoidHighways = v;
                              modalSetState(() {});
                            },
                          ),
                          const SizedBox(height: 10),
                          _ToggleRow(
                            icon: Icons.warning_amber_outlined,
                            title: 'Hazmat Mode',
                            subtitle:
                                'Apply hazardous material routing later',
                            value: s.hazmatMode,
                            isDark: isDark,
                            onChanged: (v) {
                              s.hazmatMode = v;
                              modalSetState(() {});
                            },
                          ),
                          const SizedBox(height: 10),
                          _ToggleRow(
                            icon: Icons.night_shelter_outlined,
                            title: 'Rest Stop Alerts',
                            subtitle:
                                'Show nearby rest stops and parking alerts',
                            value: s.restStopAlerts,
                            isDark: isDark,
                            onChanged: (v) {
                              s.restStopAlerts = v;
                              modalSetState(() {});
                            },
                          ),
                          const SizedBox(height: 14),
                          Text(
                            'Vehicle Profile',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: textColor,
                            ),
                          ),
                          const SizedBox(height: 12),
                          _SimpleValueTile(
                            title: 'Height',
                            value: s.vehicleHeight,
                            isDark: isDark,
                            onTap: () => _showSaved('Height editor coming soon'),
                          ),
                          const SizedBox(height: 10),
                          _SimpleValueTile(
                            title: 'Weight',
                            value: s.vehicleWeight,
                            isDark: isDark,
                            onTap: () => _showSaved('Weight editor coming soon'),
                          ),
                          const SizedBox(height: 10),
                          _SimpleValueTile(
                            title: 'Trailer Type',
                            value: s.trailerType,
                            isDark: isDark,
                            onTap: () =>
                                _showSaved('Trailer editor coming soon'),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  void _showLegalSupportSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _sheetBg(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return _ThemedSheet(
          builder: (context, isDark, cardBg, softBg, borderColor, textColor,
              subtextColor) {
            return SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _SheetHandle(isDark: isDark),
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Legal & Support',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: textColor,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    _SheetInfoTile(
                      icon: Icons.description_outlined,
                      title: 'Terms of Use',
                      subtitle: 'Rules for using RoadDogg AI Assist',
                      isDark: isDark,
                    ),
                    const SizedBox(height: 10),
                    _SheetInfoTile(
                      icon: Icons.privacy_tip_outlined,
                      title: 'Privacy Policy',
                      subtitle:
                          'How location, voice, and app data are handled',
                      isDark: isDark,
                    ),
                    const SizedBox(height: 10),
                    _SheetInfoTile(
                      icon: Icons.support_agent_outlined,
                      title: 'Support',
                      subtitle: 'Contact support@roaddogg.local',
                      isDark: isDark,
                    ),
                    const SizedBox(height: 10),
                    _SheetInfoTile(
                      icon: Icons.bug_report_outlined,
                      title: 'Report a Bug',
                      subtitle: 'Send bug details and screenshots later',
                      isDark: isDark,
                    ),
                    const SizedBox(height: 10),
                    _SheetInfoTile(
                      icon: Icons.info_outline,
                      title: 'App Version',
                      subtitle: 'RoadDogg AI Assist v1.0.0',
                      isDark: isDark,
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Color _sheetBg(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? const Color(0xFF181818) : Colors.white;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.settings,
      builder: (context, _) {
        final s = widget.settings;
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final screenBg =
            isDark ? const Color(0xFF111111) : const Color(0xFFF4F4F4);
        final cardBg = isDark ? const Color(0xFF1A1A1A) : Colors.white;
        final borderColor =
            isDark ? const Color(0xFF2D2D2D) : const Color(0xFFEAEAEA);
        final textColor = isDark ? Colors.white : Colors.black87;

        return Scaffold(
          backgroundColor: screenBg,
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
              children: [
                SizedBox(
                  height: 52,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Center(
                        child: Text(
                          'Settings',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: textColor,
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(999),
                          onTap: _showAccountSheet,
                          child: Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: cardBg,
                              shape: BoxShape.circle,
                              border: Border.all(color: borderColor),
                              boxShadow: isDark
                                  ? const []
                                  : const [
                                      BoxShadow(
                                        blurRadius: 8,
                                        offset: Offset(0, 2),
                                        color: Color(0x12000000),
                                      ),
                                    ],
                            ),
                            child: Icon(
                              Icons.person_outline,
                              color: textColor,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _MainSettingsTile(
                  icon: Icons.person_outline,
                  title: 'Account',
                  subtitle: 'Profile, sign in, truck, and company details',
                  trailingText: s.signedIn ? 'Live' : 'Guest',
                  isDark: isDark,
                  onTap: _showAccountSheet,
                ),
                const SizedBox(height: 12),
                _MainSettingsTile(
                  icon: Icons.smart_toy_outlined,
                  title: 'Assistant & Voice',
                  subtitle: 'Voice replies, hold to talk, and assistant voice',
                  trailingText:
                      s.voice[0].toUpperCase() + s.voice.substring(1),
                  isDark: isDark,
                  onTap: _showAssistantVoiceSheet,
                ),
                const SizedBox(height: 12),
                _MainSettingsTile(
                  icon: Icons.tune,
                  title: 'App Preferences',
                  subtitle:
                      'Backend, notifications, permissions, units, and privacy',
                  isDark: isDark,
                  onTap: _showAppPreferencesSheet,
                ),
                const SizedBox(height: 12),
                _MainSettingsTile(
                  icon: Icons.local_shipping_outlined,
                  title: 'Driving Preferences',
                  subtitle: 'Truck mode, tolls, hazmat, trailer, and routing',
                  isDark: isDark,
                  onTap: _showDrivingPreferencesSheet,
                ),
                const SizedBox(height: 12),
                _MainSettingsTile(
                  icon: Icons.description_outlined,
                  title: 'Legal & Support',
                  subtitle: 'Privacy policy, terms, support, bugs, and app info',
                  isDark: isDark,
                  onTap: _showLegalSupportSheet,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ThemedSheet extends StatelessWidget {
  const _ThemedSheet({
    required this.builder,
  });

  final Widget Function(
    BuildContext context,
    bool isDark,
    Color cardBg,
    Color softBg,
    Color borderColor,
    Color textColor,
    Color subtextColor,
  ) builder;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF1A1A1A) : Colors.white;
    final softBg = isDark ? const Color(0xFF222222) : const Color(0xFFF7F7F7);
    final borderColor =
        isDark ? const Color(0xFF2D2D2D) : const Color(0xFFEAEAEA);
    final textColor = isDark ? Colors.white : Colors.black87;
    final subtextColor = isDark ? Colors.white70 : Colors.black54;

    return builder(
      context,
      isDark,
      cardBg,
      softBg,
      borderColor,
      textColor,
      subtextColor,
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle({required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 42,
        height: 5,
        decoration: BoxDecoration(
          color: isDark ? Colors.white24 : Colors.black26,
          borderRadius: BorderRadius.circular(99),
        ),
      ),
    );
  }
}

class _MainSettingsTile extends StatelessWidget {
  const _MainSettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    required this.isDark,
    this.trailingText,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool isDark;
  final String? trailingText;

  @override
  Widget build(BuildContext context) {
    final cardBg = isDark ? const Color(0xFF1A1A1A) : Colors.white;
    final softBg = isDark ? const Color(0xFF222222) : const Color(0xFFF7F7F7);
    final borderColor =
        isDark ? const Color(0xFF2D2D2D) : const Color(0xFFEAEAEA);
    final textColor = isDark ? Colors.white : Colors.black87;
    final subtextColor = isDark ? Colors.white70 : Colors.black54;

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: borderColor),
          boxShadow: isDark
              ? const []
              : const [
                  BoxShadow(
                    blurRadius: 10,
                    offset: Offset(0, 3),
                    color: Color(0x10000000),
                  ),
                ],
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: softBg,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: textColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: textColor,
                          ),
                        ),
                      ),
                      if (trailingText != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            trailingText!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: subtextColor,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right,
              color: isDark ? Colors.white38 : Colors.black38,
            ),
          ],
        ),
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    required this.isDark,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final softBg = isDark ? const Color(0xFF222222) : const Color(0xFFF7F7F7);
    final iconBg = isDark ? const Color(0xFF2A2A2A) : Colors.white;
    final borderColor =
        isDark ? const Color(0xFF2D2D2D) : const Color(0xFFEAEAEA);
    final textColor = isDark ? Colors.white : Colors.black87;
    final subtextColor = isDark ? Colors.white70 : Colors.black54;

    return Container(
      decoration: BoxDecoration(
        color: softBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: borderColor),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: textColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: subtextColor,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }
}

class _SegmentChoiceRow extends StatelessWidget {
  const _SegmentChoiceRow({
    required this.title,
    required this.values,
    required this.selected,
    required this.onSelected,
    required this.isDark,
  });

  final String title;
  final List<String> values;
  final String selected;
  final ValueChanged<String> onSelected;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final softBg = isDark ? const Color(0xFF222222) : const Color(0xFFF7F7F7);
    final textColor = isDark ? Colors.white : Colors.black87;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: softBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark ? const Color(0xFF2D2D2D) : const Color(0xFFEAEAEA),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 14,
              color: textColor,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: values.map((value) {
              final isSelected = selected == value;
              return GestureDetector(
                onTap: () => onSelected(value),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? Colors.black
                        : (isDark ? const Color(0xFF1A1A1A) : Colors.white),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isSelected
                          ? Colors.black
                          : (isDark
                              ? const Color(0xFF343434)
                              : Colors.black12),
                    ),
                  ),
                  child: Text(
                    value,
                    style: TextStyle(
                      color: isSelected ? Colors.white : textColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _SimpleValueTile extends StatelessWidget {
  const _SimpleValueTile({
    required this.title,
    required this.value,
    required this.onTap,
    required this.isDark,
  });

  final String title;
  final String value;
  final VoidCallback onTap;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final softBg = isDark ? const Color(0xFF222222) : const Color(0xFFF7F7F7);
    final textColor = isDark ? Colors.white : Colors.black87;
    final subtextColor = isDark ? Colors.white70 : Colors.black54;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: softBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark ? const Color(0xFF2D2D2D) : const Color(0xFFEAEAEA),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
              ),
            ),
            Text(
              value,
              style: TextStyle(
                color: subtextColor,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              Icons.chevron_right,
              color: isDark ? Colors.white38 : Colors.black38,
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileField extends StatelessWidget {
  const _ProfileField({
    required this.controller,
    required this.label,
    required this.icon,
    required this.isDark,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool isDark;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final softBg = isDark ? const Color(0xFF222222) : const Color(0xFFF7F7F7);
    final textColor = isDark ? Colors.white : Colors.black87;
    final subtextColor = isDark ? Colors.white70 : Colors.black54;

    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: TextStyle(color: textColor),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: subtextColor),
        prefixIcon: Icon(icon, color: subtextColor),
        filled: true,
        fillColor: softBg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: isDark ? const Color(0xFF2D2D2D) : const Color(0xFFEAEAEA),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Colors.black),
        ),
      ),
    );
  }
}

class _SheetInfoTile extends StatelessWidget {
  const _SheetInfoTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.isDark,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final softBg = isDark ? const Color(0xFF222222) : const Color(0xFFF7F7F7);
    final iconBg = isDark ? const Color(0xFF2A2A2A) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black87;
    final subtextColor = isDark ? Colors.white70 : Colors.black54;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: softBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark ? const Color(0xFF2D2D2D) : const Color(0xFFEAEAEA),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: textColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: subtextColor,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}