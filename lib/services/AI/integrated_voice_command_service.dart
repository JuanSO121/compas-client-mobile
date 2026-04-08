// lib/services/AI/integrated_voice_command_service.dart
// ✅ v4.0 — Reinicio automático post-comando + arquitectura limpia.
//
// ============================================================================
// PROBLEMA RAÍZ (v3.x)
// ============================================================================
//
//  Después de ejecutar un comando (ej: "navegar a Entrada"), el sistema
//  quedaba sordo: el STT no se reactivaba y el wake word tampoco.
//
//  Flujo roto en v3.x:
//    1. WakeWordService detecta "Oye COMPAS" → cierra su sesión STT.
//    2. Coordinator llama startListening() → STT escucha → usuario habla.
//    3. _onSpeechResult() recibe el comando final → _processCommand().
//    4. _onSpeechStatus('done') → markIdle() en STTSessionManager. ✅
//    5. Coordinator ejecuta el intent y habla TTS.
//    6. TTS termina → VoiceNavigationService._resumeWakeWord().
//    7. ❌ _resumeWakeWord() hace un early return porque _queue.isNotEmpty
//       (la instrucción de navegación TTS aún está en cola).
//    8. ❌ WakeWordService nunca hace resume() → ya no escucha nada.
//
//  Adicionalmente en STTSessionManager v1.x:
//    _minTimeBetweenSessions (500ms) bloqueaba canStart() si el coordinator
//    intentaba abrir el STT justo al terminar el TTS.
//
// ============================================================================
// SOLUCIÓN v4.0
// ============================================================================
//
//  1. _autoRestartWakeWord() — llamado al final de _processCommand() y en
//     _onSpeechStatus('done'). Espera a que el TTS termine (con timeout)
//     antes de hacer resume() en WakeWordService. No depende de que
//     VoiceNavigationService._resumeWakeWord() haga el trabajo.
//
//  2. El coordinator ya no necesita orquestar el reinicio del wake word
//     desde fuera. Este servicio se auto-gestiona.
//
//  3. STTSessionManager v2.0: sin _minTimeBetweenSessions, sin timers
//     internos. canStart() solo verifica el estado FSM.
//
//  4. Separación clara de responsabilidades:
//     - IntegratedVoiceCommandService: gestiona el STT de comandos.
//     - WakeWordService: gestiona detección del wake word.
//     - VoiceNavigationService: gestiona el TTS de guía.
//     - Coordinator (NavigationCoordinator): orquesta el flujo alto nivel.
//
// ============================================================================
// NOTAS SOBRE speech_to_text (documentación oficial)
// ============================================================================
//
//  El paquete speech_to_text está diseñado para "comandos cortos y frases
//  breves, no para conversión continua o escucha siempre activa".
//  (https://pub.dev/packages/speech_to_text)
//
//  La estrategia correcta para un asistente de voz es:
//    - WakeWordService: sesión larga con pauseFor alto → detecta el wake word.
//    - IntegratedVoiceCommandService: sesión corta por demanda → captura el
//      comando → cierra → devuelve control a WakeWordService.
//
//  Este archivo implementa exactamente ese patrón.

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_recognition_error.dart' as stt;
import 'package:speech_to_text/speech_recognition_result.dart' as stt;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:permission_handler/permission_handler.dart';

import '../../models/shared_models.dart';
import 'voice_command_classifier.dart';
import 'robot_fsm.dart';
import 'stt_session_manager.dart';
import 'wake_word_service.dart';

class IntegratedVoiceCommandService {
  static final IntegratedVoiceCommandService _instance =
      IntegratedVoiceCommandService._internal();
  factory IntegratedVoiceCommandService() => _instance;
  IntegratedVoiceCommandService._internal();

  // ─── Dependencias ──────────────────────────────────────────────────────────

  final stt.SpeechToText _speech = stt.SpeechToText();
  final VoiceCommandClassifier _classifier = VoiceCommandClassifier();
  final RobotFSM _fsm = RobotFSM();
  final STTSessionManager _sessionManager = STTSessionManager();

  STTSessionManager get sessionManager => _sessionManager;

  // ─── Referencias externas ──────────────────────────────────────────────────

  /// Inyectado por el coordinator para poder hacer resume() post-TTS.
  WakeWordService? _wakeWordService;

  /// Callback que el coordinator registra para saber si el TTS está hablando.
  /// Si es null, no se espera al TTS antes de reactivar el wake word.
  bool Function()? isTtsSpeaking;

  // ─── Estado interno ────────────────────────────────────────────────────────

  bool _isInitialized = false;
  bool _isListening = false;
  bool _isProcessing = false;
  String _lastPartialText = '';
  int _consecutiveErrors = 0;

  /// ✅ Bandera de control: true mientras el sistema está en modo "escucha
  /// activa" (wake word detectado, esperando comando). Permite que
  /// _autoRestartWakeWord() sepa si debe reactivar el wake word o no.
  bool _wakeWordModeActive = false;

  // Variantes de wake word que el STT podría capturar accidentalmente
  // al solaparse la sesión de WakeWordService con la de comandos.
  static const List<String> _wakeWordVariants = [
    'oye compas',
    'oye compass',
    'oye comas',
    'oy compas',
    'hoy compas',
    'hey compas',
    'hey compass',
  ];

  // ─── Configuración STT ─────────────────────────────────────────────────────

  /// Tiempo que el STT espera silencio antes de enviar resultado final.
  /// Android ignora valores > ~5s en muchos dispositivos.
  static const Duration _pauseFor = Duration(milliseconds: 4500);

  /// Tiempo máximo de escucha por sesión de comando.
  static const Duration _listenFor = Duration(seconds: 15);

  static const int _maxConsecutiveErrors = 3;

  // ─── Cooldown entre sesiones STT ───────────────────────────────────────────

  /// Tiempo mínimo entre el cierre de una sesión STT y la apertura de otra.
  /// Necesario en Android para que el SpeechRecognizer libere el hardware.
  /// Más corto que en v1.x porque STTSessionManager ya no impone su propio
  /// cooldown — este es el único punto de control.
  static const Duration _sessionCooldown = Duration(milliseconds: 600);

  DateTime? _lastSessionClosedAt;

  // ─── Callbacks ─────────────────────────────────────────────────────────────

  Function(NavigationIntent)? onCommandDetected;
  Function(NavigationIntent)? onCommandExecuted;
  Function(String)? onCommandRejected;
  Function(String)? onStatusUpdate;
  Function(String)? onPartialResult;

  // ─── Inicialización ────────────────────────────────────────────────────────

  Future<void> initialize() async {
    if (_isInitialized) return;

    await _ensurePermissions();

    final available = await _speech.initialize(
      onError: _onSpeechError,
      onStatus: _onSpeechStatus,
      debugLogging: false,
    );

    if (!available) throw Exception('speech_to_text no disponible');

    try {
      await _classifier.initialize();
      _log('✅ Clasificador TFLite listo');
    } catch (e) {
      _log('⚠️ TFLite no disponible — usando keyword fallback: $e');
    }

    _isInitialized = true;
    _log('v4.0 lista');
  }

  Future<void> _ensurePermissions() async {
    final status = await Permission.microphone.status;
    if (status.isDenied) {
      final result = await Permission.microphone.request();
      if (!result.isGranted) throw Exception('Permiso de micrófono denegado');
    }
    if (status.isPermanentlyDenied) {
      throw Exception('Permiso permanentemente denegado — ir a Ajustes');
    }
  }

  // ─── Inyección de dependencias ─────────────────────────────────────────────

  /// Llamado por el coordinator para conectar el WakeWordService.
  /// Permite que este servicio reactive el wake word tras cada comando.
  void attachWakeWordService(WakeWordService wakeWordService) {
    _wakeWordService = wakeWordService;
    _log('WakeWordService conectado');
  }

  void setWakeWordActive(bool active) {
    _wakeWordModeActive = active;
  }

  /// Informa a este servicio si está activo en modo "post-wake-word".
  /// Cuando es true, después de procesar un comando se reactivará
  /// el wake word automáticamente.
  void setWakeWordModeActive(bool active) {
    _wakeWordModeActive = active;
    _log('wakeWordMode=$active');
  }

  // ─── startListening ────────────────────────────────────────────────────────

  Future<void> startListening() async {
    if (!_isInitialized) throw StateError('Servicio no inicializado');
    if (_isListening) {
      _log('⚠️ Ya escuchando');
      return;
    }

    // Respetar cooldown para que Android libere el SpeechRecognizer.
    if (_lastSessionClosedAt != null) {
      final elapsed = DateTime.now().difference(_lastSessionClosedAt!);
      if (elapsed < _sessionCooldown) {
        final remaining = _sessionCooldown - elapsed;
        _log('Cooldown: esperando ${remaining.inMilliseconds}ms');
        await Future.delayed(remaining);
      }
    }

    try {
      await _startListeningSession();
    } catch (e) {
      _consecutiveErrors++;
      _log(
        '❌ Error iniciando ($e) — intento $_consecutiveErrors/$_maxConsecutiveErrors',
      );
      if (_consecutiveErrors < _maxConsecutiveErrors) {
        await Future.delayed(const Duration(milliseconds: 500));
        await startListening();
      } else {
        _consecutiveErrors = 0;
        rethrow;
      }
    }
  }

  Future<void> _startListeningSession() async {
    if (!_sessionManager.markStarting()) {
      _log('Session manager rechazó el inicio');
      return;
    }

    if (_isProcessing) {
      _log('⚠️ Procesando — cancelando apertura');
      _sessionManager.markIdle();
      return;
    }

    _lastPartialText = '';

    try {
      await _speech.listen(
        onResult: _onSpeechResult,
        listenFor: _listenFor,
        pauseFor: _pauseFor,
        localeId: 'es_CO',
        listenOptions: stt.SpeechListenOptions(
          partialResults: true,
          cancelOnError: false,
          listenMode: stt.ListenMode.confirmation,
          onDevice: false,
          autoPunctuation: false,
          enableHapticFeedback: false,
        ),
      );

      _isListening = true;
      _sessionManager.markActive();
      _consecutiveErrors = 0;
      _log(
        '✅ Escuchando (pauseFor=${_pauseFor.inMs}ms, listenFor=${_listenFor.inSeconds}s)',
      );
      onStatusUpdate?.call('Escuchando...');
    } catch (e) {
      _isListening = false;
      _sessionManager.markIdle();
      if (e.toString().contains('error_busy')) {
        _log('STT ocupado — esperando 1s antes de reintentar');
        await Future.delayed(const Duration(seconds: 1));
      }
      rethrow;
    }
  }

  // ─── stopListening ─────────────────────────────────────────────────────────

  Future<void> stopListening() async {
    if (!_isListening && !_isProcessing && _sessionManager.isIdle) {
      return;
    }

    _log('Deteniendo STT...');
    _isListening = false;
    _isProcessing = false;
    _consecutiveErrors = 0;

    try {
      if (_speech.isListening) {
        await _speech.stop();
      }
    } catch (e) {
      _log('⚠️ Error en stop(): $e');
      _sessionManager.forceReset();
      return;
    }

    _lastSessionClosedAt = DateTime.now();
    _sessionManager.markIdle();
    onStatusUpdate?.call('Escucha detenida');
  }

  // ─── Resultado STT ─────────────────────────────────────────────────────────

  void _onSpeechResult(stt.SpeechRecognitionResult result) {
    final text = result.recognizedWords.trim();
    if (text.isEmpty) return;

    if (result.finalResult) {
      _log('STT final: "$text"');
      _processCommand(text);
    } else if (text != _lastPartialText) {
      _lastPartialText = text;
      onPartialResult?.call(text);
    }
  }

  // ─── Procesamiento del comando ─────────────────────────────────────────────

  Future<void> _processCommand(String text) async {
    if (_isProcessing) {
      _log('⚠️ Ya procesando');
      return;
    }

    // Filtrar si el STT capturó accidentalmente el wake word.
    final normalized = text.toLowerCase().trim();
    if (_wakeWordModeActive &&
        _wakeWordVariants.any(
          (v) => normalized == v || normalized.startsWith(v),
        )) {
      _log('⚠️ Wake word capturado por STT — ignorado: "$text"');
      return;
    }

    if (text.length < 2) {
      _log('Texto muy corto — ignorado: "$text"');
      return;
    }

    _isProcessing = true;

    try {
      _log('📝 Procesando: "$text"');

      final intent = NavigationIntent(
        type: IntentType.navigate,
        target: 'forward',
        priority: 5,
        suggestedResponse: text,
      );

      _consecutiveErrors = 0;
      onCommandDetected?.call(intent);

      // ✅ Microtask garantiza que onCommandDetected termine (y el coordinator
      // guarde el texto capturado) antes de que onCommandExecuted lo consuma.
      await Future.microtask(() {
        onCommandExecuted?.call(intent);
      });
    } catch (e) {
      _log('❌ Error procesando: $e');
      _consecutiveErrors++;
    } finally {
      _isProcessing = false;
      // ✅ v4.0: Reactivar el wake word después de cada comando, independiente
      // de que el TTS haya terminado o no. La espera al TTS se hace internamente.
      _autoRestartWakeWord();
    }
  }

  // ─── Auto-reinicio del wake word ───────────────────────────────────────────

  /// Reactiva el WakeWordService después de que el TTS de respuesta termine.
  ///
  /// Este método es el núcleo del fix v4.0. En versiones anteriores, el
  /// reinicio dependía de VoiceNavigationService._resumeWakeWord(), que
  /// hacía early return si el TTS aún tenía items en cola.
  ///
  /// Aquí esperamos explícitamente a que el TTS termine (con timeout) antes
  /// de llamar wakeWordService.resume(). Esto garantiza que el micrófono
  /// no intente abrir dos sesiones simultáneas.
  Future<void> _autoRestartWakeWord() async {
    if (!_wakeWordModeActive) return;
    final wws = _wakeWordService;
    if (wws == null || !wws.isInitialized) return;

    // Esperar a que el TTS de confirmación termine antes de abrir el mic.
    // Max 8 segundos — si el TTS no termina en ese tiempo, reactivar igual.
    const Duration ttsWaitTimeout = Duration(seconds: 8);
    const Duration pollInterval = Duration(milliseconds: 200);
    final deadline = DateTime.now().add(ttsWaitTimeout);

    while (DateTime.now().isBefore(deadline)) {
      final speaking = isTtsSpeaking?.call() ?? false;
      if (!speaking) break;
      await Future.delayed(pollInterval);
    }

    // Cooldown adicional para que Android libere el canal de audio del TTS.
    await Future.delayed(const Duration(milliseconds: 400));

    if (!_wakeWordModeActive)
      return; // pudo haberse desactivado durante la espera

    try {
      await wws.resume();
      _log('✅ Wake word reactivado post-comando');
    } catch (e) {
      _log('⚠️ Error reactivando wake word: $e');
    }
  }

  // ─── Callbacks STT ─────────────────────────────────────────────────────────

  void _onSpeechStatus(String status) {
    _log('STT status: $status');

    if (status == 'done' || status == 'notListening') {
      final wasListening = _isListening;
      _isListening = false;
      _lastSessionClosedAt = DateTime.now();

      if (!_sessionManager.isIdle) {
        _sessionManager.markIdle();
      }

      // Si la sesión terminó sola sin que procesáramos un comando (ej: timeout
      // de silencio), y estamos en modo wake word → reactivar.
      if (wasListening && !_isProcessing && _wakeWordModeActive) {
        _log('STT terminó sin resultado → reactivando wake word');
        _autoRestartWakeWord();
      }
    }

    if (status == 'listening') {
      _consecutiveErrors = 0;
    }
  }

  void _onSpeechError(stt.SpeechRecognitionError error) {
    // error_busy: transición normal entre sesiones — ignorar.
    if (error.errorMsg == 'error_busy') return;

    // error_speech_timeout: silencio prolongado — reiniciar si en modo wake word.
    if (error.errorMsg == 'error_speech_timeout') {
      _isListening = false;
      _lastSessionClosedAt = DateTime.now();
      _sessionManager.markIdle();
      if (_wakeWordModeActive && !_isProcessing) {
        _autoRestartWakeWord();
      }
      return;
    }

    // error_client: race condition de Android al abrir sesión muy rápido.
    // No es fatal — reintentar con delay mayor.
    if (error.errorMsg == 'error_client') {
      _log('error_client — esperando 1500ms antes de reintentar');
      _isListening = false;
      _lastSessionClosedAt = DateTime.now();
      _sessionManager.markIdle();
      if (_wakeWordModeActive && !_isProcessing) {
        Future.delayed(const Duration(milliseconds: 1500), () {
          if (_wakeWordModeActive && !_isProcessing) {
            _autoRestartWakeWord();
          }
        });
      }
      return;
    }

    _log('STT error: ${error.errorMsg} (permanent=${error.permanent})');
    _isListening = false;
    _lastSessionClosedAt = DateTime.now();
    _sessionManager.markIdle();
    _consecutiveErrors++;

    if (error.permanent || _consecutiveErrors >= _maxConsecutiveErrors) {
      _log('❌ Error permanente o límite alcanzado');
      _consecutiveErrors = 0;
      return;
    }

    // Error recuperable → reintentar con delay.
    if (_wakeWordModeActive && !_isProcessing) {
      Future.delayed(const Duration(seconds: 2), _autoRestartWakeWord);
    }
  }

  // ─── Getters y helpers ─────────────────────────────────────────────────────

  bool get isInitialized => _isInitialized;
  bool get isListening => _isListening;
  bool get isProcessing => _isProcessing;
  bool get wakeWordModeActive => _wakeWordModeActive;

  Map<String, dynamic> getStatistics() => {
    'is_initialized': _isInitialized,
    'is_listening': _isListening,
    'is_processing': _isProcessing,
    'consecutive_errors': _consecutiveErrors,
    'session_state': _sessionManager.state.name,
    'wake_word_mode': _wakeWordModeActive,
    'pause_for_ms': _pauseFor.inMilliseconds,
    'session_cooldown_ms': _sessionCooldown.inMilliseconds,
    'fsm_stats': _fsm.getStatistics(),
  };

  void resetFSM() {
    _fsm.reset();
    _consecutiveErrors = 0;
  }

  static void _log(String msg) {
    assert(() {
      debugPrint('[VoiceCmd] $msg');
      return true;
    }());
  }

  void dispose() {
    stopListening();
    _classifier.dispose();
    _sessionManager.dispose();
    _wakeWordService = null;
    isTtsSpeaking = null;
  }
}

// ─── Extensión de conveniencia ────────────────────────────────────────────────

extension _DurationMs on Duration {
  int get inMs => inMilliseconds;
}
