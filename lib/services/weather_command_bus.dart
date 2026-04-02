import 'dart:async';

enum WeatherCommandType {
  open,
  city,
  radar,
  refresh,
}

class WeatherCommand {
  final WeatherCommandType type;
  final String? city;

  const WeatherCommand({
    required this.type,
    this.city,
  });
}

class WeatherCommandBus {
  WeatherCommandBus._();
  static final WeatherCommandBus instance = WeatherCommandBus._();

  final StreamController<WeatherCommand> _controller =
      StreamController<WeatherCommand>.broadcast();

  Stream<WeatherCommand> get stream => _controller.stream;

  void open() {
    _controller.add(const WeatherCommand(type: WeatherCommandType.open));
  }

  void openCity(String city) {
    _controller.add(
      WeatherCommand(type: WeatherCommandType.city, city: city),
    );
  }

  void openRadar() {
    _controller.add(const WeatherCommand(type: WeatherCommandType.radar));
  }

  void refresh() {
    _controller.add(const WeatherCommand(type: WeatherCommandType.refresh));
  }
}