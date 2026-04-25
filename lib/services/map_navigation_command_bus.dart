import 'dart:async';

enum MapNavigationAction {
  navigate,
  chooseResultByIndex,
  chooseResultByName,
  confirmStartRoute,
  cancelNavigation,
  stopNavigation,
  clearRoute,
  reroute,
  setAvoidTolls,
  setAvoidHighways,
  zoomIn,
  zoomOut,
  recenter,
  setMapTypeSatellite,
  setMapTypeTerrain,
  setMapTypeNormal,
  setTraffic,
  queryEta,
  queryMilesLeft,
  queryNextTurn,
  repeatInstruction,
  queryAfterThis,
}

class MapNavigationReply {
  final bool ok;
  final String message;

  const MapNavigationReply({required this.ok, required this.message});
}

class MapNavigateCommand {
  final MapNavigationAction action;
  final String destinationQuery;
  final int? selectionIndex;
  final String? selectionName;
  final bool? enabled;
  final Completer<MapNavigationReply>? reply;

  const MapNavigateCommand({
    required this.action,
    this.destinationQuery = '',
    this.selectionIndex,
    this.selectionName,
    this.enabled,
    this.reply,
  });
}

class MapNavigationCommandBus {
  MapNavigationCommandBus._();

  static final MapNavigationCommandBus instance = MapNavigationCommandBus._();

  final StreamController<MapNavigateCommand> _controller =
      StreamController<MapNavigateCommand>.broadcast();

  Stream<MapNavigateCommand> get stream => _controller.stream;

  void navigate(String destinationQuery) {
    _controller.add(
      MapNavigateCommand(
        action: MapNavigationAction.navigate,
        destinationQuery: destinationQuery.trim(),
      ),
    );
  }

  Future<MapNavigationReply> send(MapNavigateCommand command) {
    final completer = Completer<MapNavigationReply>();
    _controller.add(
      MapNavigateCommand(
        action: command.action,
        destinationQuery: command.destinationQuery,
        selectionIndex: command.selectionIndex,
        selectionName: command.selectionName,
        enabled: command.enabled,
        reply: completer,
      ),
    );
    return completer.future;
  }
}
