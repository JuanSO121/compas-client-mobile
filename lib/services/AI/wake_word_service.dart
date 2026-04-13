// lib/services/AI/wake_word_service.dart
// ✅ v4.2 — pauseFor extendido · error_no_match recuperable · guard de eco TTS
//
// ============================================================================
//  CAMBIOS v4.1 → v4.2
// ============================================================================
//
//  FIX 1 — pauseFor: 8s → 20s
//    Con CPU saturada por ARCore/Unity (GC >100ms, FeatureExtraction 117ms)
//    el reconocedor expira el silencio antes de que el usuario termine de
//    hablar. Aumentar a 20s da margen suficiente sin coste real de batería
//    porque el VAD de Android sigue activo y el buffer se drena en cuanto
//    hay audio. En hardware rápido el comportamiento es idéntico a 8s.
//
//  FIX 2 — error_no_match tratado como recuperable (no permanent)
//    Android a veces marca error_no_match con permanent:true cuando la CPU
//    no puede procesar el audio a tiempo (logs: "FeatureExtraction took
//    117ms"). NO es un error irrecuperable del sistema — simplemente no
//    reconoció la frase. Solución: ignorar el flag permanent para este
//    error específico y reiniciar la sesión con _restartDelay normal.
//    Elimina el ciclo fatal: error_no_match → onError() → stop total.
//
//  FIX 3 — Guard de eco TTS (_ttsActive + suppressUntil)
//    Cuando TTS habla, el STT capta el audio propio y cierra la sesión
//    prematuramente (log: STT: "sistema" → notListening).
//    Nuevas APIs:
//      notifyTTSStarted() — llamar desde VoiceNavigationService._speak()
//                           antes de _ttsService!.speak()
//      notifyTTSEnded()   — llamar en el finally de _speak()
//    Internamente se establece un _suppressUntil = now + 1500ms tras el
//    final del TTS. Durante ese intervalo _onResult() descarta resultados
//    para evitar que el eco residual del altavoz se confunda con wake word.
//    _openSession() también bloquea la apertura si TTS está activo, y la
//    reencola automáticamente con _ttsSuppressDelay (600ms).
//
//  TODO LO DEMÁS ES IDÉNTICO A v4.1.

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';

// ─── WakeWordConfig ───────────────────────────────────────────────────────────

class WakeWordConfig {
  final String  keyword;
  final String? modelPath;
  final bool    isBuiltIn;

  const WakeWordConfig.builtIn(this.keyword)
      : modelPath = null,
        isBuiltIn = true;

  const WakeWordConfig.custom({
    required this.keyword,
    required String? modelPath,
  })  : modelPath = modelPath,
        isBuiltIn = false;
}

// ─── WakeWordService ──────────────────────────────────────────────────────────

class WakeWordService {
  static final WakeWordService _instance = WakeWordService._internal();
  factory WakeWordService() => _instance;
  WakeWordService._internal();

  // ─── Logging ────────────────────────────────────────────────────────────
  static void _log(String msg) {
    assert(() {
      debugPrint('[WakeWord] $msg');
      return true;
    }());
  }

  static void _logError(String msg) => debugPrint('[WakeWord] ❌ $msg');

  // ─── STT ────────────────────────────────────────────────────────────────
  final SpeechToText _stt = SpeechToText();

  // ─── Estado ─────────────────────────────────────────────────────────────
  bool    _isInitialized = false;
  bool    _isListening   = false;
  bool    _isPaused      = false;
  bool    _isStarted     = false;
  bool    _detected      = false;

  String? _currentKeyword;
  double  _currentSensitivity = 0.7;

  int       _detectionCount = 0;
  DateTime? _lastDetection;

  // ─── FIX 3: Guard de eco TTS ─────────────────────────────────────────────
  bool      _ttsActive    = false;          // TTS reproduciendo ahora mismo
  DateTime? _suppressUntil;                // eco residual suprimido hasta aquí

  // Delay para reintentar _openSession() cuando TTS aún está activo
  static const Duration _ttsSuppressDelay = Duration(milliseconds: 600);

  // Ventana de supresión tras el fin del TTS para ignorar eco residual
  static const Duration _ttsEchoWindow = Duration(milliseconds: 1500);

  // ─── Callbacks ──────────────────────────────────────────────────────────
  Function()?       onWakeWordDetected;
  Function(String)? onError;

  // ─── Palabras clave ──────────────────────────────────────────────────────
  static const List<String> _keywords = [
    'oye compas',
    'oye compass',
    'oye comas',
    'ey compas',
    'hey compas',
    'hey compass',
    'oye com pas',
    'compas',
    'compass',
  ];

  static const Duration _sessionDuration = Duration(hours: 1);

  // ✅ v4.1: 800ms (mantenido)
  static const Duration _restartDelay = Duration(milliseconds: 800);

  // ✅ v4.1: 1500ms para error_client (mantenido)
  static const Duration _errorClientDelay = Duration(milliseconds: 1500);

  // ─── initialize ──────────────────────────────────────────────────────────

  Future<void> initialize({
    required String accessKey,
    WakeWordConfig config = const WakeWordConfig.builtIn('hey google'),
    double sensitivity = 0.7,
  }) async {
    if (_isInitialized) return;

    try {
      _log('Inicializando v4.2 (pauseFor=20s, error_no_match recuperable, guard TTS)...');

      _currentKeyword     = config.keyword;
      _currentSensitivity = sensitivity;

      final available = await _stt.initialize(
        onError:      _onSttError,
        onStatus:     _onSttStatus,
        debugLogging: false,
      );

      if (!available) throw Exception('STT no disponible en este dispositivo');

      _isInitialized = true;
      _log('v4.2 listo — keywords: ${_keywords.join(", ")}');
    } catch (e) {
      _logError('Error inicializando: $e');
      onError?.call(e.toString());
      rethrow;
    }
  }

  // ─── API de guard TTS (FIX 3) ────────────────────────────────────────────

  /// Llamar desde VoiceNavigationService ANTES de iniciar TTS.
  /// Cierra la sesión STT activa para evitar que el altavoz contamine el mic.
  Future<void> notifyTTSStarted() async {
    _ttsActive   = true;
    _suppressUntil = null; // resetear ventana anterior
    _log('TTS activo — suprimiendo STT');
    await _closeSession();
  }

  /// Llamar desde VoiceNavigationService en el finally de _speak().
  /// Activa la ventana de supresión de eco y reencola la apertura de sesión.
  void notifyTTSEnded() {
    _ttsActive     = false;
    _suppressUntil = DateTime.now().add(_ttsEchoWindow);
    _log('TTS terminó — eco suprimido ${_ttsEchoWindow.inMilliseconds}ms, '
        'reabriendo STT...');

    if (_isStarted && !_isPaused && !_detected) {
      Future.delayed(_ttsEchoWindow, () {
        if (_isStarted && !_isPaused && !_detected && !_isListening) {
          _openSession();
        }
      });
    }
  }

  // ─── start ───────────────────────────────────────────────────────────────

  Future<void> start() async {
    if (!_isInitialized) throw StateError('No inicializado');
    if (_isStarted && !_isPaused) return;

    _isStarted = true;
    _isPaused  = false;
    _detected  = false;

    _log('Iniciando detección...');
    await _openSession();
  }

  // ─── pause ───────────────────────────────────────────────────────────────

  Future<void> pause() async {
    if (!_isStarted || _isPaused) return;
    _isPaused = true;
    _log('Pausando...');
    await _closeSession();
  }

  // ─── resume ──────────────────────────────────────────────────────────────

  Future<void> resume() async {
    if (!_isStarted) return;
    if (!_isPaused && _isListening) return;

    _isPaused = false;
    _detected = false;
    _log('Reanudando...');
    await _openSession();
  }

  // ─── stop ────────────────────────────────────────────────────────────────

  Future<void> stop() async {
    if (!_isStarted) return;
    _isStarted = false;
    _isPaused  = false;
    _log('Deteniendo...');
    await _closeSession();
  }

  // ─── Sesión STT ──────────────────────────────────────────────────────────

  Future<void> _openSession() async {
    if (_isListening) return;
    if (!_isInitialized || !_isStarted || _isPaused) return;

    // FIX 3: bloquear apertura mientras TTS está activo
    if (_ttsActive) {
      _log('TTS activo — posponiendo apertura de sesión ${_ttsSuppressDelay.inMilliseconds}ms');
      Future.delayed(_ttsSuppressDelay, () {
        if (_isStarted && !_isPaused && !_detected && !_isListening) {
          _openSession();
        }
      });
      return;
    }

    // FIX 3: bloquear si aún estamos en la ventana de eco residual
    final now = DateTime.now();
    if (_suppressUntil != null && now.isBefore(_suppressUntil!)) {
      final remaining = _suppressUntil!.difference(now);
      _log('Eco residual — posponiendo ${remaining.inMilliseconds}ms');
      Future.delayed(remaining, () {
        if (_isStarted && !_isPaused && !_detected && !_isListening) {
          _openSession();
        }
      });
      return;
    }

    try {
      _isListening = true;

      await _stt.listen(
        onResult:       _onResult,
        listenFor:      _sessionDuration,
        // ✅ FIX 1: 8s → 20s para tolerar CPU saturada por ARCore/Unity
        pauseFor:       const Duration(seconds: 20),
        partialResults: true,
        localeId:       'es_CO',
        cancelOnError:  false,
        listenMode:     ListenMode.dictation,
      );

      _log('Sesión abierta (listenFor=1h, pauseFor=20s)');
    } catch (e) {
      _isListening = false;
      _logError('Error abriendo sesión: $e');
      _scheduleRestart();
    }
  }

  Future<void> _closeSession() async {
    if (!_isListening) return;
    _isListening = false;
    try {
      await _stt.stop();
      _log('Sesión cerrada');
    } catch (e) {
      _logError('Error cerrando sesión: $e');
    }
  }

  // ─── Resultado STT ───────────────────────────────────────────────────────

  void _onResult(SpeechRecognitionResult result) {
    if (!_isStarted || _isPaused || _detected) return;

    // FIX 3: descartar resultados durante ventana de eco TTS
    if (_ttsActive) return;
    final now = DateTime.now();
    if (_suppressUntil != null && now.isBefore(_suppressUntil!)) return;

    final text = result.recognizedWords.toLowerCase().trim();
    if (text.isEmpty) return;

    _log('STT: "$text"');

    for (final kw in _keywords) {
      if (text.contains(kw)) {
        _log('✅ Detectado: "$kw"');
        _detectionCount++;
        _lastDetection = DateTime.now();
        _detected = true;

        _closeSession().then((_) {
          onWakeWordDetected?.call();
        });
        return;
      }
    }
  }

  // ─── Callbacks STT ───────────────────────────────────────────────────────

  void _onSttStatus(String status) {
    _log('STT status: $status');

    if (status == 'done' || status == 'notListening') {
      final wasListening = _isListening;
      _isListening = false;

      if (wasListening && _isStarted && !_isPaused && !_detected) {
        _log('Sesión terminó sola — reiniciando...');
        _scheduleRestart();
      }
    }
  }

  void _onSttError(SpeechRecognitionError error) {
    // error_busy: ignorar
    if (error.errorMsg == 'error_busy') return;

    // error_speech_timeout: reiniciar normalmente
    if (error.errorMsg == 'error_speech_timeout') {
      _isListening = false;
      if (_isStarted && !_isPaused && !_detected) {
        _scheduleRestart();
      }
      return;
    }

    // ✅ v4.1 FIX: error_client — condición de carrera recuperable
    if (error.errorMsg == 'error_client') {
      _log('error_client — esperando liberación del recognizer '
          '(${_errorClientDelay.inMilliseconds}ms)...');
      _isListening = false;
      if (_isStarted && !_isPaused && !_detected) {
        Future.delayed(_errorClientDelay, () {
          if (_isStarted && !_isPaused && !_detected && !_isListening) {
            _openSession();
          }
        });
      }
      return;
    }

    // ✅ v4.2 FIX 2: error_no_match — NO es fatal aunque permanent:true
    // Android lo marca permanent cuando la CPU no procesa el audio a tiempo
    // (FeatureExtraction >100ms). Simplemente reiniciar la sesión.
    if (error.errorMsg == 'error_no_match') {
      _log('error_no_match — ignorando flag permanent, reiniciando sesión...');
      _isListening = false;
      if (_isStarted && !_isPaused && !_detected) {
        _scheduleRestart();
      }
      return;
    }

    // Otros errores
    _logError('STT error: ${error.errorMsg} (permanent: ${error.permanent})');
    _isListening = false;

    if (error.permanent) {
      onError?.call(error.errorMsg);
      return;
    }

    // Error recuperable
    if (_isStarted && !_isPaused && !_detected) {
      Future.delayed(const Duration(seconds: 2), () {
        if (_isStarted && !_isPaused && !_detected) _openSession();
      });
    }
  }

  // ─── Reinicio automático ─────────────────────────────────────────────────

  void _scheduleRestart() {
    Future.delayed(_restartDelay, () {
      if (_isStarted && !_isPaused && !_detected && !_isListening) {
        _openSession();
      }
    });
  }

  // ─── setSensitivity — no-op ──────────────────────────────────────────────

  Future<void> setSensitivity(double sensitivity, String accessKey) async {
    _currentSensitivity = sensitivity;
  }

  // ─── getStatistics ───────────────────────────────────────────────────────

  Map<String, dynamic> getStatistics() => {
    'is_initialized':          _isInitialized,
    'is_started':              _isStarted,
    'is_listening':            _isListening,
    'is_paused':               _isPaused,
    'detected':                _detected,
    'tts_active':              _ttsActive,
    'suppress_until':          _suppressUntil?.toIso8601String(),
    'keyword':                 _currentKeyword,
    'sensitivity':             _currentSensitivity,
    'detection_count':         _detectionCount,
    'last_detection':          _lastDetection?.toIso8601String(),
    'engine':                  'speech_to_text_v4.2_long_session',
    'restart_delay_ms':        _restartDelay.inMilliseconds,
    'error_client_delay_ms':   _errorClientDelay.inMilliseconds,
    'tts_suppress_delay_ms':   _ttsSuppressDelay.inMilliseconds,
    'tts_echo_window_ms':      _ttsEchoWindow.inMilliseconds,
    'pause_for_seconds':       20,
  };

  void resetStatistics() {
    _detectionCount = 0;
    _lastDetection  = null;
  }

  // ─── Getters ─────────────────────────────────────────────────────────────

  bool    get isInitialized  => _isInitialized;
  bool    get isListening    => _isListening && !_isPaused;
  bool    get isPaused       => _isPaused;
  bool    get isTTSActive    => _ttsActive;
  int     get detectionCount => _detectionCount;
  String? get currentKeyword => _currentKeyword;

  // ─── dispose ─────────────────────────────────────────────────────────────

  Future<void> dispose() async {
    await stop();
    _isInitialized = false;
  }
}