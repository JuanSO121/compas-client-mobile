// lib/services/AI/wake_word_service.dart
// ✅ v3.0 — Drop-in replacement de Porcupine con speech_to_text
//           API 100% idéntica al original — NavigationCoordinator sin cambios

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

  final Logger      _logger = Logger();
  final SpeechToText _stt   = SpeechToText();

  bool    _isInitialized     = false;
  bool    _isListening       = false;
  bool    _isPaused          = false;
  String? _currentKeyword;
  double  _currentSensitivity = 0.7;

  // Estadísticas
  int       _detectionCount = 0;
  DateTime? _lastDetection;

  // Callbacks — mismos nombres que el original
  Function()?       onWakeWordDetected;
  Function(String)? onError;

  // Control del bucle
  bool _loopActive = false;

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
  // Firma idéntica al original — accessKey y config se ignoran (no hay licencia)

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
      _logger.i('Inicializando WakeWordService v3 (speech_to_text)...');

      _currentKeyword    = config.keyword;
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
      _logger.i('✅ WakeWordService v3 listo');
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
    _logger.d('⏸️ Wake word pausado');
  }

  // ─── resume ─────────────────────────────────────────────────────────────────

  Future<void> resume() async {
    if (!_isPaused) return;
    _isPaused = false;
    _logger.d('▶️ Wake word reanudado');
    // El bucle retoma en el siguiente ciclo automáticamente
  }

  // ─── stop ───────────────────────────────────────────────────────────────────

  Future<void> stop() async {
    if (!_isListening) return;
    _loopActive  = false;
    _isListening = false;
    _isPaused    = false;
    try { await _stt.stop(); } catch (_) {}
    _logger.i('⏹️ Wake word detenido');
  }

  // ─── Bucle interno ──────────────────────────────────────────────────────────

  Future<void> _runLoop() async {
    while (_loopActive) {
      if (_isPaused) { await Future.delayed(_cyclePause); continue; }

      try {
        await _oneCycle();
      } catch (e) {
        _logger.w('[WakeWord] Ciclo falló: $e — reintentando');
        await Future.delayed(const Duration(seconds: 1));
      }

      await Future.delayed(_cyclePause);
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

  // ─── setSensitivity — no-op, firma idéntica al original ──────────────────────

  Future<void> setSensitivity(double sensitivity, String accessKey) async {
    _currentSensitivity = sensitivity;
    _logger.d('[WakeWord] setSensitivity ignorado en v3 (speech_to_text)');
  }

  // ─── getStatistics — misma estructura que el original ────────────────────────

  Map<String, dynamic> getStatistics() => {
    'is_initialized':    _isInitialized,
    'is_listening':      _isListening,
    'is_paused':         _isPaused,
    'keyword':           _currentKeyword,
    'sensitivity':       _currentSensitivity,
    'detection_count':   _detectionCount,
    'last_detection':    _lastDetection?.toIso8601String(),
    'time_since_last':   _lastDetection != null
        ? DateTime.now().difference(_lastDetection!).inSeconds
        : null,
    'engine':            'speech_to_text_v3',
  };

  void resetStatistics() {
    _detectionCount = 0;
    _lastDetection  = null;
  }

  // ─── Getters — mismos que el original ────────────────────────────────────────

  bool    get isInitialized  => _isInitialized;
  bool    get isListening    => _isListening && !_isPaused;
  bool    get isPaused       => _isPaused;
  int     get detectionCount => _detectionCount;
  String? get currentKeyword => _currentKeyword;

  // ─── dispose ─────────────────────────────────────────────────────────────────

  Future<void> dispose() async {
    await stop();
    _isInitialized = false;
    _logger.i('WakeWordService disposed');
  }
}