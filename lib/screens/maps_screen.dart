import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../services/app_settings.dart';
import '../services/google_places_routes_client.dart';

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

  LatLng _currentCenter = const LatLng(29.7604, -95.3698);
  Marker? _currentMarker;
  final Set<Marker> _poiMarkers = {};
  final Set<Polyline> _routePolylines = {};

  List<PlaceSearchResult> _results = [];
  String _activeLabel = '';
  bool _sheetExpanded = false;

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

  /// Voice action: start navigation to a destination.
  /// - If [destinationQuery] is empty and a place is already selected, start the route.
  /// - Otherwise search for the query, pick the first result, compute the route, then start.
  Future<void> runAssistantNavigate(String destinationQuery) async {
    final q = destinationQuery.trim();
    if (q.isEmpty) {
      if (_selectedPlace != null) {
        _startRoute();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pick a destination first.')),
        );
      }
      return;
    }

    _searchCtrl.text = q;
    await _runTextSearch(q);

    if (!mounted) return;
    if (_results.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No results for $q')),
      );
      return;
    }

    final first = _results.first;
    await _selectPlace(first);
    if (!mounted) return;
    _startRoute();
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
      _sheetExpanded = true;
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
      _sheetExpanded = true;
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

  Future<void> _selectPlace(PlaceSearchResult place) async {
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
        _navigating = false;
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

  void _startRoute() {
    if (_selectedPlace == null) return;

    setState(() {
      _navigating = true;
      _sheetExpanded = false;
    });

    final destination = LatLng(
      _selectedPlace!.latitude!,
      _selectedPlace!.longitude!,
    );

    _goToLocation(destination, zoom: 14.8);

    final placeName =
        _selectedPlace!.name.isEmpty ? 'destination' : _selectedPlace!.name;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Navigation started to $placeName'),
      ),
    );
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
  }

  String _etaLabel(int minutes) {
    if (minutes < 60) {
      return '$minutes min';
    }
    final hours = minutes ~/ 60;
    final mins = minutes % 60;
    if (mins == 0) return '$hours hr';
    return '$hours hr $mins min';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final isDark = Theme.of(context).brightness == Brightness.dark;

    final panelBg = isDark
        ? const Color(0xE61A1A1A)
        : Colors.white.withOpacity(0.96);
    final borderColor =
        isDark ? const Color(0xFF2D2D2D) : const Color(0xFFEAEAEA);
    final titleColor = isDark ? Colors.white : Colors.black87;
    final subtitleColor = isDark ? Colors.white70 : Colors.black54;
    final hintColor = isDark ? Colors.white54 : Colors.black54;
    final iconColor = isDark ? Colors.white : Colors.black87;

    final currentStep =
        _navSteps.isNotEmpty ? _navSteps[_currentStepIndex] : null;

    return Scaffold(
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: _currentCenter,
              zoom: 12,
            ),
            mapType: _mapType,
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
          if (_loadingLocation || _searching || _routing)
            Container(
              color: Colors.black.withOpacity(0.18),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 12),
                    Text(
                      _loadingLocation
                          ? 'Getting location...'
                          : _searching
                              ? 'Searching...'
                              : 'Routing...',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                children: [
                  if (_navigating && currentStep != null) ...[
                    Material(
                      elevation: isDark ? 0 : 8,
                      borderRadius: BorderRadius.circular(20),
                      color: panelBg,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: borderColor),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: Colors.black,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: const Icon(
                                Icons.turn_right,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    currentStep.instruction,
                                    style: TextStyle(
                                      color: titleColor,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${_metersToMiles(currentStep.distanceMeters).toStringAsFixed(1)} mi',
                                    style: TextStyle(
                                      color: subtitleColor,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              onPressed: _nextStep,
                              icon: Icon(
                                Icons.arrow_forward,
                                color: iconColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  Material(
                    elevation: isDark ? 0 : 8,
                    borderRadius: BorderRadius.circular(18),
                    color: panelBg,
                    child: Container(
                      height: 58,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: borderColor),
                      ),
                      child: Row(
                        children: [
                          const SizedBox(width: 12),
                          Icon(Icons.search, color: iconColor),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _searchCtrl,
                              style: TextStyle(
                                color: titleColor,
                                fontSize: 16,
                              ),
                              decoration: InputDecoration(
                                hintText: 'Search places...',
                                hintStyle: TextStyle(
                                  color: hintColor,
                                  fontSize: 16,
                                ),
                                border: InputBorder.none,
                              ),
                              onSubmitted: (_) => _runSearch(),
                            ),
                          ),
                          IconButton(
                            onPressed: _runSearch,
                            icon: Icon(Icons.arrow_forward, color: iconColor),
                          ),
                          const SizedBox(width: 4),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 42,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _quickCategories.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final item = _quickCategories[index];
                        return _CategoryChip(
                          label: item.label,
                          icon: item.icon,
                          onTap: () => _runNearbySearch(item.label),
                        );
                      },
                    ),
                  ),
                  const Spacer(),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _MapActionButton(
                          isDark: isDark,
                          icon: Icons.my_location,
                          onTap: () async {
                            await _refreshCurrentLocation(moveCamera: true);
                          },
                        ),
                        const SizedBox(height: 10),
                        _MapActionButton(
                          isDark: isDark,
                          icon: Icons.layers_outlined,
                          onTap: _toggleMapType,
                        ),
                      ],
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Material(
                      elevation: isDark ? 0 : 6,
                      borderRadius: BorderRadius.circular(16),
                      color: panelBg,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: borderColor),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
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
                          child: Text(
                            _error!,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isDark
                                  ? Colors.red.shade300
                                  : Colors.red.shade700,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (_selectedPlace != null &&
                      _routeMiles != null &&
                      _routeMinutes != null) ...[
                    const SizedBox(height: 12),
                    Material(
                      elevation: isDark ? 0 : 8,
                      borderRadius: BorderRadius.circular(20),
                      color: panelBg,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: borderColor),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _selectedPlace!.name.isEmpty
                                  ? 'Destination'
                                  : _selectedPlace!.name,
                              style: TextStyle(
                                color: titleColor,
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _selectedPlace!.address,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: subtitleColor,
                                fontSize: 12,
                                height: 1.3,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                _RouteStatChip(
                                  label:
                                      '${(_navigating ? (_remainingMiles ?? _routeMiles!) : _routeMiles!).toStringAsFixed(1)} mi',
                                  isDark: isDark,
                                ),
                                const SizedBox(width: 8),
                                _RouteStatChip(
                                  label: _etaLabel(
                                    _navigating
                                        ? (_remainingMinutes ?? _routeMinutes!)
                                        : _routeMinutes!,
                                  ),
                                  isDark: isDark,
                                ),
                                const SizedBox(width: 8),
                                _RouteStatChip(
                                  label: _navigating ? 'On Route' : _mapTypeLabel(),
                                  isDark: isDark,
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: titleColor,
                                      side: BorderSide(color: borderColor),
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 14,
                                      ),
                                    ),
                                    onPressed: _clearRoute,
                                    child: const Text('Clear'),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: FilledButton(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: Colors.black,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 14,
                                      ),
                                    ),
                                    onPressed: _navigating ? _nextStep : _startRoute,
                                    child: Text(
                                      _navigating ? 'Next Step' : 'Start',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (_results.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            _sheetExpanded = !_sheetExpanded;
                          });
                        },
                        child: Material(
                          elevation: isDark ? 0 : 6,
                          borderRadius: BorderRadius.circular(14),
                          color: panelBg,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: borderColor),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _activeLabel.isEmpty ? 'Results' : _activeLabel,
                                  style: TextStyle(
                                    color: titleColor,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '${_results.length}',
                                  style: TextStyle(
                                    color: subtitleColor,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Icon(
                                  _sheetExpanded
                                      ? Icons.expand_more
                                      : Icons.expand_less,
                                  color: subtitleColor,
                                  size: 18,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (_sheetExpanded)
                      Material(
                        elevation: isDark ? 0 : 8,
                        borderRadius: BorderRadius.circular(18),
                        color: panelBg,
                        child: Container(
                          width: double.infinity,
                          constraints: BoxConstraints(
                            maxHeight: _selectedPlace != null ? 140 : 240,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: borderColor),
                          ),
                          child: ListView.separated(
                            padding: const EdgeInsets.all(10),
                            itemCount: _results.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
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
                      ),
                  ],
                  SizedBox(height: _selectedPlace != null ? 100 : 90),
                ],
              ),
            ),
          ),
          if (_navigating && _selectedPlace != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 86,
              child: _BottomNavStatusCard(
                isDark: Theme.of(context).brightness == Brightness.dark,
                placeName: _selectedPlace!.name.isEmpty
                    ? 'Destination'
                    : _selectedPlace!.name,
                etaLabel: _etaLabel(_remainingMinutes ?? _routeMinutes ?? 1),
                milesLabel:
                    '${(_remainingMiles ?? _routeMiles ?? 0).toStringAsFixed(1)} mi left',
              ),
            ),
        ],
      ),
    );
  }
}

class _QuickMapCategory {
  final String label;
  final IconData icon;

  const _QuickMapCategory(this.label, this.icon);
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Material(
      color: isDark
          ? const Color(0xE61A1A1A)
          : Colors.white.withOpacity(0.96),
      elevation: isDark ? 0 : 5,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: isDark
                  ? const Color(0xFF2D2D2D)
                  : const Color(0xFFEAEAEA),
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 16,
                color: isDark ? Colors.white : Colors.black87,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: isDark ? Colors.white : Colors.black87,
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
    return Material(
      color: isDark
          ? const Color(0xE61A1A1A)
          : Colors.white.withOpacity(0.96),
      elevation: isDark ? 0 : 6,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark
                  ? const Color(0xFF2D2D2D)
                  : const Color(0xFFEAEAEA),
            ),
          ),
          child: Icon(
            icon,
            color: isDark ? Colors.white : Colors.black87,
          ),
        ),
      ),
    );
  }
}

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
    final tileBg = isDark ? const Color(0xFF1A1A1A) : const Color(0xFFF7F7F7);
    final border = isDark ? const Color(0xFF2D2D2D) : const Color(0xFFEAEAEA);
    final titleColor = isDark ? Colors.white : Colors.black87;
    final subtitleColor = isDark ? Colors.white70 : Colors.black54;

    final ratingText = place.rating == null
        ? ''
        : place.userRatingCount == null
            ? '${place.rating!.toStringAsFixed(1)}★'
            : '${place.rating!.toStringAsFixed(1)}★ (${place.userRatingCount})';

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
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.place_outlined, color: Colors.white),
            ),
            const SizedBox(width: 10),
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
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    place.address,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: subtitleColor,
                      fontSize: 12,
                      height: 1.3,
                    ),
                  ),
                  if (ratingText.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      ratingText,
                      style: TextStyle(
                        color: subtitleColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right,
              color: subtitleColor,
            ),
          ],
        ),
      ),
    );
  }
}

class _RouteStatChip extends StatelessWidget {
  const _RouteStatChip({
    required this.label,
    required this.isDark,
  });

  final String label;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF222222) : const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: isDark ? const Color(0xFF2D2D2D) : const Color(0xFFEAEAEA),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: isDark ? Colors.white : Colors.black87,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _BottomNavStatusCard extends StatelessWidget {
  const _BottomNavStatusCard({
    required this.isDark,
    required this.placeName,
    required this.etaLabel,
    required this.milesLabel,
  });

  final bool isDark;
  final String placeName;
  final String etaLabel;
  final String milesLabel;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: isDark ? 0 : 10,
      borderRadius: BorderRadius.circular(18),
      color: isDark ? const Color(0xEE1A1A1A) : Colors.white.withOpacity(0.97),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isDark ? const Color(0xFF2D2D2D) : const Color(0xFFEAEAEA),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.navigation_outlined,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    placeName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isDark ? Colors.white : Colors.black87,
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '$milesLabel • ETA $etaLabel',
                    style: TextStyle(
                      color: isDark ? Colors.white70 : Colors.black54,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}