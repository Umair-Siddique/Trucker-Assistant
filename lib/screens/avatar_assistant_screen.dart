import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../services/app_settings.dart';
import '../services/logs_command_bus.dart' as logsbus;
import '../services/map_command_bus.dart' as mapbus;
import '../services/openai_realtime_voice.dart';
import '../services/openai_responses_client.dart';
import '../services/settings_command_bus.dart' as settingsbus;
import '../services/weather_command_bus.dart' as weatherbus;

class AvatarAssistantScreen extends StatefulWidget {
  const AvatarAssistantScreen({super.key, required this.settings});

  final AppSettings settings;

  @override
  State<AvatarAssistantScreen> createState() => _AvatarAssistantScreenState();
}

class _AvatarAssistantScreenState extends State<AvatarAssistantScreen> {
  late final OpenaiRealtimeVoiceController _openAiVoice;
  final OpenAiResponsesClient _openAiText = OpenAiResponsesClient();
  final FlutterTts _openAiFlutterTts = FlutterTts();

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
  DateTime? _lastOpenAiInterruptTap;

  /// Realtime replies are text-only from the API; device [FlutterTts] reads them aloud
  /// sentence-by-sentence as text streams (no waiting for server audio / no just_audio concat).
  String _openAiTtsRemainder = '';
  Future<void> _openAiTtsChain = Future<void>.value();
  /// Bumped to drop any [.then] callbacks still chained from before (replacing the Future alone
  /// does not cancel them).
  int _openAiLocalTtsGen = 0;
  static final RegExp _openAiTtsSentence = RegExp(r'^(.+?[\.\!\?\n])\s*');

  StreamSubscription<PlayerState>? _openAiPlayerStateSub;
  static const bool _openAiPlaybackDebugLogs = true;

  static const String driverName = 'Gabriel';
  // (Backend audio playback removed; app uses device TTS + OpenAI Realtime.)

  bool get _isIos => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  void _openAiPlaybackLog(String msg) {
    if (!_openAiPlaybackDebugLogs) return;
    debugPrint(
      '[OpenAIPlayback][${_isIos ? 'ios' : 'other'}] $msg',
    );
  }

  void _attachOpenAiPlaybackDebugListeners() {
    if (!_openAiPlaybackDebugLogs || _openAiPlayerStateSub != null) return;
    _openAiPlayerStateSub = _player.playerStateStream.listen((state) {
      _openAiPlaybackLog(
        'playerState playing=${state.playing} '
        'processing=${state.processingState} '
        'index=${_player.currentIndex ?? -1} '
        'ttsRemainderLen=${_openAiTtsRemainder.length}',
      );
    });
    _openAiPlaybackLog('debug listeners attached');
  }

  @override
  void initState() {
    super.initState();
    _openAiVoice = OpenaiRealtimeVoiceController();
    _attachOpenAiPlaybackDebugListeners();

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
    unawaited(_initOpenAiFlutterTts());
  }

  @override
  void didUpdateWidget(covariant AvatarAssistantScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
    unawaited(_openAiPlayerStateSub?.cancel());
    _openAiPlayerStateSub = null;
    unawaited(_resetOpenAiPlaybackSource(stopPlayer: true));
    _openAiSuppressTailTimer?.cancel();
    _openAiVoice.setSuppressMicToServer(false);
    if (_openAiListening) {
      unawaited(_openAiVoice.stopContinuousListening());
    }
    unawaited(_openAiVoice.dispose());
    _player.dispose();
    _scrollController.dispose();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _greetOnOpen() async {
    final greeting = _timeGreeting();
    _addMsg('AI: $greeting');

    if (!widget.settings.speakReplies) return;
    await _speakOpenAiLocalTtsLine(greeting);
    await _finishOpenAiLocalTtsResponse();
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
    return 'You are RoadDogg, an AI co-pilot for professional truck drivers. '
        'Be brief when you can, but write complete sentences and thoughts—the '
        'app will read your text aloud with device text-to-speech. '
        'The driver\'s name is $displayName. '
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
      onUserTurnBoundary: () {
        if (!mounted) return;
        // New user utterance: stop reading any previous assistant reply.
        unawaited(_hardStopOpenAiLocalTtsQueue());
        setState(() => _openAiUserIdx = null);
      },
      onAssistantTurnBoundary: () {
        if (!mounted) return;
        // New assistant item: drop queued lines from the prior item (chain reset is not enough).
        unawaited(_hardStopOpenAiLocalTtsQueue());
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
        _feedOpenAiLocalTts(d);
      },
      onAssistantPcmDelta: (_) {
        // Session is text-only; server should not send PCM.
      },
      onAssistantResponseDone: () {
        if (!mounted) return;
        _flushOpenAiLocalTtsTail();
        _openAiTtsChain = _openAiTtsChain
            .then((_) => _finishOpenAiLocalTtsResponse())
            .catchError((Object e, StackTrace st) {
          debugPrint('OpenAI local TTS finish: $e\n$st');
        });
      },
    );

    bool ok = false;
    try {
      ok = await _openAiVoice.startContinuousListening(
        apiKey: OpenaiRealtimeVoiceController.apiKeyFromEnv!,
        voice: OpenaiRealtimeVoiceController.voiceFromSettings(
          widget.settings.voice,
        ),
        instructions: _buildRealtimeInstructions(),
      );
    } catch (e, st) {
      // Thrown errors bypass _rtLog; surface here so `flutter run` shows the cause.
      debugPrint('OpenaiRealtimeVoice startContinuousListening threw: $e');
      debugPrint(st.toString());
      if (!mounted) return;
      _addErr('Voice chat error: $e');
      return;
    }

    if (!mounted) return;
    if (ok) {
      setState(() => _openAiListening = true);
    } else {
      _addErr('Could not start voice chat (mic permission or connection).');
    }
  }

  Future<void> _stopOpenAiVoiceSession() async {
    await _resetOpenAiPlaybackSource(stopPlayer: true);
    await _openAiVoice.stopContinuousListening();
    if (!mounted) return;
    setState(() {
      _openAiListening = false;
      _openAiUserIdx = null;
      _openAiAiIdx = null;
    });
  }

  Future<void> _interruptOpenAiAssistant() async {
    final now = DateTime.now();
    if (_lastOpenAiInterruptTap != null &&
        now.difference(_lastOpenAiInterruptTap!) <
            const Duration(milliseconds: 500)) {
      return;
    }
    _lastOpenAiInterruptTap = now;
    await _resetOpenAiPlaybackSource(stopPlayer: true);
    await _openAiVoice.cancelAssistant();
  }

  Future<void> _initOpenAiFlutterTts() async {
    if (kIsWeb) return;
    try {
      await _openAiFlutterTts.setLanguage('en-US');
      await _openAiFlutterTts.setSpeechRate(0.5);
      await _openAiFlutterTts.setVolume(1.0);
      await _openAiFlutterTts.setPitch(1.0);
      await _openAiFlutterTts.awaitSpeakCompletion(true);
    } catch (e, st) {
      debugPrint('OpenAI FlutterTts init: $e\n$st');
    }
  }

  void _feedOpenAiLocalTts(String chunk) {
    if (!widget.settings.speakReplies || !widget.settings.ttsEnabled) {
      return;
    }
    if (chunk.isEmpty) return;
    _openAiTtsRemainder += chunk;
    for (;;) {
      final m = _openAiTtsSentence.firstMatch(_openAiTtsRemainder);
      if (m == null) break;
      final sentence = m.group(1)!.trim();
      _openAiTtsRemainder = _openAiTtsRemainder.substring(m.end);
      if (sentence.isNotEmpty) {
        _enqueueOpenAiLocalTts(sentence);
      }
    }
  }

  void _flushOpenAiLocalTtsTail() {
    if (!widget.settings.speakReplies || !widget.settings.ttsEnabled) {
      _openAiTtsRemainder = '';
      return;
    }
    final tail = _openAiTtsRemainder.trim();
    _openAiTtsRemainder = '';
    if (tail.isNotEmpty) {
      _enqueueOpenAiLocalTts(tail);
    }
  }

  void _enqueueOpenAiLocalTts(String line) {
    final t = line.trim();
    if (t.isEmpty) return;
    final gen = _openAiLocalTtsGen;
    _openAiTtsChain = _openAiTtsChain
        .then((_) async {
      if (!mounted || gen != _openAiLocalTtsGen) return;
      await _speakOpenAiLocalTtsLine(t);
    }).catchError((Object e, StackTrace st) {
      debugPrint('OpenAI local TTS: $e\n$st');
    });
  }

  Future<void> _speakOpenAiLocalTtsLine(String text) async {
    if (!mounted) return;
    if (!widget.settings.speakReplies || !widget.settings.ttsEnabled) {
      return;
    }
    try {
      if (_openAiAssistantPlaybackDepth == 0) {
        _enterOpenAiAssistantLocalPlayback();
      }
      await _openAiFlutterTts.speak(text);
    } catch (e, st) {
      debugPrint('OpenAI flutter_tts.speak failed: $e\n$st');
    }
  }

  Future<void> _finishOpenAiLocalTtsResponse() async {
    if (!mounted) return;
    if (_openAiAssistantPlaybackDepth > 0) {
      _leaveOpenAiAssistantLocalPlayback();
    }
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
    _openAiSuppressTailTimer = Timer(const Duration(milliseconds: 320), () {
      _openAiSuppressTailTimer = null;
      if (!mounted || _openAiAssistantPlaybackDepth != 0) return;
      _openAiVoice.setSuppressMicToServer(false);
    });
  }

  /// Stops [just_audio], clears OpenAI TTS queue (generation bump), and stops the TTS engine.
  Future<void> _hardStopOpenAiLocalTtsQueue() async {
    _openAiLocalTtsGen++;
    _openAiTtsRemainder = '';
    _openAiTtsChain = Future<void>.value();
    _openAiSuppressTailTimer?.cancel();
    _openAiSuppressTailTimer = null;
    _openAiAssistantPlaybackDepth = 0;
    _openAiVoice.setSuppressMicToServer(false);
    try {
      await _openAiFlutterTts.stop();
    } catch (_) {}
  }

  Future<void> _resetOpenAiPlaybackSource({required bool stopPlayer}) async {
    if (stopPlayer) {
      try {
        await _player.stop();
      } catch (_) {}
    }
    await _hardStopOpenAiLocalTtsQueue();
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

    int? aiIndex;
    try {
      _addMsg('AI: ');
      aiIndex = _msgs.length - 1;
      final bubbleIdx = aiIndex;

      final handled = await _handleImmediateIntent(t);
      if (handled) {
        if (mounted) {
          setState(() {
            _msgs[bubbleIdx] =
                _msgs[bubbleIdx] == 'AI: ' ? 'AI: OK' : _msgs[bubbleIdx];
          });
        }
        return;
      }

      final reply = await _openAiText.reply(userText: t);
      if (!mounted) return;
      setState(() {
        _msgs[bubbleIdx] = 'AI: $reply';
      });
      _scrollToBottom();
      if (widget.settings.speakReplies && widget.settings.ttsEnabled) {
        _enqueueOpenAiLocalTts(reply);
        _flushOpenAiLocalTtsTail();
        await _finishOpenAiLocalTtsResponse();
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
    final mapsHandled = _handleImmediateMapIntent(rawText);
    if (mapsHandled) return true;

    final settingsHandled = _handleImmediateSettingsIntent(rawText);
    if (settingsHandled) return true;

    final logsHandled = _handleImmediateLogsIntent(rawText);
    if (logsHandled) return true;

    final weatherHandled = _handleImmediateWeatherIntent(rawText);
    if (weatherHandled) return true;

    return false;
  }

  bool _handleImmediateMapIntent(String rawText) {
    final text = rawText.trim();
    final lower = text.toLowerCase();
    if (text.isEmpty) return false;

    const prefixes = [
      'find ',
      'find me ',
      'show me ',
      'take me to ',
      'go to ',
      'search for ',
      'look for ',
      'pull up ',
    ];
    for (final p in prefixes) {
      if (lower.startsWith(p)) {
        mapbus.MapCommandBus.instance.search(text);
        _addMsg('AI: Opening maps.');
        return true;
      }
    }

    const keywords = [
      'truck stop',
      'truck stops',
      'truckstop',
      'truckstops',
      'nearby truck',
      'fuel',
      'rest area',
      'rest areas',
      'hospital',
      'walmart',
      'chick-fil-a',
      "love's",
      'loves',
      'pilot',
      'flying j',
      'petro',
      'ta ',
      'ta truck stop',
      'parking',
      'food',
      'repair',
      'repairs',
      'in n out',
      'restaurant',
    ];

    for (final k in keywords) {
      if (lower.contains(k)) {
        mapbus.MapCommandBus.instance.search(text);
        _addMsg('AI: Opening maps.');
        return true;
      }
    }

    return false;
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
              color: isDark ? const Color(0x22000000) : const Color(0x12000000),
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
