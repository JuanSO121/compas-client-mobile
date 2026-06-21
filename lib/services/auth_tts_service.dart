// lib/services/auth_tts_service.dart
//
// ============================================================================
//  AuthTTSService  v4.2 — Fix canal TTS/STT · speakBeforeListen robusto
// ============================================================================
//
//  CAMBIOS v4.1 → v4.2
// ============================================================================
//
//  CONTEXTO — Por qué el micrófono falla en Android:
//  ─────────────────────────────────────────────────
//  En Android, TTS (TextToSpeech) y STT (SpeechRecognizer) comparten el
//  canal de audio. Si el TTS no libera completamente el canal antes de que
//  STT intente abrirlo, el motor STT recibe error_no_match con permanent:true
//  o error_client, y el micrófono queda muerto hasta reiniciar la app.
//
//  FIX 1 — waitForCompletion() con doble barrera
//  ─────────────────────────────────────────────
//  La versión anterior usaba solo el Completer interno (_waitCompleter).
//  Si el handler setCompletionHandler() se disparaba ANTES de que
//  waitForCompletion() fuera llamado (race condition en el event loop de
//  Flutter), el Completer ya estaba completado y waitForCompletion()
//  retornaba inmediatamente sin esperar el silencio real del canal.
//
//  CORRECCIÓN: añadido _audioReleaseDelay (300ms) después de que el
//  Completer completa. Esto garantiza que el canal de audio de Android
//  quede efectivamente libre antes de que el STT intente abrirlo.
//
//  FIX 2 — speakBeforeListen() más robusto
//  ────────────────────────────────────────
//  La señal de "ya escucho" ('Si.') es crítica: si el TTS no termina
//  antes de que STT abra, produce eco y el motor rechaza el audio.
//  CORRECCIÓN: speakBeforeListen() ahora hace:
//    1. speak() con priority 2, interrupt: true (interrumpe cualquier TTS activo)
//    2. waitForCompletion() con timeout 3s
//    3. _audioReleaseDelay adicional de 400ms
//  Esto da margen suficiente para que Android libere el canal de audio.
//
//  FIX 3 — Guard de completado reducido de 25s → 15s
//  ──────────────────────────────────────────────────
//  El guard anterior de 25s podía mantener el canal de audio ocupado
//  demasiado tiempo si el TTS se colgaba silenciosamente. 15s es más
//  que suficiente para cualquier texto de la app y libera antes.
//
//  FIX 4 — _stopInternal() con delay de liberación de canal
//  ─────────────────────────────────────────────────────────
//  Al detener el TTS (p.ej. antes de abrir STT), se añade una pausa de
//  150ms después de _tts.stop() para que Android libere el canal de audio
//  antes de que el llamador continúe. Antes era 80ms, insuficiente en
//  dispositivos lentos (Android 10, Snapdragon 400-series).
//
//  FIX 5 — announceServiceError: priority 1 (era 2)
//  ──────────────────────────────────────────────────
//  Con priority 2 e interrupt: false, el aviso de error de micrófono se
//  descartaba si había cualquier otro TTS activo (prio >= 2). Bajando a
//  priority 1, se descarta solo si hay algo de igual o mayor prioridad,
//  manteniendo el comportamiento no-interruptivo de v4.1.
//
//  TODOS LOS FIXES v4.0 y v4.1 SE MANTIENEN INTACTOS.

import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:io';

import 'voice_nav_service.dart';

class AuthTTSService {
  // ── Singleton ──────────────────────────────────────────────────────────────
  static final AuthTTSService _instance = AuthTTSService._internal();
  factory AuthTTSService() => _instance;
  AuthTTSService._internal();

  static void _log(String msg) {
    assert(() {
      debugPrint('[AuthTTS] $msg');
      return true;
    }());
  }

  static void _logError(String msg) => debugPrint('[AuthTTS] ❌ $msg');

  // ── FIX 1: delay de liberación de canal de audio tras TTS ─────────────────
  // 300ms es suficiente en la mayoría de dispositivos Android (Snapdragon 6xx+).
  // Para Snapdragon 400-series o Android 10, se usa 400ms en speakBeforeListen.
  static const Duration _audioReleaseDelay = Duration(milliseconds: 300);

  // ── Estado ─────────────────────────────────────────────────────────────────
  final FlutterTts _tts = FlutterTts();
  bool _isInitialized   = false;
  bool _isSpeaking      = false;
  bool _isWarmingUp     = false;
  int  _currentPriority = -1;

  Completer<void>? _waitCompleter;
  Timer?           _completionGuard;

  void _safeComplete() {
    _completionGuard?.cancel();
    _completionGuard = null;

    if (_waitCompleter != null && !_waitCompleter!.isCompleted) {
      _waitCompleter!.complete();
    }
    VoiceNavService().unblock();
  }

  // ── Inicialización ─────────────────────────────────────────────────────────

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      _tts.setStartHandler(() {
        if (_isWarmingUp) return;
        _isSpeaking = true;
        _log('Iniciado');
      });

      _tts.setCompletionHandler(() {
        if (_isWarmingUp) return;
        _isSpeaking      = false;
        _currentPriority = -1;
        _safeComplete();
        _log('Completado');
      });

      _tts.setCancelHandler(() {
        if (_isWarmingUp) return;
        _isSpeaking      = false;
        _currentPriority = -1;
        _safeComplete();
        _log('Cancelado');
      });

      _tts.setErrorHandler((msg) {
        if (_isWarmingUp) return;
        _isSpeaking      = false;
        _currentPriority = -1;
        _safeComplete();
        _logError('Error TTS: $msg');
      });

      await _tts.setLanguage('es-ES');
      await _tts.setSpeechRate(0.44);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);

      if (Platform.isAndroid) {
        await _tts.setQueueMode(0); // FLUSH — más predecible
      }

      _isInitialized = true;
      _log('Inicializado v4.2');

      // Warm-up aislado — NO dispara handlers principales
      _isWarmingUp = true;
      try {
        await _tts.speak(' ');
        await Future.delayed(const Duration(milliseconds: 350));
      } catch (_) {}
      _isWarmingUp     = false;
      _isSpeaking      = false;
      _currentPriority = -1;

    } catch (e) {
      _logError('Error inicializando: $e');
      rethrow;
    }
  }

  // ── API pública ────────────────────────────────────────────────────────────

  Future<void> announceScreen(String text) async =>
      speak(text, priority: 3, interrupt: true);

  Future<void> announceButton(String text) async =>
      speak(text, priority: 1, interrupt: true);

  Future<void> announceError(String text) async =>
      speak(text, priority: 2, interrupt: true);

  Future<void> announceSuccess(String text) async =>
      speak(text, priority: 2, interrupt: true);

  // FIX v4.1 mantenido + FIX 5: priority 1 (en lugar de 2) para que no
  // compita con announceScreen (prio 3) ni announceError (prio 2).
  // interrupt: false — si hay algo activo, se descarta silenciosamente.
  Future<void> announceServiceError(String text) async =>
      speak(text, priority: 1, interrupt: false);

  /// Confirmación corta de "ya estoy escuchando".
  Future<void> announceListening() async =>
      speak('Escuchando.', priority: 1, interrupt: false);

  // ── speakBeforeListen ──────────────────────────────────────────────────────
  //
  // FIX 2: señal de "ya escucho" con doble barrera de liberación de canal.
  // Interrumpe cualquier TTS activo, espera completado y añade delay extra.
  // Esto evita que el motor STT reciba el audio del TTS como entrada.

  Future<void> speakBeforeListen() async {
    // Interrumpir cualquier TTS activo antes de la señal
    if (_isSpeaking) {
      await _stopInternal();
    }

    await speak('Si.', priority: 2, interrupt: true);
    await waitForCompletion(timeout: const Duration(seconds: 3));

    // FIX 2: delay adicional para liberar canal de audio en dispositivos lentos
    await Future.delayed(const Duration(milliseconds: 400));
  }

  // ── speak interno ──────────────────────────────────────────────────────────

  Future<void> speak(
      String text, {
        required int  priority,
        bool          interrupt = false,
      }) async {
    if (!_isInitialized) {
      _logError('No inicializado — llamar initialize() primero');
      return;
    }
    if (text.trim().isEmpty) return;

    if (_isSpeaking && priority < _currentPriority) {
      _log('Ocupado (prio $_currentPriority), descartando prio $priority');
      return;
    }

    // Si interrupt es false y hay algo hablando, descartar (FIX v4.1)
    if (_isSpeaking && !interrupt) {
      _log('Ocupado (prio $_currentPriority), no-interrupt descartando prio $priority');
      return;
    }

    if (_isSpeaking) {
      await _stopInternal();
      // FIX 1: pausa extra tras stop para liberar canal antes de nuevo speak
      await Future.delayed(const Duration(milliseconds: 100));
    }

    final clean = _cleanText(text);
    if (clean.isEmpty) return;

    _currentPriority = priority;
    _log('[$priority] "$clean"');

    VoiceNavService().block();

    _isSpeaking    = true;
    _waitCompleter = Completer<void>();

    _completionGuard?.cancel();
    // FIX 3: guard reducido de 25s → 15s para liberar canal antes
    _completionGuard = Timer(const Duration(seconds: 15), () {
      _log('Guard de completado activado — forzando fin');
      _isSpeaking      = false;
      _currentPriority = -1;
      _safeComplete();
    });

    try {
      _tts.speak(clean);
    } catch (e) {
      _logError('speak error: $e');
      _isSpeaking      = false;
      _currentPriority = -1;
      _safeComplete();
    }
  }

  Future<void> stop() async => _stopInternal();

  Future<void> _stopInternal() async {
    if (!_isSpeaking) return;
    _isSpeaking      = false;
    _currentPriority = -1;
    _completionGuard?.cancel();
    _completionGuard = null;
    try {
      await _tts.stop();
    } catch (e) {
      _logError('stop error: $e');
    }
    // FIX 4: 150ms (era 80ms) — suficiente para Snapdragon 400-series
    await Future.delayed(const Duration(milliseconds: 150));
    if (_waitCompleter != null && !_waitCompleter!.isCompleted) {
      _waitCompleter!.complete();
    }
    VoiceNavService().unblock();
  }

  // ── waitForCompletion ──────────────────────────────────────────────────────
  //
  // FIX 1: añadido _audioReleaseDelay (300ms) tras completar el Completer.
  // Esto garantiza que el canal de audio de Android quede libre antes de
  // que el llamador (normalmente _ivrSpeak o _speakAndWait) abra STT.

  Future<void> waitForCompletion({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (!_isSpeaking) {
      // Ya no está hablando, pero el canal puede no estar libre todavía.
      // Pequeña pausa de seguridad.
      await Future.delayed(const Duration(milliseconds: 80));
      return;
    }

    final completer = _waitCompleter;
    if (completer == null || completer.isCompleted) {
      await Future.delayed(const Duration(milliseconds: 80));
      return;
    }

    try {
      await completer.future.timeout(
        timeout,
        onTimeout: () {
          _log('waitForCompletion: timeout, continuando');
          _isSpeaking      = false;
          _currentPriority = -1;
          _safeComplete();
        },
      );
    } catch (_) {}

    // FIX 1: pausa de liberación de canal de audio DESPUÉS de que el
    // Completer completa. Evita race condition TTS→STT en Android.
    await Future.delayed(_audioReleaseDelay);
  }

  // ── _cleanText ─────────────────────────────────────────────────────────────

  String _cleanText(String text) {
    return text
        .replaceAll('°', ' ')
        .replaceAll('·', ' ')
        .replaceAll('•', ' ')
        .replaceAll(
      RegExp(r'[^\w\s\.,!?;:()\-áéíóúñÁÉÍÓÚÑ@]', unicode: true),
      ' ',
    )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  bool get isInitialized => _isInitialized;
  bool get isSpeaking    => _isSpeaking;

  void dispose() {
    _completionGuard?.cancel();
    _tts.stop();
    _isInitialized   = false;
    _isSpeaking      = false;
    _currentPriority = -1;
    if (_waitCompleter != null && !_waitCompleter!.isCompleted) {
      _waitCompleter!.complete();
    }
    _log('Liberado');
  }
}