import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../services/app_settings.dart';
import '../services/google_places_routes_client.dart';
import '../services/map_navigation_command_bus.dart' as mapnavbus;

class MapsScreen extends StatefulWidget {
  const MapsScreen({
    super.key,
    required this.settings,
  });

  final AppSettings settings;

  @override
  State<MapsScreen> createState() => MapsScreenState();
}

class MapsScreenState extends State<MapsScreen>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _searchCtrl = TextEditingController();
  final Completer<GoogleMapController> _mapController =
      Completer<GoogleMapController>();

  GoogleMapController? _controller;
  late final GooglePlacesRoutesClient _client;

  bool _loadingLocation = true;
  bool _locationAllowed = false;
  bool _searching = false;
  bool _routing = false;
  String? _error;

  MapType _mapType = MapType.normal;
  bool _showTraffic = false;
  bool _avoidTolls = false;
  bool _avoidHighways = false;
  bool _awaitingStartConfirmation = false;

  LatLng _currentCenter = const LatLng(29.7604, -95.3698);
  Marker? _currentMarker;
  final Set<Marker> _poiMarkers = {};
  final Set<Polyline> _routePolylines = {};

  List<PlaceSearchResult> _results = [];
  String _activeLabel = '';

  PlaceSearchResult? _selectedPlace;
  double? _routeMiles;
  int? _routeMinutes;
  bool _navigating = false;

  final List<RouteStepResult> _navSteps = [];
  int _currentStepIndex = 0;
  double? _remainingMiles;
  int? _remainingMinutes;

  static const List<_QuickMapCategory> _quickCategories = [
    _QuickMapCategory('Truck Stops', Icons.local_shipping_outlined),
    _QuickMapCategory('Fuel', Icons.local_gas_station_outlined),
    _QuickMapCategory('Food', Icons.restaurant_outlined),
    _QuickMapCategory('Parking', Icons.local_parking_outlined),
    _QuickMapCategory('Repairs', Icons.build_outlined),
  ];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _client = GooglePlacesRoutesClient();
    _initLocation();
  }

  @override
  void didUpdateWidget(covariant MapsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> onTabVisible() async {
    await _refreshCurrentLocation(moveCamera: false);
  }

  Future<void> runAssistantSearch(String query) async {
    _searchCtrl.text = query;
    await _runTextSearch(query);
  }

  Future<void> runAssistantNearby(String category) async {
    await _runNearbySearch(category);
  }

  Future<mapnavbus.MapNavigationReply> runAssistantNavigationCommand(
    mapnavbus.MapNavigateCommand command,
  ) async {
    switch (command.action) {
      case mapnavbus.MapNavigationAction.navigate:
        return _assistantNavigate(command.destinationQuery);
      case mapnavbus.MapNavigationAction.chooseResultByIndex:
        return _assistantChooseByIndex(command.selectionIndex);
      case mapnavbus.MapNavigationAction.chooseResultByName:
        return _assistantChooseByName(command.selectionName ?? '');
      case mapnavbus.MapNavigationAction.confirmStartRoute:
        return _assistantConfirmStartRoute();
      case mapnavbus.MapNavigationAction.cancelNavigation:
        return _assistantCancelPendingNavigation();
      case mapnavbus.MapNavigationAction.stopNavigation:
        return _assistantStopNavigation();
      case mapnavbus.MapNavigationAction.clearRoute:
        return _assistantClearRoute();
      case mapnavbus.MapNavigationAction.reroute:
        return _assistantReroute();
      case mapnavbus.MapNavigationAction.setAvoidTolls:
        return _assistantSetAvoidTolls(command.enabled ?? true);
      case mapnavbus.MapNavigationAction.setAvoidHighways:
        return _assistantSetAvoidHighways(command.enabled ?? true);
      case mapnavbus.MapNavigationAction.zoomIn:
        return _assistantZoomBy(1);
      case mapnavbus.MapNavigationAction.zoomOut:
        return _assistantZoomBy(-1);
      case mapnavbus.MapNavigationAction.recenter:
        return _assistantRecenter();
      case mapnavbus.MapNavigationAction.setMapTypeSatellite:
        return _assistantSetMapType(MapType.hybrid, 'satellite');
      case mapnavbus.MapNavigationAction.setMapTypeTerrain:
        return _assistantSetMapType(MapType.terrain, 'terrain');
      case mapnavbus.MapNavigationAction.setMapTypeNormal:
        return _assistantSetMapType(MapType.normal, 'map');
      case mapnavbus.MapNavigationAction.setTraffic:
        return _assistantSetTraffic(command.enabled ?? true);
      case mapnavbus.MapNavigationAction.queryEta:
        return _assistantQueryEta();
      case mapnavbus.MapNavigationAction.queryMilesLeft:
        return _assistantQueryMilesLeft();
      case mapnavbus.MapNavigationAction.queryNextTurn:
        return _assistantQueryNextTurn();
      case mapnavbus.MapNavigationAction.repeatInstruction:
        return _assistantRepeatInstruction();
      case mapnavbus.MapNavigationAction.queryAfterThis:
        return _assistantQueryAfterThis();
    }
  }

  Future<void> runAssistantNavigate(String destinationQuery) async {
    await _assistantNavigate(destinationQuery);
  }

  Future<mapnavbus.MapNavigationReply> _assistantNavigate(
    String destinationQuery,
  ) async {
    final q = destinationQuery.trim();
    if (q.isEmpty) {
      if (_selectedPlace == null) {
        return const mapnavbus.MapNavigationReply(
          ok: false,
          message: 'Pick a destination first.',
        );
      }
      // Already navigating → report live status instead of re-asking.
      if (_navigating) {
        final placeName = _placeLabel(_selectedPlace!);
        final miles =
            (_remainingMiles ?? _routeMiles ?? 0).toStringAsFixed(1);
        final eta = _etaLabel(_remainingMinutes ?? _routeMinutes ?? 0);
        return mapnavbus.MapNavigationReply(
          ok: true,
          message:
              'You are navigating to $placeName — $miles miles left, ETA $eta.',
        );
      }
      _awaitingStartConfirmation = true;
      final placeName = _placeLabel(_selectedPlace!);
      return mapnavbus.MapNavigationReply(
        ok: true,
        message: 'Start route to $placeName, correct?',
      );
    }

    // New destination query — always clears any active navigation and searches.
    _searchCtrl.text = q;
    await _runTextSearch(q);

    if (!mounted) {
      return const mapnavbus.MapNavigationReply(
        ok: false,
        message: 'Maps is not ready yet.',
      );
    }
    if (_results.isEmpty) {
      return mapnavbus.MapNavigationReply(
        ok: false,
        message: 'No results for $q.',
      );
    }

    if (_results.length > 1) {
      final top = _results.take(3).toList();
      final options = <String>[];
      for (int i = 0; i < top.length; i++) {
        options.add('${i + 1}) ${_placeLabel(top[i])}');
      }
      return mapnavbus.MapNavigationReply(
        ok: true,
        message:
            'I found multiple results: ${options.join(' ; ')}. Say "the second one" or "choose <name>".',
      );
    }

    await _selectPlace(_results.first);
    _awaitingStartConfirmation = true;
    return mapnavbus.MapNavigationReply(
      ok: true,
      message: 'Start route to ${_placeLabel(_results.first)}, correct?',
    );
  }

  Future<mapnavbus.MapNavigationReply> _assistantChooseByIndex(
      int? index) async {
    if (_results.isEmpty) {
      return const mapnavbus.MapNavigationReply(
        ok: false,
        message: 'No search results yet. Say where to navigate first.',
      );
    }
    final i = index ?? 0;
    if (i < 1 || i > _results.length) {
      return mapnavbus.MapNavigationReply(
        ok: false,
        message: 'Please choose a result between 1 and ${_results.length}.',
      );
    }
    final picked = _results[i - 1];
    await _selectPlace(picked);
    _awaitingStartConfirmation = true;
    return mapnavbus.MapNavigationReply(
      ok: true,
      message: 'Start route to ${_placeLabel(picked)}, correct?',
    );
  }

  Future<mapnavbus.MapNavigationReply> _assistantChooseByName(
      String name) async {
    final needle = name.trim().toLowerCase();
    if (needle.isEmpty || _results.isEmpty) {
      return const mapnavbus.MapNavigationReply(
        ok: false,
        message: 'No matching results yet. Try "choose second one".',
      );
    }
    PlaceSearchResult? picked;
    for (final p in _results) {
      final label = '${p.name} ${p.address}'.toLowerCase();
      if (label.contains(needle)) {
        picked = p;
        break;
      }
    }
    if (picked == null) {
      return mapnavbus.MapNavigationReply(
        ok: false,
        message: 'I could not find "$name" in current results.',
      );
    }

    await _selectPlace(picked);
    _awaitingStartConfirmation = true;
    return mapnavbus.MapNavigationReply(
      ok: true,
      message: 'Start route to ${_placeLabel(picked)}, correct?',
    );
  }

  mapnavbus.MapNavigationReply _assistantConfirmStartRoute() {
    if (_selectedPlace == null) {
      return const mapnavbus.MapNavigationReply(
        ok: false,
        message: 'No destination selected.',
      );
    }
    // If already navigating, just report current status — no need to restart.
    if (_navigating) {
      final placeName = _placeLabel(_selectedPlace!);
      final miles =
          (_remainingMiles ?? _routeMiles ?? 0).toStringAsFixed(1);
      final eta = _etaLabel(_remainingMinutes ?? _routeMinutes ?? 0);
      return mapnavbus.MapNavigationReply(
        ok: true,
        message:
            'Already navigating to $placeName — $miles miles left, ETA $eta.',
      );
    }
    _startRoute();
    return mapnavbus.MapNavigationReply(
      ok: true,
      message: 'Starting route to ${_placeLabel(_selectedPlace!)}.',
    );
  }

  mapnavbus.MapNavigationReply _assistantCancelPendingNavigation() {
    if (_awaitingStartConfirmation) {
      _awaitingStartConfirmation = false;
      return const mapnavbus.MapNavigationReply(
        ok: true,
        message: 'Canceled. I will not start the route.',
      );
    }
    return const mapnavbus.MapNavigationReply(
      ok: true,
      message: 'Nothing to cancel.',
    );
  }

  mapnavbus.MapNavigationReply _assistantStopNavigation() {
    if (!_navigating) {
      return const mapnavbus.MapNavigationReply(
        ok: false,
        message: 'Navigation is not active.',
      );
    }
    setState(() {
      _navigating = false;
      _awaitingStartConfirmation = false;
    });
    return const mapnavbus.MapNavigationReply(
      ok: true,
      message: 'Navigation stopped.',
    );
  }

  mapnavbus.MapNavigationReply _assistantClearRoute() {
    if (_selectedPlace == null && _routePolylines.isEmpty) {
      return const mapnavbus.MapNavigationReply(
        ok: false,
        message: 'No active route to clear.',
      );
    }
    _clearRoute();
    return const mapnavbus.MapNavigationReply(
      ok: true,
      message: 'Route cleared.',
    );
  }

  Future<mapnavbus.MapNavigationReply> _assistantReroute() async {
    final place = _selectedPlace;
    if (place == null) {
      return const mapnavbus.MapNavigationReply(
        ok: false,
        message: 'No destination selected to reroute.',
      );
    }
    final resumeNav = _navigating;
    await _selectPlace(place, keepNavigating: resumeNav);
    if (resumeNav) {
      _startRoute(showSnackBar: false);
    }
    return const mapnavbus.MapNavigationReply(
      ok: true,
      message: 'Route refreshed.',
    );
  }

  Future<mapnavbus.MapNavigationReply> _assistantSetAvoidTolls(
      bool enabled) async {
    _avoidTolls = enabled;
    final place = _selectedPlace;
    if (place != null) {
      await _selectPlace(place, keepNavigating: _navigating);
    }
    return mapnavbus.MapNavigationReply(
      ok: true,
      message: enabled ? 'Avoiding tolls.' : 'Tolls are allowed again.',
    );
  }

  Future<mapnavbus.MapNavigationReply> _assistantSetAvoidHighways(
    bool enabled,
  ) async {
    _avoidHighways = enabled;
    final place = _selectedPlace;
    if (place != null) {
      await _selectPlace(place, keepNavigating: _navigating);
    }
    return mapnavbus.MapNavigationReply(
      ok: true,
      message: enabled ? 'Avoiding highways.' : 'Highways are allowed again.',
    );
  }

  Future<mapnavbus.MapNavigationReply> _assistantZoomBy(int delta) async {
    final controller = _controller;
    if (controller == null) {
      return const mapnavbus.MapNavigationReply(
        ok: false,
        message: 'Map is not ready yet.',
      );
    }
    if (delta > 0) {
      // Zoom in always centers on the driver's current GPS position.
      await controller.animateCamera(
        CameraUpdate.newLatLngZoom(_currentCenter, 17),
      );
      return const mapnavbus.MapNavigationReply(
        ok: true,
        message: 'Zoomed in on your current location.',
      );
    } else {
      await controller.animateCamera(CameraUpdate.zoomBy(delta.toDouble()));
      return const mapnavbus.MapNavigationReply(
        ok: true,
        message: 'Zoomed out.',
      );
    }
  }

  Future<mapnavbus.MapNavigationReply> _assistantRecenter() async {
    await _refreshCurrentLocation(moveCamera: true);
    return const mapnavbus.MapNavigationReply(
      ok: true,
      message: 'Recentered on your location.',
    );
  }

  mapnavbus.MapNavigationReply _assistantSetMapType(
      MapType mapType, String label) {
    setState(() => _mapType = mapType);
    return mapnavbus.MapNavigationReply(
      ok: true,
      message: 'Switched to $label view.',
    );
  }

  mapnavbus.MapNavigationReply _assistantSetTraffic(bool enabled) {
    setState(() => _showTraffic = enabled);
    return mapnavbus.MapNavigationReply(
      ok: true,
      message: enabled ? 'Traffic enabled.' : 'Traffic hidden.',
    );
  }

  mapnavbus.MapNavigationReply _assistantQueryEta() {
    if (_selectedPlace == null || _routeMinutes == null) {
      return const mapnavbus.MapNavigationReply(
        ok: false,
        message: 'No active route yet.',
      );
    }
    final mins =
        _navigating ? (_remainingMinutes ?? _routeMinutes!) : _routeMinutes!;
    return mapnavbus.MapNavigationReply(
      ok: true,
      message: 'ETA is ${_etaLabel(mins)}.',
    );
  }

  mapnavbus.MapNavigationReply _assistantQueryMilesLeft() {
    if (_selectedPlace == null || _routeMiles == null) {
      return const mapnavbus.MapNavigationReply(
        ok: false,
        message: 'No active route yet.',
      );
    }
    final miles =
        _navigating ? (_remainingMiles ?? _routeMiles!) : _routeMiles!;
    return mapnavbus.MapNavigationReply(
      ok: true,
      message: '${miles.toStringAsFixed(1)} miles remaining.',
    );
  }

  mapnavbus.MapNavigationReply _assistantQueryNextTurn() {
    if (!_navigating || _navSteps.isEmpty) {
      return const mapnavbus.MapNavigationReply(
        ok: false,
        message: 'No active turn-by-turn navigation.',
      );
    }
    final step = _navSteps[_currentStepIndex];
    final miles = _metersToMiles(step.distanceMeters).toStringAsFixed(1);
    return mapnavbus.MapNavigationReply(
      ok: true,
      message: 'Next turn: ${step.instruction} in $miles miles.',
    );
  }

  mapnavbus.MapNavigationReply _assistantRepeatInstruction() {
    return _assistantQueryNextTurn();
  }

  mapnavbus.MapNavigationReply _assistantQueryAfterThis() {
    if (!_navigating || _navSteps.isEmpty) {
      return const mapnavbus.MapNavigationReply(
        ok: false,
        message: 'No active turn-by-turn navigation.',
      );
    }
    final nextIndex = _currentStepIndex + 1;
    if (nextIndex >= _navSteps.length) {
      return const mapnavbus.MapNavigationReply(
        ok: true,
        message: 'That is the final step.',
      );
    }
    final step = _navSteps[nextIndex];
    return mapnavbus.MapNavigationReply(
      ok: true,
      message: 'After this: ${step.instruction}.',
    );
  }

  String _placeLabel(PlaceSearchResult place) {
    final n = place.name.trim();
    if (n.isNotEmpty) return n;
    final a = place.address.trim();
    if (a.isNotEmpty) return a;
    return 'destination';
  }

  Future<void> _initLocation() async {
    if (!mounted) return;

    setState(() {
      _loadingLocation = true;
      _error = null;
    });

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw Exception('Location services are turned off.');
      }

      LocationPermission permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied) {
        throw Exception('Location permission was denied.');
      }

      if (permission == LocationPermission.deniedForever) {
        throw Exception('Location permission is permanently denied.');
      }

      _locationAllowed = true;
      await _refreshCurrentLocation(moveCamera: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingLocation = false;
        _locationAllowed = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _refreshCurrentLocation({required bool moveCamera}) async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw Exception('Location services are turned off.');
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw Exception('Location permission is not available.');
      }

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
      );

      final target = LatLng(pos.latitude, pos.longitude);

      if (!mounted) return;
      setState(() {
        _locationAllowed = true;
        _loadingLocation = false;
        _error = null;
        _currentCenter = target;
        _currentMarker = Marker(
          markerId: const MarkerId('me'),
          position: target,
          infoWindow: const InfoWindow(title: 'Your Location'),
        );
      });

      if (moveCamera) {
        await _goToLocation(target, zoom: 16);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingLocation = false;
        _locationAllowed = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _goToLocation(LatLng target, {double zoom = 15}) async {
    final controller = _controller;
    if (controller == null) return;

    await controller.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: target, zoom: zoom),
      ),
    );
  }

  Future<void> _fitRouteBounds(LatLngBounds bounds) async {
    final controller = _controller;
    if (controller == null) return;
    await controller.animateCamera(
      CameraUpdate.newLatLngBounds(bounds, 80),
    );
  }

  LatLngBounds _boundsFromPoints(List<LatLng> points) {
    double? minLat;
    double? maxLat;
    double? minLng;
    double? maxLng;

    for (final p in points) {
      minLat = minLat == null ? p.latitude : math.min(minLat, p.latitude);
      maxLat = maxLat == null ? p.latitude : math.max(maxLat, p.latitude);
      minLng = minLng == null ? p.longitude : math.min(minLng, p.longitude);
      maxLng = maxLng == null ? p.longitude : math.max(maxLng, p.longitude);
    }

    return LatLngBounds(
      southwest: LatLng(minLat ?? 0, minLng ?? 0),
      northeast: LatLng(maxLat ?? 0, maxLng ?? 0),
    );
  }

  void _toggleMapType() {
    setState(() {
      if (_mapType == MapType.normal) {
        _mapType = MapType.hybrid;
      } else if (_mapType == MapType.hybrid) {
        _mapType = MapType.terrain;
      } else {
        _mapType = MapType.normal;
      }
    });
  }

  String _mapTypeLabel() {
    switch (_mapType) {
      case MapType.hybrid:
        return 'Hybrid';
      case MapType.terrain:
        return 'Terrain';
      case MapType.normal:
      default:
        return 'Map';
    }
  }

  Future<void> _runSearch() async {
    final query = _searchCtrl.text.trim();
    if (query.isEmpty) return;
    await _runTextSearch(query);
  }

  Future<void> _runTextSearch(String query) async {
    setState(() {
      _searching = true;
      _error = null;
      _activeLabel = query;
      _clearRouteInternal();
    });

    try {
      final places = await _client.searchText(
        query: query,
        latitude: _currentCenter.latitude,
        longitude: _currentCenter.longitude,
        maxResults: 8,
      );

      _applyPlaces(places, label: query);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _runNearbySearch(String category) async {
    setState(() {
      _searching = true;
      _error = null;
      _activeLabel = category;
      _clearRouteInternal();
    });

    try {
      final places = await _client.searchNearby(
        category: category,
        latitude: _currentCenter.latitude,
        longitude: _currentCenter.longitude,
        maxResults: 8,
      );

      _applyPlaces(places, label: category);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _applyPlaces(List<PlaceSearchResult> places, {required String label}) {
    if (!mounted) return;

    final markers = <Marker>{};

    for (final place in places) {
      if (place.latitude == null || place.longitude == null) continue;

      markers.add(
        Marker(
          markerId: MarkerId(place.id.isEmpty ? place.name : place.id),
          position: LatLng(place.latitude!, place.longitude!),
          infoWindow: InfoWindow(
            title: place.name.isEmpty ? 'Place' : place.name,
            snippet: place.address,
          ),
          onTap: () {
            _selectPlace(place);
          },
        ),
      );
    }

    setState(() {
      _searching = false;
      _results = places;
      _poiMarkers
        ..clear()
        ..addAll(markers);
      _activeLabel = label;
    });

    if (places.isNotEmpty) {
      final first = places.first;
      if (first.latitude != null && first.longitude != null) {
        _goToLocation(LatLng(first.latitude!, first.longitude!), zoom: 13.5);
      }
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${places.length} result(s) for $label')),
    );
  }

  Future<void> _focusPlace(PlaceSearchResult place) async {
    if (place.latitude == null || place.longitude == null) return;
    await _goToLocation(
      LatLng(place.latitude!, place.longitude!),
      zoom: 16,
    );
  }

  Future<void> _selectPlace(
    PlaceSearchResult place, {
    bool keepNavigating = false,
  }) async {
    if (place.latitude == null || place.longitude == null) return;

    setState(() {
      _routing = true;
      _error = null;
    });

    try {
      final route = await _client.computeRoute(
        originLatitude: _currentCenter.latitude,
        originLongitude: _currentCenter.longitude,
        destinationLatitude: place.latitude!,
        destinationLongitude: place.longitude!,
        avoidTolls: _avoidTolls,
        avoidHighways: _avoidHighways,
      );

      final decoded = _decodePolyline(route.encodedPolyline);
      final miles = route.distanceMeters / 1609.344;
      final minutes = math.max(1, (route.durationSeconds / 60).round());

      setState(() {
        _routing = false;
        _selectedPlace = place;
        _routeMiles = miles;
        _remainingMiles = miles;
        _routeMinutes = minutes;
        _remainingMinutes = minutes;
        _navigating = keepNavigating;
        _currentStepIndex = 0;
        _navSteps
          ..clear()
          ..addAll(route.steps);
        _routePolylines
          ..clear()
          ..add(
            Polyline(
              polylineId: const PolylineId('real_route'),
              points: decoded,
              width: 6,
              color: Colors.blueAccent,
            ),
          );
      });

      if (decoded.isNotEmpty) {
        await _fitRouteBounds(_boundsFromPoints(decoded));
      } else {
        await _goToLocation(
          LatLng(place.latitude!, place.longitude!),
          zoom: 14,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _routing = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  List<LatLng> _decodePolyline(String encoded) {
    final List<LatLng> points = [];
    int index = 0;
    int lat = 0;
    int lng = 0;

    while (index < encoded.length) {
      int b;
      int shift = 0;
      int result = 0;

      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);

      final dlat = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lat += dlat;

      shift = 0;
      result = 0;

      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);

      final dlng = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lng += dlng;

      points.add(LatLng(lat / 1E5, lng / 1E5));
    }

    return points;
  }

  double _metersToMiles(int meters) => meters / 1609.344;

  void _startRoute({bool showSnackBar = true}) {
    if (_selectedPlace == null) return;

    setState(() {
      _navigating = true;
      _awaitingStartConfirmation = false;
    });

    final destination = LatLng(
      _selectedPlace!.latitude!,
      _selectedPlace!.longitude!,
    );

    _goToLocation(destination, zoom: 14.8);

    final placeName =
        _selectedPlace!.name.isEmpty ? 'destination' : _selectedPlace!.name;

    if (showSnackBar) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Navigation started to $placeName'),
        ),
      );
    }
  }

  void _nextStep() {
    if (_navSteps.isEmpty) return;

    setState(() {
      if (_currentStepIndex < _navSteps.length - 1) {
        _currentStepIndex += 1;

        int remainingMeters = 0;
        int remainingSeconds = 0;

        for (int i = _currentStepIndex; i < _navSteps.length; i++) {
          remainingMeters += _navSteps[i].distanceMeters;
          remainingSeconds += _navSteps[i].durationSeconds;
        }

        _remainingMiles = _metersToMiles(remainingMeters);
        _remainingMinutes = math.max(1, (remainingSeconds / 60).round());
      } else {
        _remainingMiles = 0;
        _remainingMinutes = 0;
      }
    });
  }

  void _clearRoute() {
    setState(() {
      _clearRouteInternal();
    });
  }

  void _clearRouteInternal() {
    _selectedPlace = null;
    _routeMiles = null;
    _routeMinutes = null;
    _remainingMiles = null;
    _remainingMinutes = null;
    _navigating = false;
    _routing = false;
    _currentStepIndex = 0;
    _navSteps.clear();
    _routePolylines.clear();
    _awaitingStartConfirmation = false;
  }

  String _etaLabel(int minutes) {
    if (minutes < 60) return '$minutes min';
    final hours = minutes ~/ 60;
    final mins = minutes % 60;
    if (mins == 0) return '$hours hr';
    return '$hours hr $mins min';
  }

  // ── Bottom panel builders ──────────────────────────────────────────────────

  Widget _buildBottomPanel(BuildContext context, bool isDark) {
    final panelBg =
        isDark ? const Color(0xF21C1C1C) : Colors.white;
    final borderColor =
        isDark ? const Color(0xFF2D2D2D) : const Color(0xFFE8E8E8);
    final titleColor = isDark ? Colors.white : Colors.black87;
    final subtitleColor = isDark ? Colors.white70 : Colors.black54;
    final bottomPad = MediaQuery.of(context).padding.bottom + 6;

    return Container(
      decoration: BoxDecoration(
        color: panelBg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        border: Border(
          top: BorderSide(color: borderColor),
          left: BorderSide(color: borderColor),
          right: BorderSide(color: borderColor),
        ),
        boxShadow: [
          BoxShadow(
            blurRadius: 28,
            offset: const Offset(0, -6),
            color: Colors.black.withOpacity(isDark ? 0.45 : 0.12),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 4),
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? Colors.white24 : Colors.black26,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ),

          if (_navigating && _selectedPlace != null)
            _buildNavPanel(isDark, titleColor, subtitleColor, borderColor, bottomPad)
          else if (_selectedPlace != null && _routeMiles != null)
            _buildRoutePanel(isDark, titleColor, subtitleColor, borderColor, bottomPad)
          else if (_results.isNotEmpty)
            _buildResultsPanel(isDark, titleColor, subtitleColor, borderColor, bottomPad),
        ],
      ),
    );
  }

  Widget _buildResultsPanel(bool isDark, Color titleColor, Color subtitleColor,
      Color borderColor, double bottomPad) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _activeLabel.isEmpty ? 'Results' : _activeLabel,
                  style: TextStyle(
                    color: titleColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF2A2A2A)
                      : const Color(0xFFF0F0F0),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '${_results.length}',
                  style: TextStyle(
                    color: subtitleColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 300),
          child: ListView.separated(
            shrinkWrap: true,
            padding: EdgeInsets.fromLTRB(12, 0, 12, bottomPad),
            itemCount: _results.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final place = _results[i];
              return _PlaceTile(
                place: place,
                isDark: isDark,
                onTap: () async {
                  await _focusPlace(place);
                  await _selectPlace(place);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildRoutePanel(bool isDark, Color titleColor, Color subtitleColor,
      Color borderColor, double bottomPad) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, bottomPad),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _selectedPlace!.name.isEmpty
                ? 'Destination'
                : _selectedPlace!.name,
            style: TextStyle(
              color: titleColor,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          if (_selectedPlace!.address.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              _selectedPlace!.address,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: subtitleColor,
                fontSize: 13,
                height: 1.3,
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              _RouteStatChip(
                label: '${_routeMiles!.toStringAsFixed(1)} mi',
                isDark: isDark,
                icon: Icons.straighten_rounded,
              ),
              const SizedBox(width: 8),
              _RouteStatChip(
                label: _etaLabel(_routeMinutes!),
                isDark: isDark,
                icon: Icons.access_time_rounded,
              ),
              const SizedBox(width: 8),
              _RouteStatChip(
                label: _mapTypeLabel(),
                isDark: isDark,
                icon: Icons.map_outlined,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: titleColor,
                    side: BorderSide(color: borderColor),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: _clearRoute,
                  child: const Text('Clear',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: _startRoute,
                  child: const Text('Start',
                      style: TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 16)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNavPanel(bool isDark, Color titleColor, Color subtitleColor,
      Color borderColor, double bottomPad) {
    final currentStep =
        _navSteps.isNotEmpty ? _navSteps[_currentStepIndex] : null;
    final softBg =
        isDark ? const Color(0xFF242424) : const Color(0xFFF5F5F5);

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, bottomPad),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.navigation_rounded,
                    color: Colors.white, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _selectedPlace!.name.isEmpty
                          ? 'Destination'
                          : _selectedPlace!.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: titleColor,
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${(_remainingMiles ?? _routeMiles ?? 0).toStringAsFixed(1)} mi · ETA ${_etaLabel(_remainingMinutes ?? _routeMinutes ?? 1)}',
                      style: TextStyle(
                        color: subtitleColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: _clearRoute,
                child: const Text(
                  'End',
                  style: TextStyle(
                      color: Colors.red, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          if (currentStep != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: softBg,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.turn_right_rounded,
                        color: Colors.white, size: 20),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      currentStep.instruction,
                      style: TextStyle(
                        color: titleColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    children: [
                      Text(
                        _metersToMiles(currentStep.distanceMeters)
                            .toStringAsFixed(1),
                        style: TextStyle(
                          color: titleColor,
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                        ),
                      ),
                      Text('mi',
                          style:
                              TextStyle(color: subtitleColor, fontSize: 11)),
                    ],
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: _nextStep,
                    icon: Icon(Icons.skip_next_rounded,
                        color: subtitleColor, size: 22),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final panelBg =
        isDark ? const Color(0xF21C1C1C) : Colors.white;
    final borderColor =
        isDark ? const Color(0xFF2D2D2D) : const Color(0xFFE8E8E8);
    final titleColor = isDark ? Colors.white : Colors.black87;

    final currentStep =
        _navSteps.isNotEmpty ? _navSteps[_currentStepIndex] : null;

    // Panel is visible when results exist OR a place is selected
    final hasBottomPanel = _results.isNotEmpty || _selectedPlace != null;

    return Scaffold(
      body: Stack(
        children: [
          // ── Full-screen map ──────────────────────────────────────────
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: _currentCenter,
              zoom: 12,
            ),
            mapType: _mapType,
            trafficEnabled: _showTraffic,
            myLocationEnabled: _locationAllowed,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            mapToolbarEnabled: false,
            compassEnabled: false,
            polylines: _routePolylines,
            markers: {
              if (_currentMarker != null) _currentMarker!,
              ..._poiMarkers,
            },
            onMapCreated: (controller) {
              _controller = controller;
              if (!_mapController.isCompleted) {
                _mapController.complete(controller);
              }
            },
          ),

          // ── Loading overlay ──────────────────────────────────────────
          if (_loadingLocation || _searching || _routing)
            Container(
              color: Colors.black.withOpacity(0.22),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 28, vertical: 22),
                  decoration: BoxDecoration(
                    color: panelBg,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: borderColor),
                    boxShadow: const [
                      BoxShadow(
                          blurRadius: 24,
                          color: Color(0x30000000),
                          offset: Offset(0, 8))
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(strokeWidth: 2),
                      const SizedBox(height: 14),
                      Text(
                        _loadingLocation
                            ? 'Getting location...'
                            : _searching
                                ? 'Searching...'
                                : 'Routing...',
                        style: TextStyle(
                          color: titleColor,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ── Top overlay: nav instruction + search bar + chips ────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Navigation instruction card (active only when navigating)
                    if (_navigating && currentStep != null) ...[
                      _NavInstructionCard(
                        isDark: isDark,
                        instruction: currentStep.instruction,
                        distanceMiles:
                            _metersToMiles(currentStep.distanceMeters),
                        onNext: _nextStep,
                      ),
                      const SizedBox(height: 10),
                    ],

                    // Search bar
                    Material(
                      elevation: isDark ? 0 : 10,
                      shadowColor: const Color(0x22000000),
                      borderRadius: BorderRadius.circular(16),
                      color: panelBg,
                      child: Container(
                        height: 52,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: borderColor),
                        ),
                        child: Row(
                          children: [
                            const SizedBox(width: 14),
                            Icon(
                              Icons.search_rounded,
                              color:
                                  isDark ? Colors.white60 : Colors.black45,
                              size: 22,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextField(
                                controller: _searchCtrl,
                                style: TextStyle(
                                  color: titleColor,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                                decoration: InputDecoration(
                                  hintText: 'Search places...',
                                  hintStyle: TextStyle(
                                    color: isDark
                                        ? Colors.white38
                                        : Colors.black38,
                                    fontSize: 15,
                                  ),
                                  border: InputBorder.none,
                                  isDense: true,
                                ),
                                onSubmitted: (_) => _runSearch(),
                              ),
                            ),
                            if (_searchCtrl.text.isNotEmpty)
                              GestureDetector(
                                onTap: () {
                                  _searchCtrl.clear();
                                  setState(() {});
                                },
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: Icon(Icons.close_rounded,
                                      color: isDark
                                          ? Colors.white38
                                          : Colors.black38,
                                      size: 18),
                                ),
                              ),
                            GestureDetector(
                              onTap: _runSearch,
                              child: Container(
                                margin: const EdgeInsets.only(right: 8),
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: Colors.black,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(Icons.arrow_forward_rounded,
                                    color: Colors.white, size: 18),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 10),

                    // Category chips
                    SizedBox(
                      height: 36,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _quickCategories.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(width: 8),
                        itemBuilder: (_, i) {
                          final item = _quickCategories[i];
                          return _CategoryChip(
                            label: item.label,
                            icon: item.icon,
                            isDark: isDark,
                            onTap: () => _runNearbySearch(item.label),
                          );
                        },
                      ),
                    ),

                    // Error banner
                    if (_error != null) ...[
                      const SizedBox(height: 10),
                      GestureDetector(
                        onTap: () {
                          showDialog<void>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Maps error'),
                              content: SingleChildScrollView(
                                child: SelectableText(_error!),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(ctx).pop(),
                                  child: const Text('Close'),
                                ),
                              ],
                            ),
                          );
                        },
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: panelBg,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                                color: Colors.red.withOpacity(0.4)),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.error_outline_rounded,
                                  color: Colors.red.shade400, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _error!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.red.shade400,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),

          // ── Right FABs — animate up when bottom panel appears ────────
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            right: 12,
            bottom: hasBottomPanel ? 290 : 20,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _MapActionButton(
                  isDark: isDark,
                  icon: Icons.my_location_rounded,
                  onTap: () => _refreshCurrentLocation(moveCamera: true),
                ),
                const SizedBox(height: 10),
                _MapActionButton(
                  isDark: isDark,
                  icon: Icons.layers_rounded,
                  onTap: _toggleMapType,
                ),
              ],
            ),
          ),

          // ── Bottom panel ─────────────────────────────────────────────
          if (hasBottomPanel)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _buildBottomPanel(context, isDark),
            ),
        ],
      ),
    );
  }
}

// ── Supporting data ────────────────────────────────────────────────────────────

class _QuickMapCategory {
  final String label;
  final IconData icon;

  const _QuickMapCategory(this.label, this.icon);
}

// ── Navigation instruction card (top, when navigating) ────────────────────────

class _NavInstructionCard extends StatelessWidget {
  const _NavInstructionCard({
    required this.isDark,
    required this.instruction,
    required this.distanceMiles,
    required this.onNext,
  });

  final bool isDark;
  final String instruction;
  final double distanceMiles;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(
            blurRadius: 20,
            offset: Offset(0, 6),
            color: Color(0x40000000),
          ),
        ],
      ),
      child: Row(
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.turn_right_rounded,
                    color: Colors.white, size: 26),
              ),
              const SizedBox(height: 4),
              Text(
                distanceMiles.toStringAsFixed(1),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Text(
                'mi',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.55),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              instruction,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
          ),
          IconButton(
            onPressed: onNext,
            icon: Icon(Icons.skip_next_rounded,
                color: Colors.white.withOpacity(0.6), size: 24),
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }
}

// ── Category chip ──────────────────────────────────────────────────────────────

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.icon,
    required this.isDark,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = isDark ? const Color(0xF01C1C1C) : Colors.white;
    final border =
        isDark ? const Color(0xFF2D2D2D) : const Color(0xFFE8E8E8);
    final textColor = isDark ? Colors.white : Colors.black87;

    return Material(
      color: bg,
      elevation: isDark ? 0 : 6,
      shadowColor: const Color(0x1A000000),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: textColor),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(
                  color: textColor,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Map action button (FAB) ────────────────────────────────────────────────────

class _MapActionButton extends StatelessWidget {
  const _MapActionButton({
    required this.isDark,
    required this.icon,
    required this.onTap,
  });

  final bool isDark;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = isDark ? const Color(0xF01C1C1C) : Colors.white;
    final border =
        isDark ? const Color(0xFF2D2D2D) : const Color(0xFFE8E8E8);

    return Material(
      color: bg,
      elevation: isDark ? 0 : 8,
      shadowColor: const Color(0x1A000000),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: border),
          ),
          child: Icon(
            icon,
            color: isDark ? Colors.white : Colors.black87,
            size: 22,
          ),
        ),
      ),
    );
  }
}

// ── Place result tile ──────────────────────────────────────────────────────────

class _PlaceTile extends StatelessWidget {
  const _PlaceTile({
    required this.place,
    required this.isDark,
    required this.onTap,
  });

  final PlaceSearchResult place;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tileBg =
        isDark ? const Color(0xFF222222) : const Color(0xFFF7F7F7);
    final border =
        isDark ? const Color(0xFF2D2D2D) : const Color(0xFFEAEAEA);
    final titleColor = isDark ? Colors.white : Colors.black87;
    final subtitleColor = isDark ? Colors.white70 : Colors.black54;

    final ratingText = place.rating == null
        ? ''
        : place.userRatingCount == null
            ? '${place.rating!.toStringAsFixed(1)}★'
            : '${place.rating!.toStringAsFixed(1)}★  (${place.userRatingCount})';

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: tileBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.place_outlined,
                  color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    place.name.isEmpty ? 'Place' : place.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: titleColor,
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    place.address,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: subtitleColor,
                      fontSize: 12,
                    ),
                  ),
                  if (ratingText.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      ratingText,
                      style: TextStyle(
                        color: subtitleColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.arrow_forward_ios_rounded,
                color: subtitleColor, size: 14),
          ],
        ),
      ),
    );
  }
}

// ── Route stat chip ────────────────────────────────────────────────────────────

class _RouteStatChip extends StatelessWidget {
  const _RouteStatChip({
    required this.label,
    required this.isDark,
    required this.icon,
  });

  final String label;
  final bool isDark;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final bg =
        isDark ? const Color(0xFF242424) : const Color(0xFFF3F3F3);
    final border =
        isDark ? const Color(0xFF2D2D2D) : const Color(0xFFEAEAEA);
    final textColor = isDark ? Colors.white : Colors.black87;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: textColor),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: textColor,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
