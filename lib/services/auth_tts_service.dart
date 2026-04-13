// lib/services/auth_tts_service.dart
//
// ============================================================================
//  AuthTTSService  v1.0
// ============================================================================
//
//  Servicio TTS EXCLUSIVO para el flujo de autenticación (Welcome, Login,
//  Register). Se mantiene completamente separado del TTSService de navegación
//  para evitar conflictos de estado y prioridad.
//
//  Decisiones de diseño:
//  • Singleton ligero — se inicializa en WelcomeScreen y se libera al entrar
//    a ArNavigationScreen.
//  • Prioridades internas:
//      0 = anuncio de pantalla  (se omite si hay otro hablando)
//      1 = feedback de botón    (interrumpe anuncio de pantalla)
//      2 = error / validación   (interrumpe todo)
//  • Cola simple de un solo elemento: si llega un mensaje de mayor prioridad
//    cancela el actual. Si es igual o menor, se descarta.
//  • _cleanText reutiliza la misma lógica que TTSService v2.7.
// ============================================================================

import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:io';

class AuthTTSService {
  // ── Singleton ──────────────────────────────────────────────────────────────
  static final AuthTTSService _instance = AuthTTSService._internal();
  factory AuthTTSService() => _instance;
  AuthTTSService._internal();

  // ── Logging ────────────────────────────────────────────────────────────────
  static void _log(String msg) {
    assert(() {
      debugPrint('[AuthTTS] $msg');
      return true;
    }());
  }

  static void _logError(String msg) => debugPrint('[AuthTTS] ❌ $msg');

  // ── Estado ─────────────────────────────────────────────────────────────────
  final FlutterTts _tts = FlutterTts();
  bool _isInitialized = false;
  bool _isSpeaking = false;
  int _currentPriority = -1;

  Completer<void>? _waitCompleter;

  void _safeComplete() {
    if (_waitCompleter != null && !_waitCompleter!.isCompleted) {
      _waitCompleter!.complete();
    }
  }

  // ── Inicialización ─────────────────────────────────────────────────────────

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      _tts.setStartHandler(() {
        _isSpeaking = true;
        _log('Iniciado');
      });

      _tts.setCompletionHandler(() {
        _isSpeaking = false;
        _currentPriority = -1;
        _safeComplete();
        _log('Completado');
      });

      _tts.setCancelHandler(() {
        _isSpeaking = false;
        _currentPriority = -1;
        _safeComplete();
        _log('Cancelado');
      });

      _tts.setErrorHandler((msg) {
        _isSpeaking = false;
        _currentPriority = -1;
        _safeComplete();
        _logError('Error TTS: $msg');
      });

      // Configuración en español — misma que TTSService
      await _tts.setLanguage('es-ES');
      await _tts.setSpeechRate(0.48);   // Ligeramente más lento para auth
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);

      if (Platform.isAndroid) {
        await _tts.setQueueMode(0);
        await _tts.awaitSpeakCompletion(true);
      }

      _isInitialized = true;

      // Warm-up silencioso
      await Future.delayed(const Duration(milliseconds: 150));
      try {
        await _tts.speak(' ');
        await Future.delayed(const Duration(milliseconds: 200));
      } catch (_) {}

      _log('Inicializado v1.0');
    } catch (e) {
      _logError('Error inicializando: $e');
      rethrow;
    }
  }

  // ── API pública ────────────────────────────────────────────────────────────

  /// Anuncia la pantalla al entrar.
  /// Prioridad 0 — se omite si ya hay algo hablando.
  Future<void> announceScreen(String text) async {
    await speak(text, priority: 0, interrupt: false);
  }

  /// Feedback de botón al tocarlo.
  /// Prioridad 1 — interrumpe anuncios de pantalla.
  Future<void> announceButton(String text) async {
    await speak(text, priority: 1, interrupt: true);
  }

  /// Error o mensaje de validación.
  /// Prioridad 2 — interrumpe todo.
  Future<void> announceError(String text) async {
    await speak(text, priority: 2, interrupt: true);
  }

  /// Confirmación de acción exitosa.
  /// Prioridad 2 — misma prioridad que error.
  Future<void> announceSuccess(String text) async {
    await speak(text, priority: 2, interrupt: true);
  }

  // ── speak interno ──────────────────────────────────────────────────────────

  Future<void> speak(
      String text, {
        required int priority,
        bool interrupt = false,
      }) async {
    if (!_isInitialized) {
      _logError('No inicializado — llamar initialize() primero');
      return;
    }
    if (text.trim().isEmpty) return;

    // Si hay algo hablando con MAYOR o IGUAL prioridad y no interrumpimos
    if (_isSpeaking && !interrupt) {
      _log('Ocupado (prio $_currentPriority), descartando prio $priority');
      return;
    }

    // Si la prioridad entrante es MENOR que la activa, no interrumpir
    if (_isSpeaking && interrupt && priority < _currentPriority) {
      _log('Prioridad $priority < activa $_currentPriority, descartando');
      return;
    }

    // Detener el actual si vamos a interrumpir
    if (_isSpeaking && interrupt) {
      await _stopInternal();
      await Future.delayed(const Duration(milliseconds: 300));
    }

    final clean = _cleanText(text);
    if (clean.isEmpty) return;

    _currentPriority = priority;
    _log('[$priority] "$clean"');

    try {
      _waitCompleter = Completer<void>();
      _isSpeaking = true;
      await _tts.speak(clean);
    } catch (e) {
      _logError('speak error: $e');
      _isSpeaking = false;
      _currentPriority = -1;
      _safeComplete();
    }
  }

  Future<void> stop() async => _stopInternal();

  Future<void> _stopInternal() async {
    if (!_isSpeaking) return;
    try {
      await _tts.stop();
    } catch (e) {
      _logError('stop error: $e');
    }
    _isSpeaking = false;
    _currentPriority = -1;
    _safeComplete();
  }

  // ── _cleanText (igual que TTSService v2.7) ─────────────────────────────────
  String _cleanText(String text) {
    return text
        .replaceAll('°', ' ')
        .replaceAll('·', ' ')
        .replaceAll('•', ' ')
        .replaceAll(
        RegExp(r'[^\w\s\.,!?;:()\-áéíóúñÁÉÍÓÚÑ]', unicode: true), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  // ── Getters ────────────────────────────────────────────────────────────────
  bool get isInitialized => _isInitialized;
  bool get isSpeaking => _isSpeaking;

  /// Liberar cuando el usuario ya entró a la app (antes de ArNavigationScreen).
  void dispose() {
    _tts.stop();
    _safeComplete();
    _isInitialized = false;
    _isSpeaking = false;
    _currentPriority = -1;
    _log('Liberado');
  }
}