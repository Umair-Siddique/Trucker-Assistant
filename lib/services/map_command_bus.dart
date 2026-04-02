import 'dart:async';

class MapSearchCommand {
  final String query;

  const MapSearchCommand(this.query);
}

class MapCommandBus {
  MapCommandBus._();

  static final MapCommandBus instance = MapCommandBus._();

  final StreamController<MapSearchCommand> _controller =
      StreamController<MapSearchCommand>.broadcast();

  Stream<MapSearchCommand> get stream => _controller.stream;

  void search(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    _controller.add(MapSearchCommand(trimmed));
  }
}