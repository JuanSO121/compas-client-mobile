// lib/services/AI/integrated_voice_command_service.dart

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

  final Logger                 _logger         = Logger();
  final stt.SpeechToText       _speech         = stt.SpeechToText();
  final VoiceCommandClassifier _classifier     = VoiceCommandClassifier();
  final RobotFSM               _fsm            = RobotFSM();
  final STTSessionManager      _sessionManager = STTSessionManager();

  STTSessionManager get sessionManager => _sessionManager;

  bool   _isInitialized     = false;
  bool   _isListening       = false;
  bool   _isProcessing      = false;
  String _lastPartialText   = '';
  int    _consecutiveErrors = 0;

  // ✅ BUG 3 FIX: el coordinator avisa si Porcupine está activo.
  // Cuando es true, filtramos el wake word si el STT lo captura por error.
  bool _wakeWordActive = false;
  void setWakeWordActive(bool active) => _wakeWordActive = active;

  // Frases de wake word que el STT podría capturar accidentalmente
  static const List<String> _wakeWordVariants = [
    'oye compas',
    'oye compass',
    'oye comas',
    'oy compas',
    'hoy compas',
  ];

  static const Duration _pauseTimeout = Duration(milliseconds: 4500);
  static const int _maxConsecutiveErrors = 3;

  // ─── Callbacks ────────────────────────────────────────────────────────────

  Function(NavigationIntent)? onCommandDetected;
  Function(NavigationIntent)? onCommandExecuted;
  Function(String)?           onCommandRejected;
  Function(String)?           onStatusUpdate;
  Function(String partialText)? onPartialResult;

  // ─── Inicialización ───────────────────────────────────────────────────────

  Future<void> initialize() async {
    if (_isInitialized) {
      _logger.w('Servicio ya inicializado');
      return;
    }

    try {
      _logger.i('Inicializando IntegratedVoiceCommandService v3...');

      await _ensurePermissions();

      final available = await _speech.initialize(
        onError:      _onSpeechError,
        onStatus:     _onSpeechStatus,
        debugLogging: false,
      );

      if (!available) {
        throw Exception('Speech recognition no disponible');
      }

      try {
        _logger.i('Intentando inicializar TFLite...');
        await _classifier.initialize();
        _logger.i('✅ TFLite inicializado');
      } catch (e) {
        _logger.w('⚠️ TFLite no disponible: $e');
        _logger.i('📌 Usando clasificación por keywords (fallback)');
      }

      _isInitialized = true;
      _logger.i('✅ IntegratedVoiceCommandService v3 listo');
      _logger.i('   pauseFor: ${_pauseTimeout.inMilliseconds}ms');

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
      throw Exception('Permiso permanentemente denegado. Ve a Ajustes.');
    }

    _logger.i('✅ Permisos verificados');
  }

  // ─── Control de escucha ───────────────────────────────────────────────────

  Future<void> startListening() async {
    if (!_isInitialized) throw StateError('Servicio no inicializado');

    if (_isListening) {
      _logger.w('Ya está escuchando');
      return;
    }

    try {
      await _startListeningSession();
    } catch (e) {
      _logger.e('Error iniciando escucha: $e');
      _consecutiveErrors++;

      if (_consecutiveErrors < _maxConsecutiveErrors) {
        _logger.w('Reintentando... (${_consecutiveErrors}/$_maxConsecutiveErrors)');
        await Future.delayed(const Duration(milliseconds: 500));
        await startListening();
      } else {
        _logger.e('Demasiados errores consecutivos, abortando');
        _consecutiveErrors = 0;
        rethrow;
      }
    }
  }

  Future<void> _startListeningSession() async {
    if (!await _sessionManager.markStarting()) {
      _logger.w('⚠️ Session manager rechazó inicio — estado: ${_sessionManager.state.name}');
      return;
    }

    if (_isProcessing) {
      _logger.w('⚠️ Procesando comando, cancelando inicio');
      _sessionManager.markIdle();
      return;
    }

    _lastPartialText = '';

    final options = stt.SpeechListenOptions(
      partialResults:       true,
      onDevice:             false,
      autoPunctuation:      false,
      enableHapticFeedback: false,
      cancelOnError:        false,
      listenMode:           stt.ListenMode.confirmation,
    );

    try {
      await _speech.listen(
        onResult:     _onSpeechResult,
        pauseFor:     _pauseTimeout,
        localeId:     'es_CO',
        listenOptions: options,
      );

      _isListening = true;
      _sessionManager.markActive();
      _logger.i('✅ Sesión STT activa (pauseFor=${_pauseTimeout.inMilliseconds}ms)');
      onStatusUpdate?.call('Escuchando...');

    } catch (e) {
      _logger.e('Error iniciando sesión STT: $e');
      _isListening = false;
      _sessionManager.markIdle(); // ✅ Siempre limpiar el estado

      if (e.toString().contains('error_busy')) {
        _logger.w('STT ocupado, esperando 1s...');
        await Future.delayed(const Duration(seconds: 1));
      }

      rethrow;
    }
  }

  // ─── Resultado de voz ─────────────────────────────────────────────────────

  void _onSpeechResult(stt.SpeechRecognitionResult result) {
    final text = result.recognizedWords.trim();

    if (text.isEmpty) return;

    if (result.finalResult) {
      _logger.i('✅ STT final: "$text"');
      _processCommand(text);
    } else {
      if (text != _lastPartialText) {
        _lastPartialText = text;
        _logger.d('⏳ STT parcial: "$text"');
        onPartialResult?.call(text);
      }
    }
  }

  // ─── Procesamiento del comando ────────────────────────────────────────────

  Future<void> _processCommand(String text) async {
    if (_isProcessing) {
      _logger.w('Ya procesando comando');
      return;
    }

    // ✅ BUG 3 FIX: filtrar wake word si Porcupine está activo.
    // El STT a veces captura el propio wake word cuando se solapa con
    // el inicio/fin de sesión de Porcupine. Ignorarlo silenciosamente.
    if (_wakeWordActive) {
      final normalized = text.toLowerCase().trim();
      if (_wakeWordVariants.any((v) => normalized == v || normalized.startsWith(v))) {
        _logger.w('⚠️ STT capturó wake word accidentalmente — ignorado: "$text"');
        return;
      }
    }

    _isProcessing = true;

    try {
      if (text.trim().isEmpty || text.length < 2) {
        _logger.w('Texto muy corto ignorado: "$text"');
        return;
      }

      _logger.i('📝 Texto capturado: "$text"');

      final intent = NavigationIntent(
        type:              IntentType.navigate,
        target:            'forward',
        priority:          5,
        suggestedResponse: text,
      );

      _consecutiveErrors = 0;

      // Notificar captura del texto
      onCommandDetected?.call(intent);

      // ✅ BUG 2 FIX: onCommandExecuted en el siguiente microtask.
      // El coordinator necesita que onCommandDetected haya guardado
      // el texto (capturedText) ANTES de que onCommandExecuted lo use.
      // Sin este delay eran síncronos y capturedText era null al ejecutar.
      await Future.microtask(() {
        onCommandExecuted?.call(intent);
      });

    } catch (e, stackTrace) {
      _logger.e('Error procesando texto: $e\n$stackTrace');
      _consecutiveErrors++;
    } finally {
      _isProcessing = false;
    }
  }

  // ─── Detener ──────────────────────────────────────────────────────────────

  Future<void> stopListening() async {
    if (!_isListening && !_isProcessing && _sessionManager.isIdle) {
      _logger.d('Ya detenido');
      return;
    }

    _logger.i('Deteniendo escucha...');
    _isListening      = false;
    _isProcessing     = false;
    _consecutiveErrors = 0;

    try {
      if (_speech.isListening) {
        _sessionManager.markStopping();
        await _speech.stop();
      }
      _sessionManager.markIdle();
      _logger.d('⏹️ Sesión STT cerrada');
    } catch (e) {
      _logger.e('Error deteniendo STT: $e');
      _sessionManager.forceReset();
    }

    onStatusUpdate?.call('Escucha detenida');
  }

  // ─── Callbacks de error y estado ─────────────────────────────────────────

  void _onSpeechError(stt.SpeechRecognitionError error) {
    _logger.e('STT Error: ${error.errorMsg} (permanent: ${error.permanent})');

    if (error.errorMsg == 'error_busy') {
      _logger.w('⚠️ STT busy (esperado durante transición), ignorando');
      return;
    }

    if (error.errorMsg == 'error_speech_timeout' && _lastPartialText.isEmpty) {
      _logger.d('Timeout por silencio (nadie habló)');
      return;
    }

    _consecutiveErrors++;

    if (error.permanent || _consecutiveErrors >= _maxConsecutiveErrors) {
      _logger.e('Error permanente o límite alcanzado, deteniendo STT');
      stopListening();
      onStatusUpdate?.call('Error de reconocimiento');
    }
  }

  void _onSpeechStatus(String status) {
    _logger.d('STT Status: $status');

    if (status == 'done' || status == 'notListening') {
      _isListening = false;

      // ✅ BUG 1 FIX: marcar el session manager como idle cuando el STT
      // termina por su cuenta (pauseFor expirado, fin natural de sesión).
      // Sin esto el coordinator veía sessionManager.isIdle==false y entraba
      // en un bucle intentando detener un STT que ya había terminado.
      if (!_sessionManager.isIdle) {
        _logger.d('🔄 STT terminó solo → markIdle()');
        _sessionManager.markIdle();
      }
    }

    if (status == 'listening') {
      _consecutiveErrors = 0;
    }
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────

  VoiceCommandResult _fallbackClassification(String text) {
    final normalized = text.toLowerCase().trim();

    if (normalized.contains('muev') || normalized.contains('adelante') ||
        normalized.contains('avanza') || normalized.contains('camina') ||
        normalized.contains('anda')   || normalized.contains('sigue')  ||
        normalized.contains('vamos')  || normalized.contains('forward')) {
      return VoiceCommandResult(label: 'MOVE', confidence: 0.80, passesThreshold: true, threshold: 0.65, inferenceTimeMs: 0, logits: []);
    }
    if (normalized.contains('para')  || normalized.contains('det') ||
        normalized.contains('stop')  || normalized.contains('alto') ||
        normalized.contains('quieto')|| normalized.contains('frena')) {
      return VoiceCommandResult(label: 'STOP', confidence: 0.90, passesThreshold: true, threshold: 0.65, inferenceTimeMs: 0, logits: []);
    }
    if (normalized.contains('izquierda') || normalized.contains('izq') || normalized.contains('left')) {
      return VoiceCommandResult(label: 'TURN_LEFT', confidence: 0.75, passesThreshold: true, threshold: 0.60, inferenceTimeMs: 0, logits: []);
    }
    if (normalized.contains('derecha') || normalized.contains('der') || normalized.contains('right')) {
      return VoiceCommandResult(label: 'TURN_RIGHT', confidence: 0.75, passesThreshold: true, threshold: 0.60, inferenceTimeMs: 0, logits: []);
    }
    if (normalized.contains('ayuda') || normalized.contains('help') || normalized.contains('auxilio')) {
      return VoiceCommandResult(label: 'HELP', confidence: 0.85, passesThreshold: true, threshold: 0.70, inferenceTimeMs: 0, logits: []);
    }
    if (normalized.contains('repite') || normalized.contains('repeat') || normalized.contains('otra vez')) {
      return VoiceCommandResult(label: 'REPEAT', confidence: 0.70, passesThreshold: true, threshold: 0.55, inferenceTimeMs: 0, logits: []);
    }

    return VoiceCommandResult(label: 'UNKNOWN', confidence: 0.30, passesThreshold: false, threshold: 0.50, inferenceTimeMs: 0, logits: []);
  }

  Action _labelToAction(String label) {
    switch (label) {
      case 'MOVE':       return Action.move;
      case 'STOP':       return Action.stop;
      case 'TURN_LEFT':  return Action.turnLeft;
      case 'TURN_RIGHT': return Action.turnRight;
      case 'REPEAT':     return Action.repeat;
      case 'HELP':       return Action.help;
      default:           return Action.unknown;
    }
  }

  NavigationIntent _actionToIntent(Action action, String text) {
    switch (action) {
      case Action.move:      return NavigationIntent(type: IntentType.navigate, target: 'forward', priority: 8, suggestedResponse: 'Avanzando');
      case Action.stop:      return NavigationIntent(type: IntentType.stop,     target: '',        priority: 10, suggestedResponse: 'Deteniéndome');
      case Action.turnLeft:  return NavigationIntent(type: IntentType.navigate, target: 'left',    priority: 7, suggestedResponse: 'Girando a la izquierda');
      case Action.turnRight: return NavigationIntent(type: IntentType.navigate, target: 'right',   priority: 7, suggestedResponse: 'Girando a la derecha');
      case Action.help:      return NavigationIntent(type: IntentType.help,     target: '',        priority: 9, suggestedResponse: 'Activando ayuda');
      default:               return NavigationIntent.unknown();
    }
  }

  Future<void> setSpeechRate(double rate) async {}
  Future<void> setVolume(double volume) async {}

  Map<String, dynamic> getStatistics() => {
    'is_initialized':    _isInitialized,
    'is_listening':      _isListening,
    'is_processing':     _isProcessing,
    'consecutive_errors': _consecutiveErrors,
    'session_state':     _sessionManager.state.name,
    'pause_timeout_ms':  _pauseTimeout.inMilliseconds,
    'wake_word_active':  _wakeWordActive,
    'fsm_stats':         _fsm.getStatistics(),
    'classifier_stats':  {'inference_count': _classifier.inferenceCount},
  };

  void resetFSM() {
    _fsm.reset();
    _consecutiveErrors = 0;
  }

  bool get isInitialized => _isInitialized;
  bool get isListening   => _isListening;
  bool get isProcessing  => _isProcessing;

  void dispose() {
    stopListening();
    _classifier.dispose();
    _sessionManager.dispose();
    _logger.i('IntegratedVoiceCommandService disposed');
  }
}