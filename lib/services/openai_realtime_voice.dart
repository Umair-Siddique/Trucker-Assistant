import 'dart:async';
import 'dart:developer' as developer;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:openai_realtime_dart/openai_realtime_dart.dart';
import 'package:record/record.dart';

import 'logs_command_bus.dart' as logsbus;
import 'map_command_bus.dart' as mapbus;
import 'map_navigation_command_bus.dart' as mapnavbus;
import 'settings_command_bus.dart' as settingsbus;
import 'weather_command_bus.dart' as weatherbus;

typedef OpenaiVoiceTextCallback = void Function(String text);
typedef OpenaiVoicePcmCallback = void Function(Uint8List chunk);

/// OpenAI Realtime with **server VAD**: stream mic continuously; model responds after you stop speaking.
///
/// Android often stops [AudioRecord] when TTS plays (audio focus). This class configures a
/// voice-communication session and **restarts** the PCM stream whenever it ends while listening.
class OpenaiRealtimeVoiceController {
  OpenaiRealtimeVoiceController();

  /// Set false to silence all realtime-voice diagnostics.
  static bool verboseLogging = true;

  /// When true (default), each log is also sent with [debugPrint] so `flutter run` in a terminal
  /// shows them. [developer.log] alone often does **not** appear there for iOS device runs.
  static bool mirrorLogsToTerminal = true;

  RealtimeClient? _client;
  final AudioRecorder _recorder = AudioRecorder();

  StreamSubscription<Uint8List>? _pcmSub;

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

  /// One-shot per response: once assistant text/audio starts streaming, force uplink silence so server
  /// VAD does not treat speaker bleed as the user talking (that fires [conversationInterrupted] and
  /// cuts the reply mid-sentence). Reset on each [responseDone].
  bool _assistantEchoGuardApplied = false;

  StreamSubscription<AudioInterruptionEvent>? _audioInterruptionSub;
  StreamSubscription<void>? _audioBecomingNoisySub;
  StreamSubscription<AudioDevicesChangedEvent>? _audioDevicesChangedSub;

  int _micStreamEpoch = 0;
  int _appendInputAudioErrors = 0;

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

  static String get _platformLabel {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.android:
        return 'android';
      default:
        return defaultTargetPlatform.name;
    }
  }

  void _rtLog(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (!verboseLogging) return;
    final line = '[OpenaiRealtimeVoice][$_platformLabel] $message';
    developer.log(
      line,
      name: 'OpenaiRealtimeVoice',
      error: error,
      stackTrace: stackTrace,
    );
    if (mirrorLogsToTerminal) {
      debugPrint(line);
      if (error != null) {
        debugPrint('[OpenaiRealtimeVoice] error: $error');
      }
      if (stackTrace != null) {
        debugPrint(stackTrace.toString());
      }
    }
  }

  Future<void> _ensureAudioSessionDebugListeners() async {
    if (kIsWeb) return;
    if (_audioInterruptionSub != null) return;
    try {
      final session = await AudioSession.instance;
      _audioInterruptionSub = session.interruptionEventStream.listen((e) {
        _rtLog(
          'audio_session interruption begin=${e.begin} type=${e.type}',
        );
      });
      _audioBecomingNoisySub = session.becomingNoisyEventStream.listen((_) {
        _rtLog('audio_session becomingNoisy (e.g. route unplugged)');
      });
      _audioDevicesChangedSub =
          session.devicesChangedEventStream.listen((e) {
        _rtLog(
          'audio_session devicesChanged '
          'added=${e.devicesAdded.length} removed=${e.devicesRemoved.length}',
        );
      });
      _rtLog('audio_session debug listeners attached');
    } catch (e, st) {
      _rtLog('audio_session debug listeners failed', error: e, stackTrace: st);
    }
  }

  Future<void> _tearDownAudioSessionDebugListeners() async {
    await _audioInterruptionSub?.cancel();
    await _audioBecomingNoisySub?.cancel();
    await _audioDevicesChangedSub?.cancel();
    _audioInterruptionSub = null;
    _audioBecomingNoisySub = null;
    _audioDevicesChangedSub = null;
  }

  static Voice voiceFromSettings(String raw) {
    final s = raw.trim().toLowerCase();
    for (final v in Voice.values) {
      if (v.name == s) return v;
    }
    return Voice.alloy;
  }

  void setSuppressMicToServer(bool suppress) {
    final was = _suppressMicToServer;
    _suppressMicToServer = suppress;
    _rtLog('setSuppressMicToServer suppress=$suppress (was $was)');
  }

  void _ensureAssistantEchoGuard() {
    if (_assistantEchoGuardApplied) return;
    _assistantEchoGuardApplied = true;
    final was = _suppressMicToServer;
    _suppressMicToServer = true;
    _rtLog('assistant echo guard: suppressMic $was -> true');
  }

  void setCallbacks({
    OpenaiVoiceTextCallback? onUserText,
    OpenaiVoiceTextCallback? onAssistantTextDelta,
    OpenaiVoicePcmCallback? onAssistantPcmDelta,
    VoidCallback? onAssistantResponseDone,
    VoidCallback? onUserTurnBoundary,
    VoidCallback? onAssistantTurnBoundary,
  }) {
    _onUserText = onUserText;
    _onAssistantTextDelta = onAssistantTextDelta;
    _onAssistantPcmDelta = onAssistantPcmDelta;
    _onAssistantResponseDone = onAssistantResponseDone;
    _onUserTurnBoundary = onUserTurnBoundary;
    _onAssistantTurnBoundary = onAssistantTurnBoundary;
  }

  Future<void> dispose() async {
    _rtLog('dispose');
    _responseGenerationActive = false;
    _assistantEchoGuardApplied = false;
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
    await _tearDownAudioSessionDebugListeners();
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
      _rtLog(
        'voice audio session active '
        '(category=playAndRecord mode=spokenAudio)',
      );
      await _ensureAudioSessionDebugListeners();
    } catch (e, st) {
      _rtLog('voice audio session configure/active failed', error: e, stackTrace: st);
    }
  }

  Future<void> _deactivateVoiceAudioSession() async {
    if (kIsWeb) return;
    await _tearDownAudioSessionDebugListeners();
    try {
      final session = await AudioSession.instance;
      await session.setActive(false);
      _rtLog('voice audio session setActive(false)');
    } catch (e, st) {
      _rtLog('voice audio session deactivate failed', error: e, stackTrace: st);
    }
  }

  Future<bool> _ensureSession({
    required String apiKey,
    required Voice voice,
    required String instructions,
  }) async {
    if (kIsWeb) return false;

    if (_client != null && _client!.isConnected()) {
      _rtLog('_ensureSession reusing connection, updateSession');
      await _client!.updateSession(
        modalities: const [Modality.text],
        voice: voice,
        instructions: instructions,
        maxResponseOutputTokens:
            const SessionConfigMaxResponseOutputTokens.string('inf'),
      );
      return true;
    }

    await _client?.disconnect();
    _client = null;
    _handlersAttached = false;
    _lastUserItemId = null;
    _lastAssistantItemId = null;

    try {
      final client = RealtimeClient(apiKey: apiKey, debug: verboseLogging);
      _client = client;
      _rtLog('RealtimeClient created debug=$verboseLogging');

      await _registerTools(client);

      await client.updateSession(
        modalities: const [Modality.text],
        instructions: instructions,
        voice: voice,
        inputAudioFormat: AudioFormat.pcm16,
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
        maxResponseOutputTokens:
            const SessionConfigMaxResponseOutputTokens.string('inf'),
      );

      final ok = await client.connect();
      if (!ok) {
        _rtLog('realtime connect() returned false');
        await client.disconnect();
        _client = null;
        _handlersAttached = false;
        return false;
      }
      await client.waitForSessionCreated();
      _rtLog('realtime session created connected=${client.isConnected()}');
      _attachHandlers(client);
      return true;
    } catch (e, st) {
      _rtLog('_ensureSession failed', error: e, stackTrace: st);
      try {
        await _client?.disconnect();
      } catch (_) {}
      _client = null;
      _handlersAttached = false;
      _lastUserItemId = null;
      _lastAssistantItemId = null;
      return false;
    }
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
        name: 'start_map_navigation',
        description:
            'Start in-app navigation to a destination. Use this when the user says "start navigation", '
            '"take me to", "navigate to", "start destination", or similar. If a destination is provided, '
            'the app will search it on the map, pick the best match, compute a route, and start.',
        parameters: {
          'type': 'object',
          'properties': {
            'destination': {
              'type': 'string',
              'description':
                  'Destination name/address. Optional if a destination is already selected in Maps.',
            },
          },
        },
      ),
      (Map<String, dynamic> params) async {
        final dest = (params['destination'] ?? '').toString().trim();
        mapnavbus.MapNavigationCommandBus.instance.navigate(dest);
        return {'ok': true, 'destination': dest};
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
    _rtLog('handlers attached');

    client.on(RealtimeEventType.conversationInterrupted, (_) {
      _rtLog(
        'conversationInterrupted (ignored — never clears local playback; '
        'server VAD/speaker echo caused constant mid-reply cutoffs). '
        'responseGen=$_responseGenerationActive suppressMic=$_suppressMicToServer',
      );
      // [RealtimeClient] maps inputAudioBufferSpeechStarted -> this event. Forwarding it
      // to the UI used to stop [just_audio] mid-stream. Use the in-app stop control if
      // the driver needs to cancel.
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
            _rtLog('user turn boundary itemId=$id');
            _onUserTurnBoundary?.call();
          }
          final t = delta?.transcript;
          if (t != null && t.trim().isNotEmpty) {
            _rtLog(
              'user transcript delta len=${t.trim().length} '
              'preview=${_previewForLog(t.trim(), 48)}',
            );
            _onUserText?.call(t.trim());
          }
        } else if (msg.role == ItemRole.assistant) {
          if (id != _lastAssistantItemId) {
            _lastAssistantItemId = id;
            _rtLog('assistant turn boundary itemId=$id');
            _onAssistantTurnBoundary?.call();
          }
          final piece = delta?.text ?? delta?.transcript;
          final pcm = delta?.audio;
          if ((piece != null && piece.isNotEmpty) ||
              (pcm != null && pcm.isNotEmpty)) {
            _responseGenerationActive = true;
            _ensureAssistantEchoGuard();
          }
          if (piece != null && piece.isNotEmpty) {
            _rtLog(
              'assistant text delta len=${piece.length} '
              'preview=${_previewForLog(piece, 48)}',
            );
            _onAssistantTextDelta?.call(piece);
          }
          if (pcm != null && pcm.isNotEmpty) {
            _rtLog('assistant pcm delta bytes=${pcm.length}');
            _onAssistantPcmDelta?.call(pcm);
          }
        }
      } else if (wrapped != null) {
        _rtLog(
          'conversationUpdated unhandled item type=${wrapped.item.runtimeType}',
        );
      }
    });

    client.realtime.on(RealtimeEventType.responseDone, (_) {
      _rtLog(
        'responseDone responseGenWas=$_responseGenerationActive '
        'micRunning=$_micPumpRunning suppressMic=$_suppressMicToServer',
      );
      _responseGenerationActive = false;
      _assistantEchoGuardApplied = false;
      _onAssistantResponseDone?.call();
    });

    client.realtime.on(RealtimeEventType.error, (ev) {
      final msg = ev.toString();
      if (msg.contains('response_cancel_not_active')) {
        _rtLog('realtime error (ignored): response_cancel_not_active');
        return;
      }
      _rtLog('realtime error: $ev');
    });
  }

  static String _previewForLog(String s, int maxChars) {
    if (s.length <= maxChars) return s.replaceAll('\n', ' ');
    return '${s.replaceAll('\n', ' ').substring(0, maxChars)}…';
  }

  /// Keeps sending mic PCM while [_micPumpRunning] and the socket stays up. Restarts after focus loss.
  Future<void> _micPumpLoop(int generation) async {
    _rtLog(
      'mic pump loop start gen=$generation micGen=$_micGeneration '
      'connected=${_client?.isConnected() ?? false}',
    );
    while (_micPumpRunning &&
        generation == _micGeneration &&
        _client != null &&
        _client!.isConnected()) {
      if (!await _recorder.hasPermission()) {
        _rtLog('mic pump waiting: recorder hasPermission=false');
        await Future<void>.delayed(const Duration(milliseconds: 400));
        continue;
      }

      try {
        if (await _recorder.isRecording()) {
          await _recorder.stop();
        }
      } catch (_) {}

      _micStreamEpoch++;
      final epoch = _micStreamEpoch;
      var chunks = 0;
      var bytesSent = 0;
      var firstChunkLogged = false;
      final streamDone = Completer<void>();
      void completeStream(String reason) {
        if (!streamDone.isCompleted) {
          _rtLog(
            'mic stream ended epoch=$epoch reason=$reason '
            'chunks=$chunks bytesSent=$bytesSent appendErrors=$_appendInputAudioErrors',
          );
          streamDone.complete();
        }
      }

      try {
        _rtLog('mic startStream epoch=$epoch gen=$generation');
        final stream = await _recorder.startStream(_recordConfig);
        if (!_micPumpRunning ||
            generation != _micGeneration ||
            _client == null ||
            !_client!.isConnected()) {
          _rtLog(
            'mic startStream aborted before listen '
            'micRunning=$_micPumpRunning genMatch=${generation == _micGeneration} '
            'connected=${_client?.isConnected() ?? false}',
          );
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
            chunks++;
            if (!firstChunkLogged) {
              firstChunkLogged = true;
              _rtLog(
                'mic first pcm chunk epoch=$epoch bytes=${chunk.length} '
                'suppressMic=$_suppressMicToServer '
                'connected=${_client?.isConnected() ?? false}',
              );
            }
            if (chunks % 250 == 0) {
              _rtLog(
                'mic pcm progress epoch=$epoch chunks=$chunks '
                'bytesSent=$bytesSent suppress=$_suppressMicToServer '
                'connected=${_client?.isConnected() ?? false}',
              );
            }
            try {
              final toSend = _suppressMicToServer
                  ? Uint8List(chunk.length)
                  : chunk;
              if (!_suppressMicToServer) {
                bytesSent += toSend.length;
              }
              await _client?.appendInputAudio(toSend);
            } catch (e, st) {
              _appendInputAudioErrors++;
              _rtLog(
                'appendInputAudio failed (count=$_appendInputAudioErrors)',
                error: e,
                stackTrace: st,
              );
            }
          },
          onDone: () => completeStream('onDone'),
          onError: (Object e, StackTrace st) {
            _rtLog('mic stream onError', error: e, stackTrace: st);
            completeStream('onError');
          },
          cancelOnError: false,
        );

        await streamDone.future;
      } catch (e, st) {
        _rtLog('Mic startStream/listen failed epoch=$epoch', error: e, stackTrace: st);
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
        _rtLog('mic pump scheduling stream restart after 220ms (reactivate session)');
        await Future<void>.delayed(const Duration(milliseconds: 220));
        await _activateVoiceAudioSession();
      }
    }
    _rtLog(
      'mic pump loop exit gen=$generation micGen=$_micGeneration '
      'micRunning=$_micPumpRunning connected=${_client?.isConnected() ?? false}',
    );
  }

  /// Start streaming mic audio; server VAD commits turns and generates replies automatically.
  Future<bool> startContinuousListening({
    required String apiKey,
    required Voice voice,
    required String instructions,
  }) async {
    _rtLog('startContinuousListening');
    _appendInputAudioErrors = 0;
    final client = _client;
    if (client == null || !client.isConnected()) {
      final ok = await _ensureSession(
        apiKey: apiKey,
        voice: voice,
        instructions: instructions,
      );
      if (!ok) {
        _rtLog('startContinuousListening aborted: session not ready');
        return false;
      }
    }

    if (!await _recorder.hasPermission()) {
      _rtLog('startContinuousListening aborted: no mic permission');
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
    _rtLog('startContinuousListening ok micGen=$gen connected=${_client?.isConnected()}');
    unawaited(_micPumpLoop(gen));

    return true;
  }

  /// Stop microphone streaming and close the Realtime connection.
  Future<void> stopContinuousListening() async {
    _rtLog('stopContinuousListening');
    _responseGenerationActive = false;
    _assistantEchoGuardApplied = false;
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
    if (!_responseGenerationActive) {
      _rtLog('cancelAssistant skipped (no active response generation)');
      return;
    }
    _rtLog('cancelAssistant invoking cancelResponse');
    try {
      await _client?.cancelResponse(null);
    } catch (e, st) {
      _rtLog('cancelAssistant failed', error: e, stackTrace: st);
    } finally {
      _responseGenerationActive = false;
    }
  }
}
