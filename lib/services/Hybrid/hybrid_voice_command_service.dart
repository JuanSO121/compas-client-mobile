// lib/services/Hybrid/hybrid_voice_command_service.dart
// ✅ SERVICIO HÍBRIDO: GEMINI (online) + TFLite (offline + safety)

import 'dart:async';
import 'package:logger/logger.dart';
import 'package:speech_to_text/speech_recognition_error.dart' as stt;
import 'package:speech_to_text/speech_recognition_result.dart' as stt;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:permission_handler/permission_handler.dart';
import 'package:google_generative_ai/google_generative_ai.dart';

import '../../models/shared_models.dart';
import '../../config/api_config.dart';
import '../../models/voice_command.dart';
import '../AI/ai_mode_controller.dart';
import '../AI/robot_fsm.dart';
import '../AI/stt_session_manager.dart';
import '../AI/voice_command_classifier.dart';


class HybridVoiceCommandService {
  static final HybridVoiceCommandService _instance =
  HybridVoiceCommandService._internal();
  factory HybridVoiceCommandService() => _instance;
  HybridVoiceCommandService._internal();

  final Logger _logger = Logger();
  final stt.SpeechToText _speech = stt.SpeechToText();
  final VoiceCommandClassifier _classifier = VoiceCommandClassifier();
  final RobotFSM _fsm = RobotFSM();
  final STTSessionManager _sessionManager = STTSessionManager();
  final AIModeController _aiMode = AIModeController();

  // Gemini
  GenerativeModel? _geminiModel;
  ChatSession? _chatSession;

  bool _isInitialized = false;
  bool _isListening = false;
  bool _isProcessing = false;
  String _lastPartialText = '';
  int _consecutiveErrors = 0;

  static const Duration _pauseTimeout = Duration(seconds: 2);
  static const int _maxConsecutiveErrors = 3;

  // ✅ INTENCIONES CRÍTICAS DE SEGURIDAD (detectadas siempre localmente)
  static const List<String> _criticalIntents = [
    'baño',
    'salida',
    'perdido',
    'ayuda',
    'socorro',
    'auxilio',
    'emergencia',
  ];

  Function(NavigationIntent)? onCommandDetected;
  Function(NavigationIntent)? onCommandExecuted;
  Function(String)? onCommandRejected;
  Function(String)? onStatusUpdate;
  Function(String)? onGeminiResponse; // ✅ Respuesta conversacional

  STTSessionManager get sessionManager => _sessionManager;

  Future<void> initialize() async {
    if (_isInitialized) {
      _logger.w('Servicio ya inicializado');
      return;
    }

    try {
      _logger.i('Inicializando HybridVoiceCommandService...');

      await _ensurePermissions();

      // 1. Inicializar AI Mode Controller
      await _aiMode.initialize();

      // 2. Inicializar Gemini si está disponible
      if (_aiMode.geminiAvailable) {
        await _initializeGemini();
      }

      // 3. Inicializar STT
      final available = await _speech.initialize(
        onError: _onSpeechError,
        onStatus: _onSpeechStatus,
        debugLogging: false,
        finalTimeout: const Duration(milliseconds: 1500),
      );

      if (!available) {
        throw Exception('Speech recognition no disponible');
      }

      // 4. Inicializar clasificador local (siempre necesario para safety)
      try {
        await _classifier.initialize();
        _logger.i('✅ Clasificador local listo');
      } catch (e) {
        _logger.w('⚠️ Clasificador local no disponible: $e');
      }

      _isInitialized = true;
      _logger.i('✅ HybridVoiceCommandService listo');
      _logger.i('   Modo: ${_aiMode.getModeDescription()}');

    } catch (e) {
      _logger.e('❌ Error inicializando servicio: $e');
      rethrow;
    }
  }

  Future<void> _initializeGemini() async {
    try {
      _geminiModel = GenerativeModel(
        model: 'gemini-1.5-flash',
        apiKey: ApiConfig.geminiApiKey,
        generationConfig: GenerationConfig(
          temperature: 0.7,
          maxOutputTokens: 150,
        ),
        systemInstruction: Content.system('''
Eres COMPAS, un asistente de navegación para personas con discapacidad visual en interiores.

CONTEXTO:
- Estás en un edificio educativo
- El usuario se comunica por voz
- Debes ser conciso, claro y empático

FUNCIONES:
1. Responder preguntas sobre el entorno
2. Dar indicaciones de navegación
3. Proporcionar información de orientación

IMPORTANTE:
- Respuestas cortas (máximo 2 oraciones)
- Lenguaje natural y amigable
- Si detectas emergencia, di "EMERGENCIA" al inicio
- Para navegación, menciona puntos de referencia

Ejemplos:
Usuario: "¿Dónde está la cafetería?"
Tú: "La cafetería está en el segundo piso, al lado de las escaleras principales."

Usuario: "¿Qué hay frente a mí?"
Tú: "Necesito activar la cámara para ver qué hay adelante."
'''),
      );

      // Crear sesión de chat
      _chatSession = _geminiModel!.startChat();

      _logger.i('✅ Gemini inicializado para conversación');
    } catch (e) {
      _logger.e('Error inicializando Gemini: $e');
      _geminiModel = null;
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
      _logger.i('🎤 Escucha iniciada (${_aiMode.getModeDescription()})');

    } catch (e) {
      _logger.e('Error iniciando escucha: $e');
      _consecutiveErrors++;

      if (_consecutiveErrors < _maxConsecutiveErrors) {
        _logger.w('Reintentando... ($_consecutiveErrors/$_maxConsecutiveErrors)');
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
    if (!await _sessionManager.markStarting()) {
      _logger.w('⚠️ Session manager rechazó inicio');
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

      final mode = _aiMode.canUseGemini() ? 'online' : 'offline';
      onStatusUpdate?.call('Escuchando ($mode)...');

    } catch (e) {
      _logger.e('Error iniciando sesión STT: $e');
      _isListening = false;
      _sessionManager.markIdle();
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
        return;
      }

      // ✅ PASO 1: VERIFICAR INTENCIÓN CRÍTICA DE SEGURIDAD (siempre local)
      final criticalIntent = _detectCriticalIntent(text);
      if (criticalIntent != null) {
        _logger.w('🚨 INTENCIÓN CRÍTICA DETECTADA: ${criticalIntent.type}');
        await _handleCriticalIntent(criticalIntent);
        return;
      }

      // ✅ PASO 2: DECIDIR PROCESAMIENTO SEGÚN MODO
      if (_aiMode.canUseGemini()) {
        await _processWithGemini(text);
      } else {
        await _processWithLocalModel(text);
      }

    } catch (e, stackTrace) {
      _logger.e('Error procesando comando: $e');
      _logger.e('StackTrace: $stackTrace');
      _consecutiveErrors++;
    } finally {
      _isProcessing = false;
    }
  }

  /// ✅ DETECTAR INTENCIONES CRÍTICAS (siempre local, inmediato)
  NavigationIntent? _detectCriticalIntent(String text) {
    final normalized = text.toLowerCase().trim();

    // Baño
    if (normalized.contains('baño') ||
        normalized.contains('sanitario') ||
        normalized.contains('servicio')) {
      return NavigationIntent(
        type: IntentType.navigate,
        target: 'bathroom',
        priority: 10,
        suggestedResponse: 'Navegando al baño más cercano',
      );
    }

    // Salida
    if (normalized.contains('salida') ||
        normalized.contains('salir') ||
        normalized.contains('exit')) {
      return NavigationIntent(
        type: IntentType.navigate,
        target: 'exit',
        priority: 10,
        suggestedResponse: 'Dirigiéndote a la salida',
      );
    }

    // Perdido / Ayuda
    if (normalized.contains('perdido') ||
        normalized.contains('perdida') ||
        normalized.contains('perdida') ||
        normalized.contains('ayuda') ||
        normalized.contains('socorro') ||
        normalized.contains('auxilio') ||
        normalized.contains('emergencia')) {
      return NavigationIntent(
        type: IntentType.help,
        target: '',
        priority: 10,
        suggestedResponse: 'Activando asistencia de emergencia',
      );
    }

    return null;
  }

  /// ✅ MANEJAR INTENCIÓN CRÍTICA (acción inmediata)
  Future<void> _handleCriticalIntent(NavigationIntent intent) async {
    _consecutiveErrors = 0;

    onCommandDetected?.call(intent);
    onCommandExecuted?.call(intent);

    _logger.i('✅ Intención crítica ejecutada: ${intent.target}');
  }

  /// ✅ PROCESAR CON GEMINI (online + conversacional)
  Future<void> _processWithGemini(String text) async {
    _logger.i('[GEMINI] Procesando: "$text"');

    try {
      // Enviar mensaje a Gemini
      final response = await _chatSession!.sendMessage(
        Content.text(text),
      ).timeout(const Duration(seconds: 5));

      final geminiText = response.text?.trim() ?? '';

      if (geminiText.isEmpty) {
        throw Exception('Respuesta vacía de Gemini');
      }

      _logger.i('[GEMINI] Respuesta: "$geminiText"');

      // ✅ Verificar si Gemini detectó emergencia
      if (geminiText.toUpperCase().startsWith('EMERGENCIA')) {
        final emergencyIntent = NavigationIntent(
          type: IntentType.help,
          target: '',
          priority: 10,
          suggestedResponse: geminiText.replaceFirst('EMERGENCIA', '').trim(),
        );
        await _handleCriticalIntent(emergencyIntent);
        return;
      }

      // ✅ Respuesta conversacional normal
      onGeminiResponse?.call(geminiText);

      // Verificar si hay comando de navegación implícito
      final navIntent = _extractNavigationFromGemini(geminiText, text);
      if (navIntent != null) {
        onCommandDetected?.call(navIntent);
        onCommandExecuted?.call(navIntent);
      }

      _consecutiveErrors = 0;

    } on TimeoutException {
      _logger.e('⏱️ Timeout con Gemini, usando modelo local');
      await _processWithLocalModel(text);
    } catch (e) {
      _logger.e('❌ Error con Gemini: $e, usando fallback local');
      await _processWithLocalModel(text);
    }
  }

  /// ✅ EXTRAER NAVEGACIÓN DE RESPUESTA GEMINI
  NavigationIntent? _extractNavigationFromGemini(String response, String originalText) {
    final lower = response.toLowerCase();

    // Detectar comandos de movimiento en la respuesta
    if (lower.contains('avanz') || lower.contains('adelante')) {
      return NavigationIntent(
        type: IntentType.navigate,
        target: 'forward',
        priority: 7,
        suggestedResponse: response,
      );
    }

    if (lower.contains('izquierda')) {
      return NavigationIntent(
        type: IntentType.navigate,
        target: 'left',
        priority: 7,
        suggestedResponse: response,
      );
    }

    if (lower.contains('derecha')) {
      return NavigationIntent(
        type: IntentType.navigate,
        target: 'right',
        priority: 7,
        suggestedResponse: response,
      );
    }

    return null;
  }

  /// ✅ PROCESAR CON MODELO LOCAL (offline o fallback)
  Future<void> _processWithLocalModel(String text) async {
    _logger.i('[LOCAL] Procesando: "$text"');

    VoiceCommandResult result;

    if (_classifier.isInitialized) {
      result = await _classifier.classify(text);
    } else {
      result = _fallbackClassification(text);
    }

    _logger.i('[LOCAL] "$text" → ${result.label} (${(result.confidence * 100).toStringAsFixed(1)}%)');

    if (!result.passesThreshold) {
      _logger.w('⛔ Confianza baja');
      onCommandRejected?.call('Comando no reconocido');
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
  }

  VoiceCommandResult _fallbackClassification(String text) {
    final normalized = text.toLowerCase().trim();

    if (normalized.contains('muev') || normalized.contains('adelante') ||
        normalized.contains('avanza') || normalized.contains('forward')) {
      return VoiceCommandResult(
        label: 'MOVE',
        confidence: 0.80,
        passesThreshold: true,
        threshold: 0.65,
        inferenceTimeMs: 0,
        logits: [],
      );
    }

    if (normalized.contains('para') || normalized.contains('det') ||
        normalized.contains('stop') || normalized.contains('alto')) {
      return VoiceCommandResult(
        label: 'STOP',
        confidence: 0.90,
        passesThreshold: true,
        threshold: 0.65,
        inferenceTimeMs: 0,
        logits: [],
      );
    }

    if (normalized.contains('izquierda') || normalized.contains('left')) {
      return VoiceCommandResult(
        label: 'TURN_LEFT',
        confidence: 0.75,
        passesThreshold: true,
        threshold: 0.60,
        inferenceTimeMs: 0,
        logits: [],
      );
    }

    if (normalized.contains('derecha') || normalized.contains('right')) {
      return VoiceCommandResult(
        label: 'TURN_RIGHT',
        confidence: 0.75,
        passesThreshold: true,
        threshold: 0.60,
        inferenceTimeMs: 0,
        logits: [],
      );
    }

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
      return;
    }

    _isListening = false;
    _isProcessing = false;
    _consecutiveErrors = 0;

    try {
      if (_speech.isListening) {
        _sessionManager.markStopping();
        await _speech.stop();
      }
      _sessionManager.markIdle();
    } catch (e) {
      _logger.e('Error deteniendo STT: $e');
      _sessionManager.forceReset();
    }

    onStatusUpdate?.call('Escucha detenida');
  }

  void _onSpeechError(stt.SpeechRecognitionError error) {
    _logger.e('STT Error: ${error.errorMsg}');

    if (error.errorMsg == 'error_busy') {
      return;
    }

    _consecutiveErrors++;

    if (error.permanent || _consecutiveErrors >= _maxConsecutiveErrors) {
      stopListening();
      onStatusUpdate?.call('Error de reconocimiento');
    }
  }

  void _onSpeechStatus(String status) {
    if (status == 'done' || status == 'notListening') {
      _isListening = false;
    }

    if (status == 'listening') {
      _consecutiveErrors = 0;
    }
  }

  Action _labelToAction(String label) {
    switch (label) {
      case 'MOVE': return Action.move;
      case 'STOP': return Action.stop;
      case 'TURN_LEFT': return Action.turnLeft;
      case 'TURN_RIGHT': return Action.turnRight;
      case 'REPEAT': return Action.repeat;
      case 'HELP': return Action.help;
      default: return Action.unknown;
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

  Map<String, dynamic> getStatistics() {
    return {
      'is_initialized': _isInitialized,
      'is_listening': _isListening,
      'is_processing': _isProcessing,
      'consecutive_errors': _consecutiveErrors,
      'session_state': _sessionManager.state.name,
      'ai_mode': _aiMode.getStatistics(),
      'fsm_stats': _fsm.getStatistics(),
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
    _aiMode.dispose();
    _logger.i('HybridVoiceCommandService disposed');
  }
}