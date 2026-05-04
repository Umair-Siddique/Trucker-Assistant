import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:lottie/lottie.dart' as import_lottie;
import 'package:just_audio/just_audio.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../services/app_settings.dart';
import '../services/logs_command_bus.dart' as logsbus;
import '../services/map_command_bus.dart' as mapbus;
import '../services/map_navigation_command_bus.dart' as mapnavbus;
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

class _AvatarAssistantScreenState extends State<AvatarAssistantScreen>
    with TickerProviderStateMixin {
  late final AnimationController _pulseCtrl;
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
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
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
    _pulseCtrl.dispose();
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
    _openAiTtsChain = _openAiTtsChain.then((_) async {
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
    final mapsHandled = await _handleImmediateMapIntent(rawText);
    if (mapsHandled) return true;

    final settingsHandled = _handleImmediateSettingsIntent(rawText);
    if (settingsHandled) return true;

    final logsHandled = _handleImmediateLogsIntent(rawText);
    if (logsHandled) return true;

    final weatherHandled = _handleImmediateWeatherIntent(rawText);
    if (weatherHandled) return true;

    return false;
  }

  Future<bool> _handleImmediateMapIntent(String rawText) async {
    final text = rawText.trim();
    final lower = text.toLowerCase();
    if (text.isEmpty) return false;

    Future<bool> sendMapNav(mapnavbus.MapNavigateCommand command) async {
      final reply =
          await mapnavbus.MapNavigationCommandBus.instance.send(command);
      if (reply.message.trim().isNotEmpty) {
        _addMsg('AI: ${reply.message}');
      }
      return true;
    }

    String? extractDestination(String inputLower, String source) {
      final prefixes = <String>[
        'navigate to ',
        'take me to ',
        'start navigation to ',
        'start route to ',
        'route me to ',
      ];
      for (final p in prefixes) {
        if (inputLower.startsWith(p)) {
          return source.substring(p.length).trim();
        }
      }
      return null;
    }

    int? extractOrdinalIndex(String inputLower) {
      if (RegExp(r'\bfirst\b').hasMatch(inputLower)) return 1;
      if (RegExp(r'\bsecond\b').hasMatch(inputLower)) return 2;
      if (RegExp(r'\bthird\b').hasMatch(inputLower)) return 3;
      if (RegExp(r'\bfourth\b').hasMatch(inputLower)) return 4;
      if (RegExp(r'\bfifth\b').hasMatch(inputLower)) return 5;
      final m =
          RegExp(r'\b(\d+)(?:st|nd|rd|th)?\s+one\b').firstMatch(inputLower);
      if (m != null) return int.tryParse(m.group(1)!);
      return null;
    }

    final navDestination = extractDestination(lower, text);
    if (navDestination != null && navDestination.isNotEmpty) {
      return sendMapNav(
        mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.navigate,
          destinationQuery: navDestination,
        ),
      );
    }

    if (lower == 'start navigation' ||
        lower == 'start route' ||
        lower == 'navigate' ||
        lower == 'start navigation now') {
      return sendMapNav(
        const mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.navigate,
        ),
      );
    }

    final ord = extractOrdinalIndex(lower);
    if (ord != null &&
        (lower.contains('one') ||
            lower.contains('option') ||
            lower.contains('result'))) {
      return sendMapNav(
        mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.chooseResultByIndex,
          selectionIndex: ord,
        ),
      );
    }

    if (lower.startsWith('choose ') ||
        lower.startsWith('pick ') ||
        lower.startsWith('select ')) {
      final picked = text
          .replaceFirst(
              RegExp(r'^(choose|pick|select)\s+', caseSensitive: false), '')
          .trim();
      if (picked.isNotEmpty) {
        return sendMapNav(
          mapnavbus.MapNavigateCommand(
            action: mapnavbus.MapNavigationAction.chooseResultByName,
            selectionName: picked,
          ),
        );
      }
    }

    if (lower == 'correct' ||
        lower == 'confirm' ||
        lower == 'yes start route' ||
        lower == 'start route yes' ||
        lower == 'go ahead') {
      return sendMapNav(
        const mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.confirmStartRoute,
        ),
      );
    }

    if (lower == 'cancel' ||
        lower == 'cancel route' ||
        lower == 'cancel navigation') {
      return sendMapNav(
        const mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.cancelNavigation,
        ),
      );
    }

    if (lower.contains('stop navigation')) {
      return sendMapNav(
        const mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.stopNavigation,
        ),
      );
    }

    if (lower.contains('clear route')) {
      return sendMapNav(
        const mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.clearRoute,
        ),
      );
    }

    // "Go back to route / resume navigation / clear search results"
    final resumeNavPhrases = [
      'back to my route',
      'back to route',
      'back on route',
      'back to navigation',
      'back to my destination',
      'back to destination',
      'go back to destination',
      'go back to my destination',
      'go back to route',
      'go back to navigation',
      'take me back to my route',
      'take me back to navigation',
      'resume navigation',
      'resume route',
      'continue to destination',
      'continue my route',
      'continue navigation',
      'clear search',
      'clear results',
      'clear markers',
      'dismiss results',
      'hide results',
      'remove markers',
      'show my route',
      'focus on route',
      'focus on my route',
      'return to navigation',
      'return to route',
      'cancel search',
    ];
    if (resumeNavPhrases.any((p) => lower.contains(p))) {
      return sendMapNav(
        const mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.clearSearchResults,
        ),
      );
    }

    // "Find X along the route / along my way / on the way"
    final alongRoutePhrases = [
      ' along the route',
      ' along my route',
      ' along the way',
      ' along my way',
      ' on the way',
      ' on my way',
      ' on the route',
      ' during the route',
    ];
    for (final phrase in alongRoutePhrases) {
      if (lower.contains(phrase)) {
        final query = text.substring(0, lower.indexOf(phrase)).trim();
        final cleaned = query
            .replaceFirst(RegExp(r'^(find|find me|show me|look for|search for)\s+', caseSensitive: false), '')
            .trim();
        if (cleaned.isNotEmpty) {
          return sendMapNav(
            mapnavbus.MapNavigateCommand(
              action: mapnavbus.MapNavigationAction.searchAlongRoute,
              destinationQuery: cleaned,
            ),
          );
        }
        break;
      }
    }

    if (lower.contains('reroute') || lower.contains('re route')) {
      return sendMapNav(
        const mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.reroute,
        ),
      );
    }

    if (lower.contains('avoid toll')) {
      return sendMapNav(
        const mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.setAvoidTolls,
          enabled: true,
        ),
      );
    }
    if (lower.contains('use toll') || lower.contains('allow toll')) {
      return sendMapNav(
        const mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.setAvoidTolls,
          enabled: false,
        ),
      );
    }

    if (lower.contains('avoid highway')) {
      return sendMapNav(
        const mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.setAvoidHighways,
          enabled: true,
        ),
      );
    }
    if (lower.contains('use highway') || lower.contains('allow highway')) {
      return sendMapNav(
        const mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.setAvoidHighways,
          enabled: false,
        ),
      );
    }

    if (lower == 'eta' ||
        lower == 'eta?' ||
        lower.contains('what is the eta')) {
      return sendMapNav(
        const mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.queryEta,
        ),
      );
    }

    if (lower.contains('miles left') || lower.contains('how many miles')) {
      return sendMapNav(
        const mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.queryMilesLeft,
        ),
      );
    }

    if (lower.contains('next turn')) {
      return sendMapNav(
        const mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.queryNextTurn,
        ),
      );
    }

    if (lower == 'repeat that' ||
        lower == 'repeat' ||
        lower.contains('say that again')) {
      return sendMapNav(
        const mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.repeatInstruction,
        ),
      );
    }

    if (lower.contains('what\'s after this') ||
        lower.contains('what is after this')) {
      return sendMapNav(
        const mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.queryAfterThis,
        ),
      );
    }

    if (lower == 'zoom in' || lower.contains('zoom in')) {
      return sendMapNav(
        const mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.zoomIn,
        ),
      );
    }
    if (lower == 'zoom out' || lower.contains('zoom out')) {
      return sendMapNav(
        const mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.zoomOut,
        ),
      );
    }

    if (lower.contains('recenter') || lower.contains('center on me')) {
      return sendMapNav(
        const mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.recenter,
        ),
      );
    }

    if (lower.contains('reset compass') ||
        lower.contains('north up') ||
        lower.contains('face north') ||
        lower.contains('reset north') ||
        lower == 'compass') {
      return sendMapNav(
        const mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.resetCompass,
        ),
      );
    }

    if (lower.contains('what direction') ||
        lower.contains('which direction') ||
        lower.contains('what heading') ||
        lower.contains('my heading') ||
        lower.contains('am i heading') ||
        lower.contains('direction am i') ||
        lower == 'heading') {
      return sendMapNav(
        const mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.queryHeading,
        ),
      );
    }

    if (lower.contains('satellite')) {
      return sendMapNav(
        const mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.setMapTypeSatellite,
        ),
      );
    }
    if (lower.contains('terrain')) {
      return sendMapNav(
        const mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.setMapTypeTerrain,
        ),
      );
    }
    if (lower.contains('switch to map') || lower.contains('normal map')) {
      return sendMapNav(
        const mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.setMapTypeNormal,
        ),
      );
    }

    if (lower.contains('show traffic')) {
      return sendMapNav(
        const mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.setTraffic,
          enabled: true,
        ),
      );
    }
    if (lower.contains('hide traffic')) {
      return sendMapNav(
        const mapnavbus.MapNavigateCommand(
          action: mapnavbus.MapNavigationAction.setTraffic,
          enabled: false,
        ),
      );
    }

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

  // ── Strip stored prefix for display ──────────────────────────
  String _displayText(String msg) {
    if (msg.startsWith('AI: ')) return msg.substring(4);
    if (msg.startsWith('AI:')) return msg.substring(3);
    if (msg.startsWith('You: ')) return msg.substring(5);
    if (msg.startsWith('You:')) return msg.substring(4);
    if (msg.startsWith('ERROR: ')) return msg.substring(7);
    if (msg.startsWith('ERROR:')) return msg.substring(6);
    return msg;
  }

  Widget _buildBubble(String msg, bool isDark) {
    final isAi = _isAiMsg(msg);
    final isUser = _isUserMsg(msg);
    final isError = _isErrorMsg(msg);
    final displayText = _displayText(msg);
    final isTyping =
        (isAi || (!isUser && !isError)) && displayText.trim().isEmpty && _busy;

    final border = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE4E4E7);

    if (isUser) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8, left: 60),
        child: Align(
          alignment: Alignment.centerRight,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 290),
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF2C2C2E) : Colors.black,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
                bottomLeft: Radius.circular(20),
                bottomRight: Radius.circular(5),
              ),
            ),
            child: Text(
              displayText,
              style: TextStyle(
                color: isDark ? Colors.white : Colors.white,
                fontSize: 14.5,
                height: 1.45,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      );
    }

    if (isError) {
      final errBg = isDark ? const Color(0xFF2A1010) : const Color(0xFFFFF3F3);
      final errFg =
          isDark ? const Color(0xFFFF8080) : const Color(0xFFB91C1C);
      final errBorder =
          isDark ? const Color(0xFF5C1818) : const Color(0xFFFFD0D0);
      return Padding(
        padding: const EdgeInsets.only(bottom: 8, right: 40),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Container(
              width: 30,
              height: 30,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: errBg,
                shape: BoxShape.circle,
                border: Border.all(color: errBorder),
              ),
              child:
                  Icon(Icons.warning_amber_rounded, color: errFg, size: 15),
            ),
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 11),
                decoration: BoxDecoration(
                  color: errBg,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(20),
                    topRight: Radius.circular(20),
                    bottomLeft: Radius.circular(5),
                    bottomRight: Radius.circular(20),
                  ),
                  border: Border.all(color: errBorder),
                ),
                child: Text(
                  displayText,
                  style: TextStyle(
                    color: errFg,
                    fontSize: 13.5,
                    height: 1.45,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // AI message
    final aiBg = isDark ? const Color(0xFF1C1C1E) : Colors.white;
    final aiFg = isDark ? const Color(0xFFF2F2F7) : const Color(0xFF0F0F0F);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8, right: 60),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // AI avatar — gradient rounded square with "RD"
          Container(
            width: 30,
            height: 30,
            margin: const EdgeInsets.only(right: 8, bottom: 2),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF1C1C1E), Color(0xFF3A3A3C)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Center(
              child: Text(
                'RD',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ),
          Flexible(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
              decoration: BoxDecoration(
                color: aiBg,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(5),
                  topRight: Radius.circular(20),
                  bottomLeft: Radius.circular(20),
                  bottomRight: Radius.circular(20),
                ),
                border: Border.all(color: border),
                boxShadow: isDark
                    ? null
                    : [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
              ),
              child: isTyping
                  ? const _TypingDots()
                  : Text(
                      displayText,
                      style: TextStyle(
                        color: aiFg,
                        fontSize: 14.5,
                        height: 1.5,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mq = MediaQuery.of(context);

    final bg = isDark ? const Color(0xFF111111) : const Color(0xFFF2F4F7);
    final surface = isDark ? const Color(0xFF1C1C1E) : Colors.white;
    final headerBg = isDark ? const Color(0xFF161618) : Colors.white;
    final border = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE4E4E7);
    final textColor = isDark ? Colors.white : const Color(0xFF0F0F0F);
    final hintColor = isDark ? const Color(0xFF8E8E93) : const Color(0xFF8E8E93);

    final voiceActive = _openAiListening || _isHolding;

    final statusText = _openAiListening
        ? 'Hands-free  ·  tap mic to end  ·  Stop interrupts reply'
        : _isHolding
            ? 'Listening… release to send'
            : _busy
                ? 'Working on your request…'
                : _useOpenAiVoice
                    ? 'Tap mic for hands-free voice, or type below'
                    : 'Hold mic to talk, or type below';

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: bg,
        body: Column(
          children: [
            // ── Header (replaces AppBar for full status-bar control) ────
            Container(
              color: headerBg,
              child: SafeArea(
                bottom: false,
                child: Container(
                  height: 62,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: headerBg,
                    border: Border(
                      bottom: BorderSide(color: border, width: 0.8),
                    ),
                  ),
                  child: Row(
                    children: [
                      // AI logo
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF1C1C1E), Color(0xFF3A3A3C)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Center(
                          child: Text(
                            'RD',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'RoadDogg AI',
                              style: TextStyle(
                                color: textColor,
                                fontWeight: FontWeight.w800,
                                fontSize: 15,
                                letterSpacing: -0.2,
                              ),
                            ),
                            const SizedBox(height: 1),
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 300),
                              child: Text(
                                _openAiListening
                                    ? '● Live session active'
                                    : _isHolding
                                        ? '● Listening…'
                                        : _busy
                                            ? 'Thinking…'
                                            : 'AI Co-Pilot for Truckers',
                                key: ValueKey(_openAiListening
                                    ? 'live'
                                    : _isHolding
                                        ? 'hold'
                                        : _busy
                                            ? 'busy'
                                            : 'idle'),
                                style: TextStyle(
                                  color: _openAiListening
                                      ? Colors.green.shade600
                                      : _isHolding
                                          ? Colors.orange.shade600
                                          : hintColor,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Busy indicator
                      if (_busy && !voiceActive)
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.8,
                            color: hintColor,
                          ),
                        ),
                      if (_busy && !voiceActive) const SizedBox(width: 12),
                    ],
                  ),
                ),
              ),
            ),

            // ── Chat area ──────────────────────────────────────
            Expanded(
              child: _msgs.isEmpty
                  ? _AssistantEmptyState(
                      isDark: isDark,
                      onSuggestion: (text) => _sendText(text),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: EdgeInsets.fromLTRB(
                          16, 16, 16, mq.viewInsets.bottom + 12),
                      itemCount: _msgs.length,
                      itemBuilder: (_, i) {
                        return TweenAnimationBuilder<double>(
                          key: ValueKey(i),
                          tween: Tween(begin: 0.0, end: 1.0),
                          duration: const Duration(milliseconds: 260),
                          curve: Curves.easeOutCubic,
                          builder: (_, v, child) => Opacity(
                            opacity: v,
                            child: Transform.translate(
                              offset: Offset(0, 10 * (1 - v)),
                              child: child,
                            ),
                          ),
                          child: _buildBubble(_msgs[i], isDark),
                        );
                      },
                    ),
            ),

            // ── Bottom input area ──────────────────────────────
            Container(
              color: headerBg,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Input row
                      Container(
                        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
                        decoration: BoxDecoration(
                          color: bg,
                          borderRadius: BorderRadius.circular(26),
                          border: Border.all(color: border),
                          boxShadow: isDark
                              ? null
                              : [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.06),
                                    blurRadius: 10,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
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
                                  fontWeight: FontWeight.w500,
                                ),
                                decoration: InputDecoration(
                                  hintText: _busy
                                      ? 'Working…'
                                      : _openAiListening
                                          ? 'Voice chat active…'
                                          : _isHolding
                                              ? 'Listening…'
                                              : 'Ask RoadDogg anything…',
                                  hintStyle: TextStyle(
                                    color: hintColor,
                                    fontSize: 15,
                                  ),
                                  border: InputBorder.none,
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                    vertical: 9,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            // Stop button
                            if (_useOpenAiVoice && _openAiListening) ...[
                              _ActionButton(
                                onTap: _interruptOpenAiAssistant,
                                backgroundColor: Colors.red.shade600,
                                borderColor: Colors.red.shade700,
                                icon: Icons.stop_rounded,
                                iconColor: Colors.white,
                              ),
                              const SizedBox(width: 6),
                            ],
                            // Mic button with pulse ring
                            AnimatedBuilder(
                              animation: _pulseCtrl,
                              builder: (_, child) {
                                final pulse =
                                    voiceActive ? _pulseCtrl.value : 0.0;
                                return Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    if (voiceActive)
                                      Transform.scale(
                                        scale: 1.0 + 0.4 * pulse,
                                        child: Container(
                                          width: 42,
                                          height: 42,
                                          decoration: BoxDecoration(
                                            color: Colors.black.withValues(
                                                alpha: 0.22 * (1 - pulse)),
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                      ),
                                    child!,
                                  ],
                                );
                              },
                              child: GestureDetector(
                                onTap:
                                    _useOpenAiVoice ? _toggleOpenAiVoice : null,
                                onLongPressStart: _useOpenAiVoice
                                    ? null
                                    : (_) => _startHoldToTalk(),
                                onLongPressEnd: _useOpenAiVoice
                                    ? null
                                    : (_) => _stopHoldToTalkAndSend(),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  curve: Curves.easeOutCubic,
                                  width: 42,
                                  height: 42,
                                  decoration: BoxDecoration(
                                    color: voiceActive
                                        ? (_openAiListening
                                            ? Colors.green.shade700
                                            : Colors.black)
                                        : surface,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: voiceActive
                                          ? Colors.transparent
                                          : border,
                                    ),
                                  ),
                                  child: Icon(
                                    voiceActive ? Icons.mic : Icons.mic_none,
                                    color: voiceActive
                                        ? Colors.white
                                        : hintColor,
                                    size: 19,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            // Send button
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              child: _ActionButton(
                                onTap: _busy ? null : _sendTypedMessage,
                                backgroundColor:
                                    _busy ? const Color(0xFF2C2C2E) : Colors.black,
                                borderColor: Colors.transparent,
                                icon: Icons.arrow_upward_rounded,
                                iconColor:
                                    _busy ? Colors.white38 : Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      // Status hint
                      Text(
                        statusText,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: hintColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.1,
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
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Reusable action button (circular)
// ─────────────────────────────────────────────────────────────

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.onTap,
    required this.backgroundColor,
    required this.borderColor,
    required this.icon,
    required this.iconColor,
  });

  final VoidCallback? onTap;
  final Color backgroundColor;
  final Color borderColor;
  final IconData icon;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: backgroundColor,
          shape: BoxShape.circle,
          border: Border.all(color: borderColor),
        ),
        child: Icon(icon, color: iconColor, size: 20),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Typing dots indicator
// ─────────────────────────────────────────────────────────────

class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dotColor = isDark ? Colors.white54 : Colors.black38;

    return SizedBox(
      height: 20,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          final start = i * 0.25;
          final end = start + 0.4;
          final anim = CurvedAnimation(
            parent: _ctrl,
            curve: Interval(start.clamp(0, 1), end.clamp(0, 1),
                curve: Curves.easeInOut),
          );
          return AnimatedBuilder(
            animation: anim,
            builder: (_, __) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Transform.translate(
                offset: Offset(0, -4 * anim.value),
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: dotColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Empty / welcome state
// ─────────────────────────────────────────────────────────────

class _AssistantEmptyState extends StatelessWidget {
  const _AssistantEmptyState({
    required this.isDark,
    required this.onSuggestion,
  });

  final bool isDark;
  final void Function(String) onSuggestion;

  static const _suggestions = [
    ('Find nearby fuel stop', Icons.local_gas_station_outlined),
    ('Navigate to truck stop', Icons.local_shipping_outlined),
    ('Check the weather', Icons.cloud_outlined),
    ('Open my driver logs', Icons.article_outlined),
    ('Find a rest area', Icons.hotel_outlined),
    ('Show traffic', Icons.traffic_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    final surface = isDark ? const Color(0xFF1C1C1E) : Colors.white;
    final border = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE4E4E7);
    final textColor =
        isDark ? const Color(0xFFF2F2F7) : const Color(0xFF0F0F0F);
    final subtextColor = isDark ? const Color(0xFF8E8E93) : const Color(0xFF8E8E93);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Lottie animation as hero
            import_lottie.Lottie.asset(
              'assets/animations/AI Assistant.json',
              width: 160,
              height: 160,
              fit: BoxFit.contain,
              repeat: true,
            ),
            const SizedBox(height: 8),
            Text(
              'RoadDogg AI',
              style: TextStyle(
                color: textColor,
                fontSize: 24,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Your AI co-pilot for the long haul.\nAsk about routes, logs, weather, or the road ahead.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: subtextColor,
                fontSize: 13,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 28),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              decoration: BoxDecoration(
                color: surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: border),
                boxShadow: isDark
                    ? null
                    : [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'TRY ASKING',
                    style: TextStyle(
                      color: subtextColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.0,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _suggestions.map((s) {
                      return GestureDetector(
                        onTap: () => onSuggestion(s.$1),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 13, vertical: 9),
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF2C2C2E)
                                : const Color(0xFFF5F5F7),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: border),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(s.$2, size: 13, color: subtextColor),
                              const SizedBox(width: 6),
                              Text(
                                s.$1,
                                style: TextStyle(
                                  color: textColor,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
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
