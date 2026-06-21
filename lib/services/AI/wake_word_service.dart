// lib/services/AI/wake_word_service.dart
// ✅ v4.3 — Fix race condition timer/suppressUntil · health guard · closeSession reset
//
// ============================================================================
//  CAMBIOS v4.2 → v4.3
// ============================================================================
//
//  CONTEXTO DEL BUG:
//    Al decir "oye compa" (parcial sin match), el STT recibe el texto pero
//    no dispara detección. Inmediatamente después el TTS habla ("Sistema
//    conversacional activado"), notifyTTSStarted() cierra la sesión, y
//    notifyTTSEnded() programa un timer de 2500ms para reabrir.
//    El timer llega cuando _suppressUntil aún no expiró (milisegundos de
//    diferencia por CPU saturada de ARCore, GC >300ms en logs). Esto genera
//    un timer anidado de ~0-50ms que cuando llega encuentra _isListening en
//    estado inconsistente → el micrófono muere silenciosamente.
//
//  FIX 1 — notifyTTSEnded(): margen +150ms + limpiar _suppressUntil antes
//    El timer ahora llega GARANTIZADAMENTE después de que _suppressUntil
//    expiró. Se limpia _suppressUntil antes de llamar _openSession() para
//    evitar que la condición de carrera genere un timer anidado.
//
//  FIX 2 — _openSession(): limpiar _suppressUntil antes del delay anidado
//    Si por alguna razón el timer llega cuando el guard de eco aún está
//    activo, se limpia _suppressUntil antes de programar el siguiente delay
//    para que la re-entrada no vuelva a pasar por este bloque.
//
//  FIX 3 — _closeSession(): resetear _isListening SIEMPRE (antes del guard)
//    Cuando notifyTTSStarted() llama _closeSession() mientras una sesión
//    está en proceso de apertura, _isListening puede quedar true. Moverlo
//    antes del if garantiza el reset en todos los caminos.
//
//  FIX 4 — _onHealthTick(): respetar ventana de supresión de eco
//    El health monitor no debe intervenir mientras hay un timer de eco
//    pendiente. Añadido guard contra _suppressUntil activo para evitar
//    que el watchdog compita con el timer de notifyTTSEnded().
//
//  TODOS LOS FIXES v4.2 SE MANTIENEN INTACTOS.

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

  // ─── Guard de eco TTS ────────────────────────────────────────────────────
  bool      _ttsActive     = false;
  DateTime? _suppressUntil;

  // ─── Health monitor ──────────────────────────────────────────────────────
  Timer? _healthTimer;
  static const Duration _healthCheckInterval = Duration(seconds: 12);
  bool _healthMonitorEnabled = false;

  // ─── Timings ─────────────────────────────────────────────────────────────
  // FIX 1: margen adicional sobre _ttsEchoWindow para que el timer llegue
  // GARANTIZADAMENTE después de que _suppressUntil expiró, incluso con
  // CPU saturada por ARCore (GC >300ms observado en logs).
  static const Duration _ttsSuppressDelay = Duration(milliseconds: 600);
  static const Duration _ttsEchoWindow    = Duration(milliseconds: 2500);
  static const Duration _timerMargin      = Duration(milliseconds: 150);

  // ─── Callbacks ──────────────────────────────────────────────────────────
  Function()?       onWakeWordDetected;
  Function(String)? onError;

  // ─── Keywords ────────────────────────────────────────────────────────────
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
  static const Duration _restartDelay    = Duration(milliseconds: 800);
  static const Duration _errorClientDelay = Duration(milliseconds: 1500);

  // ─── initialize ──────────────────────────────────────────────────────────

  Future<void> initialize({
    required String accessKey,
    WakeWordConfig config = const WakeWordConfig.builtIn('hey google'),
    double sensitivity = 0.7,
  }) async {
    if (_isInitialized) return;

    try {
      _log('Inicializando v4.3 (race-condition fix, health guard)...');

      _currentKeyword     = config.keyword;
      _currentSensitivity = sensitivity;

      final available = await _stt.initialize(
        onError:      _onSttError,
        onStatus:     _onSttStatus,
        debugLogging: false,
      );

      if (!available) throw Exception('STT no disponible en este dispositivo');

      _isInitialized = true;
      _log('v4.3 listo — keywords: ${_keywords.join(", ")}');
    } catch (e) {
      _logError('Error inicializando: $e');
      onError?.call(e.toString());
      rethrow;
    }
  }

  // ─── Health monitor ──────────────────────────────────────────────────────

  void enableHealthMonitor() {
    _healthMonitorEnabled = true;
    _log('Health monitor activado (${_healthCheckInterval.inSeconds}s)');
    _restartHealthTimer();
  }

  // ─── API de guard TTS ────────────────────────────────────────────────────

  /// Llamar desde VoiceNavigationService ANTES de iniciar TTS.
  Future<void> notifyTTSStarted() async {
    _ttsActive     = true;
    _suppressUntil = null;
    _log('TTS activo — suprimiendo STT');
    await _closeSession();
  }

  /// Llamar desde VoiceNavigationService en el finally de _speak().
  ///
  /// FIX 1: el timer se programa con _ttsEchoWindow + _timerMargin (150ms)
  /// para que llegue GARANTIZADAMENTE después de que _suppressUntil expiró,
  /// incluso con CPU saturada por ARCore. Se limpia _suppressUntil antes de
  /// llamar _openSession() para evitar timer anidado por race condition.
  void notifyTTSEnded() {
    _ttsActive     = false;
    _suppressUntil = DateTime.now().add(_ttsEchoWindow);

    _log('TTS terminó — supresión de eco ${_ttsEchoWindow.inMilliseconds}ms');

    Future.delayed(_ttsEchoWindow + _timerMargin, () async {
      if (!_ttsActive && _isInitialized && _isStarted && !_isPaused && !_detected) {
        // FIX 1: limpiar _suppressUntil antes de _openSession() para que
        // el guard de eco no genere un segundo timer anidado.
        _suppressUntil = null;
        await _openSession();
      }
    });
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

    // Guard: TTS activo
    if (_ttsActive) {
      _log('TTS activo — posponiendo apertura ${_ttsSuppressDelay.inMilliseconds}ms');
      Future.delayed(_ttsSuppressDelay, () {
        if (_isStarted && !_isPaused && !_detected && !_isListening && !_ttsActive) {
          _openSession();
        }
      });
      return;
    }

    // FIX 2: guard de eco residual — limpiar _suppressUntil antes del delay
    // para que la re-entrada no vuelva a pasar por este bloque.
    final now = DateTime.now();
    if (_suppressUntil != null && now.isBefore(_suppressUntil!)) {
      final remaining = _suppressUntil!.difference(now);
      _log('Eco residual — posponiendo ${remaining.inMilliseconds}ms');

      // FIX 2: limpiar antes de programar el delay para evitar re-entrada
      _suppressUntil = null;

      Future.delayed(remaining + const Duration(milliseconds: 100), () {
        if (_isStarted && !_isPaused && !_detected && !_isListening && !_ttsActive) {
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
        pauseFor:       const Duration(seconds: 20),
        partialResults: true,
        localeId:       'es_CO',
        cancelOnError:  false,
        listenMode:     ListenMode.dictation,
      );

      _log('Sesión abierta (listenFor=1h, pauseFor=20s)');
      _restartHealthTimer();
    } catch (e) {
      _isListening = false;
      _logError('Error abriendo sesión: $e');
      _scheduleRestart();
    }
  }

  /// FIX 3: resetear _isListening ANTES del guard para garantizar el reset
  /// en todos los caminos, incluso cuando se llama durante una apertura
  /// incompleta (ej: notifyTTSStarted() llega mientras _openSession() está
  /// en curso y _isListening ya fue seteado a true).
  Future<void> _closeSession() async {
    // FIX 3: mover el reset ANTES del guard
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
        _detected      = true;

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
    if (error.errorMsg == 'error_busy') return;

    if (error.errorMsg == 'error_speech_timeout') {
      _isListening = false;
      if (_isStarted && !_isPaused && !_detected) {
        _scheduleRestart();
      }
      return;
    }

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

    // v4.2 FIX: error_no_match no es fatal aunque permanent:true
    if (error.errorMsg == 'error_no_match') {
      _log('error_no_match — ignorando flag permanent, reiniciando sesión...');
      _isListening = false;
      if (_isStarted && !_isPaused && !_detected) {
        _scheduleRestart();
      }
      return;
    }

    _logError('STT error: ${error.errorMsg} (permanent: ${error.permanent})');
    _isListening = false;

    if (error.permanent) {
      onError?.call(error.errorMsg);
      return;
    }

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

  // ─── Health monitor ──────────────────────────────────────────────────────

  void _restartHealthTimer() {
    _healthTimer?.cancel();
    if (!_healthMonitorEnabled) return;

    _healthTimer = Timer.periodic(_healthCheckInterval, (_) => _onHealthTick());
  }

  Future<void> _onHealthTick() async {
    if (_ttsActive) return;
    if (!_isInitialized) return;
    if (_stt.isListening) return;
    if (!_isStarted || _isPaused || _detected) return;

    // FIX 4: no intervenir si hay un timer de eco pendiente — el
    // watchdog no debe competir con el timer de notifyTTSEnded().
    final now = DateTime.now();
    if (_suppressUntil != null && now.isBefore(_suppressUntil!)) {
      _log('Health: eco pendiente — skip');
      return;
    }

    _log('⚠️ Health: STT inactivo sin razón — reiniciando sesión');

    await _closeSession();
    await Future.delayed(const Duration(milliseconds: 600));
    await _openSession();
  }

  // ─── setSensitivity — no-op ──────────────────────────────────────────────

  Future<void> setSensitivity(double sensitivity, String accessKey) async {
    _currentSensitivity = sensitivity;
  }

  // ─── getStatistics ───────────────────────────────────────────────────────

  Map<String, dynamic> getStatistics() => {
    'is_initialized':        _isInitialized,
    'is_started':            _isStarted,
    'is_listening':          _isListening,
    'is_paused':             _isPaused,
    'detected':              _detected,
    'tts_active':            _ttsActive,
    'suppress_until':        _suppressUntil?.toIso8601String(),
    'keyword':               _currentKeyword,
    'sensitivity':           _currentSensitivity,
    'detection_count':       _detectionCount,
    'last_detection':        _lastDetection?.toIso8601String(),
    'engine':                'speech_to_text_v4.3_race_fix',
    'restart_delay_ms':      _restartDelay.inMilliseconds,
    'error_client_delay_ms': _errorClientDelay.inMilliseconds,
    'tts_suppress_delay_ms': _ttsSuppressDelay.inMilliseconds,
    'tts_echo_window_ms':    _ttsEchoWindow.inMilliseconds,
    'timer_margin_ms':       _timerMargin.inMilliseconds,
    'pause_for_seconds':     20,
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
    _healthTimer?.cancel();
    await stop();
    _isInitialized = false;
  }
}