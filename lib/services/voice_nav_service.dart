// lib/services/voice_nav_service.dart
//
// ============================================================================
//  VoiceNavService  v1.1 — Shutdown limpio al salir del flujo auth
// ============================================================================
//
//  CAMBIOS v1.0 → v1.1
// ============================================================================
//
//  BUG — Instancia huérfana compitiendo con WakeWordService por el micrófono
//  ─────────────────────────────────────────────────────────────────────────
//  SÍNTOMA (log):
//    [WakeWord] Sesión abierta (listenFor=1h, pauseFor=20s)   ← AR OK
//    [AuthVoiceNav] STT error: error_no_match, permanent:true ← instancia huérfana
//    Lost connection to device                                 ← proceso muerto
//
//  CAUSA:
//    Al navegar de LoginScreen/RegisterScreen → ArNavigationScreen, ninguna
//    pantalla llamaba a VoiceNavService().dispose() ni
//    AuthVoiceNavigationService().dispose(). Ambas instancias singleton
//    mantenían su SpeechToText activo. Cuando WakeWordService abría su
//    sesión STT, encontraba el canal de audio ocupado por la instancia
//    auth → error_no_match con permanent:true → WakeWord no podía iniciar
//    → app se desestabilizaba y el proceso moría.
//
//  FIX 1 — shutdownForARTransition():
//    Nuevo método público que hace un shutdown completo y limpio:
//    · Para la escucha (stopListening)
//    · Cancela el timer de restart
//    · Cancela el audio de STT
//    · Marca el servicio como no inicializado (fuerza re-init si se reutiliza)
//    · NO cierra el StreamController (lo deja abierto para posible re-uso)
//    Debe llamarse desde el widget/controller que navega a ArNavigationScreen,
//    ANTES de hacer Navigator.push/pushReplacement.
//
//  FIX 2 — Timer de restart cancelable:
//    _restartTimer guardado como campo para poder cancelarlo en shutdown.
//    Antes, _scheduleRestart() lanzaba un Future suelto que podía reactivar
//    el STT incluso después de stopListening(), creando una ventana de
//    race condition de ~800ms.
//
//  FIX 3 — _stopSpeech() más robusta:
//    Añadido await a _speech.stop() para garantizar que el canal de audio
//    se libera completamente antes de que shutdownForARTransition() retorne.
//    La versión anterior era fire-and-forget.
//
//  TODO LO DEMÁS ES IDÉNTICO A v1.0.

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_result.dart' as stt;

enum VoiceNavCommand { login, register, guest, back, help }

class VoiceNavService {
  // ── Singleton ──────────────────────────────────────────────────────────────
  static final VoiceNavService _instance = VoiceNavService._internal();
  factory VoiceNavService() => _instance;
  VoiceNavService._internal();

  // ── Logging ────────────────────────────────────────────────────────────────
  static void _log(String msg) {
    assert(() {
      debugPrint('[VoiceNav] $msg');
      return true;
    }());
  }

  // ── Estado ─────────────────────────────────────────────────────────────────
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _initialized = false;
  bool _listening   = false;
  bool _blocked     = false;

  // FIX 2: timer guardado para poder cancelarlo en shutdown
  Timer? _restartTimer;

  final StreamController<VoiceNavCommand> _controller =
  StreamController<VoiceNavCommand>.broadcast();

  Stream<VoiceNavCommand> get commands => _controller.stream;

  bool get isListening => _listening && !_blocked;

  // ── Inicialización ─────────────────────────────────────────────────────────

  Future<bool> initialize() async {
    if (_initialized) return true;

    _initialized = await _speech.initialize(
      onError: (e) {
        _log('STT error: ${e.errorMsg}');
        if (e.errorMsg == 'error_busy') return;
        if (!_blocked && _listening) _scheduleRestart();
      },
      onStatus: (status) {
        _log('STT status: $status');
        if ((status == 'done' || status == 'notListening') &&
            !_blocked &&
            _listening) {
          _scheduleRestart();
        }
      },
      debugLogging: false,
    );

    _log(_initialized
        ? 'Inicializado OK v1.1'
        : 'STT no disponible en este dispositivo');
    return _initialized;
  }

  // ── API pública ────────────────────────────────────────────────────────────

  Future<void> startListening() async {
    if (!_initialized || _listening || _blocked) return;
    _listening = true;
    _log('Escucha iniciada');
    await _listen();
  }

  void stopListening() {
    _listening = false;
    _restartTimer?.cancel();   // FIX 2: cancelar timer pendiente
    _restartTimer = null;
    _stopSpeech();
    _log('Escucha detenida');
  }

  void block() {
    if (_blocked) return;
    _blocked = true;
    _restartTimer?.cancel();   // FIX 2: evitar restart durante bloqueo TTS
    _restartTimer = null;
    _stopSpeech();
    _log('Bloqueado (TTS activo)');
  }

  Future<void> unblock() async {
    if (!_blocked) return;
    _blocked = false;
    _log('Desbloqueado');
    if (_listening) {
      await Future.delayed(const Duration(milliseconds: 200));
      await _listen();
    }
  }

  // ── FIX 1 — Shutdown limpio para transición a AR ───────────────────────────

  /// Apaga el servicio completamente antes de navegar a ArNavigationScreen.
  ///
  /// CUÁNDO LLAMAR:
  ///   Desde el controller/widget que hace Navigator.push hacia ArNavigationScreen,
  ///   ANTES de ejecutar la navegación. También llamar desde AuthVoiceNavigationService
  ///   justo antes de hacer dispose() o pauseListening() definitivo.
  ///
  /// POR QUÉ ES NECESARIO:
  ///   VoiceNavService y AuthVoiceNavigationService son singletons. Si no se
  ///   apagan explícitamente, sus instancias de SpeechToText siguen activas
  ///   y compiten con WakeWordService por el canal de audio de Android,
  ///   causando error_no_match con permanent:true → micrófono muerto en AR.
  ///
  /// DIFERENCIA CON dispose():
  ///   dispose() cierra el StreamController (destructivo, no reversible).
  ///   shutdownForARTransition() solo para la escucha y marca el servicio
  ///   como no inicializado. Si por alguna razón el flujo auth se retoma,
  ///   initialize() puede volver a llamarse.
  Future<void> shutdownForARTransition() async {
    _log('▶ shutdownForARTransition iniciado');

    _listening = false;
    _blocked   = false;

    // FIX 2: cancelar cualquier timer de restart pendiente
    _restartTimer?.cancel();
    _restartTimer = null;

    // FIX 3: await para garantizar liberación del canal de audio
    await _stopSpeechAsync();

    // Marcar como no inicializado para forzar re-init si se reutiliza
    _initialized = false;

    _log('✅ shutdownForARTransition completado — canal de audio liberado');
  }

  // ── Internos ───────────────────────────────────────────────────────────────

  Future<void> _listen() async {
    if (!_initialized || _blocked || !_listening) return;
    if (_speech.isListening) return;

    await _speech.listen(
      onResult: (stt.SpeechRecognitionResult result) {
        if (!result.finalResult) return;
        final raw = result.recognizedWords.trim().toLowerCase();
        _log('Reconocido: "$raw"');
        final cmd = _parse(raw);
        if (cmd != null && !_controller.isClosed) {
          _log('Comando emitido: $cmd');
          _controller.add(cmd);
        }
      },
      localeId: 'es_CO',
      listenFor: const Duration(seconds: 30),
      pauseFor:  const Duration(seconds: 6),
      listenOptions: stt.SpeechListenOptions(
        partialResults:       false,
        cancelOnError:        false,
        listenMode:           stt.ListenMode.dictation,
        onDevice:             false,
        autoPunctuation:      false,
        enableHapticFeedback: false,
      ),
    );
  }

  // FIX 3: versión síncrona (fire-and-forget) para uso en block/stop
  void _stopSpeech() {
    try {
      _speech.stop();
      _speech.cancel();
    } catch (_) {}
  }

  // FIX 3: versión async con await para garantizar liberación del canal
  Future<void> _stopSpeechAsync() async {
    try {
      await _speech.stop();
    } catch (_) {}
    try {
      await _speech.cancel();
    } catch (_) {}
  }

  void _scheduleRestart() {
    // FIX 2: cancelar restart previo antes de programar uno nuevo
    _restartTimer?.cancel();
    _restartTimer = Timer(const Duration(milliseconds: 800), () {
      _restartTimer = null;
      if (_listening && !_blocked && !_speech.isListening) {
        _listen();
      }
    });
  }

  // ── Parser de comandos ─────────────────────────────────────────────────────

  static VoiceNavCommand? _parse(String text) {
    if (_containsAny(text, [
      'sesión', 'sesion', 'iniciar', 'inicio', 'login',
      'ingresar', 'entrar', 'acceder',
    ])) return VoiceNavCommand.login;

    if (_containsAny(text, [
      'registro', 'registrar', 'registrarme', 'nuevo', 'nueva cuenta',
      'crear cuenta', 'crear',
    ])) return VoiceNavCommand.register;

    if (_containsAny(text, [
      'invitado', 'sin cuenta', 'explorar', 'probar', 'como invitado',
    ])) return VoiceNavCommand.guest;

    if (_containsAny(text, [
      'volver', 'atrás', 'atras', 'regresar', 'cancelar', 'salir',
    ])) return VoiceNavCommand.back;

    if (_containsAny(text, [
      'ayuda', 'ayúdame', 'ayudame', 'qué puedo', 'que puedo', 'opciones',
    ])) return VoiceNavCommand.help;

    return null;
  }

  static bool _containsAny(String text, List<String> words) =>
      words.any((w) => text.contains(w));

  // ── Dispose ────────────────────────────────────────────────────────────────

  /// Solo llamar al cerrar la app por completo.
  /// Para transición a AR, usar shutdownForARTransition().
  void dispose() {
    _restartTimer?.cancel();  // FIX 2
    _restartTimer = null;
    stopListening();
    if (!_controller.isClosed) _controller.close();
    _initialized = false;
    _log('Liberado');
  }
}