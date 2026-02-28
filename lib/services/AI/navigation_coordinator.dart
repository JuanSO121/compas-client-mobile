// lib/services/AI/navigation_coordinator.dart
// ✅ COORDINADOR CONVERSACIONAL - VERSIÓN ACTUALIZADA
// Integra conversación natural + comandos de navegación

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
import 'conversation_service.dart';

enum CoordinatorState {
  idle,
  wakeWordDetected,
  listeningCommand,
  processing,
  speaking,
}

class NavigationCoordinator {
  static final NavigationCoordinator _instance = NavigationCoordinator._internal();
  factory NavigationCoordinator() => _instance;
  NavigationCoordinator._internal();

  final Logger _logger = Logger();

  final ConversationService _conversationService = ConversationService();
  final IntegratedVoiceCommandService _voiceService = IntegratedVoiceCommandService();
  final WakeWordService _wakeWordService = WakeWordService();
  final TTSService _ttsService = TTSService();
  final AIModeController _aiModeController = AIModeController();

  CoordinatorState _state = CoordinatorState.idle;
  bool _isInitialized = false;
  bool _isActive = false;
  bool _wakeWordAvailable = false;


  Timer? _commandTimeoutTimer;
  static const Duration _commandTimeout = Duration(seconds: 5);

  NavigationIntent? _currentIntent;
  NavigationMode _mode = NavigationMode.eventBased;

  // ✅ Historial de entrada del usuario
  String? _lastUserInput;

  Function(String)? onStatusUpdate;
  Function(NavigationIntent)? onIntentDetected;
  Function(NavigationIntent)? onCommandExecuted;
  Function(String)? onCommandRejected;
  Function(String)? onConversationalResponse; // ✅ NUEVO

  Future<void> initialize() async {
    if (_isInitialized) {
      _logger.w('Ya inicializado');
      return;
    }

    try {
      _logger.i('🚀 Inicializando NavigationCoordinator...');

      await _ttsService.initialize();
      await _aiModeController.initialize();
      await _conversationService.initialize();
      await _initializeWakeWord();
      await _voiceService.initialize();

      _setupServiceCallbacks();

      _isInitialized = true;
      _state = CoordinatorState.idle;

      _logger.i('═══════════════════════════════════════');
      _logger.i('✅ SISTEMA CONVERSACIONAL INICIALIZADO');
      _logger.i('   Wake Word: ${_wakeWordAvailable ? "✅ ACTIVO" : "❌ INACTIVO"}');
      _logger.i('   Modo IA: ${_aiModeController.getModeDescription()}');
      _logger.i('═══════════════════════════════════════');

      final status = _wakeWordAvailable
          ? '✅ Di "Oye COMPAS" para comenzar'
          : '✅ Presiona Play para hablar';

      onStatusUpdate?.call(status);

    } catch (e, stack) {
      _logger.e('❌ Error inicializando: $e');
      _logger.e('Stack: $stack');
      throw Exception('Fallo al inicializar: $e');
    }
  }

  Future<void> _initializeWakeWord() async {
    try {
      _logger.i('═══════════════════════════════════════');
      _logger.i('🔍 VERIFICANDO WAKE WORD');
      _logger.i('═══════════════════════════════════════');

      final key = ApiConfig.picovoiceAccessKey;

      if (key.isEmpty || key.contains('...') || key.length < 20) {
        _logger.w('❌ Access Key INVÁLIDO');
        _wakeWordAvailable = false;
        return;
      }

      await _wakeWordService.initialize(
        accessKey: key,
        config: const WakeWordConfig.custom(
          keyword: 'oye compas',
          modelPath: 'assets/wake_words/oye_compas_android.ppn',
        ),
        sensitivity: 0.7,
      );

      _wakeWordService.onWakeWordDetected = _onWakeWordDetected;
      _wakeWordService.onError = (error) {
        _logger.e('❌ Wake word error: $error');
        onStatusUpdate?.call('Error: $error');
      };

      _wakeWordAvailable = true;
      _logger.i('✅ Wake word "Oye COMPAS" ACTIVO');

    } catch (e, stack) {
      _logger.e('❌ Error wake word: $e');
      _logger.e('Stack: $stack');
      _wakeWordAvailable = false;
      _logger.w('⚠️ Continuando sin wake word');
    }
  }

  void _setupServiceCallbacks() {
    // ✅ Variable para capturar el texto STT
    String? capturedText;

    _voiceService.onCommandDetected = (intent) {
      // Capturar el texto original del usuario
      capturedText = intent.suggestedResponse;
      _logger.d('📝 Texto capturado: "$capturedText"');
    };

    _voiceService.onCommandExecuted = (intent) async {
      if (_state != CoordinatorState.listeningCommand) {
        _logger.w('⚠️ Estado incorrecto: $_state');
        return;
      }

      // ✅ Usar el texto capturado
      final userText = capturedText ?? intent.suggestedResponse;
      capturedText = null; // Limpiar

      await _processUserInput(userText);
    };

    _voiceService.onCommandRejected = (reason) {
      _logger.w('⛔ Rechazado: $reason');
      capturedText = null;
      _returnToIdle();
    };
  }

  /// ✅ PROCESAR ENTRADA DEL USUARIO (Chatbot primero)
  Future<void> _processUserInput(String userInput) async {
    if (_state != CoordinatorState.listeningCommand) {
      _logger.w('⚠️ Estado incorrecto para procesar: $_state');
      return;
    }

    _lastUserInput = userInput;
    _logger.i('💬 Usuario: "$userInput"');

    try {
      _state = CoordinatorState.processing;

      // Detener STT mientras procesamos
      if (_voiceService.isListening) {
        await _voiceService.stopListening();
        await _voiceService.sessionManager.waitUntilIdle();
      }

      // Verificar conexión
      await _aiModeController.verifyInternetNow();

      // ✅ CHATEAR con el usuario (chatbot primero)
      final response = await _conversationService.chat(userInput);

      _logger.i('🤖 Bot (${response.type.name}): "${response.message}"');

      // Hablar la respuesta del chatbot
      _state = CoordinatorState.speaking;
      await _ttsService.speak(response.message, interrupt: true);

      // ✅ DESPUÉS de hablar, ejecutar navegación si existe
      if (response.shouldNavigate) {
        _logger.i('🎯 Ejecutando navegación: ${response.intent!.target}');
        _currentIntent = response.intent;
        onIntentDetected?.call(response.intent!);

        await _ttsService.waitForCompletion();
        onCommandExecuted?.call(response.intent!);
      } else {
        _logger.i('💬 Conversación pura (sin navegación)');
        if (onConversationalResponse != null) {
          onConversationalResponse?.call(response.message);
        }
        await _ttsService.waitForCompletion();
      }

      await _completeAndReturnToIdle();

    } catch (e, stack) {
      _logger.e('❌ Error procesando entrada: $e');
      _logger.e('Stack: $stack');

      _state = CoordinatorState.speaking;
      await _ttsService.speak('Lo siento, hubo un error. ¿Puedes repetir?', interrupt: true);
      await _ttsService.waitForCompletion();

      await _returnToIdle();
    }
  }

  void _onWakeWordDetected() async {
    if (_state != CoordinatorState.idle) {
      _logger.w('⚠️ Ignorado - Estado: $_state');
      return;
    }

    _logger.i('🎯 "Oye COMPAS" detectado!');
    HapticFeedback.heavyImpact();
    await _transitionToListeningCommand();
  }

  Future<void> _transitionToListeningCommand() async {
    try {
      _state = CoordinatorState.wakeWordDetected;
      _logger.d('🔄 IDLE → WAKE_WORD_DETECTED');

      // ✅ Limpieza preventiva de STT
      if (_voiceService.isListening || !_voiceService.sessionManager.isIdle) {
        _logger.w('⚠️ STT no estaba limpio, forzando detención...');
        await _voiceService.stopListening();
        await _voiceService.sessionManager.waitUntilIdle(
          timeout: const Duration(seconds: 2),
        );
        _logger.i('✅ STT limpiado completamente');
      }

      // ✅ Pausa wake word
      if (_wakeWordService.isListening) {
        await _wakeWordService.pause();
        _logger.d('⏸️ Wake word pausado');
        await Future.delayed(const Duration(milliseconds: 300));
      }

      // ✅ Hablar y esperar
      _state = CoordinatorState.speaking;

      final greeting = _getRandomGreeting();
      await _ttsService.speak(greeting, interrupt: true);
      await _ttsService.waitForCompletion();
      await Future.delayed(const Duration(milliseconds: 200));

      // ✅ Iniciar STT con validación
      _state = CoordinatorState.listeningCommand;

      if (!_voiceService.sessionManager.canStart()) {
        _logger.e('❌ Session manager no permite inicio');
        await _returnToIdle();
        return;
      }

      await _voiceService.startListening();
      _logger.i('🎤 Escuchando...');
      onStatusUpdate?.call('Escuchando...');

      // ✅ Timeout
      _commandTimeoutTimer?.cancel();
      _commandTimeoutTimer = Timer(_commandTimeout, () {
        _logger.w('⏱️ Timeout del comando');
        _returnToIdle();
      });

    } catch (e) {
      _logger.e('❌ Error en transición: $e');
      await _returnToIdle();
    }
  }

  String _getRandomGreeting() {
    final greetings = [
      'Dime',
      '¿Sí?',
      'Te escucho',
      '¿En qué puedo ayudarte?',
      'Aquí estoy',
    ];
    return greetings[DateTime.now().millisecond % greetings.length];
  }

  Future<void> _returnToIdle() async {
    if (_state == CoordinatorState.idle && _wakeWordService.isListening && _isActive) {
      return;
    }

    _logger.d('🔄 $_state → IDLE (Recuperación)');

    try {
      _commandTimeoutTimer?.cancel();

      // ✅ Limpieza exhaustiva de STT
      if (_voiceService.isListening || !_voiceService.sessionManager.isIdle) {
        _logger.i('🧹 Limpiando sesión STT...');
        await _voiceService.stopListening();
        await _voiceService.sessionManager.waitUntilIdle(
          timeout: const Duration(seconds: 3),
        );
        _logger.i('✅ STT completamente limpio');
      }

      if (_ttsService.isSpeaking) {
        await _ttsService.stop();
      }

      await Future.delayed(const Duration(milliseconds: 400));
      _state = CoordinatorState.idle;

      if (_wakeWordAvailable && _isActive) {
        await _wakeWordService.resume();
        _logger.i('🎤 Wake word reanudado');
        onStatusUpdate?.call('Esperando "Oye COMPAS"...');
      }
    } catch (e) {
      _logger.e('❌ Error crítico volviendo a IDLE: $e');
      _state = CoordinatorState.idle;
      _voiceService.sessionManager.forceReset();
    }
  }

  Future<void> _completeAndReturnToIdle() async {
    _logger.d('🔄 Ciclo completado. Volviendo a IDLE...');

    // ✅ Limpieza preventiva antes de volver a IDLE
    if (_voiceService.isListening || !_voiceService.sessionManager.isIdle) {
      _logger.i('🧹 Limpiando STT antes de completar...');
      await _voiceService.stopListening();
      await _voiceService.sessionManager.waitUntilIdle();
    }

    _state = CoordinatorState.idle;

    if (_wakeWordAvailable && _isActive) {
      try {
        await _wakeWordService.resume();
        _logger.i('🎤 Wake word reanudado tras ciclo exitoso');
        onStatusUpdate?.call('Esperando "Oye COMPAS"...');
      } catch (e) {
        _logger.e('❌ Error reanudando wake word: $e');
      }
    }
  }

  Future<void> start({NavigationMode mode = NavigationMode.eventBased}) async {
    if (!_isInitialized) throw Exception('No inicializado');
    if (_isActive) {
      _logger.w('Ya activo');
      return;
    }

    try {
      _mode = mode;
      _isActive = true;
      _state = CoordinatorState.idle;

      _logger.i('═══════════════════════════════════════');
      _logger.i('🚀 INICIANDO SISTEMA CONVERSACIONAL');
      _logger.i('   Modo: ${mode.name}');
      _logger.i('   Wake Word: ${_wakeWordAvailable ? "SI" : "NO"}');
      _logger.i('   Modo IA: ${_aiModeController.getModeDescription()}');
      _logger.i('═══════════════════════════════════════');

      if (_wakeWordAvailable) {
        await _wakeWordService.start();
        _logger.i('🎤 Wake word escuchando');
        onStatusUpdate?.call('Di "Oye COMPAS"');

        await Future.delayed(const Duration(milliseconds: 500));
        await _ttsService.speak('Sistema conversacional activado');
        await _ttsService.waitForCompletion();

      } else {
        _logger.w('⚠️ SIN WAKE WORD - Modo manual');

        await _voiceService.sessionManager.waitUntilIdle();
        await Future.delayed(const Duration(milliseconds: 500));

        await _voiceService.startListening();
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

      if (_wakeWordService.isListening) {
        await _wakeWordService.stop();
      }

      if (_voiceService.isListening) {
        await _voiceService.stopListening();
        await _voiceService.sessionManager.waitUntilIdle();
      }

      _state = CoordinatorState.idle;
      _logger.i('⏸️ Detenido');

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
        sensitivity,
        ApiConfig.picovoiceAccessKey,
      );

      _logger.i('🔧 Sensibilidad: ${(sensitivity * 100).toInt()}%');
      if (wasActive) await start(mode: _mode);
    } catch (e) {
      _logger.e('❌ Error sensibilidad: $e');
    }
  }

  /// ✅ NUEVO: Limpiar historial de conversación
  void clearConversationHistory() {
    _conversationService.clearHistory();
    _logger.i('🗑️ Historial de conversación limpiado');
  }

  Map<String, dynamic> getStatistics() {
    return {
      'voice_service': _voiceService.getStatistics(),
      'conversation_service': _conversationService.getStatistics(),
      'wake_word': _wakeWordAvailable
          ? _wakeWordService.getStatistics()
          : {'enabled': false},
      'ai_mode': _aiModeController.getStatistics(),
      'system': {
        'is_active': _isActive,
        'mode': _mode.toString(),
        'state': _state.name,
        'wake_word_available': _wakeWordAvailable,
        'is_speaking': _ttsService.isSpeaking,
        'last_user_input': _lastUserInput,
      },
    };
  }

  void reset() {
    _voiceService.resetFSM();
    _voiceService.sessionManager.forceReset();
    if (_wakeWordAvailable) {
      _wakeWordService.resetStatistics();
    }
    clearConversationHistory();
    _currentIntent = null;
    _lastUserInput = null;
    _state = CoordinatorState.idle;
    _commandTimeoutTimer?.cancel();
    _logger.i('🔄 Reset completo');
  }

  bool get isInitialized => _isInitialized;
  bool get isActive => _isActive;
  bool get wakeWordAvailable => _wakeWordAvailable;
  NavigationMode get currentMode => _mode;
  NavigationIntent? get currentIntent => _currentIntent;
  CoordinatorState get state => _state;
  bool get isSpeaking => _ttsService.isSpeaking;
  String? get lastUserInput => _lastUserInput;

  

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