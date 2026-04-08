// lib/services/AI/navigation_coordinator.dart
// ✅ v7.3 — Flutter silencioso al navegar · Sin "Sistema detenido" · TTS coordinado

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'dart:async';

import '../../models/shared_models.dart';
import '../../config/api_config.dart';
import '../tts_service.dart';
import '../unity_bridge_service.dart';
import 'conversation_service.dart';
import 'integrated_voice_command_service.dart';
import 'wake_word_service.dart';
import 'ai_mode_controller.dart';

enum CoordinatorState {
  idle,
  wakeWordDetected,
  listeningCommand,
  processing,
  speaking,
}

class NavigationCoordinator {
  static final NavigationCoordinator _instance =
      NavigationCoordinator._internal();
  factory NavigationCoordinator() => _instance;
  NavigationCoordinator._internal();

  // ─── Logging ──────────────────────────────────────────────────────────────
  static void _log(String msg) {
    assert(() {
      debugPrint('[NavCoord] $msg');
      return true;
    }());
  }

  static void _logError(String msg) => debugPrint('[NavCoord] ❌ $msg');

  // ─── Dependencias ─────────────────────────────────────────────────────────

  final ConversationService           _conversationService = ConversationService();
  final IntegratedVoiceCommandService _voiceService        = IntegratedVoiceCommandService();
  final WakeWordService               _wakeWordService     = WakeWordService();
  final TTSService                    _ttsService          = TTSService();
  final AIModeController              _aiModeController    = AIModeController();

  UnityBridgeService? _unityBridge;

  // ─── Estado ───────────────────────────────────────────────────────────────

  CoordinatorState _state             = CoordinatorState.idle;
  bool             _isInitialized     = false;
  bool             _isActive          = false;
  bool             _wakeWordAvailable = false;

  bool _navigationExecuted = false;
  bool _navigationActive   = false;

  Completer<VoiceStatusInfo?>? _voiceStatusCompleter;

  Timer? _commandTimeoutTimer;

  static const Duration _commandTimeout      = Duration(seconds: 15);
  static const Duration _ttsEchoDelay        = Duration(milliseconds: 300);
  static const Duration _voiceStatusTimeout  = Duration(seconds: 3);

  NavigationIntent? _currentIntent;
  NavigationMode    _mode = NavigationMode.eventBased;
  String?           _lastUserInput;
  String            _partialText = '';

  // ─── Callbacks públicos ───────────────────────────────────────────────────

  Function(String)?           onStatusUpdate;
  Function(NavigationIntent)? onIntentDetected;
  Function(NavigationIntent)? onCommandExecuted;
  Function(String)?           onCommandRejected;
  Function(String)?           onConversationalResponse;

  TTSService get ttsService => _ttsService;

  // ─── Inicialización ───────────────────────────────────────────────────────

  Future<void> initialize() async {
    if (_isInitialized) {
      _log('Ya inicializado — skip');
      return;
    }

    try {
      _log('Inicializando NavigationCoordinator v7.3...');

      await _ttsService.initialize();
      await _aiModeController.initialize();
      await _conversationService.initialize();
      await _initializeWakeWord();
      await _voiceService.initialize();

      _setupServiceCallbacks();

      _isInitialized = true;
      _state = CoordinatorState.idle;

      _log('SISTEMA v7.3 INICIALIZADO — '
          'WakeWord: ${_wakeWordAvailable ? "ACTIVO" : "INACTIVO"} — '
          'Modo: ${_aiModeController.getModeDescription()}');

      onStatusUpdate?.call(
        _wakeWordAvailable
            ? '✅ Di "Oye COMPAS" para comenzar'
            : '✅ Presiona Play para hablar',
      );
    } catch (e, stack) {
      _logError('Error inicializando: $e\n$stack');
      throw Exception('Fallo al inicializar: $e');
    }
  }

  void attachUnityBridge(UnityBridgeService bridge) {
    _unityBridge = bridge;
    bridge.onVoiceStatusReceived = _onVoiceStatusReceived;

    // sync TTS → Unity
    _ttsService.onTTSStatusChanged = (isSpeaking, priority) {
      bridge.sendTTSStatus(
        isSpeaking: isSpeaking,
        priority: priority,
      );
    };

    // ✅ NUEVO — permitir que voiceService espere al TTS
    _voiceService.isTtsSpeaking = () => _ttsService.isSpeaking;

    // ✅ NUEVO — conectar wake word al voice service
    if (_wakeWordAvailable) {
      _voiceService.attachWakeWordService(_wakeWordService);
    }

    _log('UnityBridgeService conectado + TTS sync');
  }

  // ─── voice_status ─────────────────────────────────────────────────────────

  void _onVoiceStatusReceived(VoiceStatusInfo info) {
    _log('voice_status: $info');
    _voiceStatusCompleter?.complete(info);
    _voiceStatusCompleter = null;
  }

  Future<VoiceStatusInfo?> _fetchVoiceStatus() async {
    if (_unityBridge == null) return null;

    _voiceStatusCompleter = Completer<VoiceStatusInfo?>();
    _unityBridge!.requestVoiceStatus();

    try {
      return await _voiceStatusCompleter!.future
          .timeout(_voiceStatusTimeout, onTimeout: () {
        _log('voice_status timeout');
        return null;
      });
    } catch (e) {
      _logError('_fetchVoiceStatus: $e');
      return null;
    } finally {
      _voiceStatusCompleter = null;
    }
  }

  String _buildVoiceStatusPhrase(VoiceStatusInfo info) {
    if (!info.isGuiding && !info.isPreprocessing) {
      return 'No hay navegación activa.';
    }
    if (info.isPreprocessing) {
      return 'Calculando la ruta'
          '${info.destination.isNotEmpty ? " a ${info.destination}" : ""}. '
          'Un momento.';
    }

    final sb = StringBuffer();
    if (info.destination.isNotEmpty)    sb.write('Vas hacia ${info.destination}. ');
    if (info.remainingSteps > 0)        sb.write('Quedan ${info.remainingSteps} pasos. ');
    if (info.nextInstruction.isNotEmpty) sb.write('Próxima indicación: ${info.nextInstruction}');
    else if (info.ttsBusy)              sb.write('La guía de voz está hablando.');

    final result = sb.toString().trim();
    return result.isNotEmpty ? result : 'Navegación activa.';
  }

  // ─── Wake word ────────────────────────────────────────────────────────────

  Future<void> _initializeWakeWord() async {
    try {
      await _wakeWordService.initialize(
        accessKey: 'speech_to_text_no_key_needed_v3',
        config: const WakeWordConfig.custom(
          keyword:   'oye compas',
          modelPath: 'assets/wake_words/oye_compas_android.ppn',
        ),
        sensitivity: 0.7,
      );

      _wakeWordService.onWakeWordDetected = _onWakeWordDetected;
      _wakeWordService.onError = (error) {
        _logError('Wake word error: $error');
        onStatusUpdate?.call('Error wake word: $error');
      };

      _wakeWordAvailable = true;
      _log('Wake word "Oye COMPAS" activo');
    } catch (e, stack) {
      _logError('Wake word no disponible: $e\n$stack');
      _wakeWordAvailable = false;
    }
  }

  // ─── Callbacks de voz ─────────────────────────────────────────────────────

  void _setupServiceCallbacks() {
    String? capturedText;

    _voiceService.onPartialResult = (partialText) {
      if (_state != CoordinatorState.listeningCommand) return;
      _partialText = partialText;
      onStatusUpdate?.call('🎤 "$partialText"');
      _resetCommandTimeout();
    };

    _voiceService.onCommandDetected = (intent) {
      capturedText = intent.suggestedResponse;
    };

    _voiceService.onCommandExecuted = (intent) async {
      if (_state != CoordinatorState.listeningCommand) {
        capturedText = null;
        _partialText = '';
        return;
      }

      final userText = (capturedText != null && capturedText!.isNotEmpty)
          ? capturedText!
          : (_partialText.isNotEmpty ? _partialText : intent.suggestedResponse);
      capturedText = null;
      _partialText = '';

      _commandTimeoutTimer?.cancel();
      await _processUserInput(userText);
    };

    _voiceService.onCommandRejected = (reason) {
      capturedText = null;
      _partialText = '';
      _returnToIdle();
    };
  }

  // ─── Timer dinámico ───────────────────────────────────────────────────────

  void _resetCommandTimeout() {
    _commandTimeoutTimer?.cancel();
    _commandTimeoutTimer = Timer(_commandTimeout, () {
      if (_partialText.isNotEmpty) {
        final textToProcess = _partialText;
        _partialText = '';
        _processUserInput(textToProcess);
      } else {
        _returnToIdle();
      }
    });
  }

  // ─── Fuzzy matching de waypoints ──────────────────────────────────────────

  String _normalizeWaypoint(String text) => text
      .toLowerCase()
      .replaceAll('°', ' ')
      .replaceAll('á', 'a').replaceAll('é', 'e')
      .replaceAll('í', 'i').replaceAll('ó', 'o')
      .replaceAll('ú', 'u').replaceAll('ñ', 'n')
      .replaceAll(RegExp(r'[^\w\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  String? _resolveWaypointName(String spoken, List<WaypointInfo> waypoints) {
    if (waypoints.isEmpty) return null;

    final input = _normalizeWaypoint(spoken);

    for (final wp in waypoints) {
      if (_normalizeWaypoint(wp.name) == input) return wp.name;
    }

    for (final wp in waypoints) {
      final norm = _normalizeWaypoint(wp.name);
      if (norm.contains(input) || input.contains(norm)) return wp.name;
    }

    final inputWords = input.split(' ')
        .where((w) => w.length >= 3)
        .toSet();

    String? bestMatch;
    int bestScore = 0;

    for (final wp in waypoints) {
      final wpWords = _normalizeWaypoint(wp.name)
          .split(' ')
          .where((w) => w.length >= 3)
          .toSet();
      final score = inputWords.intersection(wpWords).length;
      if (score > bestScore) {
        bestScore = score;
        bestMatch = wp.name;
      }
    }

    return bestScore >= 1 ? bestMatch : null;
  }

  // ─── Procesamiento principal ──────────────────────────────────────────────

  Future<void> _processUserInput(String userInput) async {

    if (userInput.toLowerCase().contains('oye compa') ||
        userInput.toLowerCase().contains('te escucho')) {
      _log('🧹 Ignorando eco del sistema');
      await _returnToIdle();
      return;
    }

    if (_state != CoordinatorState.listeningCommand &&
        _state != CoordinatorState.processing) {
      return;
    }

    if (userInput.trim().isEmpty) {
      await _returnToIdle();
      return;
    }

    _lastUserInput      = userInput;
    _navigationExecuted = false;
    _log('Usuario: "$userInput"');
    onStatusUpdate?.call('Procesando: "$userInput"');

    try {
      _state = CoordinatorState.processing;

      if (_voiceService.isListening) {
        await _voiceService.stopListening();
        await _voiceService.sessionManager.waitUntilIdle();
      }

      await _aiModeController.verifyInternetNow();

      final response = await _conversationService.chat(userInput);
      _log('COMPAS (${response.type.name}): "${response.message}"');

      _state = CoordinatorState.speaking;

      // ── Intents con navegación ────────────────────────────────────────────

      if (response.shouldNavigate && response.intent != null) {
        final target = response.intent!.target;

        // ── REPEAT ──────────────────────────────────────────────────────────
        if (target == '__unity:repeat_instruction') {
          _unityBridge?.repeatInstruction();
          await _completeAndReturnToIdle(suppressSTT: _navigationActive);
          return;
        }

        // ── STATUS ──────────────────────────────────────────────────────────
        if (target == '__unity:voice_status') {
          final statusInfo = await _fetchVoiceStatus();
          final phrase = statusInfo != null
              ? _buildVoiceStatusPhrase(statusInfo)
              : 'No pude obtener el estado.';
          // Status es conversacional: Flutter habla.
          await _ttsService.speak(phrase, interrupt: false);
          await _ttsService.waitForCompletion();
          onConversationalResponse?.call(phrase);
          await _completeAndReturnToIdle(suppressSTT: _navigationActive);
          return;
        }

        // ── STOP_VOICE ───────────────────────────────────────────────────────
        if (target == '__unity:stop_voice') {
          _unityBridge?.stopVoice();
          // Confirmación breve por Flutter (Unity ya no habla nada)
          final confirmMsg = 'Guía de voz detenida.';
          await _ttsService.speak(confirmMsg, interrupt: false);
          await _ttsService.waitForCompletion();
          await _completeAndReturnToIdle(suppressSTT: _navigationActive);
          return;
        }

        // ── Otros prefijos __unity:* (comandos internos) ─────────────────────
        if (target.startsWith('__unity:')) {
          // ✅ v7.3: Flutter NO habla. Unity gestiona su propio feedback.
          onIntentDetected?.call(response.intent!);
          await Future.delayed(_ttsEchoDelay);
          if (!_navigationExecuted) {
            _navigationExecuted = true;
            _navigationActive   = true;
            onCommandExecuted?.call(response.intent!);
          }
          return;
        }

        // ── NAVEGACIÓN NORMAL ─────────────────────────────────────────────────
        final waypoints = _unityBridge?.cachedWaypoints ?? [];
        final resolved  = _resolveWaypointName(target, waypoints);

        if (resolved == null) {
          // No hay match — Flutter habla el error (Unity no sabe qué decir)
          final names = waypoints.isNotEmpty
              ? waypoints.map((w) => w.name).join(', ')
              : 'ninguno cargado aún';
          final errMsg = waypoints.isNotEmpty
              ? 'No encontré ese destino. Los disponibles son: $names.'
              : 'Aún no tengo la lista de destinos. Intenta en un momento.';

          _logError('Waypoint no resuelto: "$target" — disponibles: $names');
          await _ttsService.speak(errMsg, interrupt: true);
          await _ttsService.waitForCompletion();
          await _completeAndReturnToIdle(suppressSTT: _navigationActive);
          return;
        }

        _log('Waypoint resuelto: "$target" → "$resolved"');

        final resolvedIntent = NavigationIntent(
          type:              response.intent!.type,
          target:            resolved,
          priority:          response.intent!.priority,
          suggestedResponse: response.intent!.suggestedResponse,
        );

        // ✅ v7.3: Flutter NO habla aquí.
        // Unity hablará "Listo, vamos a X." cuando reciba navigate_to.
        // Solo notificamos la UI y ejecutamos el comando.
        onIntentDetected?.call(resolvedIntent);
        await Future.delayed(_ttsEchoDelay);

        if (!_navigationExecuted) {
          _navigationExecuted = true;
          _navigationActive   = true;
          onCommandExecuted?.call(resolvedIntent);
        }

        // Volvemos a idle/wake-word pero mantenemos suppressSTT=true
        // porque la navegación sigue activa.
        await _completeAndReturnToIdle(suppressSTT: true);

      } else {
        // ── RESPUESTA CONVERSACIONAL (HELP, UNKNOWN, etc.) ────────────────────
        // Flutter habla cuando NO hay navegación involucrada.
        final bridgeReady = _unityBridge != null &&
            _unityBridge!.isReady &&
            response.message.isNotEmpty;

        if (bridgeReady) {
          // Usar Unity TTS con p=1 para no interrumpir instrucciones activas
          _unityBridge!.speakArbitraryText(
            response.message,
            priority: 1,
            interrupt: false,
          );
        } else {
          await _ttsService.speak(response.message, interrupt: false);
          await _ttsService.waitForCompletion();
        }

        onConversationalResponse?.call(response.message);
        await _completeAndReturnToIdle(suppressSTT: _navigationActive);
      }

    } catch (e, stack) {
      _logError('Error procesando entrada: $e\n$stack');
      _state = CoordinatorState.speaking;

      await _ttsService.speak(
        'Lo siento, hubo un error. ¿Puedes repetir?',
        interrupt: true,
      );
      await _ttsService.waitForCompletion();
      _navigationActive = false;
      await _returnToIdle();
    }
  }

  // ─── Wake word ────────────────────────────────────────────────────────────

  void _onWakeWordDetected() async {
    if (_state != CoordinatorState.idle) return;

    _log('"Oye COMPAS" detectado');
    HapticFeedback.heavyImpact();

    // ✅ NUEVO — activar modo wake word
    _voiceService.setWakeWordModeActive(true);

    await _transitionToListeningCommand();
  }

  Future<void> _transitionToListeningCommand() async {
    try {
      _state = CoordinatorState.wakeWordDetected;

      if (_voiceService.isListening || !_voiceService.sessionManager.isIdle) {
        await _voiceService.stopListening();
        await _voiceService.sessionManager.waitUntilIdle(
          timeout: const Duration(seconds: 2),
        );
      }

      if (_wakeWordService.isListening) {
        await _wakeWordService.pause();
        await Future.delayed(const Duration(milliseconds: 300));
      }

      _state = CoordinatorState.speaking;

      final greeting = _getRandomGreeting();
      await _ttsService.speak(greeting, interrupt: true);
      await _ttsService.waitForCompletion();

      // 🔥 CRÍTICO: esperar a que el audio REAL deje de sonar
            while (_ttsService.isSpeaking) {
              await Future.delayed(const Duration(milliseconds: 50));
            }

      // buffer extra realista (hardware/audio)
            await Future.delayed(const Duration(milliseconds: 500));

      _state = CoordinatorState.listeningCommand;
      _partialText = '';

      if (!_voiceService.sessionManager.canStart()) {
        _logError('Session manager no permite inicio');
        await _returnToIdle();
        return;
      }

      _voiceService.setWakeWordActive(false);
      if (_ttsService.isSpeaking) {
        _log('⛔ Bloqueado: TTS aún activo antes de STT');
        return;
      }
      await _voiceService.startListening();
      onStatusUpdate?.call('Escuchando...');
      _resetCommandTimeout();
    } catch (e) {
      _logError('Error en transición: $e');
      await _returnToIdle();
    }
  }

  // ─── Utilidades ───────────────────────────────────────────────────────────

  String _getRandomGreeting() {
    const greetings = [
  'Dime, te escucho',
  'Estoy listo, dime',
  '¿En qué puedo ayudarte exactamente?',
];
    return greetings[DateTime.now().millisecond % greetings.length];
  }

  Future<void> _returnToIdle() async {
    if (_state == CoordinatorState.idle &&
        _wakeWordService.isListening &&
        _isActive) return;

    try {
      _commandTimeoutTimer?.cancel();
      _partialText = '';

      if (_voiceService.isListening || !_voiceService.sessionManager.isIdle) {
        await _voiceService.stopListening();
        await _voiceService.sessionManager.waitUntilIdle(
          timeout: const Duration(seconds: 3),
        );
      }

      if (_ttsService.isSpeaking) await _ttsService.stop();

      await Future.delayed(const Duration(milliseconds: 400));
      _state = CoordinatorState.idle;

      if (_wakeWordAvailable && _isActive) {
        _voiceService.setWakeWordActive(true);
        await _voiceService.sessionManager.waitUntilIdle(
          timeout: const Duration(seconds: 2),
        );
        await Future.delayed(const Duration(milliseconds: 800));
        await _wakeWordService.resume();
        onStatusUpdate?.call('Esperando "Oye COMPAS"...');
      }
    } catch (e) {
      _logError('Error crítico volviendo a IDLE: $e');
      _state = CoordinatorState.idle;
      _voiceService.sessionManager.forceReset();
    }
  }

  Future<void> _completeAndReturnToIdle({bool suppressSTT = false}) async {
    _commandTimeoutTimer?.cancel();
    _partialText = '';

    if (_voiceService.isListening || !_voiceService.sessionManager.isIdle) {
      await _voiceService.stopListening();
      await _voiceService.sessionManager.waitUntilIdle();
    }

    _state = CoordinatorState.idle;

    if (_wakeWordAvailable && _isActive) {
      // ✅ Siempre reanudar wake word, independiente de suppressSTT
      try {
        _voiceService.setWakeWordActive(true);
        await _wakeWordService.resume();
        onStatusUpdate?.call(
          suppressSTT ? 'Navegando... (di "Oye COMPAS")' : 'Esperando "Oye COMPAS"...',
        );
      } catch (e) {
        _logError('Error reanudando wake word: $e');
      }
    } else if (!suppressSTT && _isActive) {
      // Sin wake word disponible: reactivar STT directo
      try {
        await Future.delayed(const Duration(milliseconds: 600));
        if (_voiceService.sessionManager.canStart()) {
          await _voiceService.startListening();
          _resetCommandTimeout();
          onStatusUpdate?.call('Escuchando...');
        }
      } catch (e) {
        _logError('Error reactivando STT: $e');
      }
    } else {
      onStatusUpdate?.call('Navegando...');
    }
  }

  // ─── API pública ──────────────────────────────────────────────────────────

  void resetNavigation() {
    _navigationActive   = false;
    _navigationExecuted = false;
    _currentIntent      = null;
    _log('Navegación terminada — STT reactivado');

    if (!_isActive) return;

    if (!_wakeWordAvailable) {
      _completeAndReturnToIdle(suppressSTT: false);
    }
  }

  Future<void> start({NavigationMode mode = NavigationMode.eventBased}) async {
    if (!_isInitialized) throw Exception('No inicializado');
    if (_isActive) return;

    try {
      _mode     = mode;
      _isActive = true;
      _state    = CoordinatorState.idle;

      if (_wakeWordAvailable) {
        _voiceService.setWakeWordActive(true);
        await _wakeWordService.start();
        onStatusUpdate?.call('Di "Oye COMPAS"');
        await Future.delayed(const Duration(milliseconds: 500));
        await _ttsService.speak('Sistema conversacional activado');
        await _ttsService.waitForCompletion();
      } else {
        _voiceService.setWakeWordActive(false);
        await _voiceService.sessionManager.waitUntilIdle();
        await Future.delayed(const Duration(milliseconds: 500));
        await _voiceService.startListening();
        _resetCommandTimeout();
        onStatusUpdate?.call('Escuchando...');
      }
    } catch (e) {
      _isActive = false;
      _logError('Error start: $e');
      rethrow;
    }
  }

  Future<void> stop() async {
    if (!_isActive) return;

    try {
      _isActive         = false;
      _navigationActive = false;

      _voiceService.setWakeWordModeActive(false);

      _commandTimeoutTimer?.cancel();
      _partialText = '';

      _voiceStatusCompleter?.complete(null);
      _voiceStatusCompleter = null;

      _voiceService.setWakeWordActive(false);

      if (_wakeWordService.isListening) await _wakeWordService.stop();
      if (_voiceService.isListening) {
        await _voiceService.stopListening();
        await _voiceService.sessionManager.waitUntilIdle();
      }

      _state = CoordinatorState.idle;

      // ✅ v7.3: eliminado _ttsService.speak('Sistema detenido').
      //          Era ruido innecesario sin valor para el usuario.

    } catch (e) {
      _logError('Error stop: $e');
    }
  }

  void setMode(NavigationMode mode) => _mode = mode;

  Future<void> setWakeWordSensitivity(double sensitivity) async {
    if (!_wakeWordAvailable) return;
    try {
      final wasActive = _isActive;
      if (wasActive) await stop();
      await _wakeWordService.setSensitivity(
          sensitivity, ApiConfig.picovoiceAccessKey);
      if (wasActive) await start(mode: _mode);
    } catch (e) {
      _logError('Error sensibilidad: $e');
    }
  }

  void clearConversationHistory() {
    _conversationService.clearHistory();
  }

  Map<String, dynamic> getStatistics() => {
    'voice_service':        _voiceService.getStatistics(),
    'conversation_service': _conversationService.getStatistics(),
    'wake_word':            _wakeWordAvailable
        ? _wakeWordService.getStatistics()
        : {'enabled': false},
    'ai_mode':              _aiModeController.getStatistics(),
    'system': {
      'is_active':              _isActive,
      'mode':                   _mode.toString(),
      'state':                  _state.name,
      'wake_word_available':    _wakeWordAvailable,
      'is_speaking':            _ttsService.isSpeaking,
      'last_user_input':        _lastUserInput,
      'navigation_active':      _navigationActive,
      'unity_bridge_connected': _unityBridge != null,
      'waypoints_cached':       _unityBridge?.cachedWaypoints.length ?? 0,
    },
  };

  void reset() {
    _voiceService.resetFSM();
    _voiceService.sessionManager.forceReset();
    _voiceService.setWakeWordActive(_wakeWordAvailable && _isActive);
    if (_wakeWordAvailable) _wakeWordService.resetStatistics();
    clearConversationHistory();
    _currentIntent      = null;
    _lastUserInput      = null;
    _partialText        = '';
    _navigationExecuted = false;
    _navigationActive   = false;
    _voiceStatusCompleter?.complete(null);
    _voiceStatusCompleter = null;
    _state             = CoordinatorState.idle;
    _commandTimeoutTimer?.cancel();
  }

  void dispose() {
    stop();
    _commandTimeoutTimer?.cancel();
    _voiceStatusCompleter?.complete(null);
    _voiceStatusCompleter = null;
    if (_unityBridge != null) {
      _unityBridge!.onVoiceStatusReceived = null;
    }
    _voiceService.dispose();
    _wakeWordService.dispose();
    _ttsService.dispose();
    _conversationService.dispose();
    _aiModeController.dispose();
  }

  // ─── Getters ──────────────────────────────────────────────────────────────

  bool              get isInitialized     => _isInitialized;
  bool              get isActive          => _isActive;
  bool              get wakeWordAvailable => _wakeWordAvailable;
  NavigationMode    get currentMode       => _mode;
  NavigationIntent? get currentIntent     => _currentIntent;
  CoordinatorState  get state             => _state;
  bool              get isSpeaking        => _ttsService.isSpeaking;
  String?           get lastUserInput     => _lastUserInput;
  bool              get navigationActive  => _navigationActive;
  WakeWordService   get wakeWordService   => _wakeWordService;

  Future<void> speak(String message) async {
    if (message.isEmpty) return;
    await _ttsService.speak(message, interrupt: false);
  }
}