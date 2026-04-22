import 'dart:async';

class MapNavigateCommand {
  /// Natural language destination query (e.g. "Pilot Travel Center", "Walmart", address).
  /// If empty, Maps should start navigation to the currently selected destination (if any).
  final String destinationQuery;

  const MapNavigateCommand(this.destinationQuery);
}

class MapNavigationCommandBus {
  MapNavigationCommandBus._();

  static final MapNavigationCommandBus instance = MapNavigationCommandBus._();

  final StreamController<MapNavigateCommand> _controller =
      StreamController<MapNavigateCommand>.broadcast();

  Stream<MapNavigateCommand> get stream => _controller.stream;

  void navigate(String destinationQuery) {
    _controller.add(MapNavigateCommand(destinationQuery.trim()));
  }
}

