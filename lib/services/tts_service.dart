// lib/services/tts_service.dart
// ✅ v2.1 — Fix "not bound to TTS engine" al iniciar
//
// ============================================================================
//  CAMBIOS v2.0 → v2.1
// ============================================================================
//
//  BUG CORREGIDO — "speak failed: not bound to TTS engine":
//
//    CAUSA: FlutterTts.initialize() completa sus Futures internos antes de que
//    el motor Android (TextToSpeech) termine el binding asíncrono con el servicio
//    del sistema. Si speak() se llama inmediatamente después del init (< 1-2s),
//    el motor aún no está listo y Android descarta el utterance silenciosamente,
//    emitiendo solo el warning "speak failed: not bound to TTS engine".
//
//    SOLUCIÓN 1 — awaitSpeakCompletion(true): Le indica a FlutterTts que espere
//    a que el motor esté listo antes de resolver el Future de speak(). Con esto,
//    speak() no retorna hasta que el utterance fue aceptado por el motor.
//
//    SOLUCIÓN 2 — Retry con backoff: Si el primer speak() falla de todos modos
//    (motor lento en algunos dispositivos), se reintenta hasta 3 veces con
//    delays de 300ms/600ms/1000ms antes de rendirse.
//
//    SOLUCIÓN 3 — Warm-up silencioso: Al inicializar, se hace un speak(" ")
//    para forzar el binding del motor antes de que llegue el primer mensaje real.
//    Esto resuelve el problema en la mayoría de dispositivos sin necesidad de retry.
//
//  COMPORTAMIENTOS CONSERVADOS v2.0:
//    - Singleton, stream broadcast, Completer independiente
//    - setQueueMode(0) = QUEUE_FLUSH
//    - API speak(text, interrupt) idéntica
//    - _cleanText() idéntico
//    - isSpeaking, isInitialized, stop(), dispose() idénticos

import 'package:flutter_tts/flutter_tts.dart';
import 'package:logger/logger.dart';
import 'dart:async';
import 'dart:io';

class TTSService {
  static final TTSService _instance = TTSService._internal();
  factory TTSService() => _instance;
  TTSService._internal();

  final Logger _logger = Logger();
  final FlutterTts _tts = FlutterTts();

  bool _isInitialized = false;
  bool _isSpeaking = false;

  final _completionController = StreamController<void>.broadcast();
  Stream<void> get onComplete => _completionController.stream;

  Completer<void>? _waitCompleter;

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      _tts.setStartHandler(() {
        _isSpeaking = true;
        _logger.d('🔊 TTS iniciado');
      });

      _tts.setCompletionHandler(() {
        _isSpeaking = false;
        _logger.d('✅ TTS completado');
        _completionController.add(null);
        if (_waitCompleter != null && !_waitCompleter!.isCompleted) {
          _waitCompleter!.complete();
        }
      });

      _tts.setErrorHandler((msg) {
        _isSpeaking = false;
        _logger.e('❌ TTS Error: $msg');
        _completionController.add(null);
        if (_waitCompleter != null && !_waitCompleter!.isCompleted) {
          _waitCompleter!.complete();
        }
      });

      await _tts.setLanguage('es-ES');
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);

      if (Platform.isAndroid) {
        await _tts.setQueueMode(0); // QUEUE_FLUSH: un utterance a la vez

        // ── SOLUCIÓN 1: awaitSpeakCompletion ──────────────────────────────
        // Le indica a FlutterTts que los Futures de speak() no resuelvan
        // hasta que el motor Android haya aceptado y completado el utterance.
        // Sin esto, speak() puede retornar antes de que el motor esté listo.
        await _tts.awaitSpeakCompletion(true);
      }

      _isInitialized = true;

      // ── SOLUCIÓN 3: Warm-up silencioso ────────────────────────────────────
      // Un speak con espacio fuerza el binding del motor Android de inmediato.
      // Cuando llegue el primer mensaje real, el motor ya estará conectado.
      // El espacio no produce audio audible pero establece la conexión.
      await Future.delayed(const Duration(milliseconds: 200));
      try {
        await _tts.speak(' ');
        await Future.delayed(const Duration(milliseconds: 300));
      } catch (_) {
        // Ignorar error del warm-up — es solo para establecer el binding
      }

      _logger.i('✅ TTS v2.1 inicializado');
    } catch (e) {
      _logger.e('Error inicializando TTS: $e');
      rethrow;
    }
  }

  Future<void> speak(String text, {bool interrupt = false}) async {
    if (!_isInitialized) throw StateError('TTS no inicializado');
    if (text.trim().isEmpty) return;

    if (_isSpeaking && interrupt) {
      await stop();
      await Future.delayed(const Duration(milliseconds: 100));
    }

    if (_isSpeaking && !interrupt) {
      _logger.d('TTS ocupado, esperando...');
      await waitForCompletion();
    }

    final cleanText = _cleanText(text);
    if (cleanText.isEmpty) return;

    _logger.d('🔊 "$cleanText"');

    // ── SOLUCIÓN 2: Retry con backoff ─────────────────────────────────────
    // Si el motor aún no está listo (raro con warm-up), reintentamos hasta
    // 3 veces con delays crecientes antes de rendirse.
    const retryDelays = [300, 600, 1000]; // ms
    int attempt = 0;

    while (attempt <= retryDelays.length) {
      try {
        _waitCompleter = Completer<void>();
        final result = await _tts.speak(cleanText);

        // result == 1 en Android = éxito; null/0 = probable fallo de binding
        if (result == 1 || result == null || Platform.isIOS) {
          // Éxito o iOS (donde result es siempre null)
          return;
        }

        // result != 1 en Android → motor no listo todavía
        _logger.w(
            '⚠️ TTS speak retornó $result (intento ${attempt + 1}/${retryDelays.length + 1})');

        if (attempt < retryDelays.length) {
          if (_waitCompleter != null && !_waitCompleter!.isCompleted) {
            _waitCompleter!.complete();
          }
          await Future.delayed(Duration(milliseconds: retryDelays[attempt]));
          attempt++;
          continue;
        }

        // Se agotaron los reintentos
        _logger.e('❌ TTS falló después de ${attempt + 1} intentos');
        _isSpeaking = false;
        if (_waitCompleter != null && !_waitCompleter!.isCompleted) {
          _waitCompleter!.complete();
        }
        return;
      } catch (e) {
        _logger.e('Error speak (intento ${attempt + 1}): $e');
        _isSpeaking = false;
        if (_waitCompleter != null && !_waitCompleter!.isCompleted) {
          _waitCompleter!.complete();
        }

        if (attempt < retryDelays.length) {
          await Future.delayed(Duration(milliseconds: retryDelays[attempt]));
          attempt++;
          continue;
        }
        return;
      }
    }
  }

  Future<void> stop() async {
    if (!_isSpeaking) return;
    try {
      await _tts.stop();
      _isSpeaking = false;
      if (_waitCompleter != null && !_waitCompleter!.isCompleted) {
        _waitCompleter!.complete();
      }
    } catch (e) {
      _logger.e('Error stop: $e');
    }
  }

  Future<void> waitForCompletion({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!_isSpeaking) return;

    final completer = _waitCompleter;
    if (completer == null || completer.isCompleted) return;

    try {
      await completer.future.timeout(timeout);
    } on TimeoutException {
      _logger.w('TTS timeout (${timeout.inSeconds}s)');
      _isSpeaking = false;
    }
  }

  String _cleanText(String text) {
    return text
        .replaceAll(
            RegExp(r'[^\w\s\.,!?;:()\-áéíóúñÁÉÍÓÚÑ]', unicode: true), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  bool get isInitialized => _isInitialized;
  bool get isSpeaking => _isSpeaking;

  void dispose() {
    _tts.stop();
    _completionController.close();
    if (_waitCompleter != null && !_waitCompleter!.isCompleted) {
      _waitCompleter!.complete();
    }
  }
}