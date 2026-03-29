// lib/services/AI/wake_word_service.dart
// ✅ v3.1 — Fix loop infinito de micrófono: _runLoop se suspende con Completer
//
// ============================================================================
//  CAMBIOS v3.0 → v3.1
// ============================================================================
//
//  BUG CORREGIDO — Sonido de micrófono prendiendo/apagando constantemente
//  sin que el usuario haga nada.
//
//  PROBLEMA EN v3.0:
//    _runLoop() iteraba cada 600ms aunque _isPaused=true:
//
//      while (_loopActive) {
//        if (_isPaused) { await Future.delayed(_cyclePause); continue; }
//        ...
//      }
//
//    En Android, cada ciclo del loop hacía:
//      1. Ver _isPaused=true → esperar 600ms
//      2. Repetir → el loop seguía corriendo en background
//
//    El sonido de mic on/off venía de los stt.stop() periódicos que
//    Android emite como callbacks de AudioFocus cada vez que el loop
//    intentaba un nuevo ciclo aunque estuviera "pausado".
//
//    Adicionalmente, resume() en v3.0 simplemente ponía _isPaused=false
//    y esperaba que el loop lo detectara en el próximo ciclo (600ms después).
//    Durante ese gap, si el TTS emitía onComplete y _resumeWakeWord() lo
//    llamaba, el STT arrancaba inmediatamente sin el delay anti-eco.
//
//  FIX 1 — _runLoop suspendido con Completer cuando _isPaused=true:
//    En lugar de iterar cada 600ms, el loop se detiene completamente
//    awaiting un Completer<void> (_resumeCompleter). No hay actividad,
//    no hay callbacks de Android, no hay sonido de mic.
//    resume() completa ese Completer y el loop reanuda inmediatamente.
//
//  FIX 2 — stop() también completa _resumeCompleter:
//    Si stop() se llama mientras el loop está suspendido esperando el
//    Completer, el loop tiene que poder salir del while. stop() pone
//    _loopActive=false y completa el Completer para desbloquearlo.
//
//  TODO LO DEMÁS ES IDÉNTICO A v3.0.

import 'dart:async';
import 'package:logger/logger.dart';
import 'package:speech_to_text/speech_to_text.dart';

// ─── WakeWordConfig — idéntica al original ────────────────────────────────────

class WakeWordConfig {
  final String  keyword;
  final String? modelPath;
  final bool    isBuiltIn;

  const WakeWordConfig.builtIn(this.keyword)
      : modelPath = null,
        isBuiltIn = true;

  const WakeWordConfig.custom({
    required this.keyword,
    required this.modelPath,
  }) : isBuiltIn = false;

  static const List<String> availableBuiltIn = [
    'alexa', 'americano', 'blueberry', 'bumblebee', 'computer',
    'grapefruit', 'grasshopper', 'hey google', 'hey siri', 'jarvis',
    'ok google', 'picovoice', 'porcupine',
  ];
}

// ─── WakeWordService ──────────────────────────────────────────────────────────

class WakeWordService {
  static final WakeWordService _instance = WakeWordService._internal();
  factory WakeWordService() => _instance;
  WakeWordService._internal();

  final Logger       _logger = Logger();
  final SpeechToText _stt    = SpeechToText();

  bool    _isInitialized      = false;
  bool    _isListening        = false;
  bool    _isPaused           = false;
  String? _currentKeyword;
  double  _currentSensitivity = 0.7;

  // Estadísticas
  int       _detectionCount = 0;
  DateTime? _lastDetection;

  // Callbacks
  Function()?       onWakeWordDetected;
  Function(String)? onError;

  // Control del bucle
  bool _loopActive = false;

  // ✅ v3.1: Completer para suspender el loop cuando _isPaused=true.
  // En v3.0 el loop iteraba cada 600ms aunque estuviera pausado,
  // generando callbacks de AudioFocus de Android → sonido de mic on/off.
  // Con el Completer, el loop queda suspendido sin actividad hasta que
  // resume() o stop() lo despierte.
  Completer<void>? _resumeCompleter;

  static const List<String> _wakeWords = [
    'oye compas',
    'ey compas',
    'hey compas',
    'oye compass',
    'hey compass',
    'compas',
    'compass',
  ];

  static const Duration _listenDuration = Duration(seconds: 5);
  static const Duration _cyclePause     = Duration(milliseconds: 600);

  // ─── initialize ─────────────────────────────────────────────────────────────

  Future<void> initialize({
    required String      accessKey,
    WakeWordConfig       config      = const WakeWordConfig.builtIn('hey google'),
    double               sensitivity = 0.7,
  }) async {
    if (_isInitialized) {
      _logger.w('Wake word service ya inicializado');
      return;
    }

    try {
      _logger.i('Inicializando WakeWordService v3.1 (speech_to_text)...');

      _currentKeyword     = config.keyword;
      _currentSensitivity = sensitivity;

      final available = await _stt.initialize(
        onError:  (e) => _logger.w('⚠️ STT wake word: ${e.errorMsg}'),
        onStatus: (s) {
          _logger.d('[WakeWord] STT status: $s');
          if (s == 'done' || s == 'notListening') _isListening = false;
        },
        debugLogging: false,
      );

      if (!available) throw Exception('STT no disponible en este dispositivo');

      _isInitialized = true;
      _logger.i('✅ WakeWordService v3.1 listo');
      _logger.i('   Keywords: ${_wakeWords.join(", ")}');
      _logger.i('   (accessKey y .ppn ignorados — sin licencia Picovoice)');
    } catch (e) {
      _logger.e('❌ Error inicializando WakeWordService: $e');
      onError?.call(e.toString());
      rethrow;
    }
  }

  // ─── start ──────────────────────────────────────────────────────────────────

  Future<void> start() async {
    if (!_isInitialized) throw StateError('Wake word service no inicializado');
    if (_isListening && !_isPaused) { _logger.w('Ya está escuchando'); return; }

    if (_isPaused) {
      await resume();
      return;
    }

    _isListening = true;
    _isPaused    = false;
    _loopActive  = true;
    _logger.i('🎤 Wake word detection iniciado');

    _runLoop(); // fire-and-forget controlado
  }

  // ─── pause ──────────────────────────────────────────────────────────────────

  Future<void> pause() async {
    if (!_isListening || _isPaused) return;
    _isPaused = true;
    try { await _stt.stop(); } catch (_) {}
    // ✅ v3.1: NO completar _resumeCompleter aquí.
    // El loop detectará _isPaused=true en el próximo ciclo y se suspenderá
    // solo con el Completer. Si ya está en _oneCycle(), esperará que termine
    // (completer.future en _oneCycle) y luego entrará al bloque de pausa.
    _logger.d('⏸️ Wake word pausado');
  }

  // ─── resume ─────────────────────────────────────────────────────────────────

  Future<void> resume() async {
    if (!_isPaused) return;
    _isPaused = false;
    _logger.d('▶️ Wake word reanudado');
    // ✅ v3.1: despertar el loop si está suspendido en el Completer.
    if (_resumeCompleter != null && !_resumeCompleter!.isCompleted) {
      _resumeCompleter!.complete();
    }
  }

  // ─── stop ───────────────────────────────────────────────────────────────────

  Future<void> stop() async {
    if (!_isListening) return;
    _loopActive  = false;
    _isListening = false;
    _isPaused    = false;

    // ✅ v3.1: despertar el loop para que pueda salir del while(_loopActive).
    // Sin esto, si stop() se llama mientras el loop está suspendido en
    // _resumeCompleter.future, el loop nunca terminaría.
    if (_resumeCompleter != null && !_resumeCompleter!.isCompleted) {
      _resumeCompleter!.complete();
    }

    try { await _stt.stop(); } catch (_) {}
    _logger.i('⏹️ Wake word detenido');
  }

  // ─── Bucle interno ──────────────────────────────────────────────────────────

  Future<void> _runLoop() async {
    while (_loopActive) {

      // ✅ v3.1 FIX: suspender completamente el loop cuando está pausado.
      //
      // En v3.0:
      //   if (_isPaused) { await Future.delayed(_cyclePause); continue; }
      //   → el loop seguía iterando cada 600ms
      //   → Android emitía callbacks de AudioFocus → sonido de mic on/off
      //
      // Ahora:
      //   El loop queda bloqueado en _resumeCompleter.future sin actividad.
      //   resume() o stop() completan el Completer para desbloquearlo.
      //   Cero iteraciones, cero callbacks de Android, cero sonido de mic.
      if (_isPaused) {
        _resumeCompleter = Completer<void>();
        await _resumeCompleter!.future;
        _resumeCompleter = null;
        // Después de despertar, volver al tope del while para re-evaluar
        // _loopActive (puede haber sido puesto false por stop())
        continue;
      }

      try {
        await _oneCycle();
      } catch (e) {
        _logger.w('[WakeWord] Ciclo falló: $e — reintentando');
        await Future.delayed(const Duration(seconds: 1));
      }

      // Delay entre ciclos solo si el loop sigue activo y no está pausado
      if (_loopActive && !_isPaused) {
        await Future.delayed(_cyclePause);
      }
    }
  }

  Future<void> _oneCycle() async {
    if (!_loopActive || _isPaused) return;

    final completer = Completer<void>();

    await _stt.listen(
      onResult: (result) {
        if (!_loopActive || _isPaused) return;

        final text = result.recognizedWords.toLowerCase().trim();
        if (text.isEmpty) return;

        _logger.d('[WakeWord] 🎙️ "$text"');

        for (final kw in _wakeWords) {
          if (text.contains(kw)) {
            _logger.i('[WakeWord] ✅ Detectada: "$kw"');
            _detectionCount++;
            _lastDetection = DateTime.now();

            _stt.stop().then((_) {
              if (_loopActive) onWakeWordDetected?.call();
            });

            if (!completer.isCompleted) completer.complete();
            return;
          }
        }

        if (result.finalResult && !completer.isCompleted) completer.complete();
      },
      listenFor:      _listenDuration,
      pauseFor:       const Duration(seconds: 3),
      partialResults: true,
      localeId:       'es_CO',
      cancelOnError:  false,
      listenMode:     ListenMode.dictation,
    );

    // Timeout de seguridad
    Future.delayed(_listenDuration + const Duration(milliseconds: 500), () {
      if (!completer.isCompleted) completer.complete();
    });

    await completer.future;
  }

  // ─── setSensitivity — no-op ───────────────────────────────────────────────

  Future<void> setSensitivity(double sensitivity, String accessKey) async {
    _currentSensitivity = sensitivity;
    _logger.d('[WakeWord] setSensitivity ignorado en v3 (speech_to_text)');
  }

  // ─── getStatistics ────────────────────────────────────────────────────────

  Map<String, dynamic> getStatistics() => {
    'is_initialized':   _isInitialized,
    'is_listening':     _isListening,
    'is_paused':        _isPaused,
    'loop_active':      _loopActive,
    'resume_pending':   _resumeCompleter != null,
    'keyword':          _currentKeyword,
    'sensitivity':      _currentSensitivity,
    'detection_count':  _detectionCount,
    'last_detection':   _lastDetection?.toIso8601String(),
    'time_since_last':  _lastDetection != null
        ? DateTime.now().difference(_lastDetection!).inSeconds
        : null,
    'engine':           'speech_to_text_v3.1',
  };

  void resetStatistics() {
    _detectionCount = 0;
    _lastDetection  = null;
  }

  // ─── Getters ──────────────────────────────────────────────────────────────

  bool    get isInitialized  => _isInitialized;
  bool    get isListening    => _isListening && !_isPaused;
  bool    get isPaused       => _isPaused;
  int     get detectionCount => _detectionCount;
  String? get currentKeyword => _currentKeyword;

  // ─── dispose ──────────────────────────────────────────────────────────────

  Future<void> dispose() async {
    await stop();
    _isInitialized = false;
    _logger.i('WakeWordService disposed');
  }
}