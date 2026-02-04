// lib/services/AI/integrated_voice_command_service.dart
// ✅ VERSIÓN ACTUALIZADA - EXPONE SESSION MANAGER

import 'dart:async';
import 'package:logger/logger.dart';
import 'package:speech_to_text/speech_recognition_error.dart' as stt;
import 'package:speech_to_text/speech_recognition_result.dart' as stt;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:permission_handler/permission_handler.dart';

import '../../models/shared_models.dart';
import 'voice_command_classifier.dart';
import 'robot_fsm.dart';
import 'stt_session_manager.dart';

class IntegratedVoiceCommandService {
  static final IntegratedVoiceCommandService _instance =
  IntegratedVoiceCommandService._internal();
  factory IntegratedVoiceCommandService() => _instance;
  IntegratedVoiceCommandService._internal();

  final Logger _logger = Logger();
  final stt.SpeechToText _speech = stt.SpeechToText();
  final VoiceCommandClassifier _classifier = VoiceCommandClassifier();
  final RobotFSM _fsm = RobotFSM();
  final STTSessionManager _sessionManager = STTSessionManager();

  // ✅ EXPONER SESSION MANAGER
  STTSessionManager get sessionManager => _sessionManager;

  bool _isInitialized = false;
  bool _isListening = false;
  bool _isProcessing = false;
  String _lastPartialText = '';
  int _consecutiveErrors = 0;

  static const Duration _pauseTimeout = Duration(seconds: 2);
  static const int _maxConsecutiveErrors = 3;

  Function(NavigationIntent)? onCommandDetected;
  Function(NavigationIntent)? onCommandExecuted;
  Function(String)? onCommandRejected;
  Function(String)? onStatusUpdate;

  Future<void> initialize() async {
    if (_isInitialized) {
      _logger.w('Servicio ya inicializado');
      return;
    }

    try {
      _logger.i('Inicializando IntegratedVoiceCommandService...');

      await _ensurePermissions();

      final available = await _speech.initialize(
        onError: _onSpeechError,
        onStatus: _onSpeechStatus,
        debugLogging: false,
        finalTimeout: const Duration(milliseconds: 1500),
      );

      if (!available) {
        throw Exception('Speech recognition no disponible');
      }

      try {
        _logger.i('Intentando inicializar TFLite...');
        await _classifier.initialize();
        _logger.i('✅ TFLite inicializado correctamente');
      } catch (e) {
        _logger.w('⚠️ TFLite no disponible: $e');
        _logger.i('📌 Usando clasificación por keywords (fallback)');
      }

      _isInitialized = true;
      _logger.i('✅ IntegratedVoiceCommandService listo');

    } catch (e) {
      _logger.e('❌ Error inicializando servicio: $e');
      rethrow;
    }
  }

  Future<void> _ensurePermissions() async {
    final micStatus = await Permission.microphone.status;

    if (micStatus.isDenied) {
      final result = await Permission.microphone.request();
      if (!result.isGranted) {
        throw Exception('Permiso de micrófono denegado');
      }
    }

    if (micStatus.isPermanentlyDenied) {
      throw Exception('Permiso permanentemente denegado');
    }

    _logger.i('✅ Permisos verificados');
  }

  Future<void> startListening() async {
    if (!_isInitialized) {
      throw StateError('Servicio no inicializado');
    }

    if (_isListening) {
      _logger.w('Ya está escuchando');
      return;
    }

    try {
      await _startListeningSession();
      _logger.i('🎤 Escucha iniciada');

    } catch (e) {
      _logger.e('Error iniciando escucha: $e');
      _consecutiveErrors++;

      if (_consecutiveErrors < _maxConsecutiveErrors) {
        _logger.w('Reintentando... (${_consecutiveErrors}/$_maxConsecutiveErrors)');
        await Future.delayed(const Duration(milliseconds: 500));
        await startListening();
      } else {
        _logger.e('Demasiados errores, abortando');
        _consecutiveErrors = 0;
        rethrow;
      }
    }
  }

  Future<void> _startListeningSession() async {
    // ✅ VALIDACIÓN MEJORADA
    if (!await _sessionManager.markStarting()) {
      _logger.w('⚠️ Session manager rechazó inicio');
      _logger.w('   Estado actual: ${_sessionManager.state.name}');
      _logger.w('   Tiempo desde último cambio: ${_sessionManager.timeSinceLastChange}');
      return;
    }

    if (_isProcessing) {
      _logger.w('⚠️ Procesando comando, cancelando inicio');
      _sessionManager.markIdle();
      return;
    }

    _lastPartialText = '';

    final options = stt.SpeechListenOptions(
      partialResults: true,
      onDevice: false,
      autoPunctuation: false,
      enableHapticFeedback: false,
      cancelOnError: false,
      listenMode: stt.ListenMode.confirmation,
    );

    try {
      await _speech.listen(
        onResult: _onSpeechResult,
        pauseFor: _pauseTimeout,
        localeId: 'es_CO',
        listenOptions: options,
      );

      _isListening = true;
      _sessionManager.markActive();
      _logger.d('✅ Sesión STT activa');

      onStatusUpdate?.call('Escuchando...');

    } catch (e) {
      _logger.e('Error iniciando sesión STT: $e');
      _isListening = false;
      _sessionManager.markIdle();

      if (e.toString().contains('error_busy')) {
        _logger.w('STT ocupado, esperando...');
        await Future.delayed(const Duration(seconds: 1));
      }

      rethrow;
    }
  }

  void _onSpeechResult(stt.SpeechRecognitionResult result) {
    final text = result.recognizedWords.trim();

    if (text.isEmpty) return;

    if (text == _lastPartialText && !result.finalResult) {
      return;
    }

    _lastPartialText = text;
    _logger.d('STT: "$text" (final: ${result.finalResult})');

    if (result.finalResult) {
      _processCommand(text);
    }
  }

  Future<void> _processCommand(String text) async {
    if (_isProcessing) {
      _logger.w('Ya procesando comando');
      return;
    }

    _isProcessing = true;

    try {
      if (text.trim().isEmpty || text.length < 2) {
        _logger.w('Texto muy corto: "$text"');
        _isProcessing = false;
        return;
      }

      VoiceCommandResult result;

      if (_classifier.isInitialized) {
        try {
          result = await _classifier.classify(text).timeout(
            const Duration(seconds: 2),
            onTimeout: () {
              _logger.e('⏱️ Timeout en TFLite');
              return VoiceCommandResult.error('Timeout');
            },
          );

          if (result.hasError) {
            throw Exception(result.errorMessage ?? 'TFLite error');
          }

        } catch (e) {
          _logger.w('❌ TFLite falló: $e - Usando fallback');
          result = _fallbackClassification(text);
        }
      } else {
        result = _fallbackClassification(text);
      }

      _logger.i('🔍 "$text" → ${result.label} (${(result.confidence * 100).toStringAsFixed(1)}%)');

      if (!result.passesThreshold) {
        _logger.w('⛔ Confianza baja: ${(result.confidence * 100).toStringAsFixed(1)}%');
        onCommandRejected?.call('Comando no reconocido con suficiente confianza');
        return;
      }

      final action = _labelToAction(result.label);
      final canExecute = _fsm.canExecute(action, result.confidence);

      if (!canExecute.$1) {
        _logger.w('⛔ FSM rechazó: ${canExecute.$2}');
        onCommandRejected?.call(canExecute.$2);
        return;
      }

      final executed = _fsm.execute(action, result.confidence, text);

      if (executed) {
        final intent = _actionToIntent(action, text);

        _consecutiveErrors = 0;

        onCommandDetected?.call(intent);
        onCommandExecuted?.call(intent);

        _logger.i('✅ Comando ejecutado: ${action.name}');
      }

    } catch (e, stackTrace) {
      _logger.e('Error procesando comando: $e');
      _logger.e('StackTrace: $stackTrace');
      _consecutiveErrors++;
    } finally {
      _isProcessing = false;
    }
  }

  VoiceCommandResult _fallbackClassification(String text) {
    final normalized = text.toLowerCase().trim();

    if (normalized.contains('muev') || normalized.contains('adelante') ||
        normalized.contains('avanza') || normalized.contains('camina') ||
        normalized.contains('anda') || normalized.contains('sigue') ||
        normalized.contains('vamos') || normalized.contains('forward')) {
      return VoiceCommandResult(
        label: 'MOVE',
        confidence: 0.80,
        passesThreshold: true,
        threshold: 0.65,
        inferenceTimeMs: 0,
        logits: [],
      );
    }

    if (normalized.contains('para') || normalized.contains('pará') ||
        normalized.contains('det') || normalized.contains('stop') ||
        normalized.contains('alto') || normalized.contains('quieto') ||
        normalized.contains('espera') || normalized.contains('frena')) {
      return VoiceCommandResult(
        label: 'STOP',
        confidence: 0.90,
        passesThreshold: true,
        threshold: 0.65,
        inferenceTimeMs: 0,
        logits: [],
      );
    }

    if (normalized.contains('izquierda') || normalized.contains('izq') ||
        normalized.contains('zurda') || normalized.contains('left')) {
      return VoiceCommandResult(
        label: 'TURN_LEFT',
        confidence: 0.75,
        passesThreshold: true,
        threshold: 0.60,
        inferenceTimeMs: 0,
        logits: [],
      );
    }

    if (normalized.contains('derecha') || normalized.contains('der') ||
        normalized.contains('diestra') || normalized.contains('right')) {
      return VoiceCommandResult(
        label: 'TURN_RIGHT',
        confidence: 0.75,
        passesThreshold: true,
        threshold: 0.60,
        inferenceTimeMs: 0,
        logits: [],
      );
    }

    if (normalized.contains('ayuda') || normalized.contains('help') ||
        normalized.contains('auxilio') || normalized.contains('socorro')) {
      return VoiceCommandResult(
        label: 'HELP',
        confidence: 0.85,
        passesThreshold: true,
        threshold: 0.70,
        inferenceTimeMs: 0,
        logits: [],
      );
    }

    if (normalized.contains('repite') || normalized.contains('repeat') ||
        normalized.contains('otra vez') || normalized.contains('de nuevo') ||
        normalized.contains('again')) {
      return VoiceCommandResult(
        label: 'REPEAT',
        confidence: 0.70,
        passesThreshold: true,
        threshold: 0.55,
        inferenceTimeMs: 0,
        logits: [],
      );
    }

    _logger.w('Texto no reconocido en fallback: "$text"');
    return VoiceCommandResult(
      label: 'UNKNOWN',
      confidence: 0.30,
      passesThreshold: false,
      threshold: 0.50,
      inferenceTimeMs: 0,
      logits: [],
    );
  }

  Future<void> stopListening() async {
    if (!_isListening && !_isProcessing && _sessionManager.isIdle) {
      _logger.d('Ya detenido');
      return;
    }

    _logger.i('Deteniendo escucha...');

    _isListening = false;
    _isProcessing = false;
    _consecutiveErrors = 0;

    try {
      if (_speech.isListening) {
        _sessionManager.markStopping();
        await _speech.stop();
      }
      _sessionManager.markIdle();
      _logger.d('⏹️ Escucha detenida completamente');
    } catch (e) {
      _logger.e('Error deteniendo STT: $e');
      _sessionManager.forceReset();
    }

    onStatusUpdate?.call('Escucha detenida');
  }

  void _onSpeechError(stt.SpeechRecognitionError error) {
    _logger.e('STT Error: ${error.errorMsg} (permanent: ${error.permanent})');

    if (error.errorMsg == 'error_busy') {
      _logger.w('⚠️ STT busy (esperado), ignorando...');
      return;
    }

    if (error.errorMsg == 'error_speech_timeout' && _lastPartialText.isEmpty) {
      _logger.d('Timeout sin habla detectada');
      return;
    }

    _consecutiveErrors++;

    if (error.permanent || _consecutiveErrors >= _maxConsecutiveErrors) {
      _logger.e('Error permanente, deteniendo...');
      stopListening();
      onStatusUpdate?.call('Error de reconocimiento');
    }
  }

  void _onSpeechStatus(String status) {
    _logger.d('STT Status: $status');

    if (status == 'done' || status == 'notListening') {
      _isListening = false;
    }

    if (status == 'listening') {
      _consecutiveErrors = 0;
    }
  }

  Action _labelToAction(String label) {
    switch (label) {
      case 'MOVE':
        return Action.move;
      case 'STOP':
        return Action.stop;
      case 'TURN_LEFT':
        return Action.turnLeft;
      case 'TURN_RIGHT':
        return Action.turnRight;
      case 'REPEAT':
        return Action.repeat;
      case 'HELP':
        return Action.help;
      default:
        return Action.unknown;
    }
  }

  NavigationIntent _actionToIntent(Action action, String text) {
    switch (action) {
      case Action.move:
        return NavigationIntent(
          type: IntentType.navigate,
          target: 'forward',
          priority: 8,
          suggestedResponse: 'Avanzando',
        );

      case Action.stop:
        return NavigationIntent(
          type: IntentType.stop,
          target: '',
          priority: 10,
          suggestedResponse: 'Deteniéndome',
        );

      case Action.turnLeft:
        return NavigationIntent(
          type: IntentType.navigate,
          target: 'left',
          priority: 7,
          suggestedResponse: 'Girando a la izquierda',
        );

      case Action.turnRight:
        return NavigationIntent(
          type: IntentType.navigate,
          target: 'right',
          priority: 7,
          suggestedResponse: 'Girando a la derecha',
        );

      case Action.help:
        return NavigationIntent(
          type: IntentType.help,
          target: '',
          priority: 9,
          suggestedResponse: 'Activando ayuda',
        );

      default:
        return NavigationIntent.unknown();
    }
  }

  Future<void> setSpeechRate(double rate) async {}
  Future<void> setVolume(double volume) async {}

  Map<String, dynamic> getStatistics() {
    return {
      'is_initialized': _isInitialized,
      'is_listening': _isListening,
      'is_processing': _isProcessing,
      'consecutive_errors': _consecutiveErrors,
      'session_state': _sessionManager.state.name,
      'fsm_stats': _fsm.getStatistics(),
      'classifier_stats': {
        'inference_count': _classifier.inferenceCount,
      },
    };
  }

  void resetFSM() {
    _fsm.reset();
    _consecutiveErrors = 0;
  }

  bool get isInitialized => _isInitialized;
  bool get isListening => _isListening;
  bool get isProcessing => _isProcessing;

  void dispose() {
    stopListening();
    _classifier.dispose();
    _sessionManager.dispose();
    _logger.i('IntegratedVoiceCommandService disposed');
  }
}