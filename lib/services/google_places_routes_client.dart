import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

class PlaceSearchResult {
  final String id;
  final String name;
  final String address;
  final double? latitude;
  final double? longitude;
  final double? rating;
  final int? userRatingCount;

  const PlaceSearchResult({
    required this.id,
    required this.name,
    required this.address,
    required this.latitude,
    required this.longitude,
    required this.rating,
    required this.userRatingCount,
  });
}

class RouteStepResult {
  final String instruction;
  final int distanceMeters;
  final int durationSeconds;

  const RouteStepResult({
    required this.instruction,
    required this.distanceMeters,
    required this.durationSeconds,
  });
}

class RouteResult {
  final int distanceMeters;
  final int durationSeconds;
  final String encodedPolyline;
  final List<RouteStepResult> steps;

  const RouteResult({
    required this.distanceMeters,
    required this.durationSeconds,
    required this.encodedPolyline,
    required this.steps,
  });
}

class GooglePlacesRoutesClient {
  GooglePlacesRoutesClient();

  static String? get _googleApiKey {
    final k = dotenv.env['GOOGLE_PLACES_API_KEY']?.trim();
    return (k == null || k.isEmpty) ? null : k;
  }

  static Never _missingKey() {
    throw Exception(
      'Missing `GOOGLE_PLACES_API_KEY` in .env. '
      'Add it, restart the app, and try again.',
    );
  }

  static String _prettyGoogleHttpError({
    required String prefix,
    required int statusCode,
    required String body,
  }) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is Map) {
        final err = Map<String, dynamic>.from(decoded['error'] as Map);
        final message = (err['message'] ?? '').toString().trim();
        final status = (err['status'] ?? '').toString().trim();
        String? reason;
        final details = err['details'];
        if (details is List) {
          for (final d in details) {
            if (d is Map && d['reason'] is String) {
              reason = d['reason'] as String;
              break;
            }
            if (d is Map && d['metadata'] is Map) {
              final md = Map<String, dynamic>.from(d['metadata'] as Map);
              if (md['reason'] is String) {
                reason = md['reason'] as String;
                break;
              }
            }
          }
        }

        if (reason == 'API_KEY_ANDROID_APP_BLOCKED') {
          return '$prefix blocked by API key restrictions. '
              'Your `GOOGLE_PLACES_API_KEY` is restricted to Android app/SDK usage. '
              'For direct REST calls (Places/Routes), use a key with Application restrictions = None '
              '(API restrictions can still be limited to Places API + Routes API).';
        }

        final msg = message.isNotEmpty ? message : body;
        final extra = [
          if (status.isNotEmpty) status,
          if (reason != null && reason.isNotEmpty) reason,
        ].join(' / ');
        return '$prefix failed: HTTP $statusCode ${extra.isEmpty ? '' : '($extra) '}'
            '${msg.length > 220 ? msg.substring(0, 220) : msg}';
      }
    } catch (_) {}

    return '$prefix failed: HTTP $statusCode ${body.length > 220 ? body.substring(0, 220) : body}';
  }

  static double? _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse((v ?? '').toString());
  }

  static int? _toInt(dynamic v) {
    if (v is num) return v.toInt();
    return int.tryParse((v ?? '').toString());
  }

  static int _parseDurationToSeconds(dynamic value) {
    final text = (value ?? '').toString().trim();
    if (!text.endsWith('s')) return 0;
    return (double.tryParse(text.substring(0, text.length - 1)) ?? 0).round();
  }

  PlaceSearchResult _normalizePlace(Map<String, dynamic> place) {
    final loc = (place['location'] as Map?) ??
        (place['geometry'] as Map?)?['location'] as Map?;

    return PlaceSearchResult(
      id: (place['id'] ?? place['placeId'] ?? place['name'] ?? '').toString(),
      name: ((place['displayName'] as Map?)?['text'] ?? place['name'] ?? '')
          .toString(),
      address:
          (place['formattedAddress'] ?? place['vicinity'] ?? '').toString(),
      latitude: _toDouble(loc?['latitude'] ?? loc?['lat']),
      longitude: _toDouble(loc?['longitude'] ?? loc?['lng']),
      rating: _toDouble(place['rating']),
      userRatingCount: _toInt(place['userRatingCount']),
    );
  }

  Future<List<PlaceSearchResult>> searchText({
    required String query,
    double? latitude,
    double? longitude,
    int maxResults = 8,
  }) async {
    final key = _googleApiKey ?? _missingKey();

    final body = <String, dynamic>{
      'textQuery': query.trim(),
      'maxResultCount': maxResults.clamp(1, 10),
    };

    if (latitude != null && longitude != null) {
      body['locationBias'] = {
        'circle': {
          'center': {'latitude': latitude, 'longitude': longitude},
          'radius': 50000.0,
        },
      };
    }

    final resp = await http.post(
      Uri.parse('https://places.googleapis.com/v1/places:searchText'),
      headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': key,
        'X-Goog-FieldMask':
            'places.id,places.displayName,places.formattedAddress,places.location,places.rating,places.userRatingCount',
      },
      body: jsonEncode(body),
    );

    final text = resp.body;
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception(
        _prettyGoogleHttpError(
          prefix: 'Google Places search',
          statusCode: resp.statusCode,
          body: text,
        ),
      );
    }

    final data = jsonDecode(text);
    final raw =
        (data is Map) ? (data['places'] as List? ?? const []) : const [];
    return raw
        .whereType<Map>()
        .map((e) => _normalizePlace(Map<String, dynamic>.from(e)))
        .toList();
  }

  static String _mapNearbyCategory(String category) {
    final lower = category.trim().toLowerCase();
    if (lower.contains('truck')) return 'truck stop';
    if (lower.contains('fuel')) return 'gas station';
    if (lower.contains('food')) return 'restaurant';
    if (lower.contains('parking')) return 'truck parking';
    if (lower.contains('repair')) return 'truck repair';
    return category.trim();
  }

  Future<List<PlaceSearchResult>> searchNearby({
    required String category,
    required double latitude,
    required double longitude,
    int maxResults = 8,
  }) async {
    final key = _googleApiKey ?? _missingKey();
    final mapped = _mapNearbyCategory(category);

    final resp = await http.post(
      Uri.parse('https://places.googleapis.com/v1/places:searchText'),
      headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': key,
        'X-Goog-FieldMask':
            'places.id,places.displayName,places.formattedAddress,places.location,places.rating,places.userRatingCount',
      },
      body: jsonEncode({
        'textQuery': mapped,
        'maxResultCount': maxResults.clamp(1, 10),
        'locationBias': {
          'circle': {
            'center': {'latitude': latitude, 'longitude': longitude},
            'radius': 30000.0,
          },
        },
      }),
    );

    final text = resp.body;
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception(
        _prettyGoogleHttpError(
          prefix: 'Google Places nearby',
          statusCode: resp.statusCode,
          body: text,
        ),
      );
    }

    final data = jsonDecode(text);
    final raw =
        (data is Map) ? (data['places'] as List? ?? const []) : const [];
    return raw
        .whereType<Map>()
        .map((e) => _normalizePlace(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<RouteResult> computeRoute({
    required double originLatitude,
    required double originLongitude,
    required double destinationLatitude,
    required double destinationLongitude,
    bool avoidTolls = false,
    bool avoidHighways = false,
  }) async {
    final key = _googleApiKey ?? _missingKey();

    final resp = await http.post(
      Uri.parse('https://routes.googleapis.com/directions/v2:computeRoutes'),
      headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': key,
        'X-Goog-FieldMask':
            'routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline,routes.legs.steps.navigationInstruction,routes.legs.steps.staticDuration,routes.legs.steps.distanceMeters',
      },
      body: jsonEncode({
        'origin': {
          'location': {
            'latLng': {
              'latitude': originLatitude,
              'longitude': originLongitude
            },
          },
        },
        'destination': {
          'location': {
            'latLng': {
              'latitude': destinationLatitude,
              'longitude': destinationLongitude,
            },
          },
        },
        'travelMode': 'DRIVE',
        'routingPreference': 'TRAFFIC_AWARE',
        'computeAlternativeRoutes': false,
        'languageCode': 'en-US',
        'units': 'IMPERIAL',
        'polylineQuality': 'HIGH_QUALITY',
        if (avoidTolls || avoidHighways)
          'routeModifiers': {
            if (avoidTolls) 'avoidTolls': true,
            if (avoidHighways) 'avoidHighways': true,
          },
      }),
    );

    final text = resp.body;
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception(
        _prettyGoogleHttpError(
          prefix: 'Google Routes',
          statusCode: resp.statusCode,
          body: text,
        ),
      );
    }

    final data = jsonDecode(text);
    final routes =
        (data is Map) ? (data['routes'] as List? ?? const []) : const [];
    final route = routes.isNotEmpty && routes.first is Map
        ? Map<String, dynamic>.from(routes.first as Map)
        : null;
    if (route == null) {
      throw Exception('No route returned from Google Routes API');
    }

    final distanceMeters = _toInt(route['distanceMeters']) ?? 0;
    final durationSeconds = _parseDurationToSeconds(route['duration']);
    final encodedPolyline =
        ((route['polyline'] as Map?)?['encodedPolyline'] ?? '').toString();

    final legs = route['legs'] as List?;
    final firstLeg = (legs != null && legs.isNotEmpty && legs.first is Map)
        ? Map<String, dynamic>.from(legs.first as Map)
        : null;
    final rawSteps = (firstLeg?['steps'] as List? ?? const []);

    final steps = rawSteps.whereType<Map>().map((raw) {
      final step = Map<String, dynamic>.from(raw);
      return RouteStepResult(
        instruction:
            (((step['navigationInstruction'] as Map?)?['instructions']) ??
                    'Continue')
                .toString(),
        distanceMeters: _toInt(step['distanceMeters']) ?? 0,
        durationSeconds: _parseDurationToSeconds(step['staticDuration']),
      );
    }).toList();

    return RouteResult(
      distanceMeters: distanceMeters,
      durationSeconds: durationSeconds,
      encodedPolyline: encodedPolyline,
      steps: steps,
    );
  }
}
