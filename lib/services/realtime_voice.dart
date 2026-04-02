import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

class RealtimeVoiceResult {
  final String text;
  final String? transcript;
  final Uint8List? audioBytes;
  /// Audio format for [audioBytes] returned by `/voice` (e.g. `mp3`, `pcm16`).
  /// `/chat` typically returns `mp3` when TTS is enabled but may omit this field.
  final String? audioFormat;
  /// Sample rate for raw PCM16 in [audioBytes] when [audioFormat] is `pcm16` (e.g. 24000 from Realtime).
  final int? pcmSampleRate;
  /// Server `/chat` or `/voice` intent (e.g. `{ type: 'map_search', query: '...' }`).
  final Map<String, dynamic>? intent;

  RealtimeVoiceResult({
    required this.text,
    this.transcript,
    this.audioBytes,
    this.audioFormat,
    this.pcmSampleRate,
    this.intent,
  });
}

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

  factory PlaceSearchResult.fromJson(Map<String, dynamic> json) {
    return PlaceSearchResult(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      address: (json['address'] ?? '').toString(),
      latitude: _toDouble(json['latitude']),
      longitude: _toDouble(json['longitude']),
      rating: _toDouble(json['rating']),
      userRatingCount: _toInt(json['userRatingCount']),
    );
  }

  static double? _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse((value ?? '').toString());
  }

  static int? _toInt(dynamic value) {
    if (value is num) return value.toInt();
    return int.tryParse((value ?? '').toString());
  }
}

class PlaceSearchResponse {
  final List<PlaceSearchResult> places;

  const PlaceSearchResponse({
    required this.places,
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

  factory RouteStepResult.fromJson(Map<String, dynamic> json) {
    return RouteStepResult(
      instruction: (json['instruction'] ?? 'Continue').toString(),
      distanceMeters: _toInt(json['distanceMeters']) ?? 0,
      durationSeconds: _toInt(json['durationSeconds']) ?? 0,
    );
  }

  static int? _toInt(dynamic value) {
    if (value is num) return value.toInt();
    return int.tryParse((value ?? '').toString());
  }
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

  factory RouteResult.fromJson(Map<String, dynamic> json) {
    final rawSteps = (json['steps'] as List<dynamic>? ?? []);
    return RouteResult(
      distanceMeters: (json['distanceMeters'] as num?)?.toInt() ?? 0,
      durationSeconds: (json['durationSeconds'] as num?)?.toInt() ?? 0,
      encodedPolyline: (json['encodedPolyline'] ?? '').toString(),
      steps: rawSteps
          .whereType<Map>()
          .map((e) => RouteStepResult.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }
}

class RealtimeVoiceClient {
  final String baseUrl;

  final _textController = StreamController<String>.broadcast();
  Stream<String> get textStream => _textController.stream;

  RealtimeVoiceClient({required this.baseUrl});

  void dispose() {
    _textController.close();
  }

  Future<RealtimeVoiceResult> sendText({
    required String message,
    String? voice,
    bool tts = true,
  }) async {
    final uri = Uri.parse('$baseUrl/chat');

    final resp = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'message': message,
        'tts': tts,
        if (voice != null && voice.trim().isNotEmpty) 'voice': voice.trim(),
      }),
    );

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    }

    final data = _safeJson(resp.body);
    final text = (data['text'] ?? data['message'] ?? '').toString().trim();

    if (text.isNotEmpty) {
      _textController.add(text);
    }

    Uint8List? audioBytes;
    final audioB64 = data['audioBase64'];
    if (audioB64 is String && audioB64.isNotEmpty) {
      audioBytes = base64Decode(audioB64);
    }

    return RealtimeVoiceResult(
      text: text.isEmpty ? 'OK' : text,
      audioBytes: audioBytes,
      audioFormat: null,
      pcmSampleRate: null,
      intent: _intentFromJson(data['intent']),
    );
  }

  /// POST /chat with `stream: true`. Parses SSE (`event` + `data` lines, blank-line separated).
  /// [onTextUpdate] receives the full assistant text accumulated so far on each `delta` event.
  /// If the backend includes `audioBase64` in the final `done` event (generated after streaming),
  /// this method will decode it into [RealtimeVoiceResult.audioBytes].
  Future<RealtimeVoiceResult> sendTextStream({
    required String message,
    String? voice,
    bool tts = true,
    required void Function(String accumulatedText) onTextUpdate,
  }) async {
    final uri = Uri.parse('$baseUrl/chat');
    final client = http.Client();
    try {
      final request = http.Request('POST', uri);
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.body = jsonEncode({
        'message': message,
        'stream': true,
        'tts': tts,
        if (voice != null && voice.trim().isNotEmpty) 'voice': voice.trim(),
      });

      final streamed = await client.send(request);
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        final errBody = await streamed.stream.bytesToString();
        throw Exception('HTTP ${streamed.statusCode}: $errBody');
      }

      var carry = '';
      final acc = StringBuffer();
      Map<String, dynamic>? metaIntent;
      Uint8List? audioBytes;
      String? audioFormat;
      int? pcmSampleRate;

      await for (final chunk in streamed.stream.transform(utf8.decoder)) {
        carry += chunk;
        while (true) {
          final sep = carry.indexOf('\n\n');
          if (sep < 0) break;
          final block = carry.substring(0, sep);
          carry = carry.substring(sep + 2);
          final parsed = _parseSseEventBlock(block);
          if (parsed == null) continue;
          final eventName = parsed.$1;
          final data = parsed.$2;
          if (eventName == 'error') {
            throw Exception(
              (data['error'] ?? 'Unknown error').toString(),
            );
          }
          if (eventName == 'meta') {
            metaIntent = _intentFromJson(data['intent']);
          }
          if (eventName == 'delta') {
            final d = (data['text'] ?? '').toString();
            if (d.isNotEmpty) {
              acc.write(d);
              final full = acc.toString();
              onTextUpdate(full);
              if (full.isNotEmpty) {
                _textController.add(full);
              }
            }
          }
          if (eventName == 'done') {
            // Optional: backend may include final fields and audio for TTS-after-streaming.
            final af = (data['audioFormat'] ?? '').toString().trim();
            if (af.isNotEmpty) audioFormat = af.toLowerCase();
            pcmSampleRate =
                _parsePcmSampleRate(data['pcmSampleRate']) ?? pcmSampleRate;

            final audioB64 = data['audioBase64'];
            if (audioB64 is String && audioB64.isNotEmpty) {
              audioBytes = base64Decode(audioB64);
            }
          }
        }
      }

      final text = acc.toString().trim();
      return RealtimeVoiceResult(
        text: text.isEmpty ? 'OK' : text,
        audioBytes: audioBytes,
        audioFormat: audioFormat,
        pcmSampleRate: pcmSampleRate,
        intent: metaIntent,
      );
    } finally {
      client.close();
    }
  }

  static Map<String, dynamic>? _intentFromJson(dynamic raw) {
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    return null;
  }

  /// Returns `(eventName, jsonPayload)` from one SSE block (lines ending with blank line).
  static (String, Map<String, dynamic>)? _parseSseEventBlock(String block) {
    String eventName = 'message';
    final dataSb = StringBuffer();
    for (final rawLine in block.split('\n')) {
      final line = rawLine.trimRight();
      if (line.isEmpty) continue;
      if (line.startsWith('event:')) {
        eventName = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        if (dataSb.isNotEmpty) dataSb.write('\n');
        dataSb.write(line.substring(5).trim());
      }
    }
    final raw = dataSb.toString();
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return (eventName, decoded);
      }
    } catch (_) {}
    return null;
  }

  Future<RealtimeVoiceResult> sendAudioBytes({
    required Uint8List bytes,
    required String filename,
    required String contentType,
    bool realtime = false,
    bool tts = true,
    String? voice,
  }) async {
    final uri = Uri.parse('$baseUrl/voice');

    final req = http.MultipartRequest('POST', uri);

    if (voice != null && voice.trim().isNotEmpty) {
      req.fields['voice'] = voice.trim();
    }
    if (realtime) {
      req.fields['realtime'] = 'true';
    }
    if (!tts) {
      req.fields['tts'] = 'false';
    }

    req.files.add(
      http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: filename,
        contentType: _parseMediaType(contentType),
      ),
    );

    final streamed = await req.send();
    final resp = await http.Response.fromStream(streamed);

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    }

    final data = _safeJson(resp.body);

    final transcript = (data['transcript'] ?? '').toString().trim();
    final text = (data['text'] ?? '').toString().trim();
    final audioFormat =
        (data['audioFormat'] ?? '').toString().trim().toLowerCase();
    final pcmSampleRate = _parsePcmSampleRate(data['pcmSampleRate']);

    if (text.isNotEmpty) {
      _textController.add(text);
    }

    Uint8List? audioBytes;
    final audioB64 = data['audioBase64'];
    if (audioB64 is String && audioB64.isNotEmpty) {
      audioBytes = base64Decode(audioB64);
    }

    return RealtimeVoiceResult(
      transcript: transcript.isEmpty ? null : transcript,
      text: text.isEmpty ? 'OK' : text,
      audioBytes: audioBytes,
      audioFormat: audioFormat.isEmpty ? null : audioFormat,
      pcmSampleRate: pcmSampleRate,
      intent: _intentFromJson(data['intent']),
    );
  }

  /// POST `/voice` with `realtime=true` and `stream=true`. Server sends SSE:
  /// `meta`, `user_transcript_delta`, `user_transcript`, `text_delta`, `audio_delta`, `done`, `error`.
  Future<RealtimeVoiceResult> sendAudioBytesStream({
    required Uint8List bytes,
    required String filename,
    required String contentType,
    bool realtime = true,
    bool stream = true,
    bool tts = true,
    String? voice,
    void Function(String delta)? onUserTranscriptDelta,
    void Function(String text)? onUserTranscript,
    void Function(String delta)? onAssistantTextDelta,
    void Function(Uint8List pcmChunk)? onAudioDelta,
  }) async {
    final uri = Uri.parse('$baseUrl/voice');

    final req = http.MultipartRequest('POST', uri);

    if (voice != null && voice.trim().isNotEmpty) {
      req.fields['voice'] = voice.trim();
    }
    if (realtime) {
      req.fields['realtime'] = 'true';
    }
    if (stream) {
      req.fields['stream'] = 'true';
    }
    if (!tts) {
      req.fields['tts'] = 'false';
    }

    req.files.add(
      http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: filename,
        contentType: _parseMediaType(contentType),
      ),
    );

    final client = http.Client();
    try {
      final streamed = await client.send(req);
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        final errBody = await streamed.stream.bytesToString();
        throw Exception('HTTP ${streamed.statusCode}: $errBody');
      }

      var carry = '';
      String transcript = '';
      String text = '';
      Uint8List? audioBytes;
      String? audioFormat;
      int? pcmSampleRate;
      Map<String, dynamic>? intent;
      final audioAccum = BytesBuilder();

      await for (final chunk in streamed.stream.transform(utf8.decoder)) {
        carry += chunk;
        while (true) {
          final sep = carry.indexOf('\n\n');
          if (sep < 0) break;
          final block = carry.substring(0, sep);
          carry = carry.substring(sep + 2);
          final parsed = _parseSseEventBlock(block);
          if (parsed == null) continue;
          final eventName = parsed.$1;
          final data = parsed.$2;

          if (eventName == 'error') {
            throw Exception(
              (data['error'] ?? 'Unknown error').toString(),
            );
          }

          if (eventName == 'meta') {
            final af = (data['audioFormat'] ?? '').toString().trim();
            if (af.isNotEmpty) audioFormat = af.toLowerCase();
            pcmSampleRate = _parsePcmSampleRate(data['pcmSampleRate']) ??
                pcmSampleRate;
          }

          if (eventName == 'user_transcript_delta') {
            final d = (data['text'] ?? '').toString();
            if (d.isNotEmpty) {
              transcript += d;
              onUserTranscriptDelta?.call(d);
            }
          }

          if (eventName == 'user_transcript') {
            final t = (data['text'] ?? '').toString();
            transcript = t;
            onUserTranscript?.call(t);
          }

          if (eventName == 'text_delta') {
            final d = (data['text'] ?? '').toString();
            if (d.isNotEmpty) {
              text += d;
              onAssistantTextDelta?.call(d);
              if (text.isNotEmpty) {
                _textController.add(text);
              }
            }
          }

          if (eventName == 'audio_delta') {
            final b64 = data['pcm16_base64'];
            if (b64 is String && b64.isNotEmpty) {
              final pcm = base64Decode(b64);
              audioAccum.add(pcm);
              onAudioDelta?.call(pcm);
            }
          }

          if (eventName == 'done') {
            transcript = (data['transcript'] ?? transcript).toString().trim();
            text = (data['text'] ?? text).toString().trim();
            intent = _intentFromJson(data['intent']) ?? intent;

            final af = (data['audioFormat'] ?? '').toString().trim();
            if (af.isNotEmpty) audioFormat = af.toLowerCase();
            pcmSampleRate =
                _parsePcmSampleRate(data['pcmSampleRate']) ?? pcmSampleRate;

            final audioB64 = data['audioBase64'];
            if (audioB64 is String && audioB64.isNotEmpty) {
              audioBytes = base64Decode(audioB64);
            } else if (audioAccum.length > 0) {
              audioBytes = audioAccum.takeBytes();
            }
          }
        }
      }

      if (text.isNotEmpty) {
        _textController.add(text);
      }

      return RealtimeVoiceResult(
        transcript: transcript.isEmpty ? null : transcript,
        text: text.isEmpty ? 'OK' : text,
        audioBytes: audioBytes,
        audioFormat: audioFormat,
        pcmSampleRate: pcmSampleRate,
        intent: intent,
      );
    } finally {
      client.close();
    }
  }

  static int? _parsePcmSampleRate(dynamic raw) {
    if (raw is num) return raw.toInt();
    return int.tryParse((raw ?? '').toString());
  }

  Future<PlaceSearchResponse> searchPlacesText({
    required String query,
    required double latitude,
    required double longitude,
    int maxResults = 8,
  }) async {
    final uri = Uri.parse('$baseUrl/places/search');

    final resp = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'query': query,
        'latitude': latitude,
        'longitude': longitude,
        'maxResults': maxResults,
      }),
    );

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    }

    final data = _safeJson(resp.body);
    final rawPlaces = (data['places'] as List<dynamic>? ?? []);

    return PlaceSearchResponse(
      places: rawPlaces
          .whereType<Map>()
          .map((e) => PlaceSearchResult.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }

  Future<PlaceSearchResponse> searchPlacesNearby({
    required String category,
    required double latitude,
    required double longitude,
    int maxResults = 8,
  }) async {
    final uri = Uri.parse('$baseUrl/places/nearby');

    final resp = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'category': category,
        'latitude': latitude,
        'longitude': longitude,
        'maxResults': maxResults,
      }),
    );

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    }

    final data = _safeJson(resp.body);
    final rawPlaces = (data['places'] as List<dynamic>? ?? []);

    return PlaceSearchResponse(
      places: rawPlaces
          .whereType<Map>()
          .map((e) => PlaceSearchResult.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }

  Future<RouteResult> computeRoute({
    required double originLatitude,
    required double originLongitude,
    required double destinationLatitude,
    required double destinationLongitude,
  }) async {
    final uri = Uri.parse('$baseUrl/route');

    final resp = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'originLatitude': originLatitude,
        'originLongitude': originLongitude,
        'destinationLatitude': destinationLatitude,
        'destinationLongitude': destinationLongitude,
      }),
    );

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    }

    final data = _safeJson(resp.body);
    final rawRoute = Map<String, dynamic>.from(
      (data['route'] as Map?) ?? <String, dynamic>{},
    );

    return RouteResult.fromJson(rawRoute);
  }

  Map<String, dynamic> _safeJson(String body) {
    try {
      final v = jsonDecode(body);
      if (v is Map<String, dynamic>) return v;
      return {'raw': v};
    } catch (_) {
      return {'raw': body};
    }
  }

  MediaType? _parseMediaType(String s) {
    final parts = s.split('/');
    if (parts.length != 2) return null;
    return MediaType(parts[0].trim(), parts[1].trim());
  }
}