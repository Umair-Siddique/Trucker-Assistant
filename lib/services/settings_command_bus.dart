import 'dart:async';

class SettingsCommandBus {
  SettingsCommandBus._();

  static final SettingsCommandBus instance = SettingsCommandBus._();

  final StreamController<void> _controller =
      StreamController<void>.broadcast();

  Stream<void> get stream => _controller.stream;

  void open() {
    _controller.add(null);
  }
}