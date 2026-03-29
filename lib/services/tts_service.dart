// lib/services/tts_service.dart
// ✅ v2.6 — Logs limpios
//
// ============================================================================
//  CAMBIOS v2.5 → v2.6
// ============================================================================
//
//  Logger reemplazado por wrapper de dos niveles:
//    _log()      → solo en debug builds (assert — eliminado en release)
//    _logError() → siempre (errores críticos reales)
//
//  TODO LO DEMÁS ES IDÉNTICO A v2.5.

import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:io';

class TTSService {
  static final TTSService _instance = TTSService._internal();
  factory TTSService() => _instance;
  TTSService._internal();

  // ─── Logging ────────────────────────────────────────────────────────────
  static void _log(String msg) {
    assert(() {
      debugPrint('[TTS] $msg');
      return true;
    }());
  }

  static void _logError(String msg) => debugPrint('[TTS] ❌ $msg');

  // ─── Estado ─────────────────────────────────────────────────────────────

  final FlutterTts _tts = FlutterTts();

  bool _isInitialized = false;
  bool _isSpeaking    = false;

  final _completionController = StreamController<void>.broadcast();
  Stream<void> get onComplete => _completionController.stream;

  Completer<void>? _waitCompleter;

  void _safeComplete() {
    if (_waitCompleter != null && !_waitCompleter!.isCompleted) {
      _waitCompleter!.complete();
    }
  }

  // ─── Inicialización ──────────────────────────────────────────────────────

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      _tts.setStartHandler(() {
        _isSpeaking = true;
        _log('TTS iniciado');
      });

      _tts.setCompletionHandler(() {
        _isSpeaking = false;
        _log('TTS completado');
        _completionController.add(null);
        _safeComplete();
      });

      _tts.setCancelHandler(() {
        _isSpeaking = false;
        _log('TTS cancelado');
        _completionController.add(null);
        _safeComplete();
      });

      _tts.setErrorHandler((msg) {
        _isSpeaking = false;
        _logError('TTS error: $msg');
        _completionController.add(null);
        _safeComplete();
      });

      await _tts.setLanguage('es-ES');
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);

      if (Platform.isAndroid) {
        await _tts.setQueueMode(0);
        await _tts.awaitSpeakCompletion(true);
      }

      _isInitialized = true;

      // Warm-up silencioso
      await Future.delayed(const Duration(milliseconds: 200));
      try {
        await _tts.speak(' ');
        await Future.delayed(const Duration(milliseconds: 300));
      } catch (_) {}

      _log('v2.6 inicializado');
    } catch (e) {
      _logError('Error inicializando: $e');
      rethrow;
    }
  }

  // ─── speak ───────────────────────────────────────────────────────────────

  Future<void> speak(String text, {bool interrupt = false}) async {
    if (!_isInitialized) throw StateError('TTS no inicializado');
    if (text.trim().isEmpty) return;

    if (_isSpeaking && interrupt) {
      await stop();
      // v2.4 FIX 1: 400ms para que el motor Android libere el engine
      await Future.delayed(const Duration(milliseconds: 400));
    }

    if (_isSpeaking && !interrupt) {
      _log('TTS ocupado, descartando (no interrupt): "$text"');
      return;
    }

    final cleanText = _cleanText(text);
    if (cleanText.isEmpty) return;

    _log('"$cleanText"');

    const retryDelays = [300, 600, 1000];
    int attempt = 0;

    while (attempt <= retryDelays.length) {
      try {
        _waitCompleter = Completer<void>();

        final result = await _tts.speak(cleanText);

        if (result == 1 || result == null || Platform.isIOS) {
          return;
        }

        if (_isSpeaking) {
          if (attempt < retryDelays.length) {
            _safeComplete();
            await Future.delayed(Duration(milliseconds: retryDelays[attempt]));
            attempt++;
            continue;
          } else {
            _safeComplete();
            return;
          }
        }

        if (attempt < retryDelays.length) {
          _safeComplete();
          await Future.delayed(Duration(milliseconds: retryDelays[attempt]));
          attempt++;
          continue;
        }

        _logError('TTS falló después de ${attempt + 1} intentos');
        _isSpeaking = false;
        _safeComplete();
        return;
      } catch (e) {
        _logError('speak error (intento ${attempt + 1}): $e');
        _isSpeaking = false;
        _safeComplete();

        if (attempt < retryDelays.length) {
          await Future.delayed(Duration(milliseconds: retryDelays[attempt]));
          attempt++;
          continue;
        }
        return;
      }
    }
  }

  // ─── stop / wait ─────────────────────────────────────────────────────────

  Future<void> stop() async {
    if (!_isSpeaking) return;
    _isSpeaking = false;
    try {
      await _tts.stop();
      _safeComplete();
    } catch (e) {
      _logError('stop error: $e');
      _safeComplete();
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
      _log('TTS timeout (${timeout.inSeconds}s)');
      _isSpeaking = false;
    }
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────

  String _cleanText(String text) {
    return text
        .replaceAll(
            RegExp(r'[^\w\s\.,!?;:()\-áéíóúñÁÉÍÓÚÑ]', unicode: true), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  bool get isInitialized => _isInitialized;
  bool get isSpeaking    => _isSpeaking;

  void dispose() {
    _tts.stop();
    _completionController.close();
    _safeComplete();
  }
}