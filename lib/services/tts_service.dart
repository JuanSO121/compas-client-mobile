// lib/services/tts_service.dart
// ✅ v2.7 — Notifica tts_status a Unity · Fix _cleanText con caracteres especiales
//
// ============================================================================
//  CAMBIOS v2.6 → v2.7
// ============================================================================
//
//  1. onTTSStatusChanged — callback nuevo que el caller puede registrar.
//     Se dispara con (isSpeaking: bool, priority: int) cada vez que el TTS
//     termina, cancela o falla. NavigationCoordinator lo conecta al
//     UnityBridgeService para que Unity pueda liberar _ttsBusy:
//
//       _ttsService.onTTSStatusChanged = (speaking, priority) {
//         _unityBridge?.sendTTSStatus(isSpeaking: speaking, priority: priority);
//       };
//
//     Unity recibe {"action":"tts_status","isSpeaking":false,"priority":0}
//     y llama NavigationVoiceGuide.ClearTTSBusy().
//
//  2. _cleanText() — fix: los caracteres especiales ahora se reemplazan por
//     espacio antes de colapsar whitespace, en lugar de eliminarse.
//     Ejemplo anterior: "Habitación 2°Piso" → "Habitacin 2Piso" (incorrecto)
//     Ejemplo nuevo:    "Habitación 2°Piso" → "Habitacion 2 Piso" (correcto)
//     El regex de eliminación mantiene letras, números, espacios y
//     puntuación básica; todo lo demás → espacio.
//
//  3. _currentPriority — rastrea la prioridad del TTS activo para incluirla
//     en el tts_status. Permite que Unity decida si liberar _ttsBusy.
//
//  TODO LO DEMÁS ES IDÉNTICO A v2.6.

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

  // ✅ v2.7: prioridad del TTS activo (se incluye en tts_status).
  int _currentPriority = 0;

  final _completionController = StreamController<void>.broadcast();
  Stream<void> get onComplete => _completionController.stream;

  Completer<void>? _waitCompleter;

  // ✅ v2.7: callback para notificar cambios de estado a Unity.
  // Firma: (isSpeaking, priority)
  // Registrar en NavigationCoordinator.attachUnityBridge():
  //   _ttsService.onTTSStatusChanged = (speaking, priority) {
  //     _unityBridge?.sendTTSStatus(isSpeaking: speaking, priority: priority);
  //   };
  Function(bool isSpeaking, int priority)? onTTSStatusChanged;

  void _safeComplete() {
    if (_waitCompleter != null && !_waitCompleter!.isCompleted) {
      _waitCompleter!.complete();
    }
  }

  void _notifyStatusDone() {
    // Notifica a Unity que el TTS terminó/canceló.
    onTTSStatusChanged?.call(false, _currentPriority);
    _currentPriority = 0;
  }

  // ─── Inicialización ──────────────────────────────────────────────────────

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      _tts.setStartHandler(() {
        _isSpeaking = true;
        _log('TTS iniciado');
        // No notificamos start a Unity — solo done/cancel importa.
      });

      _tts.setCompletionHandler(() {
        _isSpeaking = false;
        _log('TTS completado');
        _completionController.add(null);
        _safeComplete();
        _notifyStatusDone(); // ✅ v2.7
      });

      _tts.setCancelHandler(() {
        _isSpeaking = false;
        _log('TTS cancelado');
        _completionController.add(null);
        _safeComplete();
        _notifyStatusDone(); // ✅ v2.7
      });

      _tts.setErrorHandler((msg) {
        _isSpeaking = false;
        _logError('TTS error: $msg');
        _completionController.add(null);
        _safeComplete();
        _notifyStatusDone(); // ✅ v2.7
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

      _log('v2.7 inicializado');
    } catch (e) {
      _logError('Error inicializando: $e');
      rethrow;
    }
  }

  // ─── speak ───────────────────────────────────────────────────────────────

  Future<void> speak(String text, {bool interrupt = false, int priority = 0}) async {
    if (!_isInitialized) throw StateError('TTS no inicializado');
    if (text.trim().isEmpty) return;

    if (_isSpeaking && interrupt) {
      await stop();
      await Future.delayed(const Duration(milliseconds: 400));
    }

    if (_isSpeaking && !interrupt) {
      _log('TTS ocupado, descartando (no interrupt): "$text"');
      onTTSStatusChanged?.call(false, _currentPriority);
      return;
    }

    final cleanText = _cleanText(text);
    if (cleanText.isEmpty) return;

    // ✅ v2.7: guardar prioridad para incluirla en el tts_status done.
    _currentPriority = priority;
    onTTSStatusChanged?.call(true, _currentPriority);

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
      // setCancelHandler se dispara → _notifyStatusDone() se llama allí.
    } catch (e) {
      _logError('stop error: $e');
      _safeComplete();
      _notifyStatusDone();
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

  // ─── _cleanText ──────────────────────────────────────────────────────────

  /// ✅ v2.7: caracteres especiales → espacio (no eliminación directa).
  /// Evita que "2°Piso" → "2Piso"; ahora → "2 Piso".
  String _cleanText(String text) {
    return text
        // Primero reemplazar caracteres especiales comunes por espacio
        .replaceAll('°', ' ')
        .replaceAll('·', ' ')
        .replaceAll('•', ' ')
        // Luego eliminar cualquier char que no sea letra/número/espacio/puntuación básica
        .replaceAll(
            RegExp(r'[^\w\s\.,!?;:()\-áéíóúñÁÉÍÓÚÑ]', unicode: true), ' ')
        // Colapsar múltiples espacios
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  bool get isInitialized => _isInitialized;
  bool get isSpeaking    => _isSpeaking;

  void dispose() {
    _tts.stop();
    _completionController.close();
    _safeComplete();
    onTTSStatusChanged = null;
  }
}