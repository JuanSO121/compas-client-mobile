// lib/services/AI/navigation_coordinator.dart
// ✅ v4 — Expone TTSService + Fix Porcupine key agotada
//
//  CAMBIOS v3 → v4:
//  ─────────────────────────────────────────────────────────────────────────
//  + Getter `ttsService` expuesto para que VoiceNavigationService v3.0
//    pueda reutilizar el mismo engine TTS sin crear uno propio.
//    Esto elimina la competencia de dos FlutterTts en Android.
//
//  + Mejor mensaje de error cuando Porcupine falla por key agotada
//    (PorcupineActivationRefusedException). El sistema continúa en modo
//    manual sin bloquear la inicialización.
//
//  TODO LO DEMÁS ES IDÉNTICO A v3.

import 'package:logger/logger.dart';
import 'package:flutter/services.dart';
import 'dart:async';

import '../../models/shared_models.dart';
import '../../config/api_config.dart';
import '../tts_service.dart';
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

  final Logger _logger = Logger();

  final ConversationService           _conversationService = ConversationService();
  final IntegratedVoiceCommandService _voiceService        = IntegratedVoiceCommandService();
  final WakeWordService               _wakeWordService     = WakeWordService();
  final TTSService                    _ttsService          = TTSService();
  final AIModeController              _aiModeController    = AIModeController();

  CoordinatorState _state             = CoordinatorState.idle;
  bool             _isInitialized     = false;
  bool             _isActive          = false;
  bool             _wakeWordAvailable = false;

  Timer?           _commandTimeoutTimer;
  static const Duration _commandTimeout = Duration(seconds: 15);
  static const Duration _ttsEchoDelay   = Duration(milliseconds: 350);

  NavigationIntent? _currentIntent;
  NavigationMode    _mode = NavigationMode.eventBased;
  String?           _lastUserInput;
  String            _partialText = '';

  Function(String)?           onStatusUpdate;
  Function(NavigationIntent)? onIntentDetected;
  Function(NavigationIntent)? onCommandExecuted;
  Function(String)?           onCommandRejected;
  Function(String)?           onConversationalResponse;

  // ✅ v4: Getter expuesto para que VoiceNavigationService use el mismo engine
  TTSService get ttsService => _ttsService;

  // ─── Inicialización ───────────────────────────────────────────────────────

  Future<void> initialize() async {
    if (_isInitialized) {
      _logger.w('Ya inicializado');
      return;
    }

    try {
      _logger.i('🚀 Inicializando NavigationCoordinator v4...');

      await _ttsService.initialize();
      await _aiModeController.initialize();
      await _conversationService.initialize();
      await _initializeWakeWord();
      await _voiceService.initialize();

      _setupServiceCallbacks();

      _isInitialized = true;
      _state = CoordinatorState.idle;

      _logger.i('═══════════════════════════════════════');
      _logger.i('✅ SISTEMA CONVERSACIONAL v4 INICIALIZADO');
      _logger.i('   Wake Word : ${_wakeWordAvailable ? "✅ ACTIVO" : "❌ INACTIVO"}');
      _logger.i('   Modo IA   : ${_aiModeController.getModeDescription()}');
      _logger.i('   Timeout   : ${_commandTimeout.inSeconds}s (dinámico)');
      _logger.i('═══════════════════════════════════════');

      onStatusUpdate?.call(
        _wakeWordAvailable
            ? '✅ Di "Oye COMPAS" para comenzar'
            : '✅ Presiona Play para hablar',
      );

    } catch (e, stack) {
      _logger.e('❌ Error inicializando: $e');
      _logger.e('Stack: $stack');
      throw Exception('Fallo al inicializar: $e');
    }
  }

  Future<void> _initializeWakeWord() async {
    try {
      _logger.i('🔍 VERIFICANDO WAKE WORD...');

      final key = ApiConfig.picovoiceAccessKey;

      if (key.isEmpty || key.contains('...') || key.length < 20) {
        _logger.w('❌ Access Key inválido → Wake word desactivado');
        _wakeWordAvailable = false;
        return;
      }

      await _wakeWordService.initialize(
        accessKey: key,
        config: const WakeWordConfig.custom(
          keyword:   'oye compas',
          modelPath: 'assets/wake_words/oye_compas_android.ppn',
        ),
        sensitivity: 0.7,
      );

      _wakeWordService.onWakeWordDetected = _onWakeWordDetected;
      _wakeWordService.onError = (error) {
        _logger.e('❌ Wake word error: $error');
        onStatusUpdate?.call('Error wake word: $error');
      };

      _wakeWordAvailable = true;
      _logger.i('✅ Wake word "Oye COMPAS" ACTIVO');

    } catch (e, stack) {
      _logger.e('❌ Error wake word: $e\n$stack');
      _wakeWordAvailable = false;

      // ✅ v4: Mensaje específico para key agotada/expirada
      final errorStr = e.toString();
      if (errorStr.contains('ActivationRefused') ||
          errorStr.contains('ActivationLimit') ||
          errorStr.contains('00000136')) {
        _logger.w('⚠️ PICOVOICE KEY AGOTADA O EXPIRADA.');
        _logger.w('   Solución: Ve a console.picovoice.ai y genera una nueva key.');
        _logger.w('   El sistema continúa en modo manual (botón de micrófono).');
      }

      _logger.w('⚠️ Continuando sin wake word (modo manual activado)');
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
      _logger.d('📝 Texto capturado: "$capturedText"');
    };

    _voiceService.onCommandExecuted = (intent) async {
      if (_state != CoordinatorState.listeningCommand) {
        _logger.w('⚠️ Estado incorrecto al recibir resultado: $_state — ignorando');
        capturedText = null;
        _partialText = '';
        return;
      }

      final userText = (capturedText != null && capturedText!.isNotEmpty)
          ? capturedText!
          : (_partialText.isNotEmpty ? _partialText : intent.suggestedResponse);
      capturedText  = null;
      _partialText  = '';

      _commandTimeoutTimer?.cancel();
      await _processUserInput(userText);
    };

    _voiceService.onCommandRejected = (reason) {
      _logger.w('⛔ Rechazado: $reason');
      capturedText = null;
      _partialText = '';
      _returnToIdle();
    };
  }

  // ─── Timer dinámico ───────────────────────────────────────────────────────

  void _resetCommandTimeout() {
    _commandTimeoutTimer?.cancel();
    _commandTimeoutTimer = Timer(_commandTimeout, () {
      _logger.w('⏱️ Timeout por silencio (${_commandTimeout.inSeconds}s)');
      if (_partialText.isNotEmpty) {
        _logger.i('💡 Procesando texto parcial: "$_partialText"');
        final textToProcess = _partialText;
        _partialText = '';
        _processUserInput(textToProcess);
      } else {
        _returnToIdle();
      }
    });
  }

  // ─── Procesamiento principal ──────────────────────────────────────────────

  Future<void> _processUserInput(String userInput) async {
    if (_state != CoordinatorState.listeningCommand &&
        _state != CoordinatorState.processing) {
      _logger.w('⚠️ Estado incorrecto para procesar: $_state');
      return;
    }

    if (userInput.trim().isEmpty) {
      _logger.w('⚠️ Texto vacío, volviendo a idle');
      await _returnToIdle();
      return;
    }

    _lastUserInput = userInput;
    _logger.i('💬 Usuario: "$userInput"');
    onStatusUpdate?.call('Procesando: "$userInput"');

    try {
      _state = CoordinatorState.processing;

      if (_voiceService.isListening) {
        await _voiceService.stopListening();
        await _voiceService.sessionManager.waitUntilIdle();
      }

      await _aiModeController.verifyInternetNow();

      final response = await _conversationService.chat(userInput);
      _logger.i('🤖 Bot (${response.type.name}): "${response.message}"');

      _state = CoordinatorState.speaking;
      await _ttsService.speak(response.message, interrupt: true);

      if (response.shouldNavigate) {
        _logger.i('🎯 Ejecutando navegación: ${response.intent!.target}');
        _currentIntent = response.intent;
        onIntentDetected?.call(response.intent!);
        await _ttsService.waitForCompletion();
        onCommandExecuted?.call(response.intent!);
      } else {
        onConversationalResponse?.call(response.message);
        await _ttsService.waitForCompletion();
      }

      await _completeAndReturnToIdle();

    } catch (e, stack) {
      _logger.e('❌ Error procesando entrada: $e\n$stack');
      _state = CoordinatorState.speaking;
      await _ttsService.speak(
          'Lo siento, hubo un error. ¿Puedes repetir?',
          interrupt: true);
      await _ttsService.waitForCompletion();
      await _returnToIdle();
    }
  }

  // ─── Wake word ────────────────────────────────────────────────────────────

  void _onWakeWordDetected() async {
    if (_state != CoordinatorState.idle) {
      _logger.w('⚠️ Wake word ignorado — Estado: $_state');
      return;
    }

    _logger.i('🎯 "Oye COMPAS" detectado!');
    HapticFeedback.heavyImpact();
    await _transitionToListeningCommand();
  }

  Future<void> _transitionToListeningCommand() async {
    try {
      _state = CoordinatorState.wakeWordDetected;

      if (_voiceService.isListening || !_voiceService.sessionManager.isIdle) {
        _logger.w('⚠️ STT no estaba limpio, forzando detención...');
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

      await Future.delayed(_ttsEchoDelay);

      _state = CoordinatorState.listeningCommand;
      _partialText = '';

      if (!_voiceService.sessionManager.canStart()) {
        _logger.e('❌ Session manager no permite inicio');
        await _returnToIdle();
        return;
      }

      _voiceService.setWakeWordActive(false);
      await _voiceService.startListening();
      _logger.i('🎤 Escuchando...');
      onStatusUpdate?.call('Escuchando...');

      _resetCommandTimeout();

    } catch (e) {
      _logger.e('❌ Error en transición: $e');
      await _returnToIdle();
    }
  }

  // ─── Utilidades ───────────────────────────────────────────────────────────

  String _getRandomGreeting() {
    const greetings = [
      'Dime',
      '¿Sí?',
      'Te escucho',
      '¿En qué puedo ayudarte?',
      'Aquí estoy',
    ];
    return greetings[DateTime.now().millisecond % greetings.length];
  }

  Future<void> _returnToIdle() async {
    if (_state == CoordinatorState.idle &&
        _wakeWordService.isListening &&
        _isActive) return;

    _logger.d('🔄 $_state → IDLE');

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
        await _wakeWordService.resume();
        onStatusUpdate?.call('Esperando "Oye COMPAS"...');
      }
    } catch (e) {
      _logger.e('❌ Error crítico volviendo a IDLE: $e');
      _state = CoordinatorState.idle;
      _voiceService.sessionManager.forceReset();
    }
  }

  Future<void> _completeAndReturnToIdle() async {
    _commandTimeoutTimer?.cancel();
    _partialText = '';

    if (_voiceService.isListening || !_voiceService.sessionManager.isIdle) {
      await _voiceService.stopListening();
      await _voiceService.sessionManager.waitUntilIdle();
    }

    _state = CoordinatorState.idle;

    if (_wakeWordAvailable && _isActive) {
      try {
        _voiceService.setWakeWordActive(true);
        await _wakeWordService.resume();
        onStatusUpdate?.call('Esperando "Oye COMPAS"...');
      } catch (e) {
        _logger.e('❌ Error reanudando wake word: $e');
      }
    }
  }

  // ─── API pública ──────────────────────────────────────────────────────────

  Future<void> start({NavigationMode mode = NavigationMode.eventBased}) async {
    if (!_isInitialized) throw Exception('No inicializado');
    if (_isActive) { _logger.w('Ya activo'); return; }

    try {
      _mode     = mode;
      _isActive = true;
      _state    = CoordinatorState.idle;

      _logger.i('🚀 INICIANDO — Modo: ${mode.name} — Wake word: $_wakeWordAvailable');

      if (_wakeWordAvailable) {
        _voiceService.setWakeWordActive(true);
        await _wakeWordService.start();
        onStatusUpdate?.call('Di "Oye COMPAS"');
        await Future.delayed(const Duration(milliseconds: 500));
        await _ttsService.speak('Sistema conversacional activado');
        await _ttsService.waitForCompletion();
      } else {
        _logger.w('⚠️ Modo manual (sin wake word)');
        _voiceService.setWakeWordActive(false);
        await _voiceService.sessionManager.waitUntilIdle();
        await Future.delayed(const Duration(milliseconds: 500));
        await _voiceService.startListening();
        _resetCommandTimeout();
        onStatusUpdate?.call('Escuchando...');
      }

    } catch (e) {
      _isActive = false;
      _logger.e('❌ Error start: $e');
      rethrow;
    }
  }

  Future<void> stop() async {
    if (!_isActive) return;

    try {
      _logger.i('🛑 Deteniendo...');
      _isActive = false;
      _commandTimeoutTimer?.cancel();
      _partialText = '';

      _voiceService.setWakeWordActive(false);

      if (_wakeWordService.isListening) await _wakeWordService.stop();
      if (_voiceService.isListening) {
        await _voiceService.stopListening();
        await _voiceService.sessionManager.waitUntilIdle();
      }

      _state = CoordinatorState.idle;
      await _ttsService.speak('Sistema detenido', interrupt: true);
      await _ttsService.waitForCompletion();

    } catch (e) {
      _logger.e('❌ Error stop: $e');
    }
  }

  void setMode(NavigationMode mode) {
    _mode = mode;
    _logger.i('🔄 Modo: $_mode');
  }

  Future<void> setWakeWordSensitivity(double sensitivity) async {
    if (!_wakeWordAvailable) return;
    try {
      final wasActive = _isActive;
      if (wasActive) await stop();
      await _wakeWordService.setSensitivity(
          sensitivity, ApiConfig.picovoiceAccessKey);
      if (wasActive) await start(mode: _mode);
    } catch (e) {
      _logger.e('❌ Error sensibilidad: $e');
    }
  }

  void clearConversationHistory() {
    _conversationService.clearHistory();
    _logger.i('🗑️ Historial limpiado');
  }

  Map<String, dynamic> getStatistics() => {
    'voice_service':        _voiceService.getStatistics(),
    'conversation_service': _conversationService.getStatistics(),
    'wake_word':            _wakeWordAvailable
        ? _wakeWordService.getStatistics()
        : {'enabled': false},
    'ai_mode':              _aiModeController.getStatistics(),
    'system': {
      'is_active':           _isActive,
      'mode':                _mode.toString(),
      'state':               _state.name,
      'wake_word_available': _wakeWordAvailable,
      'is_speaking':         _ttsService.isSpeaking,
      'last_user_input':     _lastUserInput,
      'timeout_seconds':     _commandTimeout.inSeconds,
    },
  };

  void reset() {
    _voiceService.resetFSM();
    _voiceService.sessionManager.forceReset();
    _voiceService.setWakeWordActive(_wakeWordAvailable && _isActive);
    if (_wakeWordAvailable) _wakeWordService.resetStatistics();
    clearConversationHistory();
    _currentIntent    = null;
    _lastUserInput    = null;
    _partialText      = '';
    _state            = CoordinatorState.idle;
    _commandTimeoutTimer?.cancel();
    _logger.i('🔄 Reset completo');
  }

  // Getters
  bool              get isInitialized     => _isInitialized;
  bool              get isActive          => _isActive;
  bool              get wakeWordAvailable => _wakeWordAvailable;
  NavigationMode    get currentMode       => _mode;
  NavigationIntent? get currentIntent     => _currentIntent;
  CoordinatorState  get state             => _state;
  bool              get isSpeaking        => _ttsService.isSpeaking;
  String?           get lastUserInput     => _lastUserInput;

  Future<void> speak(String message) async {
    if (message.isEmpty) return;
    await _ttsService.speak(message, interrupt: false);
  }

  void dispose() {
    stop();
    _commandTimeoutTimer?.cancel();
    _voiceService.dispose();
    _wakeWordService.dispose();
    _ttsService.dispose();
    _conversationService.dispose();
    _aiModeController.dispose();
    _logger.i('NavigationCoordinator disposed');
  }
}