import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:lottie/lottie.dart' as lottie;

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
  Marker? _navArrowMarker;
  BitmapDescriptor? _navArrowIcon;
  StreamSubscription<Position>? _navPositionStream;
  final Set<Marker> _poiMarkers = {};
  final Set<Polyline> _routePolylines = {};

  List<PlaceSearchResult> _results = [];
  String _activeLabel = '';
  // True when _results come from an along-route search (POI overlay, not destination search).
  bool _isAlongRouteSearch = false;

  PlaceSearchResult? _selectedPlace;
  PlaceDetailsResult? _selectedPlaceDetails;
  double? _routeMiles;
  int? _routeMinutes;
  bool _navigating = false;

  final List<RouteStepResult> _navSteps = [];
  int _currentStepIndex = 0;
  double? _remainingMiles;
  int? _remainingMinutes;
  final List<RouteResult> _routeAlternatives = [];
  int _activeRouteIndex = 0;
  List<LatLng> _activeRoutePoints = const [];
  double _currentBearing = 0.0;

  // Camera bearing tracked via ValueNotifier so only the compass button rebuilds
  final ValueNotifier<double> _cameraBearing = ValueNotifier(0.0);

  // When false the GPS stream skips camera updates so the user can manually
  // pan/reset the compass without it snapping back immediately.
  bool _cameraFollowEnabled = true;
  Timer? _cameraFollowResumeTimer;

  // Cached Lottie composition — preloaded in initState to eliminate first-frame lag
  lottie.LottieComposition? _lottieComposition;
  CameraPosition _lastCameraPosition = const CameraPosition(
    target: LatLng(29.7604, -95.3698),
    zoom: 12,
  );

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
    _preloadLottie();
  }

  Future<void> _preloadLottie() async {
    try {
      final data = await rootBundle.load('assets/animations/AI Assistant.json');
      final composition = await lottie.LottieComposition.fromByteData(data);
      if (mounted) setState(() => _lottieComposition = composition);
    } catch (_) {}
  }

  @override
  void didUpdateWidget(covariant MapsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
    _navPositionStream?.cancel();
    _cameraFollowResumeTimer?.cancel();
    _searchCtrl.dispose();
    _cameraBearing.dispose();
    super.dispose();
  }

  // ── Navigation arrow bitmap ─────────────────────────────────────────────────

  Future<BitmapDescriptor> _buildNavArrowIcon() async {
    // Draw at physical pixel resolution so the icon is exactly 52 logical dp
    // on every screen density. Without imagePixelRatio each bitmap pixel maps
    // to 1 dp, which blows up on high-DPI devices.
    final dpr = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
    const double logicalSize = 52.0;
    final double size = logicalSize * dpr;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder, Rect.fromLTWH(0, 0, size, size));

    // Drop shadow
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.22)
      ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, size * 0.06);
    canvas.drawCircle(
        Offset(size / 2, size / 2 + size * 0.04), size / 2 - size * 0.04, shadowPaint);

    // White circle background
    canvas.drawCircle(
      Offset(size / 2, size / 2),
      size / 2 - size * 0.03,
      Paint()..color = Colors.white,
    );

    // Blue navigation arrow — points straight up (north); rotation applied on marker
    final arrowPaint = Paint()
      ..color = const Color(0xFF1A73E8)
      ..style = PaintingStyle.fill;

    final path = ui.Path();
    path.moveTo(size * 0.50, size * 0.14); // tip
    path.lineTo(size * 0.74, size * 0.75); // bottom-right
    path.lineTo(size * 0.50, size * 0.61); // center indent
    path.lineTo(size * 0.26, size * 0.75); // bottom-left
    path.close();
    canvas.drawPath(path, arrowPaint);

    final picture = recorder.endRecording();
    final img = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(
      byteData!.buffer.asUint8List(),
      imagePixelRatio: dpr,
    );
  }

  // ── Live GPS stream for navigation ─────────────────────────────────────────

  void _startNavPositionStream() {
    _navPositionStream?.cancel();
    _navPositionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 3,
      ),
    ).listen((Position pos) {
      if (!mounted || !_navigating) return;
      final newCenter = LatLng(pos.latitude, pos.longitude);
      // Use GPS heading when valid; fall back to route bearing otherwise.
      final heading = pos.heading >= 0 ? pos.heading : _currentBearing;
      setState(() {
        _currentCenter = newCenter;
        _currentBearing = heading;
        _navArrowMarker = _buildNavMarker(newCenter, bearing: heading);
      });
      // Only chase the camera when the user hasn't manually taken control
      // (e.g. tapped the compass to reset north-up).
      if (_cameraFollowEnabled) {
        _controller?.animateCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(
              target: _lookAheadTarget(metersAhead: 60),
              zoom: 18.5,
              tilt: 60,
              bearing: heading,
            ),
          ),
        );
      }
    });
  }

  Marker _buildNavMarker(LatLng position, {double? bearing}) {
    return Marker(
      markerId: const MarkerId('nav_arrow'),
      position: position,
      icon: _navArrowIcon ?? BitmapDescriptor.defaultMarker,
      rotation: bearing ?? _currentBearing,
      anchor: const Offset(0.5, 0.5),
      flat: true,
      zIndexInt: 3,
      consumeTapEvents: false,
    );
  }

  Future<void> onTabVisible() async {
    await _refreshCurrentLocation(moveCamera: false);
  }

  Future<void> runAssistantSearch(String query) async {
    _searchCtrl.text = query;
    await _runSearch();
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
      case mapnavbus.MapNavigationAction.queryHeading:
        return _assistantQueryHeading();
      case mapnavbus.MapNavigationAction.resetCompass:
        await _resetNorthUp();
        return const mapnavbus.MapNavigationReply(
          ok: true,
          message: 'Compass reset to north.',
        );
      case mapnavbus.MapNavigationAction.clearSearchResults:
        return _assistantClearSearchResults();
      case mapnavbus.MapNavigationAction.searchAlongRoute:
        return _assistantSearchAlongRoute(command.destinationQuery);
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
      _startRoute();
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
      // Zoom in → center on current GPS position then zoom in.
      await controller.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: _currentCenter,
            zoom: _lastCameraPosition.zoom + 2,
          ),
        ),
      );
      return const mapnavbus.MapNavigationReply(
        ok: true,
        message: 'Zoomed in on your current location.',
      );
    } else {
      // Zoom out → if a route exists, fit the full route so the destination
      // is visible; otherwise just zoom out on the current view.
      if (_activeRoutePoints.isNotEmpty) {
        await _fitRouteBounds(_boundsFromPoints(_activeRoutePoints));
        return const mapnavbus.MapNavigationReply(
          ok: true,
          message: 'Showing full route to your destination.',
        );
      }
      await controller.animateCamera(CameraUpdate.zoomBy(-2.0));
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

  mapnavbus.MapNavigationReply _assistantQueryHeading() {
    final bearing = _currentBearing;
    final directions = [
      'North', 'Northeast', 'East', 'Southeast',
      'South', 'Southwest', 'West', 'Northwest',
    ];
    final index = ((bearing + 22.5) / 45).floor() % 8;
    final cardinal = directions[index];
    return mapnavbus.MapNavigationReply(
      ok: true,
      message: 'You are heading $cardinal — ${bearing.toStringAsFixed(0)}°.',
    );
  }

  mapnavbus.MapNavigationReply _assistantClearSearchResults() {
    final hasResults = _results.isNotEmpty || _poiMarkers.isNotEmpty;
    if (!hasResults && _navigating && _selectedPlace != null) {
      // Nothing to clear — just snap camera back to nav view.
      _cameraFollowEnabled = true;
      _controller?.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: _lookAheadTarget(metersAhead: 60),
            zoom: 18.5,
            tilt: 60,
            bearing: _currentBearing,
          ),
        ),
      );
      return mapnavbus.MapNavigationReply(
        ok: true,
        message:
            'Back on your route to ${_placeLabel(_selectedPlace!)}.',
      );
    }
    if (!hasResults) {
      return const mapnavbus.MapNavigationReply(
        ok: false,
        message: 'No search results to clear.',
      );
    }
    setState(() {
      _results.clear();
      _poiMarkers.clear();
      _activeLabel = '';
      _isAlongRouteSearch = false;
    });
    if (_navigating && _selectedPlace != null) {
      _cameraFollowEnabled = true;
      _controller?.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: _lookAheadTarget(metersAhead: 60),
            zoom: 18.5,
            tilt: 60,
            bearing: _currentBearing,
          ),
        ),
      );
      return mapnavbus.MapNavigationReply(
        ok: true,
        message:
            'Cleared. Back to navigating to ${_placeLabel(_selectedPlace!)}.',
      );
    }
    return const mapnavbus.MapNavigationReply(
      ok: true,
      message: 'Search results cleared.',
    );
  }

  Future<mapnavbus.MapNavigationReply> _assistantSearchAlongRoute(
      String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      return const mapnavbus.MapNavigationReply(
        ok: false,
        message: 'What would you like to search for along the route?',
      );
    }
    if (!_navigating || _activeRoutePoints.isEmpty) {
      return const mapnavbus.MapNavigationReply(
        ok: false,
        message:
            'No active route. Start navigation first, then I can search along your route.',
      );
    }
    _searchCtrl.text = q;
    await _runAlongRouteSearch(q);
    if (_results.isEmpty) {
      return mapnavbus.MapNavigationReply(
        ok: false,
        message: 'No $q found along your route.',
      );
    }
    return mapnavbus.MapNavigationReply(
      ok: true,
      message:
          'Found ${_results.length} result${_results.length == 1 ? '' : 's'} for $q along your route. '
          'I\'ve pinned them on the map, ordered from nearest to farthest.',
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

  Future<void> _runSearch() async {
    final query = _searchCtrl.text.trim();
    if (query.isEmpty) return;
    // Any time there are active route points (navigating OR route-preview),
    // search along the route so the destination is never cleared.
    if (_activeRoutePoints.isNotEmpty) {
      await _runAlongRouteSearch(query);
      return;
    }
    await _runTextSearch(query);
  }

  Future<void> _runTextSearch(String query) async {
    await _dismissOverlays();
    setState(() {
      _searching = true;
      _error = null;
      _activeLabel = query;
      _isAlongRouteSearch = false;
      // Clear previous search state but NEVER touch the active route —
      // _routePolylines / _activeRoutePoints / _navigating are preserved.
      _results.clear();
      _poiMarkers.clear();
      // Clear the selected destination so the results list panel shows.
      // The route polyline stays on the map until the user picks a new
      // destination (which calls _selectPlace and replaces the route).
      _selectedPlace = null;
      _selectedPlaceDetails = null;
      _routeMiles = null;
      _routeMinutes = null;
      _remainingMiles = null;
      _remainingMinutes = null;
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
      setState(() => _searching = false);
      _showSearchError(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _runNearbySearch(String category) async {
    // When a route is active (navigating or preview), chip taps pin POIs along
    // the route without touching the destination.
    if (_activeRoutePoints.isNotEmpty) {
      await _runAlongRouteSearch(category);
      return;
    }
    await _dismissOverlays();
    setState(() {
      _searching = true;
      _error = null;
      _activeLabel = category;
      _isAlongRouteSearch = false;
      _results.clear();
      _poiMarkers.clear();
      _selectedPlace = null;
      _selectedPlaceDetails = null;
      _routeMiles = null;
      _routeMinutes = null;
      _remainingMiles = null;
      _remainingMinutes = null;
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
      setState(() => _searching = false);
      _showSearchError(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _applyPlaces(
    List<PlaceSearchResult> places, {
    required String label,
    bool isAlongRoute = false,
  }) {
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
            // Along-route POIs: focus camera only, never replace destination.
            if (_isAlongRouteSearch || _navigating) {
              _focusPlace(place);
            } else {
              _selectPlace(place);
            }
          },
        ),
      );
    }

    setState(() {
      _searching = false;
      _results = places;
      _isAlongRouteSearch = isAlongRoute;
      _poiMarkers
        ..clear()
        ..addAll(markers);
      _activeLabel = label;
    });

    if (places.isNotEmpty) {
      if (isAlongRoute && _activeRoutePoints.isNotEmpty) {
        // Zoom out to show the full route so all pinned markers are visible.
        _fitRouteBounds(_boundsFromPoints(_activeRoutePoints));
      } else if (!isAlongRoute) {
        final first = places.first;
        if (first.latitude != null && first.longitude != null) {
          _goToLocation(LatLng(first.latitude!, first.longitude!), zoom: 13.5);
        }
      }
    }
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
      final detailsFuture =
          _client.fetchPlaceDetails(place: place).catchError((_) {
        return const PlaceDetailsResult(
          openNow: null,
          hoursSummary: null,
          weekdayDescriptions: <String>[],
          photoUrls: <String>[],
        );
      });

      final routeOptions = await _client.computeRoutes(
        originLatitude: _currentCenter.latitude,
        originLongitude: _currentCenter.longitude,
        destinationLatitude: place.latitude!,
        destinationLongitude: place.longitude!,
        avoidTolls: _avoidTolls,
        avoidHighways: _avoidHighways,
        computeAlternatives: true,
      );
      final details = await detailsFuture;
      final routes = routeOptions.routes;
      final primary = routes.first;
      final decoded = _decodePolyline(primary.encodedPolyline);
      final miles = primary.distanceMeters / 1609.344;
      final minutes = math.max(1, (primary.durationSeconds / 60).round());

      setState(() {
        _routing = false;
        _selectedPlace = place;
        _selectedPlaceDetails = details;
        _routeMiles = miles;
        _remainingMiles = miles;
        _routeMinutes = minutes;
        _remainingMinutes = minutes;
        _navigating = keepNavigating;
        _currentStepIndex = 0;
        _activeRouteIndex = 0;
        _routeAlternatives
          ..clear()
          ..addAll(routes);
        _activeRoutePoints = decoded;
        _navSteps
          ..clear()
          ..addAll(primary.steps);
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

  double _distanceMilesBetween(LatLng a, LatLng b) {
    const earthMiles = 3958.8;
    final dLat = (b.latitude - a.latitude) * math.pi / 180.0;
    final dLng = (b.longitude - a.longitude) * math.pi / 180.0;
    final lat1 = a.latitude * math.pi / 180.0;
    final lat2 = b.latitude * math.pi / 180.0;
    final sinDLat = math.sin(dLat / 2);
    final sinDLng = math.sin(dLng / 2);
    final h = sinDLat * sinDLat +
        math.cos(lat1) * math.cos(lat2) * sinDLng * sinDLng;
    return 2 * earthMiles * math.asin(math.min(1, math.sqrt(h)));
  }

  bool _isPlaceAlongActiveRoute(PlaceSearchResult place,
      {double corridorMiles = 4}) {
    if (_activeRoutePoints.isEmpty ||
        place.latitude == null ||
        place.longitude == null) {
      return false;
    }
    final p = LatLng(place.latitude!, place.longitude!);
    final step = _activeRoutePoints.length > 60
        ? (_activeRoutePoints.length / 60).ceil()
        : 1;
    for (int i = 0; i < _activeRoutePoints.length; i += step) {
      if (_distanceMilesBetween(p, _activeRoutePoints[i]) <= corridorMiles) {
        return true;
      }
    }
    return false;
  }

  // Returns places ordered by their earliest appearance along the active route.
  List<PlaceSearchResult> _sortAlongRoute(List<PlaceSearchResult> places) {
    final step = _activeRoutePoints.length > 60
        ? (_activeRoutePoints.length / 60).ceil()
        : 1;
    final indexed = <({PlaceSearchResult place, int idx})>[];
    for (final place in places) {
      if (place.latitude == null || place.longitude == null) continue;
      final p = LatLng(place.latitude!, place.longitude!);
      int closestIdx = 0;
      double minDist = double.infinity;
      for (int i = 0; i < _activeRoutePoints.length; i += step) {
        final d = _distanceMilesBetween(p, _activeRoutePoints[i]);
        if (d < minDist) {
          minDist = d;
          closestIdx = i;
        }
      }
      indexed.add((place: place, idx: closestIdx));
    }
    indexed.sort((a, b) => a.idx.compareTo(b.idx));
    return indexed.map((e) => e.place).toList();
  }

  Future<void> _runAlongRouteSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty || _activeRoutePoints.isEmpty) {
      await _runTextSearch(q);
      return;
    }
    await _dismissOverlays();
    setState(() {
      _searching = true;
      _error = null;
      _activeLabel = '$q · Along route';
    });

    const maxAttempts = 3;
    const retryDelays = [Duration(seconds: 1), Duration(seconds: 2)];

    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final bounds = _boundsFromPoints(_activeRoutePoints);
        const pad = 0.05;
        final places = await _client.searchText(
          query: q,
          boundsNorth: bounds.northeast.latitude + pad,
          boundsSouth: bounds.southwest.latitude - pad,
          boundsEast: bounds.northeast.longitude + pad,
          boundsWest: bounds.southwest.longitude - pad,
          maxResults: 10,
        );
        if (!mounted) return;
        final along = places.where(_isPlaceAlongActiveRoute).toList();
        final sorted = _sortAlongRoute(along.isEmpty ? places : along);
        _applyPlaces(
          sorted,
          label: along.isEmpty ? q : '$q · Along route',
          isAlongRoute: true,
        );
        return; // success
      } catch (e) {
        if (!mounted) return;
        final msg = e.toString();
        final isTransient = msg.contains('503') ||
            msg.contains('502') ||
            msg.contains('429') ||
            msg.contains('UNAVAILABLE') ||
            msg.contains('timeout');
        if (isTransient && attempt < maxAttempts - 1) {
          await Future<void>.delayed(retryDelays[attempt]);
          continue; // retry
        }
        // Final failure — show non-blocking feedback and don't touch the route.
        if (!mounted) return;
        setState(() => _searching = false);
        _showSearchError(msg.replaceFirst('Exception: ', ''));
        return;
      }
    }
  }

  // Shows a brief snackbar during navigation; a short-lived banner otherwise.
  void _showSearchError(String message) {
    if (!mounted) return;
    if (_navigating) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            message.length > 80 ? '${message.substring(0, 80)}…' : message,
            style: const TextStyle(fontSize: 13),
          ),
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.red.shade700,
        ),
      );
    } else {
      setState(() => _error = message);
      // Auto-clear the error banner after 6 s so it doesn't block the UI.
      Future<void>.delayed(const Duration(seconds: 6)).then((_) {
        if (mounted && _error == message) setState(() => _error = null);
      });
    }
  }

  Future<void> _showRouteSearchDialog() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    String? result;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _RouteSearchSheet(
        isDark: isDark,
        onSearch: (q) {
          result = q;
          Navigator.of(ctx).pop();
        },
      ),
    );
    if (result == null || result!.isEmpty) return;
    _searchCtrl.text = result!;
    await _runAlongRouteSearch(result!);
  }

  // Closes any open modal bottom sheet before showing the loading overlay.
  Future<void> _dismissOverlays() async {
    final nav = Navigator.of(context, rootNavigator: true);
    while (nav.canPop()) {
      nav.pop();
      // Give the pop animation one frame to complete
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> _resetNorthUp() async {
    final controller = _controller;
    if (controller == null) return;

    // Pause camera-follow so the GPS stream doesn't immediately override the reset.
    _cameraFollowEnabled = false;
    _cameraFollowResumeTimer?.cancel();
    _cameraFollowResumeTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) _cameraFollowEnabled = true;
    });

    final current = _lastCameraPosition;
    await controller.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: current.target,
          zoom: current.zoom,
          tilt: 0,
          bearing: 0,
        ),
      ),
    );
  }

  DateTime? _arrivalTime() {
    final mins = _remainingMinutes ?? _routeMinutes;
    if (mins == null) return null;
    return DateTime.now().add(Duration(minutes: mins));
  }

  double _metersToMiles(int meters) => meters / 1609.344;

  double _bearingDegrees(LatLng from, LatLng to) {
    final lat1 = from.latitude * math.pi / 180.0;
    final lat2 = to.latitude * math.pi / 180.0;
    final dLon = (to.longitude - from.longitude) * math.pi / 180.0;
    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    final brng = math.atan2(y, x) * 180.0 / math.pi;
    return (brng + 360.0) % 360.0;
  }

  double _navigationBearing() {
    if (_activeRoutePoints.length >= 2) {
      return _bearingDegrees(_activeRoutePoints[0], _activeRoutePoints[1]);
    }
    if (_selectedPlace?.latitude != null && _selectedPlace?.longitude != null) {
      return _bearingDegrees(
        _currentCenter,
        LatLng(_selectedPlace!.latitude!, _selectedPlace!.longitude!),
      );
    }
    return 0;
  }

  /// Returns a look-ahead point ahead of the current position along the route
  /// bearing. When used as camera target (with tilt+bearing set), the current
  /// position naturally renders in the lower ~30% of the visible map — showing
  /// the road ahead in the upper portion, exactly like Google Maps navigation.
  LatLng _lookAheadTarget({double metersAhead = 60}) {
    final bearing = _navigationBearing();
    final lat = _currentCenter.latitude;
    final dLat =
        metersAhead * math.cos(bearing * math.pi / 180.0) / 111111.0;
    final dLng = metersAhead *
        math.sin(bearing * math.pi / 180.0) /
        (111111.0 * math.cos(lat * math.pi / 180.0));
    return LatLng(lat + dLat, _currentCenter.longitude + dLng);
  }

  void _startRoute() {
    if (_selectedPlace == null) return;

    // Build nav arrow icon then activate navigation
    _buildNavArrowIcon().then((icon) {
      if (!mounted) return;
      final initialBearing = _navigationBearing();
      _cameraFollowResumeTimer?.cancel();
      _cameraFollowEnabled = true;
      setState(() {
        _navArrowIcon = icon;
        _currentBearing = initialBearing;
        _navArrowMarker = _buildNavMarker(_currentCenter, bearing: initialBearing);
        _navigating = true;
        _awaitingStartConfirmation = false;
      });

      _controller?.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: _lookAheadTarget(metersAhead: 60),
            zoom: 18.5,
            tilt: 60,
            bearing: _navigationBearing(),
          ),
        ),
      );

      _startNavPositionStream();
    });

  }

  Future<void> _switchRouteOption(int index) async {
    if (index < 0 || index >= _routeAlternatives.length) return;
    final route = _routeAlternatives[index];
    final decoded = _decodePolyline(route.encodedPolyline);
    final miles = route.distanceMeters / 1609.344;
    final minutes = math.max(1, (route.durationSeconds / 60).round());
    setState(() {
      _activeRouteIndex = index;
      _routeMiles = miles;
      _remainingMiles = miles;
      _routeMinutes = minutes;
      _remainingMinutes = minutes;
      _currentStepIndex = 0;
      _activeRoutePoints = decoded;
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
    }
  }

  Future<void> _showRouteOptionsSheet() async {
    if (_routeAlternatives.length <= 1) return;
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: ListView.separated(
            itemCount: _routeAlternatives.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final route = _routeAlternatives[i];
              final miles = (route.distanceMeters / 1609.344).toStringAsFixed(1);
              final mins = math.max(1, (route.durationSeconds / 60).round());
              return ListTile(
                onTap: () => Navigator.of(ctx).pop(i),
                leading: Icon(
                  i == _activeRouteIndex
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                title: Text('Route ${i + 1}'),
                subtitle: Text('${_etaLabel(mins)} · $miles mi'),
                trailing: i == _activeRouteIndex
                    ? const Text('Current')
                    : const Text('Switch'),
              );
            },
          ),
        );
      },
    );
    if (picked == null || picked == _activeRouteIndex) return;
    await _switchRouteOption(picked);
  }

  void _clearRoute() {
    setState(() {
      _clearRouteInternal();
    });
  }

  void _clearRouteInternal() {
    _selectedPlace = null;
    _selectedPlaceDetails = null;
    _routeMiles = null;
    _routeMinutes = null;
    _remainingMiles = null;
    _remainingMinutes = null;
    _navPositionStream?.cancel();
    _navPositionStream = null;
    _navArrowMarker = null;
    _navigating = false;
    _routing = false;
    _currentBearing = 0.0;
    _cameraFollowEnabled = true;
    _cameraFollowResumeTimer?.cancel();
    _currentStepIndex = 0;
    _activeRouteIndex = 0;
    _activeRoutePoints = const [];
    _routeAlternatives.clear();
    _navSteps.clear();
    _routePolylines.clear();
    _awaitingStartConfirmation = false;
    _isAlongRouteSearch = false;
    _results.clear();
    _poiMarkers.clear();
    _activeLabel = '';
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

          if (_navigating && _selectedPlace != null) ...[
            if (_isAlongRouteSearch && _results.isNotEmpty)
              _buildAlongRouteResultsBadge(isDark, titleColor, subtitleColor, borderColor),
            _buildNavPanel(isDark, titleColor, subtitleColor, borderColor, bottomPad),
          ] else if (_selectedPlace != null && _routeMiles != null) ...[
            if (_isAlongRouteSearch && _results.isNotEmpty)
              _buildAlongRouteResultsBadge(isDark, titleColor, subtitleColor, borderColor),
            _buildPlaceDetailsPanel(
              isDark,
              titleColor,
              subtitleColor,
              borderColor,
              bottomPad,
            ),
          ] else if (!_isAlongRouteSearch && _results.isNotEmpty)
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

  String _placeStatusLine() {
    final details = _selectedPlaceDetails;
    if (details == null) return 'Status unavailable';
    final status = details.openNow == null
        ? 'Status unavailable'
        : (details.openNow! ? 'Open now' : 'Closed now');
    final hours = details.hoursSummary;
    if (hours == null || hours.isEmpty) return status;
    return '$status · $hours';
  }

  String _ratingLine(PlaceSearchResult place) {
    if (place.rating == null) return 'No ratings yet';
    final rating = place.rating!.toStringAsFixed(1);
    final reviews = place.userRatingCount;
    if (reviews == null) return '$rating ★';
    return '$rating ★ ($reviews reviews)';
  }

  Widget _buildPlaceDetailsPanel(bool isDark, Color titleColor, Color subtitleColor,
      Color borderColor, double bottomPad) {
    final place = _selectedPlace!;
    final photoUrls = _selectedPlaceDetails?.photoUrls ?? const <String>[];
    final travelTime = _routeMinutes == null ? '--' : _etaLabel(_routeMinutes!);
    final travelMiles = _routeMiles == null ? '--' : '${_routeMiles!.toStringAsFixed(1)} mi';

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, bottomPad),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  place.name.isEmpty ? 'Destination' : place.name,
                  style: TextStyle(
                    color: titleColor,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 10),
              IconButton(
                onPressed: _clearRoute,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.close_rounded,
                  color: subtitleColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            _ratingLine(place),
            style: TextStyle(
              color: subtitleColor,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (place.address.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              place.address,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: subtitleColor,
                fontSize: 13,
                height: 1.3,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'Travel time: $travelTime · $travelMiles',
            style: TextStyle(
              color: titleColor,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _placeStatusLine(),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: subtitleColor,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    backgroundColor: isDark
                        ? const Color(0xFF2A2A2A)
                        : const Color(0xFFE9F2FF),
                    foregroundColor: titleColor,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () => _focusPlace(place),
                  child: const Text(
                    'Directions',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: _startRoute,
                  child: const Text(
                    'Start',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (photoUrls.isNotEmpty)
            SizedBox(
              height: 92,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: photoUrls.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, index) {
                  final url = photoUrls[index];
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.network(
                      url,
                      width: 132,
                      height: 92,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 132,
                        height: 92,
                        color: isDark
                            ? const Color(0xFF242424)
                            : const Color(0xFFF0F0F0),
                        child: Icon(
                          Icons.image_not_supported_outlined,
                          color: subtitleColor,
                          size: 20,
                        ),
                      ),
                    ),
                  );
                },
              ),
            )
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF242424) : const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: borderColor),
              ),
              child: Text(
                'No photos available for this place.',
                style: TextStyle(
                  color: subtitleColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNavPanel(bool isDark, Color titleColor, Color subtitleColor,
      Color borderColor, double bottomPad) {
    final travelMinutes = _remainingMinutes ?? _routeMinutes ?? 0;
    final travelMiles = _remainingMiles ?? _routeMiles ?? 0;
    final arrival = _arrivalTime();
    final arrivalLabel = arrival == null
        ? '--'
        : TimeOfDay.fromDateTime(arrival).format(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 4, 16, bottomPad),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Route options icon
          GestureDetector(
            onTap: _showRouteOptionsSheet,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF2C2C2C)
                    : const Color(0xFFF0F0F0),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.alt_route_rounded,
                color: titleColor,
                size: 22,
              ),
            ),
          ),
          const SizedBox(width: 14),
          // Time + distance
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _etaLabel(travelMinutes),
                  maxLines: 1,
                  style: TextStyle(
                    color: Colors.green.shade700,
                    fontSize: 32,
                    fontWeight: FontWeight.w900,
                    height: 1,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${travelMiles.toStringAsFixed(1)} mi · $arrivalLabel',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: subtitleColor,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          // Exit button
          FilledButton.tonal(
            onPressed: _clearRoute,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFF8DFDF),
              foregroundColor: const Color(0xFFB73737),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: 22,
                vertical: 14,
              ),
            ),
            child: const Text(
              'Exit',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 18,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Thin strip shown above the nav panel when along-route markers are on the map.
  Widget _buildAlongRouteResultsBadge(
      bool isDark, Color titleColor, Color subtitleColor, Color borderColor) {
    final label = _activeLabel.isNotEmpty ? _activeLabel : 'places';
    final count = _results.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 2),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0xFF0B7D77).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(99),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.pin_drop_rounded,
                    size: 13, color: Color(0xFF0B7D77)),
                const SizedBox(width: 5),
                Text(
                  '$count found',
                  style: const TextStyle(
                    color: Color(0xFF0B7D77),
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: titleColor,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          GestureDetector(
            onTap: () {
              setState(() {
                _results.clear();
                _poiMarkers.clear();
                _activeLabel = '';
                _isAlongRouteSearch = false;
              });
              if (_navigating) {
                // Snap back to navigation tilt view.
                _cameraFollowEnabled = true;
                _controller?.animateCamera(
                  CameraUpdate.newCameraPosition(
                    CameraPosition(
                      target: _lookAheadTarget(metersAhead: 60),
                      zoom: 18.5,
                      tilt: 60,
                      bearing: _currentBearing,
                    ),
                  ),
                );
              } else if (_activeRoutePoints.isNotEmpty) {
                // Route preview: fit route back in view.
                _fitRouteBounds(_boundsFromPoints(_activeRoutePoints));
              }
            },
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Icon(Icons.close_rounded, color: subtitleColor, size: 18),
            ),
          ),
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
            myLocationEnabled: _locationAllowed && !_navigating,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            mapToolbarEnabled: false,
            compassEnabled: false,
            polylines: _routePolylines,
            markers: {
              if (_currentMarker != null && !_navigating) _currentMarker!,
              if (_navigating && _navArrowMarker != null) _navArrowMarker!,
              ..._poiMarkers,
            },
            onMapCreated: (controller) {
              _controller = controller;
              if (!_mapController.isCompleted) {
                _mapController.complete(controller);
              }
            },
            onCameraMove: (position) {
              _lastCameraPosition = position;
              _cameraBearing.value = position.bearing;
            },
          ),

          // ── Loading overlay ──────────────────────────────────────────
          if (_loadingLocation || _searching || _routing)
            Container(
              color: Colors.black.withOpacity(0.22),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.fromLTRB(28, 16, 28, 22),
                  decoration: BoxDecoration(
                    color: panelBg,
                    borderRadius: BorderRadius.circular(24),
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
                      if (_lottieComposition != null)
                        lottie.Lottie(
                          composition: _lottieComposition!,
                          width: 120,
                          height: 120,
                          fit: BoxFit.contain,
                          repeat: true,
                        )
                      else
                        lottie.Lottie.asset(
                          'assets/animations/AI Assistant.json',
                          width: 120,
                          height: 120,
                          fit: BoxFit.contain,
                          repeat: true,
                        ),
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Navigation instruction card — full width, no side padding
                  if (_navigating && currentStep != null)
                    _NavInstructionCard(
                      instruction: currentStep.instruction,
                      distanceMeters: currentStep.distanceMeters,
                      destinationName: _selectedPlace != null
                          ? _placeLabel(_selectedPlace!)
                          : null,
                    ),

                  // Search bar + chips — only when not navigating
                  if (!_navigating)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
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
                                    color: isDark
                                        ? Colors.white60
                                        : Colors.black45,
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
                                        padding:
                                            const EdgeInsets.only(right: 6),
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
                                        borderRadius:
                                            BorderRadius.circular(10),
                                      ),
                                      child: const Icon(
                                          Icons.arrow_forward_rounded,
                                          color: Colors.white,
                                          size: 18),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
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
                        ],
                      ),
                    ),

                  // Error banner
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                      child: GestureDetector(
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
                    ),
                ],
              ),
            ),
          ),

          // ── Right FABs — animate up when bottom panel appears ────────
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            right: 12,
            bottom: _navigating ? 150 : (hasBottomPanel ? 290 : 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_navigating) ...[
                  // Rotating compass — north arrow always points to true north
                  ValueListenableBuilder<double>(
                    valueListenable: _cameraBearing,
                    builder: (_, bearing, __) => _CompassButton(
                      isDark: isDark,
                      bearing: bearing,
                      onTap: _resetNorthUp,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _MapActionButton(
                    isDark: isDark,
                    icon: Icons.search_rounded,
                    onTap: _showRouteSearchDialog,
                  ),
                ] else
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
    required this.instruction,
    this.distanceMeters,
    this.destinationName,
  });

  final String instruction;
  final int? distanceMeters;
  final String? destinationName;

  IconData _iconFor(String text) {
    final t = text.toLowerCase();
    if (t.contains('u-turn') || t.contains('uturn')) {
      return Icons.u_turn_left_rounded;
    }
    if (t.contains('sharp left')) return Icons.turn_sharp_left_rounded;
    if (t.contains('sharp right')) return Icons.turn_sharp_right_rounded;
    if (t.contains('slight left')) return Icons.turn_slight_left_rounded;
    if (t.contains('slight right')) return Icons.turn_slight_right_rounded;
    if (t.contains('left')) return Icons.turn_left_rounded;
    if (t.contains('right')) return Icons.turn_right_rounded;
    return Icons.straight_rounded;
  }

  String _distanceLabel(int meters) {
    final miles = meters / 1609.344;
    if (miles < 0.1) return 'in $meters m';
    return 'in ${miles.toStringAsFixed(1)} mi';
  }

  @override
  Widget build(BuildContext context) {
    final text = instruction.trim().isEmpty ? 'Continue straight' : instruction;
    final distLabel =
        distanceMeters != null ? _distanceLabel(distanceMeters!) : null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 14, 14, 18),
      decoration: const BoxDecoration(
        color: Color(0xFF0B7D77),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            blurRadius: 18,
            offset: Offset(0, 8),
            color: Color(0x44000000),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(_iconFor(text), color: Colors.white, size: 36),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  text,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (distLabel != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    distLabel,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                if (destinationName != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    'To: $destinationName',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
            ),
            child: const Icon(
              Icons.mic_none_rounded,
              color: Color(0xFF0B7D77),
              size: 22,
            ),
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

// ── Rotating compass FAB ───────────────────────────────────────────────────────

class _CompassButton extends StatelessWidget {
  const _CompassButton({
    required this.isDark,
    required this.bearing,
    required this.onTap,
  });

  final bool isDark;
  final double bearing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = isDark ? const Color(0xF01C1C1C) : Colors.white;
    return Material(
      color: bg,
      elevation: isDark ? 0 : 6,
      shadowColor: const Color(0x33000000),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 50,
          height: 50,
          child: Center(
            // Counter-rotate by the camera bearing so the N arrow always
            // points to true north regardless of map orientation.
            child: Transform.rotate(
              angle: -bearing * math.pi / 180.0,
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.navigation_rounded,
                      color: Colors.red, size: 18),
                  Text(
                    'N',
                    style: TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.w900,
                      color: Colors.red,
                      height: 1,
                    ),
                  ),
                ],
              ),
            ),
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

    return Material(
      color: bg,
      elevation: isDark ? 0 : 6,
      shadowColor: const Color(0x33000000),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 50,
          height: 50,
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

// ── Route search bottom sheet ──────────────────────────────────────────────────

class _RouteSearchSheet extends StatefulWidget {
  const _RouteSearchSheet({
    required this.isDark,
    required this.onSearch,
  });

  final bool isDark;
  final void Function(String query) onSearch;

  @override
  State<_RouteSearchSheet> createState() => _RouteSearchSheetState();
}

class _RouteSearchSheetState extends State<_RouteSearchSheet> {
  final _ctrl = TextEditingController();

  static const List<({String label, IconData icon})> _categories = [
    (label: 'Truck Stop', icon: Icons.local_shipping_outlined),
    (label: 'Gas Station', icon: Icons.local_gas_station_outlined),
    (label: 'Food', icon: Icons.restaurant_outlined),
    (label: 'Rest Area', icon: Icons.king_bed_outlined),
    (label: 'Repairs', icon: Icons.build_outlined),
    (label: 'Parking', icon: Icons.local_parking_outlined),
  ];

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final q = _ctrl.text.trim();
    if (q.isNotEmpty) widget.onSearch(q);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final bg = isDark ? const Color(0xFF1C1C1C) : Colors.white;
    final borderColor =
        isDark ? const Color(0xFF2D2D2D) : const Color(0xFFE8E8E8);
    final titleColor = isDark ? Colors.white : Colors.black87;
    final subtitleColor = isDark ? Colors.white60 : Colors.black54;
    final keyboardPad = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: keyboardPad),
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: borderColor),
          boxShadow: [
            BoxShadow(
              blurRadius: 36,
              offset: const Offset(0, -8),
              color: Colors.black.withOpacity(isDark ? 0.50 : 0.13),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark ? Colors.white24 : Colors.black26,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),

            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0B7D77).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.route_rounded,
                      color: Color(0xFF0B7D77),
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Search Along Route',
                        style: TextStyle(
                          color: titleColor,
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Text(
                        'Find places on your way',
                        style: TextStyle(
                          color: subtitleColor,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Search field
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Container(
                height: 54,
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF2A2A2A)
                      : const Color(0xFFF5F5F5),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: borderColor),
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 16),
                    Icon(Icons.search_rounded, color: subtitleColor, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _ctrl,
                        autofocus: true,
                        style: TextStyle(
                          color: titleColor,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                        decoration: InputDecoration(
                          hintText: 'e.g. truck stop, gas station...',
                          hintStyle: TextStyle(
                            color: isDark ? Colors.white30 : Colors.black38,
                            fontSize: 15,
                            fontWeight: FontWeight.w400,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                        ),
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _submit(),
                      ),
                    ),
                    GestureDetector(
                      onTap: _submit,
                      child: Container(
                        margin: const EdgeInsets.only(right: 8),
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: const Color(0xFF0B7D77),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.arrow_forward_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Quick category label
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Quick search',
                  style: TextStyle(
                    color: subtitleColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ),

            // Category chips
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _categories
                    .map(
                      (cat) => GestureDetector(
                        onTap: () => widget.onSearch(cat.label),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF2A2A2A)
                                : const Color(0xFFF0F0F0),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: borderColor),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(cat.icon,
                                  size: 16, color: const Color(0xFF0B7D77)),
                              const SizedBox(width: 7),
                              Text(
                                cat.label,
                                style: TextStyle(
                                  color: titleColor,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
