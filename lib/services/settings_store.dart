import 'dart:async';

enum SettingsCommandType {
  open,
  profile,
  assistantVoice,
  appPreferences,
  legalSupport,
}

class SettingsCommand {
  final SettingsCommandType type;

  const SettingsCommand({required this.type});
}

class SettingsCommandBus {
  SettingsCommandBus._();

  static final SettingsCommandBus instance = SettingsCommandBus._();

  final StreamController<SettingsCommand> _controller =
      StreamController<SettingsCommand>.broadcast();

  Stream<SettingsCommand> get stream => _controller.stream;

  void open() {
    _controller.add(const SettingsCommand(type: SettingsCommandType.open));
  }

  void openProfile() {
    _controller.add(const SettingsCommand(type: SettingsCommandType.profile));
  }

  void openAssistantVoice() {
    _controller.add(
      const SettingsCommand(type: SettingsCommandType.assistantVoice),
    );
  }

  void openAppPreferences() {
    _controller.add(
      const SettingsCommand(type: SettingsCommandType.appPreferences),
    );
  }

  void openLegalSupport() {
    _controller.add(
      const SettingsCommand(type: SettingsCommandType.legalSupport),
    );
  }
}