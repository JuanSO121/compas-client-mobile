// lib/services/tts_service.dart
// ✅ v2.0 — Fix cola TTS: mensajes de navegación se perdían
//
// ============================================================================
//  CAMBIOS v1 → v2.0
// ============================================================================
//
//  BUG 1 CORREGIDO — waitForCompletion() consumía el evento del stream broadcast:
//
//    ANTES:
//      waitForCompletion() usaba onComplete.first — esto registra un listener
//      que consume el PRIMER evento emitido y se cancela. Como onComplete es un
//      broadcast stream, si tanto waitForCompletion() como la suscripción de
//      VoiceNavigationService escuchan simultáneamente, SOLO UNO recibe el evento.
//      En la práctica, waitForCompletion() ganaba la carrera → _onTTSCompleted()
//      de VoiceNavigationService nunca se llamaba → _pendingInstruction nunca
//      se procesaba → el segundo mensaje de navegación se perdía.
//
//    AHORA:
//      waitForCompletion() usa un Completer propio que se completa desde
//      el _completionController, sin consumir el evento del broadcast stream.
//      Todos los listeners reciben el evento correctamente.
//
//  BUG 2 CORREGIDO — setQueueMode(1) impedía callbacks por utterance:
//
//    ANTES:
//      setQueueMode(1) = QUEUE_ADD → Android encola utterances internamente
//      y emite UN SOLO completionHandler al final de toda la cola.
//      VoiceNavigationService nunca sabía cuándo terminó el primer mensaje.
//
//    AHORA:
//      setQueueMode(0) = QUEUE_FLUSH → cada speak() reemplaza la cola del
//      engine. La cola se maneja completamente en Flutter (VoiceNavigationService),
//      que tiene toda la lógica de prioridades. El engine solo ejecuta un
//      utterance a la vez y siempre emite completionHandler al terminar.
//
//  COMPORTAMIENTOS CONSERVADOS:
//    - Singleton
//    - Stream onComplete broadcast para múltiples suscriptores
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

  final Logger   _logger = Logger();
  final FlutterTts _tts  = FlutterTts();

  bool _isInitialized = false;
  bool _isSpeaking    = false;

  // ✅ v2: Stream broadcast — múltiples suscriptores reciben TODOS los eventos.
  // VoiceNavigationService y waitForCompletion() son suscriptores independientes.
  final _completionController = StreamController<void>.broadcast();
  Stream<void> get onComplete => _completionController.stream;

  // ✅ v2: Completer propio para waitForCompletion() — no consume el stream.
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

        // ✅ v2 FIX 1: Emitir en el broadcast stream — TODOS los suscriptores
        // reciben este evento (VoiceNavigationService + cualquier otro listener).
        _completionController.add(null);

        // ✅ v2 FIX 1: Completar el Completer de waitForCompletion()
        // de forma INDEPENDIENTE al broadcast stream.
        if (_waitCompleter != null && !_waitCompleter!.isCompleted) {
          _waitCompleter!.complete();
        }
      });

      _tts.setErrorHandler((msg) {
        _isSpeaking = false;
        _logger.e('❌ TTS Error: $msg');

        // Notificar error como completion para no bloquear la cola
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
        // ✅ v2 FIX 2: QUEUE_FLUSH (0) — el engine ejecuta un utterance a la vez
        // y SIEMPRE emite completionHandler al terminar cada uno.
        // ANTES: QUEUE_ADD (1) emitía UN SOLO completion al final de toda la cola
        // → VoiceNavigationService nunca sabía cuándo terminó cada instrucción.
        await _tts.setQueueMode(0);
      }

      _isInitialized = true;
      _logger.i('✅ TTS v2 inicializado');

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
      // ✅ v2 FIX 1: waitForCompletion() usa Completer propio,
      // no consume el evento del broadcast stream.
      _logger.d('TTS ocupado, esperando...');
      await waitForCompletion();
    }

    try {
      final cleanText = _cleanText(text);
      _logger.d('🔊 "$cleanText"');

      // ✅ v2: Crear nuevo Completer para este utterance ANTES de speak()
      _waitCompleter = Completer<void>();

      await _tts.speak(cleanText);
    } catch (e) {
      _logger.e('Error speak: $e');
      _isSpeaking = false;
      // Asegurarse de no dejar el Completer colgado
      if (_waitCompleter != null && !_waitCompleter!.isCompleted) {
        _waitCompleter!.complete();
      }
    }
  }

  Future<void> stop() async {
    if (!_isSpeaking) return;
    try {
      await _tts.stop();
      _isSpeaking = false;
      // Liberar cualquier waitForCompletion() pendiente
      if (_waitCompleter != null && !_waitCompleter!.isCompleted) {
        _waitCompleter!.complete();
      }
    } catch (e) {
      _logger.e('Error stop: $e');
    }
  }

  /// ✅ v2: Usa Completer propio — NO consume el broadcast stream.
  /// Múltiples suscriptores a onComplete siguen recibiendo los eventos.
  Future<void> waitForCompletion({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!_isSpeaking) return;

    // Si ya hay un Completer activo, esperar en él
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
  bool get isSpeaking    => _isSpeaking;

  void dispose() {
    _tts.stop();
    _completionController.close();
    if (_waitCompleter != null && !_waitCompleter!.isCompleted) {
      _waitCompleter!.complete();
    }
  }
}