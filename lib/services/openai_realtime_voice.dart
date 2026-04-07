import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:openai_realtime_dart/openai_realtime_dart.dart';
import 'package:record/record.dart';

import 'logs_command_bus.dart' as logsbus;
import 'map_command_bus.dart' as mapbus;
import 'settings_command_bus.dart' as settingsbus;
import 'weather_command_bus.dart' as weatherbus;

typedef OpenaiVoiceVoidCallback = void Function();
typedef OpenaiVoiceTextCallback = void Function(String text);
typedef OpenaiVoicePcmCallback = void Function(Uint8List chunk);

/// OpenAI Realtime with **server VAD**: stream mic continuously; model responds after you stop speaking.
///
/// Android often stops [AudioRecord] when TTS plays (audio focus). This class configures a
/// voice-communication session and **restarts** the PCM stream whenever it ends while listening.
class OpenaiRealtimeVoiceController {
  OpenaiRealtimeVoiceController();

  RealtimeClient? _client;
  final AudioRecorder _recorder = AudioRecorder();

  StreamSubscription<Uint8List>? _pcmSub;

  VoidCallback? _onInterrupted;
  OpenaiVoiceTextCallback? _onUserText;
  OpenaiVoiceTextCallback? _onAssistantTextDelta;
  OpenaiVoicePcmCallback? _onAssistantPcmDelta;
  VoidCallback? _onAssistantResponseDone;
  VoidCallback? _onUserTurnBoundary;
  VoidCallback? _onAssistantTurnBoundary;

  bool _handlersAttached = false;
  String? _lastUserItemId;
  String? _lastAssistantItemId;

  /// Incremented to cancel an in-flight mic pump when stopping or restarting.
  int _micGeneration = 0;
  bool _micPumpRunning = false;

  /// While true, mic chunks are replaced with silence before [appendInputAudio]
  /// so speaker output is not transcribed as the user (half-duplex guard).
  bool _suppressMicToServer = false;

  /// True while the API is still generating an assistant response (between deltas and [responseDone]).
  /// Avoids calling [cancelResponse] when nothing is active (iOS would log `response_cancel_not_active`).
  bool _responseGenerationActive = false;

  static const _recordConfig = RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: 24000,
    numChannels: 1,
    echoCancel: true,
    noiseSuppress: true,
    audioInterruption: AudioInterruptionMode.none,
  );

  static String? get apiKeyFromEnv =>
      dotenv.env['OPENAI_API_KEY']?.trim().isNotEmpty == true
          ? dotenv.env['OPENAI_API_KEY']!.trim()
          : null;

  static Voice voiceFromSettings(String raw) {
    final s = raw.trim().toLowerCase();
    for (final v in Voice.values) {
      if (v.name == s) return v;
    }
    return Voice.alloy;
  }

  void setSuppressMicToServer(bool suppress) {
    _suppressMicToServer = suppress;
  }

  void setCallbacks({
    OpenaiVoiceVoidCallback? onInterrupted,
    OpenaiVoiceTextCallback? onUserText,
    OpenaiVoiceTextCallback? onAssistantTextDelta,
    OpenaiVoicePcmCallback? onAssistantPcmDelta,
    VoidCallback? onAssistantResponseDone,
    VoidCallback? onUserTurnBoundary,
    VoidCallback? onAssistantTurnBoundary,
  }) {
    _onInterrupted = onInterrupted;
    _onUserText = onUserText;
    _onAssistantTextDelta = onAssistantTextDelta;
    _onAssistantPcmDelta = onAssistantPcmDelta;
    _onAssistantResponseDone = onAssistantResponseDone;
    _onUserTurnBoundary = onUserTurnBoundary;
    _onAssistantTurnBoundary = onAssistantTurnBoundary;
  }

  Future<void> dispose() async {
    _responseGenerationActive = false;
    _suppressMicToServer = false;
    _micGeneration++;
    _micPumpRunning = false;
    await _pcmSub?.cancel();
    _pcmSub = null;
    if (await _recorder.isRecording()) {
      await _recorder.stop();
    }
    await _recorder.dispose();
    await _client?.disconnect();
    _client = null;
    _handlersAttached = false;
    _lastUserItemId = null;
    _lastAssistantItemId = null;
    await _deactivateVoiceAudioSession();
  }

  Future<void> _activateVoiceAudioSession() async {
    if (kIsWeb) return;
    try {
      final session = await AudioSession.instance;
      await session.configure(
        AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.defaultToSpeaker |
                  AVAudioSessionCategoryOptions.allowBluetooth,
          // spokenAudio / assistant: louder, media-like playback than voiceChat +
          // voiceCommunication (which many devices treat as a quiet call stream).
          avAudioSessionMode: AVAudioSessionMode.spokenAudio,
          androidAudioAttributes: const AndroidAudioAttributes(
            contentType: AndroidAudioContentType.speech,
            flags: AndroidAudioFlags.none,
            usage: AndroidAudioUsage.assistant,
          ),
          androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
          androidWillPauseWhenDucked: false,
        ),
      );
      await session.setActive(true);
    } catch (e, st) {
      debugPrint('OpenAI voice audio session: $e\n$st');
    }
  }

  Future<void> _deactivateVoiceAudioSession() async {
    if (kIsWeb) return;
    try {
      final session = await AudioSession.instance;
      await session.setActive(false);
    } catch (_) {}
  }

  Future<bool> _ensureSession({
    required String apiKey,
    required Voice voice,
    required String instructions,
  }) async {
    if (kIsWeb) return false;

    if (_client != null && _client!.isConnected()) {
      await _client!.updateSession(voice: voice, instructions: instructions);
      return true;
    }

    await _client?.disconnect();
    _client = null;
    _handlersAttached = false;
    _lastUserItemId = null;
    _lastAssistantItemId = null;

    final client = RealtimeClient(apiKey: apiKey);
    _client = client;

    await _registerTools(client);

    await client.updateSession(
      modalities: const [Modality.text, Modality.audio],
      instructions: instructions,
      voice: voice,
      inputAudioFormat: AudioFormat.pcm16,
      outputAudioFormat: AudioFormat.pcm16,
      turnDetection: const TurnDetection(
        type: TurnDetectionType.serverVad,
        threshold: 0.5,
        prefixPaddingMs: 300,
        silenceDurationMs: 650,
        createResponse: true,
      ),
      inputAudioTranscription: const InputAudioTranscriptionConfig(
        model: 'whisper-1',
      ),
      temperature: 0.7,
    );

    final ok = await client.connect();
    if (!ok) return false;
    await client.waitForSessionCreated();
    _attachHandlers(client);
    return true;
  }

  Future<void> _registerTools(RealtimeClient client) async {
    await client.addTool(
      const ToolDefinition(
        name: 'open_map_search',
        description:
            'Search the in-app map for a place, address, POI, or truck-related stop (fuel, parking, repairs, food).',
        parameters: {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'Search query for maps',
            },
          },
          'required': ['query'],
        },
      ),
      (Map<String, dynamic> params) async {
        final q = (params['query'] ?? '').toString().trim();
        if (q.isNotEmpty) {
          mapbus.MapCommandBus.instance.search(q);
        }
        return {'ok': true, 'query': q};
      },
    );

    await client.addTool(
      const ToolDefinition(
        name: 'open_settings',
        description: 'Open the app settings screen.',
        parameters: {
          'type': 'object',
          'properties': {},
        },
      ),
      (_) async {
        settingsbus.SettingsCommandBus.instance.open();
        return {'ok': true};
      },
    );

    await client.addTool(
      const ToolDefinition(
        name: 'open_driver_logs',
        description: 'Open the driver logs screen.',
        parameters: {
          'type': 'object',
          'properties': {},
        },
      ),
      (_) async {
        logsbus.LogsCommandBus.instance.open();
        return {'ok': true};
      },
    );

    await client.addTool(
      const ToolDefinition(
        name: 'open_weather',
        description:
            'Open the weather screen. Optionally show a specific city.',
        parameters: {
          'type': 'object',
          'properties': {
            'city': {
              'type': 'string',
              'description': 'City name if the user asked for weather there',
            },
          },
        },
      ),
      (Map<String, dynamic> params) async {
        final city = (params['city'] ?? '').toString().trim();
        if (city.isNotEmpty) {
          weatherbus.WeatherCommandBus.instance.openCity(city);
        } else {
          weatherbus.WeatherCommandBus.instance.open();
        }
        return {'ok': true, 'city': city};
      },
    );

    await client.addTool(
      const ToolDefinition(
        name: 'open_weather_radar',
        description: 'Open the weather radar view.',
        parameters: {
          'type': 'object',
          'properties': {},
        },
      ),
      (_) async {
        weatherbus.WeatherCommandBus.instance.openRadar();
        return {'ok': true};
      },
    );

    await client.addTool(
      const ToolDefinition(
        name: 'refresh_weather',
        description: 'Refresh the current weather data.',
        parameters: {
          'type': 'object',
          'properties': {},
        },
      ),
      (_) async {
        weatherbus.WeatherCommandBus.instance.refresh();
        return {'ok': true};
      },
    );
  }

  void _attachHandlers(RealtimeClient client) {
    if (_handlersAttached) return;
    _handlersAttached = true;

    client.on(RealtimeEventType.conversationInterrupted, (_) {
      _responseGenerationActive = false;
      _onInterrupted?.call();
    });

    client.on(RealtimeEventType.conversationUpdated, (ev) {
      final e = ev as RealtimeEventConversationUpdated;
      final wrapped = e.result.item;
      final delta = e.result.delta;

      if (wrapped?.item case final ItemMessage msg) {
        final id = msg.id;
        if (msg.role == ItemRole.user) {
          if (id != _lastUserItemId) {
            _lastUserItemId = id;
            _onUserTurnBoundary?.call();
          }
          final t = delta?.transcript;
          if (t != null && t.trim().isNotEmpty) {
            _onUserText?.call(t.trim());
          }
        } else if (msg.role == ItemRole.assistant) {
          if (id != _lastAssistantItemId) {
            _lastAssistantItemId = id;
            _onAssistantTurnBoundary?.call();
          }
          final piece = delta?.text ?? delta?.transcript;
          final pcm = delta?.audio;
          if ((piece != null && piece.isNotEmpty) ||
              (pcm != null && pcm.isNotEmpty)) {
            _responseGenerationActive = true;
          }
          if (piece != null && piece.isNotEmpty) {
            _onAssistantTextDelta?.call(piece);
          }
          if (pcm != null && pcm.isNotEmpty) {
            _onAssistantPcmDelta?.call(pcm);
          }
        }
      }
    });

    client.realtime.on(RealtimeEventType.responseDone, (_) {
      _responseGenerationActive = false;
      _onAssistantResponseDone?.call();
    });

    client.realtime.on(RealtimeEventType.error, (ev) {
      final msg = ev.toString();
      if (msg.contains('response_cancel_not_active')) {
        return;
      }
      debugPrint('OpenAI Realtime error: $ev');
    });
  }

  /// Keeps sending mic PCM while [_micPumpRunning] and the socket stays up. Restarts after focus loss.
  Future<void> _micPumpLoop(int generation) async {
    while (_micPumpRunning &&
        generation == _micGeneration &&
        _client != null &&
        _client!.isConnected()) {
      if (!await _recorder.hasPermission()) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        continue;
      }

      try {
        if (await _recorder.isRecording()) {
          await _recorder.stop();
        }
      } catch (_) {}

      final streamDone = Completer<void>();

      try {
        final stream = await _recorder.startStream(_recordConfig);
        if (!_micPumpRunning ||
            generation != _micGeneration ||
            _client == null ||
            !_client!.isConnected()) {
          await _recorder.stop();
          break;
        }

        _pcmSub = stream.listen(
          (chunk) async {
            if (!_micPumpRunning ||
                generation != _micGeneration ||
                chunk.isEmpty) {
              return;
            }
            try {
              final toSend = _suppressMicToServer
                  ? Uint8List(chunk.length)
                  : chunk;
              await _client?.appendInputAudio(toSend);
            } catch (e, st) {
              debugPrint('appendInputAudio: $e\n$st');
            }
          },
          onDone: () {
            if (!streamDone.isCompleted) streamDone.complete();
          },
          onError: (_, __) {
            if (!streamDone.isCompleted) streamDone.complete();
          },
          cancelOnError: false,
        );

        await streamDone.future;
      } catch (e, st) {
        debugPrint('Mic stream: $e\n$st');
      } finally {
        await _pcmSub?.cancel();
        _pcmSub = null;
        try {
          if (await _recorder.isRecording()) {
            await _recorder.stop();
          }
        } catch (_) {}
      }

      if (_micPumpRunning &&
          generation == _micGeneration &&
          _client != null &&
          _client!.isConnected()) {
        await Future<void>.delayed(const Duration(milliseconds: 220));
        await _activateVoiceAudioSession();
      }
    }
  }

  /// Start streaming mic audio; server VAD commits turns and generates replies automatically.
  Future<bool> startContinuousListening({
    required String apiKey,
    required Voice voice,
    required String instructions,
  }) async {
    final client = _client;
    if (client == null || !client.isConnected()) {
      final ok = await _ensureSession(
        apiKey: apiKey,
        voice: voice,
        instructions: instructions,
      );
      if (!ok) return false;
    }

    if (!await _recorder.hasPermission()) {
      return false;
    }

    _micPumpRunning = false;
    await _pcmSub?.cancel();
    _pcmSub = null;
    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (_) {}

    await _activateVoiceAudioSession();

    _micGeneration++;
    final gen = _micGeneration;
    _micPumpRunning = true;
    unawaited(_micPumpLoop(gen));

    return true;
  }

  /// Stop microphone streaming and close the Realtime connection.
  Future<void> stopContinuousListening() async {
    _responseGenerationActive = false;
    _suppressMicToServer = false;
    _micGeneration++;
    _micPumpRunning = false;

    await _pcmSub?.cancel();
    _pcmSub = null;

    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (_) {}

    await _client?.disconnect();
    _client = null;
    _handlersAttached = false;
    _lastUserItemId = null;
    _lastAssistantItemId = null;

    await _deactivateVoiceAudioSession();
  }

  /// Stop the model from generating / truncate current assistant audio (ChatGPT-style Stop).
  Future<void> cancelAssistant() async {
    if (!_responseGenerationActive) return;
    try {
      await _client?.cancelResponse(null);
    } catch (e, st) {
      debugPrint('cancelAssistant: $e\n$st');
    } finally {
      _responseGenerationActive = false;
    }
  }
}
