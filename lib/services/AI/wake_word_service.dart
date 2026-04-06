// lib/services/AI/wake_word_service.dart
// ✅ v4.1 — Fix error_client permanent · Restart delay 300ms → 800ms
//
// ============================================================================
//  CAMBIOS v4.0 → v4.1
// ============================================================================
//
//  PROBLEMA EN v4.0:
//    _onSttError() trataba error_client con permanent:true como un error
//    fatal, llamando onError() y deteniendo toda la detección definitivamente.
//
//    Causa raíz: cuando _onSttStatus recibe 'notListening' y llama
//    _scheduleRestart() con solo 300ms de delay, Android aún no liberó
//    el SpeechRecognizer interno. La siguiente llamada a listen() recibe
//    error_client porque el recognizer anterior sigue vivo.
//    Android marca este error como permanent:true, pero NO lo es en la práctica.
//
//    Flujo problemático:
//      _openSession() → listen() OK
//      → status: notListening  (cierre sucio, recognizer aún vivo en Android)
//      → _scheduleRestart(300ms) → _openSession() demasiado rápido
//      → error_client permanent:true → onError() → detención total
//
//  SOLUCIÓN v4.1:
//    1. error_client interceptado ANTES del bloque permanent general.
//       Se reintenta con 1500ms de delay — suficiente para que Android
//       libere el recognizer. No se llama onError() porque no es un
//       error real del sistema, sino una condición de carrera.
//
//    2. _restartDelay: 300ms → 800ms.
//       Reduce la frecuencia de la condición de carrera en el caso base.
//       En hardware lento subir a 1200ms si persiste.
//
//  TODO LO DEMÁS ES IDÉNTICO A v4.0.

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
  bool    _isListening   = false; // sesión STT activa
  bool    _isPaused      = false; // pausado externamente
  bool    _isStarted     = false; // start() fue llamado
  bool    _detected      = false; // wake word detectado, esperando resume()

  String? _currentKeyword;
  double  _currentSensitivity = 0.7;

  int       _detectionCount = 0;
  DateTime? _lastDetection;

  // ─── Callbacks ──────────────────────────────────────────────────────────
  Function()?       onWakeWordDetected;
  Function(String)? onError;

  // ─── Palabras clave ──────────────────────────────────────────────────────
  // Variantes de "oye compas" que Google STT en es_CO puede transcribir.
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

  // Sesión larga: Android mantiene el mic abierto sin callbacks de ruido.
  static const Duration _sessionDuration = Duration(hours: 1);

  // ✅ v4.1: aumentado de 300ms a 800ms para dar tiempo a Android a liberar
  // el SpeechRecognizer entre sesiones y evitar la condición de carrera
  // que genera error_client.
  static const Duration _restartDelay = Duration(milliseconds: 800);

  // Delay específico para recuperación de error_client. Más largo que
  // _restartDelay porque necesita esperar la liberación del recognizer.
  static const Duration _errorClientDelay = Duration(milliseconds: 1500);

  // ─── initialize ──────────────────────────────────────────────────────────

  Future<void> initialize({
    required String accessKey,      // ignorado — sin Picovoice
    WakeWordConfig config = const WakeWordConfig.builtIn('hey google'),
    double sensitivity = 0.7,
  }) async {
    if (_isInitialized) return;

    try {
      _log('Inicializando v4.1 (sesión larga, fix error_client)...');

      _currentKeyword     = config.keyword;
      _currentSensitivity = sensitivity;

      final available = await _stt.initialize(
        onError:      _onSttError,
        onStatus:     _onSttStatus,
        debugLogging: false,
      );

      if (!available) throw Exception('STT no disponible en este dispositivo');

      _isInitialized = true;
      _log('v4.1 listo — keywords: ${_keywords.join(", ")}');
    } catch (e) {
      _logError('Error inicializando: $e');
      onError?.call(e.toString());
      rethrow;
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
    if (!_isPaused && _isListening) return; // ya activo

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
    if (_isListening) return; // ya hay sesión activa
    if (!_isInitialized || !_isStarted || _isPaused) return;

    try {
      _isListening = true;

      await _stt.listen(
        onResult:       _onResult,
        listenFor:      _sessionDuration,
        pauseFor:       const Duration(seconds: 8),
        partialResults: true,
        localeId:       'es_CO',
        cancelOnError:  false,
        listenMode:     ListenMode.dictation,
      );

      _log('Sesión abierta (listenFor=1h, pauseFor=8s)');
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

    final text = result.recognizedWords.toLowerCase().trim();
    if (text.isEmpty) return;

    _log('STT: "$text"');

    for (final kw in _keywords) {
      if (text.contains(kw)) {
        _log('✅ Detectado: "$kw"');
        _detectionCount++;
        _lastDetection = DateTime.now();
        _detected = true;

        // Cerrar sesión antes de disparar callback —
        // el coordinator llamará resume() cuando esté listo.
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

      // Si terminó solo (no por pause/stop/detección) → reiniciar
      if (wasListening && _isStarted && !_isPaused && !_detected) {
        _log('Sesión terminó sola — reiniciando...');
        _scheduleRestart();
      }
    }
  }

  void _onSttError(SpeechRecognitionError error) {
    // error_busy: ignorar — ocurre en transiciones normales
    if (error.errorMsg == 'error_busy') return;

    // error_speech_timeout: el STT no oyó nada — reiniciar normalmente
    if (error.errorMsg == 'error_speech_timeout') {
      _isListening = false;
      if (_isStarted && !_isPaused && !_detected) {
        _scheduleRestart();
      }
      return;
    }

    // ✅ v4.1 FIX: error_client NO es un error fatal aunque Android lo marque
    // como permanent:true. Ocurre cuando _scheduleRestart() abre una nueva
    // sesión antes de que Android libere el SpeechRecognizer anterior.
    // Solución: esperar _errorClientDelay (1500ms) antes de reintentar.
    // No se llama onError() porque es una condición de carrera recuperable.
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

    // Otros errores
    _logError('STT error: ${error.errorMsg} (permanent: ${error.permanent})');
    _isListening = false;

    if (error.permanent) {
      onError?.call(error.errorMsg);
      return;
    }

    // Error recuperable → reiniciar tras delay mayor
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
    'is_initialized':  _isInitialized,
    'is_started':      _isStarted,
    'is_listening':    _isListening,
    'is_paused':       _isPaused,
    'detected':        _detected,
    'keyword':         _currentKeyword,
    'sensitivity':     _currentSensitivity,
    'detection_count': _detectionCount,
    'last_detection':  _lastDetection?.toIso8601String(),
    'engine':          'speech_to_text_v4.1_long_session',
    'restart_delay_ms':       _restartDelay.inMilliseconds,
    'error_client_delay_ms':  _errorClientDelay.inMilliseconds,
  };

  void resetStatistics() {
    _detectionCount = 0;
    _lastDetection  = null;
  }

  // ─── Getters ─────────────────────────────────────────────────────────────

  bool    get isInitialized  => _isInitialized;
  bool    get isListening    => _isListening && !_isPaused;
  bool    get isPaused       => _isPaused;
  int     get detectionCount => _detectionCount;
  String? get currentKeyword => _currentKeyword;

  // ─── dispose ─────────────────────────────────────────────────────────────

  Future<void> dispose() async {
    await stop();
    _isInitialized = false;
  }
}