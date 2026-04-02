import 'dart:async';

class LogsCommandBus {
  LogsCommandBus._();

  static final LogsCommandBus instance = LogsCommandBus._();

  final StreamController<void> _controller =
      StreamController<void>.broadcast();

  Stream<void> get stream => _controller.stream;

  void open() {
    _controller.add(null);
  }
}