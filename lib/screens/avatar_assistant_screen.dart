import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../services/app_settings.dart';
import '../services/logs_command_bus.dart' as logsbus;
import '../services/map_command_bus.dart' as mapbus;
import '../services/openai_realtime_voice.dart';
import '../services/realtime_voice.dart';
import '../services/settings_command_bus.dart' as settingsbus;
import '../services/weather_command_bus.dart' as weatherbus;

class AvatarAssistantScreen extends StatefulWidget {
  const AvatarAssistantScreen({super.key, required this.settings});

  final AppSettings settings;

  @override
  State<AvatarAssistantScreen> createState() => _AvatarAssistantScreenState();
}

class _AvatarAssistantScreenState extends State<AvatarAssistantScreen> {
  late RealtimeVoiceClient _rt;
  late final OpenaiRealtimeVoiceController _openAiVoice;

  final AudioPlayer _player = AudioPlayer();
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _textController = TextEditingController();
  final SpeechToText _stt = SpeechToText();
  String _holdTranscript = '';
  bool _sttReady = false;
  Completer<String>? _sttFinal;

  final List<String> _msgs = [];

  bool _isHolding = false;
  bool _busy = false;

  /// OpenAI Realtime voice session active (hands-free, server VAD).
  bool _openAiListening = false;
  int? _openAiUserIdx;
  int? _openAiAiIdx;

  /// Half-duplex: suppress uplink while local assistant audio plays (avoids mic picking up speaker).
  int _openAiAssistantPlaybackDepth = 0;
  Timer? _openAiSuppressTailTimer;

  /// Stream assistant PCM as deltas arrive (not after response completes).
  final List<Uint8List> _openAiPcmQueue = [];
  bool _openAiPcmDraining = false;
  bool _openAiPcmEndOfResponse = false;

  /// Merge tiny API deltas into larger PCM blocks so [just_audio] is not stop/started per word.
  final BytesBuilder _openAiPcmCoalesce = BytesBuilder();
  Timer? _openAiPcmCoalesceTimer;

  /// Keep one ExoPlayer instance alive by appending chunk files to one playlist.
  ConcatenatingAudioSource? _openAiPlaybackSource;
  int _openAiPlaybackLastIndex = -1;

  /// ~200 ms at 24 kHz mono PCM16.
  static const int _openAiPcmCoalesceMinBytes = 9600;
  static const Duration _openAiPcmCoalesceMaxWait = Duration(milliseconds: 120);

  static const String driverName = 'Gabriel';
  static const int _pcmChannels = 1;
  /// Assistant PCM from Realtime/TTS when [audioFormat] is `pcm16` (see backend `pcmSampleRate`).
  static const int _pcmPlaybackSampleRate = 24000;

  @override
  void initState() {
    super.initState();
    _rt = RealtimeVoiceClient(baseUrl: widget.settings.backendBaseUrl);
    _openAiVoice = OpenaiRealtimeVoiceController();

    _stt.statusListener = (status) {
      // Keep listening as long as the user is holding the mic.
      if (!mounted) return;
      if (!_isHolding) return;
      if (!_sttReady) return;
      // When recognition stops (e.g. silence), restart it to behave like "push-to-talk".
      if (status == 'notListening' || status == 'done') {
        _restartSttListenIfHolding();
      }
    };

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _greetOnOpen();
    });
  }

  @override
  void didUpdateWidget(covariant AvatarAssistantScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings.backendBaseUrl != widget.settings.backendBaseUrl) {
      _rt.dispose();
      _rt = RealtimeVoiceClient(baseUrl: widget.settings.backendBaseUrl);
    }
  }

  @override
  void dispose() {
    unawaited(_resetOpenAiPlaybackSource(stopPlayer: true));
    _openAiPcmCoalesceTimer?.cancel();
    if (_openAiPcmCoalesce.isNotEmpty) {
      _openAiPcmCoalesce.takeBytes();
    }
    _openAiPcmQueue.clear();
    _openAiPcmEndOfResponse = false;
    _openAiSuppressTailTimer?.cancel();
    _openAiVoice.setSuppressMicToServer(false);
    if (_openAiListening) {
      unawaited(_openAiVoice.stopContinuousListening());
    }
    unawaited(_openAiVoice.dispose());
    _rt.dispose();
    _player.dispose();
    _scrollController.dispose();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _greetOnOpen() async {
    final greeting = _timeGreeting();
    _addMsg('AI: $greeting');

    if (!widget.settings.speakReplies) return;

    try {
      final res = await _rt.sendText(
        message: greeting,
        voice: widget.settings.voice,
        tts: widget.settings.ttsEnabled,
      );

      _applyBackendMapIntent(res.intent);

      if (widget.settings.ttsEnabled &&
          res.audioBytes != null &&
          res.audioBytes!.isNotEmpty) {
        await _playMp3Bytes(res.audioBytes!);
      }
    } catch (_) {}
  }

  String _timeGreeting() {
    final h = DateTime.now().hour;
    final part = (h < 12)
        ? 'Good morning'
        : (h < 18)
            ? 'Good afternoon'
            : 'Good evening';
    return '$part, $driverName. What route are we driving today?';
  }

  String _buildRealtimeInstructions() {
    final name = widget.settings.driverName.trim();
    final displayName = name.isEmpty ? driverName : name;
    return 'You are RoadDogg, a concise AI co-pilot for professional truck '
        'drivers. The driver\'s name is $displayName. '
        'Use the provided tools when they want maps search, settings, driver '
        'logs, weather (including a city or radar), or to refresh weather. '
        'Do not say you opened something unless you called the matching tool.';
  }

  bool get _useOpenAiVoice =>
      widget.settings.ttsEnabled &&
      !kIsWeb &&
      OpenaiRealtimeVoiceController.apiKeyFromEnv != null;

  Future<void> _toggleOpenAiVoice() async {
    if (_openAiListening) {
      await _stopOpenAiVoiceSession();
      return;
    }
    if (_busy) return;
    await _startOpenAiVoiceSession();
  }

  Future<void> _startOpenAiVoiceSession() async {
    _openAiVoice.setCallbacks(
      onInterrupted: () {
        unawaited(_resetOpenAiPlaybackSource(stopPlayer: true));
        _openAiPcmCoalesceTimer?.cancel();
        if (_openAiPcmCoalesce.isNotEmpty) {
          _openAiPcmCoalesce.takeBytes();
        }
        _openAiPcmQueue.clear();
        _openAiPcmEndOfResponse = false;
        unawaited(_player.stop());
        _openAiSuppressTailTimer?.cancel();
        _openAiAssistantPlaybackDepth = 0;
        _openAiVoice.setSuppressMicToServer(false);
      },
      onUserTurnBoundary: () {
        if (!mounted) return;
        setState(() => _openAiUserIdx = null);
      },
      onAssistantTurnBoundary: () {
        if (!mounted) return;
        _flushOpenAiPcmCoalesceToQueue();
        _openAiPcmEndOfResponse = false;
        setState(() => _openAiAiIdx = null);
      },
      onUserText: (t) {
        if (!mounted || t.trim().isEmpty) return;
        setState(() {
          if (_openAiUserIdx == null) {
            _msgs.add('You: $t');
            _openAiUserIdx = _msgs.length - 1;
          } else {
            _msgs[_openAiUserIdx!] = 'You: $t';
          }
        });
        _scrollToBottom();
      },
      onAssistantTextDelta: (d) {
        if (!mounted || d.isEmpty) return;
        setState(() {
          if (_openAiAiIdx == null) {
            // User transcript often arrives after the model starts streaming; without
            // a user row first, the AI bubble is appended and the question ends up below.
            if (_openAiUserIdx == null) {
              _msgs.add('You: …');
              _openAiUserIdx = _msgs.length - 1;
            }
            _msgs.add('AI: $d');
            _openAiAiIdx = _msgs.length - 1;
          } else {
            final cur = _msgs[_openAiAiIdx!];
            const p = 'AI: ';
            final rest = cur.startsWith(p) ? cur.substring(p.length) : cur;
            _msgs[_openAiAiIdx!] = '$p$rest$d';
          }
        });
        _scrollToBottom();
      },
      onAssistantPcmDelta: (pcm) {
        if (!mounted) return;
        if (!widget.settings.speakReplies || !widget.settings.ttsEnabled) {
          return;
        }
        if (pcm.isEmpty) return;
        _enqueueOpenAiPcmDelta(pcm);
      },
      onAssistantResponseDone: () {
        if (!mounted) return;
        _flushOpenAiPcmCoalesceToQueue();
        _openAiPcmEndOfResponse = true;
        unawaited(_drainOpenAiPcmQueue());
      },
    );

    final ok = await _openAiVoice.startContinuousListening(
      apiKey: OpenaiRealtimeVoiceController.apiKeyFromEnv!,
      voice: OpenaiRealtimeVoiceController.voiceFromSettings(
        widget.settings.voice,
      ),
      instructions: _buildRealtimeInstructions(),
    );

    if (!mounted) return;
    if (ok) {
      setState(() => _openAiListening = true);
    } else {
      _addErr('Could not start voice chat (mic permission or connection).');
    }
  }

  Future<void> _stopOpenAiVoiceSession() async {
    await _resetOpenAiPlaybackSource(stopPlayer: true);
    _openAiPcmCoalesceTimer?.cancel();
    if (_openAiPcmCoalesce.isNotEmpty) {
      _openAiPcmCoalesce.takeBytes();
    }
    _openAiPcmQueue.clear();
    _openAiPcmEndOfResponse = false;
    unawaited(_player.stop());
    _openAiSuppressTailTimer?.cancel();
    _openAiAssistantPlaybackDepth = 0;
    _openAiVoice.setSuppressMicToServer(false);
    await _openAiVoice.stopContinuousListening();
    if (!mounted) return;
    setState(() {
      _openAiListening = false;
      _openAiUserIdx = null;
      _openAiAiIdx = null;
    });
  }

  Future<void> _interruptOpenAiAssistant() async {
    await _resetOpenAiPlaybackSource(stopPlayer: true);
    _openAiPcmCoalesceTimer?.cancel();
    if (_openAiPcmCoalesce.isNotEmpty) {
      _openAiPcmCoalesce.takeBytes();
    }
    _openAiPcmQueue.clear();
    await _player.stop();
    await _openAiVoice.cancelAssistant();
  }

  void _enqueueOpenAiPcmDelta(Uint8List pcm) {
    _openAiPcmCoalesce.add(pcm);
    if (_openAiPcmCoalesce.length >= _openAiPcmCoalesceMinBytes) {
      _flushOpenAiPcmCoalesceToQueue();
    } else {
      _openAiPcmCoalesceTimer?.cancel();
      _openAiPcmCoalesceTimer = Timer(_openAiPcmCoalesceMaxWait, () {
        if (!mounted) return;
        _flushOpenAiPcmCoalesceToQueue();
      });
    }
  }

  void _flushOpenAiPcmCoalesceToQueue() {
    _openAiPcmCoalesceTimer?.cancel();
    if (_openAiPcmCoalesce.isEmpty) return;
    _openAiPcmQueue.add(_openAiPcmCoalesce.takeBytes());
    unawaited(_drainOpenAiPcmQueue());
  }

  void _enterOpenAiAssistantLocalPlayback() {
    _openAiSuppressTailTimer?.cancel();
    _openAiAssistantPlaybackDepth++;
    if (_openAiAssistantPlaybackDepth == 1) {
      _openAiVoice.setSuppressMicToServer(true);
    }
  }

  void _leaveOpenAiAssistantLocalPlayback() {
    if (_openAiAssistantPlaybackDepth <= 0) return;
    _openAiAssistantPlaybackDepth--;
    if (_openAiAssistantPlaybackDepth > 0) return;
    _openAiSuppressTailTimer?.cancel();
    _openAiSuppressTailTimer = Timer(const Duration(milliseconds: 180), () {
      _openAiSuppressTailTimer = null;
      if (!mounted || _openAiAssistantPlaybackDepth != 0) return;
      _openAiVoice.setSuppressMicToServer(false);
    });
  }

  Future<void> _drainOpenAiPcmQueue() async {
    if (_openAiPcmDraining) return;
    _openAiPcmDraining = true;
    try {
      while (mounted && _openAiPcmQueue.isNotEmpty) {
        if (_openAiAssistantPlaybackDepth == 0) {
          _enterOpenAiAssistantLocalPlayback();
        }
        final chunk = _openAiPcmQueue.removeAt(0);
        try {
          await _enqueueOpenAiPcmForPlayback(
            chunk,
            sampleRate: _pcmPlaybackSampleRate,
          );
        } catch (_) {}
      }
    } finally {
      _openAiPcmDraining = false;
      if (mounted && _openAiPcmQueue.isNotEmpty) {
        unawaited(_drainOpenAiPcmQueue());
      } else if (mounted &&
          _openAiPcmEndOfResponse &&
          _openAiPcmQueue.isEmpty) {
        final hadPlayback = _openAiAssistantPlaybackDepth > 0;
        final targetIndex = _openAiPlaybackLastIndex;
        _openAiPcmEndOfResponse = false;
        if (targetIndex >= 0) {
          await _waitForOpenAiPlaybackThrough(targetIndex);
          await _resetOpenAiPlaybackSource(stopPlayer: false);
        }
        if (hadPlayback) {
          _leaveOpenAiAssistantLocalPlayback();
        }
      }
    }
  }

  Future<void> _ensureOpenAiPlaybackSource() async {
    if (_openAiPlaybackSource != null) return;
    _openAiPlaybackSource = ConcatenatingAudioSource(
      useLazyPreparation: true,
      children: [],
    );
    _openAiPlaybackLastIndex = -1;
  }

  Future<void> _resetOpenAiPlaybackSource({required bool stopPlayer}) async {
    if (stopPlayer) {
      try {
        await _player.stop();
      } catch (_) {}
    }
    _openAiPlaybackSource = null;
    _openAiPlaybackLastIndex = -1;
  }

  Future<void> _waitForOpenAiPlaybackThrough(int targetIndex) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (mounted) {
      final idx = _player.currentIndex ?? -1;
      final state = _player.processingState;
      if (idx > targetIndex) return;
      if (idx == targetIndex && state == ProcessingState.completed) return;
      if (idx == -1 && state == ProcessingState.idle && !_player.playing) {
        return;
      }
      if (DateTime.now().isAfter(deadline)) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> _enqueueOpenAiPcmForPlayback(
    Uint8List pcm16, {
    required int sampleRate,
  }) async {
    final wav = _wrapPcm16ToWav(
      pcm16,
      sampleRate: sampleRate,
      numChannels: _pcmChannels,
    );
    final file = File(
      '${Directory.systemTemp.path}/roaddogg_reply_${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    await file.writeAsBytes(wav, flush: true);
    await _ensureOpenAiPlaybackSource();
    final source = _openAiPlaybackSource;
    if (source == null) return;
    final audioSource = AudioSource.uri(Uri.file(file.path));
    if (source.children.isEmpty) {
      await source.add(audioSource);
      _openAiPlaybackLastIndex = 0;
      await _player.setAudioSource(
        source,
        preload: true,
      );
    } else {
      await source.add(audioSource);
      _openAiPlaybackLastIndex = source.children.length - 1;
    }
    if (!_player.playing) {
      await _player.play();
    }
  }

  Future<void> _startHoldToTalk() async {
    if (_busy) return;
    await _startHoldToTalkWithStt();
  }

  Future<void> _startHoldToTalkWithStt() async {
    if (mounted) {
      setState(() {
        _isHolding = true;
        _holdTranscript = '';
      });
    }
    _sttFinal = Completer<String>();

    final ok = await _stt.initialize(
      onError: (e) {
        if (!mounted) return;
        if (!_isHolding) return;
        setState(() {
          _isHolding = false;
          _msgs.add('ERROR: ${e.errorMsg}');
        });
        _scrollToBottom();
      },
    );
    if (!ok) {
      if (!mounted) return;
      setState(() {
        _isHolding = false;
        _msgs.add('ERROR: Speech recognition not available.');
      });
      _scrollToBottom();
      return;
    }

    _sttReady = true;
    await _restartSttListenIfHolding();
  }

  Future<void> _restartSttListenIfHolding() async {
    if (!_isHolding) return;
    if (!_sttReady) return;
    if (_stt.isListening) return;

    // Use a long listen window and "dictation" mode.
    // If the recognizer stops early, statusListener will restart it while the user holds.
    await _stt.listen(
      listenFor: const Duration(minutes: 5),
      pauseFor: const Duration(seconds: 8),
      listenMode: ListenMode.dictation,
      onResult: (result) {
        final text = result.recognizedWords.trim();
        if (text.isEmpty) return;
        _holdTranscript = text;
        if (result.finalResult && !(_sttFinal?.isCompleted ?? true)) {
          _sttFinal?.complete(text);
        }
      },
      // NOTE: `partialResults` is deprecated in newer versions; keeping it for now
      // since this project already had analyzer info-only warnings.
      partialResults: true,
    );
  }

  Future<void> _stopHoldToTalkAndSend() async {
    if (_busy) return;

    if (mounted) {
      setState(() => _isHolding = false);
    }

    try {
      _sttReady = false;
      await _stt.stop();

      // `stop()` often triggers one last finalResult callback asynchronously.
      // Wait briefly for it so we don't send a cut-off partial transcript.
      String spokenText = _holdTranscript.trim();
      final finalFuture = _sttFinal?.future;
      if (finalFuture != null) {
        try {
          final finalText = await finalFuture.timeout(
            const Duration(milliseconds: 650),
          );
          spokenText = finalText.trim();
        } catch (_) {}
      }
      _sttFinal = null;

      if (spokenText.isEmpty) {
        _addMsg('You: [voice message]');
        return;
      }

      // Use chat flow (streaming) for low latency; it will also handle intents + optional TTS.
      await _sendText(spokenText);
    } catch (e) {
      _addErr('$e');
    }
  }

  Future<void> _sendTypedMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _busy) return;

    _textController.clear();
    await _sendText(text);
  }

  Future<void> _sendText(String text) async {
    final t = text.trim();
    if (t.isEmpty || _busy) return;

    if (mounted) {
      setState(() {
        _busy = true;
        _msgs.add('You: $t');
      });
    }

    final handled = await _handleImmediateIntent(t);
    if (handled) {
      if (mounted) {
        setState(() => _busy = false);
      }
      return;
    }

    int? aiIndex;
    try {
      _addMsg('AI: ');
      aiIndex = _msgs.length - 1;
      final bubbleIdx = aiIndex;

      final res = await _rt.sendTextStream(
        message: t,
        voice: widget.settings.voice,
        tts: widget.settings.ttsEnabled,
        onTextUpdate: (accumulated) {
          if (!mounted) return;
          setState(() {
            _msgs[bubbleIdx] = 'AI: $accumulated';
          });
          _scrollToBottom();
        },
      );

      if (mounted && bubbleIdx < _msgs.length) {
        final line = _msgs[bubbleIdx];
        final fallback = res.text.trim();
        if (line == 'AI: ' || line == 'AI:') {
          setState(() {
            final body = fallback.isEmpty || fallback == 'OK'
                ? '(No text in stream — check backend / network.)'
                : fallback;
            _msgs[bubbleIdx] = 'AI: $body';
          });
        }
      }

      _applyBackendMapIntent(res.intent);

      if (widget.settings.speakReplies &&
          widget.settings.ttsEnabled &&
          res.audioBytes != null &&
          res.audioBytes!.isNotEmpty) {
        await _playBackendAudio(
          res.audioBytes!,
          res.audioFormat,
          pcmSampleRate: res.pcmSampleRate,
        );
      }
    } catch (e) {
      if (mounted && aiIndex != null && aiIndex < _msgs.length) {
        setState(() {
          _msgs[aiIndex!] = 'ERROR: $e';
        });
        _scrollToBottom();
      } else {
        _addErr('$e');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<bool> _handleImmediateIntent(String rawText) async {
    final settingsHandled = _handleImmediateSettingsIntent(rawText);
    if (settingsHandled) return true;

    final logsHandled = _handleImmediateLogsIntent(rawText);
    if (logsHandled) return true;

    final weatherHandled = _handleImmediateWeatherIntent(rawText);
    if (weatherHandled) return true;

    return false;
  }

  /// Open Maps only when the backend classifies [intent] as `map_search` (not client keyword guessing).
  void _applyBackendMapIntent(Map<String, dynamic>? intent) {
    if (intent == null) return;
    final type = (intent['type'] ?? '').toString().trim();
    if (type != 'map_search') return;
    final query = (intent['query'] ?? '').toString().trim();
    if (query.isEmpty) return;
    mapbus.MapCommandBus.instance.search(query);
  }

  bool _handleImmediateSettingsIntent(String rawText) {
    final lower = rawText.trim().toLowerCase();

    const phrases = [
      'open settings',
      'go to settings',
      'show settings',
      'pull up settings',
      'settings',
    ];

    for (final phrase in phrases) {
      if (lower == phrase || lower.contains(phrase)) {
        settingsbus.SettingsCommandBus.instance.open();
        _addMsg('AI: Opening settings.');
        return true;
      }
    }

    return false;
  }

  bool _handleImmediateLogsIntent(String rawText) {
    final lower = rawText.trim().toLowerCase();

    const phrases = [
      'open logs',
      'go to logs',
      'show logs',
      'pull up logs',
      'open driver logs',
      'go to driver logs',
      'show driver logs',
      'logs',
    ];

    for (final phrase in phrases) {
      if (lower == phrase || lower.contains(phrase)) {
        logsbus.LogsCommandBus.instance.open();
        _addMsg('AI: Opening logs.');
        return true;
      }
    }

    return false;
  }

  bool _handleImmediateWeatherIntent(String rawText) {
    final intent = _extractWeatherIntent(rawText);
    if (intent == null) return false;

    switch (intent.type) {
      case _WeatherIntentType.open:
        weatherbus.WeatherCommandBus.instance.open();
        _addMsg('AI: Opening weather.');
        return true;

      case _WeatherIntentType.city:
        final city = (intent.city ?? '').trim();
        if (city.isEmpty) return false;
        weatherbus.WeatherCommandBus.instance.openCity(city);
        _addMsg('AI: Opening weather for $city.');
        return true;

      case _WeatherIntentType.radar:
        weatherbus.WeatherCommandBus.instance.openRadar();
        _addMsg('AI: Opening radar.');
        return true;

      case _WeatherIntentType.refresh:
        weatherbus.WeatherCommandBus.instance.refresh();
        _addMsg('AI: Refreshing weather.');
        return true;
    }
  }

  _WeatherIntent? _extractWeatherIntent(String input) {
    final text = input.trim();
    if (text.isEmpty) return null;

    final lower = text.toLowerCase();
    final normalized = lower.replaceAll(RegExp(r'\s+'), '');

    final cityPatterns = <RegExp>[
      RegExp(
        r"(?:what(?:'s| is)?\s+the\s+weather(?:\s+looking\s+like)?\s+in\s+)(.+)$",
        caseSensitive: false,
      ),
      RegExp(
        r"(?:show\s+me\s+the\s+weather\s+in\s+)(.+)$",
        caseSensitive: false,
      ),
      RegExp(
        r"(?:show\s+me\s+weather\s+in\s+)(.+)$",
        caseSensitive: false,
      ),
      RegExp(
        r"(?:open\s+the\s+weather\s+in\s+)(.+)$",
        caseSensitive: false,
      ),
      RegExp(
        r"(?:pull\s+up\s+the\s+weather\s+in\s+)(.+)$",
        caseSensitive: false,
      ),
      RegExp(
        r"(?:weather\s+in\s+)(.+)$",
        caseSensitive: false,
      ),
      RegExp(
        r"(?:forecast\s+for\s+)(.+)$",
        caseSensitive: false,
      ),
    ];

    for (final rx in cityPatterns) {
      final match = rx.firstMatch(text);
      if (match != null) {
        var city = (match.group(1) ?? '').trim();
        city = city.replaceAll(RegExp(r'[?.!,]+$'), '').trim();
        if (city.isNotEmpty) {
          return _WeatherIntent.city(city);
        }
      }
    }

    if (lower == 'weather' ||
        lower == 'show me the weather' ||
        lower == 'show me weather' ||
        lower == 'show weather' ||
        lower == 'open weather' ||
        lower == 'pull up weather' ||
        lower == 'pull up the weather' ||
        lower.contains('open the weather') ||
        lower.contains('weather screen') ||
        lower.contains('show me the weather') ||
        lower.contains('show me weather')) {
      return const _WeatherIntent(_WeatherIntentType.open);
    }

    if (lower == 'radar' ||
        normalized == 'openradar' ||
        lower.contains('open radar') ||
        lower.contains('show radar') ||
        lower.contains('pull up radar') ||
        lower.contains('weather radar')) {
      return const _WeatherIntent(_WeatherIntentType.radar);
    }

    if (lower.contains('refresh weather') ||
        lower.contains('update weather') ||
        lower.contains('reload weather') ||
        lower.contains('refresh the weather')) {
      return const _WeatherIntent(_WeatherIntentType.refresh);
    }

    const weatherWords = [
      'weather',
      'forecast',
      'temperature',
      'humidity',
      'rain',
      'storm',
      'storms',
      'radar',
      'wind',
      'clouds',
      'cloud',
    ];

    for (final word in weatherWords) {
      if (lower.contains(word)) {
        return const _WeatherIntent(_WeatherIntentType.open);
      }
    }

    return null;
  }

  Future<void> _playBackendAudio(
    Uint8List audioBytes,
    String? audioFormat, {
    int? pcmSampleRate,
  }) async {
    final fmt = (audioFormat ?? '').trim().toLowerCase();
    if (fmt == 'pcm16') {
      final sr = pcmSampleRate ?? _pcmPlaybackSampleRate;
      final wav = _wrapPcm16ToWav(
        audioBytes,
        sampleRate: sr,
        numChannels: _pcmChannels,
      );
      await _playWavBytes(wav);
      return;
    }

    await _playMp3Bytes(audioBytes);
  }

  Future<void> _playMp3Bytes(Uint8List mp3) async {
    final file = File(
      '${Directory.systemTemp.path}/roaddogg_reply_${DateTime.now().millisecondsSinceEpoch}.mp3',
    );
    await file.writeAsBytes(mp3, flush: true);

    await _player.stop();
    await _player.setFilePath(file.path);
    await _player.play();
  }

  Future<void> _playWavBytes(Uint8List wav) async {
    final file = File(
      '${Directory.systemTemp.path}/roaddogg_reply_${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    await file.writeAsBytes(wav, flush: true);

    await _player.stop();
    await _player.setFilePath(file.path);
    await _player.play();
  }

  Uint8List _wrapPcm16ToWav(
    Uint8List pcm16, {
    required int sampleRate,
    required int numChannels,
  }) {
    const bitsPerSample = 16;
    final byteRate = sampleRate * numChannels * (bitsPerSample ~/ 8);
    final blockAlign = numChannels * (bitsPerSample ~/ 8);
    final dataSize = pcm16.length;
    final fileSizeMinus8 = 36 + dataSize;

    final header = BytesBuilder();
    void writeAscii(String s) => header.add(s.codeUnits);
    void writeU32(int v) {
      header.add([
        v & 0xFF,
        (v >> 8) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 24) & 0xFF,
      ]);
    }

    void writeU16(int v) {
      header.add([
        v & 0xFF,
        (v >> 8) & 0xFF,
      ]);
    }

    writeAscii('RIFF');
    writeU32(fileSizeMinus8);
    writeAscii('WAVE');
    writeAscii('fmt ');
    writeU32(16);
    writeU16(1);
    writeU16(numChannels);
    writeU32(sampleRate);
    writeU32(byteRate);
    writeU16(blockAlign);
    writeU16(bitsPerSample);
    writeAscii('data');
    writeU32(dataSize);

    final out = BytesBuilder();
    out.add(header.takeBytes());
    out.add(pcm16);
    return out.takeBytes();
  }

  void _addMsg(String m) {
    if (!mounted) return;
    setState(() => _msgs.add(m));
    _scrollToBottom();
  }

  void _addErr(String m) {
    if (!mounted) return;
    setState(() => _msgs.add('ERROR: $m'));
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent + 120,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  bool _isAiMsg(String msg) => msg.startsWith('AI:');
  bool _isUserMsg(String msg) => msg.startsWith('You:');
  bool _isErrorMsg(String msg) => msg.startsWith('ERROR:');

  Widget _buildBubble(String msg, bool isDark) {
    final isAi = _isAiMsg(msg);
    final isUser = _isUserMsg(msg);
    final isError = _isErrorMsg(msg);

    Alignment alignment = Alignment.centerLeft;
    Color bg;
    Color fg;

    if (isUser) {
      alignment = Alignment.centerRight;
      bg = Colors.black;
      fg = Colors.white;
    } else if (isError) {
      alignment = Alignment.centerLeft;
      bg = isDark ? const Color(0xFF3A1717) : const Color(0xFFFCEAEA);
      fg = isDark ? const Color(0xFFFFB4B4) : const Color(0xFF9B1C1C);
    } else if (isAi) {
      alignment = Alignment.centerLeft;
      bg = isDark ? const Color(0xFF1B1B1B) : Colors.white;
      fg = isDark ? Colors.white : Colors.black87;
    } else {
      alignment = Alignment.centerLeft;
      bg = isDark ? const Color(0xFF1B1B1B) : Colors.white;
      fg = isDark ? Colors.white : Colors.black87;
    }

    return Align(
      alignment: alignment,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 330),
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isDark
                ? (isUser ? Colors.black : const Color(0xFF2E2E2E))
                : (isUser ? Colors.black : Colors.black12),
          ),
          boxShadow: [
            BoxShadow(
              blurRadius: 8,
              offset: const Offset(0, 2),
              color: isDark
                  ? const Color(0x22000000)
                  : const Color(0x12000000),
            ),
          ],
        ),
        child: Text(
          msg,
          style: TextStyle(
            color: fg,
            fontSize: 14,
            height: 1.4,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bg = isDark ? const Color(0xFF111111) : const Color(0xFFF4F4F4);
    final surface = isDark ? const Color(0xFF181818) : Colors.white;
    final border = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFEAEAEA);
    final textColor = isDark ? Colors.white : Colors.black87;
    final hintColor = isDark ? Colors.white54 : Colors.black54;

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _msgs.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 28),
                        child: Text(
                          'Start a conversation with RoadDogg AI.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: hintColor,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
                      itemCount: _msgs.length,
                      itemBuilder: (_, i) => _buildBubble(_msgs[i], isDark),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Material(
                color: surface,
                elevation: isDark ? 0 : 6,
                borderRadius: BorderRadius.circular(22),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                  decoration: BoxDecoration(
                    color: surface,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: border),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _textController,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _sendTypedMessage(),
                          style: TextStyle(
                            color: textColor,
                            fontSize: 15,
                          ),
                          decoration: InputDecoration(
                            hintText: _busy
                                ? 'Working...'
                                : _openAiListening
                                    ? 'Voice chat on — tap mic to stop'
                                    : _isHolding
                                        ? 'Listening...'
                                        : 'Message RoadDogg AI',
                            hintStyle: TextStyle(
                              color: hintColor,
                              fontSize: 15,
                            ),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 12,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (_useOpenAiVoice && _openAiListening) ...[
                        GestureDetector(
                          onTap: _interruptOpenAiAssistant,
                          child: Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                              color: const Color(0xFFB71C1C),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: const Color(0xFF7F0000),
                              ),
                            ),
                            child: const Icon(
                              Icons.stop_rounded,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      GestureDetector(
                        onTap: _useOpenAiVoice ? _toggleOpenAiVoice : null,
                        onLongPressStart:
                            _useOpenAiVoice ? null : (_) => _startHoldToTalk(),
                        onLongPressEnd: _useOpenAiVoice
                            ? null
                            : (_) => _stopHoldToTalkAndSend(),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: (_openAiListening || _isHolding)
                                ? Colors.black
                                : surface,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: (_openAiListening || _isHolding)
                                  ? Colors.black
                                  : (isDark
                                      ? const Color(0xFF2E2E2E)
                                      : Colors.black12),
                            ),
                          ),
                          child: Icon(
                            (_openAiListening || _isHolding)
                                ? Icons.mic
                                : Icons.mic_none,
                            color: (_openAiListening || _isHolding)
                                ? Colors.white
                                : textColor,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: _busy ? null : _sendTypedMessage,
                        child: Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(
                            Icons.arrow_upward,
                            color: _busy ? Colors.white54 : Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _openAiListening
                    ? 'Hands-free voice · tap mic to end · Stop interrupts the reply'
                    : _isHolding
                        ? 'Listening... release to send'
                        : _busy
                            ? 'Working on your request...'
                            : _useOpenAiVoice
                                ? 'Tap mic for hands-free voice, or type a message'
                                : 'Hold mic for voice or type a message',
                style: TextStyle(
                  color: hintColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _WeatherIntentType {
  open,
  city,
  radar,
  refresh,
}

class _WeatherIntent {
  final _WeatherIntentType type;
  final String? city;

  const _WeatherIntent(this.type) : city = null;

  const _WeatherIntent.city(String this.city) : type = _WeatherIntentType.city;
}