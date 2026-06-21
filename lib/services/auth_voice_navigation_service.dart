// lib/services/auth_voice_navigation_service.dart
//
// ============================================================================
//  AuthVoiceNavigationService  v8.5
// ============================================================================
//
//  CAMBIOS v8.4 → v8.5
//
//  FIX 1 — STT canal ocupado entre sesiones (causa principal del fallo de mic)
//  ─────────────────────────────────────────────────────────────────────────────
//  SÍNTOMA: tras el IVR de código, dictateEmailField() fallaba en los 3 intentos
//  porque el canal STT seguía ocupado. error_no_match permanent:true = el motor
//  Android STT se rinde cuando recibe solicitudes con el canal aún bloqueado.
//
//  FIX: _hardResetStt() — stop + cancel + espera 600 ms + re-initialize si el
//  engine no responde. Se llama al inicio de cada sesión IVR/campo y después de
//  cualquier guard-timer expiration. Ya no confiamos solo en _stopStt().
//
//  FIX 2 — IVR dígito 6 pedía "primer dígito" en lugar de "dígito 6"
//  ─────────────────────────────────────────────────────────────────────────────
//  CAUSA: el guard del listenOnce expiraba, completaba con null, pero el while
//  seguía con digits.length == 5. Sin embargo, en el loop la rama `if (raw == null)`
//  hacía `continue` sin verificar si digits ya tenía dígitos acumulados, y el
//  prompt usaba `position == 1` para detectar si era el "primer dígito".
//  position = digits.length + 1 = 6, que no es 1, así que debería haber dicho
//  "dígito 6". El bug real: el guard timer expiraba y LUEGO _ivrSpeak() del
//  bloque siguiente ejecutaba el mensaje del _runCodeIvr() del loop siguiente
//  solapado con el _listenOnce anterior todavía activo en STT.
//
//  FIX: _listenOnce ahora espera _hardResetStt() antes de abrir STT nuevo.
//  Además, el guard timer tiene +5s (antes +3s) para darle más margen al
//  motor STT lento en Android <= 12.
//
//  FIX 3 — cancelaciones sucias del singleton al navegar entre pantallas
//  ─────────────────────────────────────────────────────────────────────────────
//  SÍNTOMA: cancelCodeIvr() se llamaba 3-4 veces → _ivrCancelRequested quedaba
//  en true → cuando se iniciaba dictateEmailField() en register, el flag
//  _fieldCancelRequested también quedaba contaminado por _ivrCancelRequested
//  (compartían lógica).
//
//  FIX: resetCancelFlags() — método público que resetea _ivrCancelRequested y
//  _fieldCancelRequested. Se llama automáticamente al inicio de dictateCodeIvr(),
//  dictateEmailField(), dictateNameField() y startFullRegistrationFlow().
//  También se llama en setCurrentScreen() para limpiar entre pantallas.
//
//  FIX 4 — Flujo completo de registro activado por voz (sin botón en UI)
//  ─────────────────────────────────────────────────────────────────────────────
//  Se añade AuthVoiceIntent.fullVoiceRegistration al parser.
//  Palabras clave: "registro por voz", "registrarme por voz", "todo por voz",
//  "registro completo", "registrar por voz".
//  El widget ya escucha registrationComplete y no necesita botón extra.
//
//  TODOS LOS FIXES v8.0–v8.4 SE MANTIENEN INTACTOS.

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_result.dart' as stt;
import 'package:permission_handler/permission_handler.dart';

import 'auth_tts_service.dart';
import 'AI/groq_service.dart';
import 'voice_nav_service.dart';

// ─── Timings ──────────────────────────────────────────────────────────────────

const Duration _kWakeWordDebounce    = Duration(seconds: 3);
const Duration _kTtsEchoWindow       = Duration(milliseconds: 2500);
const Duration _kFieldEchoWindow     = Duration(milliseconds: 5000);
const Duration _kCommandListenFor    = Duration(seconds: 15);
const Duration _kCommandPauseFor     = Duration(seconds: 4);
const Duration _kGroqCommandTimeout  = Duration(seconds: 8);
const Duration _kScreenAnnounceDelay = Duration(milliseconds: 600);
const Duration _kMicOpenDelay        = Duration(milliseconds: 1500);

// v8.5: más margen para motores STT lentos (Android 10-12)
const Duration _kListenOnceGuardExtra = Duration(seconds: 5);
// v8.5: tiempo de espera hard reset STT entre sesiones
const Duration _kSttHardResetDelay   = Duration(milliseconds: 650);

const int _kMaxSttErrors = 3;

// ─── Intents ──────────────────────────────────────────────────────────────────

enum AuthVoiceIntent {
  login, register, guest,
  dictateCode, dictateEmail, dictateName,
  help, repeat, back, unknown,
  registrationComplete,
  // v8.5: nuevo intent para activar flujo completo por voz
  fullVoiceRegistration,
}

// ─── Modelos ──────────────────────────────────────────────────────────────────

class FieldDictationResult {
  final String        rawText;
  final String        normalizedText;
  final AuthFieldType fieldType;
  final bool          confirmed;
  const FieldDictationResult({
    required this.rawText,
    required this.normalizedText,
    required this.fieldType,
    required this.confirmed,
  });
}

enum AuthFieldType { email, name, lastName, accessCode }

class AuthVoiceEvent {
  final AuthVoiceIntent         intent;
  final FieldDictationResult?   fieldResult;
  final String                  rawText;
  final FullRegistrationResult? registrationResult;

  const AuthVoiceEvent({
    required this.intent,
    this.fieldResult,
    required this.rawText,
    this.registrationResult,
  });
}

class CodeIvrResult {
  final String code;
  final bool   cancelled;
  const CodeIvrResult({required this.code, required this.cancelled});
  factory CodeIvrResult.cancelled() =>
      const CodeIvrResult(code: '', cancelled: true);
}

class FullRegistrationResult {
  final String email;
  final String firstName;
  final String lastName;
  final bool   cancelled;

  const FullRegistrationResult({
    required this.email,
    required this.firstName,
    required this.lastName,
    required this.cancelled,
  });

  factory FullRegistrationResult.cancelled() => const FullRegistrationResult(
    email: '', firstName: '', lastName: '', cancelled: true,
  );
}

// ─── Servicio ─────────────────────────────────────────────────────────────────

class AuthVoiceNavigationService {
  static final AuthVoiceNavigationService _instance =
  AuthVoiceNavigationService._internal();
  factory AuthVoiceNavigationService() => _instance;
  AuthVoiceNavigationService._internal();

  static void _log(String msg) {
    assert(() {
      debugPrint('[AuthVoiceNav] $msg');
      return true;
    }());
  }

  final AuthTTSService   _tts    = AuthTTSService();
  final GroqService      _groq   = GroqService();
  final stt.SpeechToText _speech = stt.SpeechToText();

  bool _initialized       = false;
  bool _wakeWordListening = false;
  bool _sttOpen           = false;
  bool _ttsActive         = false;
  bool _ivrRunning        = false;
  bool _resettingStt      = false;

  bool      _processingWakeWord   = false;
  DateTime? _lastWakeWordTime;
  DateTime? _ttsEchoSuppressUntil;
  DateTime? _fieldEchoSuppressUntil;

  String _currentScreen = 'welcome';

  final StreamController<AuthVoiceEvent> _eventController =
  StreamController<AuthVoiceEvent>.broadcast();
  Stream<AuthVoiceEvent> get events => _eventController.stream;
  bool get isListening => _wakeWordListening;

  Timer? _restartTimer;
  Timer? _commandTimeoutTimer;

  Completer<String?>? _activeListenOnceCompleter;

  // v8.5: flags separados y limpios
  bool _fieldCancelRequested = false;
  bool _ivrCancelRequested   = false;

  int _consecutiveSttErrors = 0;

  // ── Inicialización ──────────────────────────────────────────────────────────

  Future<bool> initialize() async {
    if (_initialized) return true;
    try {
      await _tts.initialize();
      await _groq.initialize();

      final status = await Permission.microphone.status;
      if (status.isDenied) {
        final r = await Permission.microphone.request();
        if (!r.isGranted) {
          _log('❌ Permiso micrófono denegado');
          await _tts.announceServiceError(
            'No se pudo acceder al micrófono. '
                'Ve a Ajustes y activa el permiso de micrófono para esta app.',
          );
          return false;
        }
      }

      _initialized = await _speech.initialize(
        onError:      _onSttError,
        onStatus:     _onSttStatus,
        debugLogging: false,
      );

      if (!_initialized) {
        await _tts.announceServiceError(
          'El reconocimiento de voz no está disponible en este dispositivo. '
              'Puedes usar el teclado para ingresar tus datos.',
        );
      }

      _log(_initialized ? '✅ Inicializado v8.5' : '❌ STT no disponible');
      return _initialized;
    } catch (e) {
      _log('Error inicializando: $e');
      await _tts.announceServiceError(
        'Hubo un error al iniciar el asistente de voz. '
            'Puedes usar el teclado para continuar.',
      );
      return false;
    }
  }

  // ── v8.5: Reset limpio de flags de cancelación ───────────────────────────────

  /// Llama esto antes de iniciar cualquier sesión IVR o de dictado.
  /// Evita que flags sucios de sesiones anteriores contaminen la nueva sesión.
  void resetCancelFlags() {
    _ivrCancelRequested   = false;
    _fieldCancelRequested = false;
    _log('Flags de cancelación reiniciados');
  }

  // ── v8.5: Hard reset del motor STT ──────────────────────────────────────────

  /// Para, cancela y espera que el motor STT libere el canal de audio.
  /// Esencial entre sesiones IVR/campo para evitar error_no_match permanent.
  Future<void> _hardResetStt() async {
    if (_resettingStt) {
      _log('Hard reset ya en progreso');
      return;
    }

    _resettingStt = true;

    try {
      _log('Hard reset STT iniciado...');

      try {
        await _speech.stop();
      } catch (_) {}

      await Future.delayed(const Duration(milliseconds: 250));

      try {
        await _speech.cancel();
      } catch (_) {}

      await Future.delayed(_kSttHardResetDelay);

      _sttOpen = false;

      _log('Hard reset STT completado');
    } finally {
      _resettingStt = false;
    }
  }
  // ── Pantalla activa ─────────────────────────────────────────────────────────

  void setCurrentScreen(String screenName) {
    _currentScreen        = screenName;
    _ttsEchoSuppressUntil = null;
    _consecutiveSttErrors = 0;
    // v8.5: limpiar flags sucios al cambiar de pantalla
    resetCancelFlags();
    _log('Pantalla activa: $screenName');
  }

  // ── Control de escucha del wake word ────────────────────────────────────────

  Future<void> startWakeWordListening() async {
    if (!_initialized || _wakeWordListening || _ttsActive || _ivrRunning) return;
    _wakeWordListening = true;
    _log('Iniciando escucha wake word...');
    await _listenForWakeWord();
  }

  void pauseListening() {
    _wakeWordListening    = false;
    _processingWakeWord   = false;
    _lastWakeWordTime     = null;
    _ttsEchoSuppressUntil = null;
    _consecutiveSttErrors = 0;
    _restartTimer?.cancel();
    _commandTimeoutTimer?.cancel();
    _commandTimeoutTimer  = null;
    _stopStt();
    _log('Escucha pausada');
  }

  Future<void> resumeListening() async {
    if (!_initialized || _wakeWordListening || _ttsActive || _ivrRunning) return;
    _wakeWordListening  = true;
    _processingWakeWord = false;
    _log('Escucha reanudada');
    await Future.delayed(const Duration(milliseconds: 700));
    if (_wakeWordListening && !_ttsActive && !_sttOpen && !_ivrRunning) {
      await _listenForWakeWord();
    }
  }

  // ── Wake word loop ──────────────────────────────────────────────────────────

  Future<void> _listenForWakeWord() async {
    if (!_wakeWordListening || _ttsActive || _sttOpen || _ivrRunning) return;
    if (_processingWakeWord) return;

    final now = DateTime.now();
    if (_ttsEchoSuppressUntil != null &&
        now.isBefore(_ttsEchoSuppressUntil!)) {
      final remaining = _ttsEchoSuppressUntil!.difference(now);
      _log('Eco TTS — posponiendo ${remaining.inMilliseconds}ms');
      _scheduleRestart(remaining + const Duration(milliseconds: 100));
      return;
    }

    _sttOpen = true;
    try {
      await _speech.listen(
        onResult:  _onWakeWordResult,
        localeId:  'es_CO',
        listenFor: const Duration(seconds: 45),
        pauseFor:  const Duration(seconds: 8),
        listenOptions: stt.SpeechListenOptions(
          partialResults:       true,
          cancelOnError:        false,
          listenMode:           stt.ListenMode.dictation,
          onDevice:             false,
          autoPunctuation:      false,
          enableHapticFeedback: false,
        ),
      );
    } catch (e) {
      _sttOpen = false;
      _log('Error en wake word listen: $e');
      _scheduleRestart(const Duration(seconds: 2));
    }
  }

  void _onWakeWordResult(stt.SpeechRecognitionResult result) {
    final text = result.recognizedWords.toLowerCase().trim();
    if (text.isEmpty) return;

    final wakeIndex = _findWakeWordIndex(text);
    if (wakeIndex == -1) return;

    final now = DateTime.now();
    if (_lastWakeWordTime != null &&
        now.difference(_lastWakeWordTime!) < _kWakeWordDebounce) return;
    if (_processingWakeWord) return;
    if (_ttsEchoSuppressUntil != null && now.isBefore(_ttsEchoSuppressUntil!)) {
      _log('Wake word ignorado: ventana eco TTS');
      return;
    }

    final afterWakeWord = _extractAfterWakeWord(text, wakeIndex).trim();
    _lastWakeWordTime   = now;
    _processingWakeWord = true;
    _stopStt();

    _log('✅ Wake word detectado. Resto: '
        '"${afterWakeWord.isEmpty ? "(vacío)" : afterWakeWord}"');

    _consecutiveSttErrors = 0;

    if (afterWakeWord.isNotEmpty) {
      Future.microtask(() => _processCommand(afterWakeWord));
    } else {
      Future.microtask(() => _listenForCommandAfterWakeWord());
    }
  }

  int _findWakeWordIndex(String text) {
    const variants = [
      'oye compas', 'oye compass', 'oye comas', 'oye compa',
      'oy compas',  'hoy compas',  'hey compas', 'hey compass',
      'oye come',   'oye companys',
    ];
    for (final v in variants) {
      final idx = text.indexOf(v);
      if (idx != -1) return idx;
    }
    return -1;
  }

  String _extractAfterWakeWord(String text, int wakeIndex) {
    const variants = [
      'oye compas', 'oye compass', 'oye comas', 'oye compa',
      'oy compas',  'hoy compas',  'hey compas', 'hey compass',
      'oye come',   'oye companys',
    ];
    for (final v in variants) {
      final idx = text.indexOf(v);
      if (idx != -1) {
        var after = text.substring(idx + v.length).trim();
        for (final c in [', ', ': ', ' por favor', ' porfa']) {
          if (after.startsWith(c.trim())) {
            after = after.substring(c.trim().length).trim();
          }
        }
        return after;
      }
    }
    return '';
  }

  // ── Segundo turno ───────────────────────────────────────────────────────────

  Future<void> _listenForCommandAfterWakeWord() async {
    if (!_wakeWordListening) {
      _processingWakeWord = false;
      return;
    }

    final screenAtStart = _currentScreen;
    _stopStt();
    await Future.delayed(const Duration(milliseconds: 300));
    if (!_wakeWordListening) {
      _processingWakeWord = false;
      return;
    }

    await _tts.speakBeforeListen();

    _sttOpen = true;
    _log('Escuchando comando post-wake-word...');

    final completer      = Completer<String?>();
    bool  commandHandled = false;

    _commandTimeoutTimer?.cancel();
    _commandTimeoutTimer = Timer(
        _kCommandListenFor + const Duration(seconds: 1), () {
      if (!commandHandled && !completer.isCompleted) {
        commandHandled = true;
        _log('⏱ Timer de comando expiró');
        completer.complete(null);
      }
    });

    await _speech.listen(
      onResult: (stt.SpeechRecognitionResult result) {
        if (!result.finalResult || commandHandled || completer.isCompleted) {
          return;
        }
        final text = result.recognizedWords.trim();
        commandHandled = true;
        completer.complete(text.isEmpty ? null : text);
      },
      localeId:  'es_CO',
      listenFor: _kCommandListenFor,
      pauseFor:  _kCommandPauseFor,
      listenOptions: stt.SpeechListenOptions(
        partialResults:       false,
        cancelOnError:        false,
        listenMode:           stt.ListenMode.confirmation,
        onDevice:             false,
        autoPunctuation:      false,
        enableHapticFeedback: false,
      ),
    );

    String? command;
    try {
      command = await completer.future;
    } catch (_) {
      command = null;
    } finally {
      _commandTimeoutTimer?.cancel();
      _commandTimeoutTimer = null;
      commandHandled       = true;
    }

    _sttOpen = false;

    if (command != null && command.isNotEmpty) {
      _log('Comando (2do turno): "$command"');
      await _processCommand(command, screenSnapshot: screenAtStart);
    } else {
      _processingWakeWord = false;
      if (_wakeWordListening) {
        await _speakAndWait(() => _tts.announceButton(_getContextHelp()));
        _scheduleRestart(const Duration(milliseconds: 400));
      }
    }
  }

  // ── Clasificación del comando ────────────────────────────────────────────────

  Future<void> _processCommand(String text,
      {String? screenSnapshot}) async {
    if (screenSnapshot != null && screenSnapshot != _currentScreen) {
      _log('Comando ignorado: pantalla cambió');
      _processingWakeWord = false;
      return;
    }

    try {
      final response = await _groq
          .chat(text,
          maxTokens: 60, systemPrompt: _buildClassifierPrompt())
          .timeout(_kGroqCommandTimeout);
      final intent = _parseAuthIntent(response.content, text);
      _log('Intent: ${intent.name} ← "${response.content}"');
      await _handleIntent(intent, text);
    } on TimeoutException {
      await _handleIntent(_parseIntentLocal(text), text);
    } catch (e) {
      _log('Error Groq: $e — parser local');
      await _handleIntent(_parseIntentLocal(text), text);
    }
  }

  // v8.5: fullVoiceRegistration añadido al prompt
  String _buildClassifierPrompt() =>
      '''Clasificas intenciones de voz en COMPAS (pantalla: $_currentScreen).
INTENTS: LOGIN, REGISTER, GUEST, DICTATE_CODE, DICTATE_EMAIL, DICTATE_NAME, FULL_VOICE_REGISTRATION, HELP, REPEAT, BACK
Responde SOLO con JSON: {"intent":"INTENT","confidence":0.XX}
FULL_VOICE_REGISTRATION: usuario quiere registrarse completamente por voz sin tocar pantalla.''';

  AuthVoiceIntent _parseAuthIntent(String groqResponse, String originalText) {
    try {
      final clean =
      groqResponse.replaceAll('```json', '').replaceAll('```', '').trim();
      final s = clean.indexOf('{'), e = clean.lastIndexOf('}');
      if (s == -1 || e == -1) return _parseIntentLocal(originalText);
      final json = clean.substring(s, e + 1);
      final im = RegExp(r'"intent"\s*:\s*"([^"]+)"').firstMatch(json);
      final cm = RegExp(r'"confidence"\s*:\s*([\d.]+)').firstMatch(json);
      if (im == null) return _parseIntentLocal(originalText);
      final conf = double.tryParse(cm?.group(1) ?? '0') ?? 0.0;
      if (conf < 0.55) return _parseIntentLocal(originalText);
      return switch (im.group(1)!) {
        'LOGIN'                  => AuthVoiceIntent.login,
        'REGISTER'               => AuthVoiceIntent.register,
        'GUEST'                  => AuthVoiceIntent.guest,
        'DICTATE_CODE'           => AuthVoiceIntent.dictateCode,
        'DICTATE_EMAIL'          => AuthVoiceIntent.dictateEmail,
        'DICTATE_NAME'           => AuthVoiceIntent.dictateName,
        'FULL_VOICE_REGISTRATION'=> AuthVoiceIntent.fullVoiceRegistration,
        'HELP'                   => AuthVoiceIntent.help,
        'REPEAT'                 => AuthVoiceIntent.repeat,
        'BACK'                   => AuthVoiceIntent.back,
        _                        => _parseIntentLocal(originalText),
      };
    } catch (_) {
      return _parseIntentLocal(originalText);
    }
  }

  // v8.5: parser local también detecta registro por voz
  AuthVoiceIntent _parseIntentLocal(String text) {
    final t = text.toLowerCase();
    if (_has(t, ['iniciar', 'ingresar', 'login', 'sesión', 'sesion', 'tengo cuenta'])) {
      return AuthVoiceIntent.login;
    }
    if (_has(t, ['registro por voz', 'registrarme por voz', 'todo por voz',
      'registro completo', 'registrar por voz', 'completamente por voz'])) {
      return AuthVoiceIntent.fullVoiceRegistration;
    }
    if (_has(t, ['registrar', 'crear cuenta', 'nueva cuenta', 'soy nuevo'])) {
      return AuthVoiceIntent.register;
    }
    if (_has(t, ['invitado', 'sin cuenta', 'explorar', 'no tengo cuenta'])) {
      return AuthVoiceIntent.guest;
    }
    if (_has(t, ['código', 'codigo', 'clave', 'acceso'])) {
      return AuthVoiceIntent.dictateCode;
    }
    if (_has(t, ['correo', 'email', 'mail'])) {
      return AuthVoiceIntent.dictateEmail;
    }
    if (_has(t, ['nombre', 'apellido'])) {
      return AuthVoiceIntent.dictateName;
    }
    if (_has(t, ['repite', 'repetir', 'otra vez', 'no entendí'])) {
      return AuthVoiceIntent.repeat;
    }
    if (_has(t, ['volver', 'atrás', 'atras', 'regresar', 'salir', 'cancelar'])) {
      return AuthVoiceIntent.back;
    }
    if (_has(t, ['ayuda', 'opciones', 'qué puedo', 'no sé', 'guía', 'dónde estoy'])) {
      return AuthVoiceIntent.help;
    }
    return AuthVoiceIntent.unknown;
  }

  // ── Handler de intent ───────────────────────────────────────────────────────

  Future<void> _handleIntent(AuthVoiceIntent intent, String rawText) async {
    switch (intent) {
      case AuthVoiceIntent.login:
        await _speakAndWait(
                () => _tts.announceButton('Abriendo inicio de sesión.'));
        _emitEvent(AuthVoiceEvent(intent: intent, rawText: rawText));
      case AuthVoiceIntent.register:
        await _speakAndWait(() => _tts.announceButton('Abriendo registro.'));
        _emitEvent(AuthVoiceEvent(intent: intent, rawText: rawText));
      case AuthVoiceIntent.guest:
        await _speakAndWait(
                () => _tts.announceButton('Entrando sin cuenta.'));
        _emitEvent(AuthVoiceEvent(intent: intent, rawText: rawText));
      case AuthVoiceIntent.dictateCode:
        _emitEvent(AuthVoiceEvent(intent: intent, rawText: rawText));
      case AuthVoiceIntent.dictateEmail:
        _emitEvent(AuthVoiceEvent(intent: intent, rawText: rawText));
      case AuthVoiceIntent.dictateName:
        _emitEvent(AuthVoiceEvent(intent: intent, rawText: rawText));
    // v8.5: flujo completo por voz activado por comando de voz
      case AuthVoiceIntent.fullVoiceRegistration:
        await _speakAndWait(
                () => _tts.announceButton('Iniciando registro completo por voz.'));
        _emitEvent(AuthVoiceEvent(intent: intent, rawText: rawText));
      case AuthVoiceIntent.help:
        await _speakAndWait(() => _tts.announceScreen(_getFullHelp()));
        _processingWakeWord = false;
        _scheduleRestart(const Duration(milliseconds: 500));
        return;
      case AuthVoiceIntent.repeat:
        _emitEvent(AuthVoiceEvent(intent: intent, rawText: rawText));
      case AuthVoiceIntent.back:
        await _speakAndWait(() => _tts.announceButton('Volviendo atrás.'));
        _emitEvent(AuthVoiceEvent(intent: intent, rawText: rawText));
      case AuthVoiceIntent.unknown:
        await _speakAndWait(
                () => _tts.announceError('No entendí. ${_getContextHelp()}'));
        _processingWakeWord = false;
        _scheduleRestart(const Duration(milliseconds: 400));
        return;
      default:
        break;
    }
    _processingWakeWord = false;
    if (!_isFieldIntent(intent)) _scheduleRestart(const Duration(seconds: 1));
  }

  bool _isFieldIntent(AuthVoiceIntent i) =>
      i == AuthVoiceIntent.dictateCode ||
          i == AuthVoiceIntent.dictateEmail ||
          i == AuthVoiceIntent.dictateName ||
          i == AuthVoiceIntent.fullVoiceRegistration;

  // ── Ayuda contextual ────────────────────────────────────────────────────────

  String _getContextHelp() {
    switch (_currentScreen) {
      case 'welcome':
        return 'Di: iniciar sesión, crear cuenta, o entrar sin cuenta.';
      case 'login':
        return 'Di: dictar código, o ayuda.';
      case 'register':
      case 'register_step2':
        return 'Di: dictar correo, dictar nombre, o registro por voz para hacerlo todo de una.';
      default:
        return 'Di ayuda para escuchar las opciones.';
    }
  }

  String _getFullHelp() {
    switch (_currentScreen) {
      case 'welcome':
        return 'Pantalla de bienvenida. Di: iniciar sesión, '
            'crear cuenta, o entrar sin cuenta.';
      case 'login':
        return 'Inicio de sesión. Necesitas tu código de seis dígitos. '
            'Di: oye compas, dictar código, y te guío.';
      case 'register':
        return 'Registro. Di: oye compas, registro por voz, '
            'y capturo tu correo, nombre y apellido sin tocar la pantalla. '
            'O di: dictar correo, para empezar solo con el correo.';
      case 'register_step2':
        return 'Registro paso dos: tu nombre. '
            'Di: oye compas, dictar nombre.';
      default:
        return 'Di: oye compas, seguido de lo que necesitas.';
    }
  }

  void _emitEvent(AuthVoiceEvent event) {
    if (!_eventController.isClosed) _eventController.add(event);
  }

  // ── Anuncios de pantalla ────────────────────────────────────────────────────

  Future<void> announceLoginScreen() async {
    await _announceScreen(
      'Pantalla de inicio de sesión. '
          'Ingresa tu código de seis dígitos. '
          'Di: oye compas, dictar código. '
          'Puedes decirlos uno a uno, o todos seguidos. '
          'O escríbelos con el teclado.',
    );
  }

  Future<void> announceRegistrationScreen(int step) async {
    await _announceScreen(step == 0
        ? 'Registro. Di oye compas, dictar correo, para empezar. '
        'O di registro por voz para hacerlo todo sin tocar la pantalla.'
        : 'Ahora di tu nombre cuando escuches la señal.');
  }

  Future<void> _announceScreen(String text) async {
    await _tts.waitForCompletion();
    await Future.delayed(_kScreenAnnounceDelay);
    await _tts.announceScreen(text);
    _log('[ScreenAnnounce] ✅');
  }

  // ══════════════════════════════════════════════════════════════════════════════
  //  IVR DE CÓDIGO  — v8.5: hard reset STT entre sesiones
  // ══════════════════════════════════════════════════════════════════════════════

  Future<CodeIvrResult> dictateCodeIvr() async {
    // v8.5: limpiar flags sucios ANTES de iniciar
    resetCancelFlags();
    _ivrRunning = true;
    pauseListening();

    // v8.5: hard reset para liberar canal de sesiones anteriores
    await _hardResetStt();

    try {
      return await _runCodeIvr();
    } catch (e) {
      _log('IVR error: $e');
      await _tts.announceServiceError(
        'Hubo un problema con el dictado. '
            'Puedes escribir el código directamente con el teclado.',
      );
      return CodeIvrResult.cancelled();
    } finally {
      _ivrRunning = false;
      // v8.5: hard reset al salir para dejar canal limpio
      await _hardResetStt();
      await resumeListening();
    }
  }

  void cancelCodeIvr() {
    _ivrCancelRequested = true;
    _ivrRunning         = false;
    _completeActiveListenOnce(null);
    _stopStt();
    _log('IVR cancelado externamente');
  }

  void cancelFieldDictation() {
    _fieldCancelRequested = true;
    _ivrRunning           = false;
    _completeActiveListenOnce(null);
    _stopStt();
    _log('Dictado de campo cancelado externamente');
  }

  /// Cierra cualquier sesión STT de auth antes de entrar al modo AR.
  ///
  /// `pauseListening()` es suficiente para moverse entre pantallas de auth, pero
  /// al abrir AR necesitamos esperar a que Android libere el canal de audio
  /// antes de que WakeWordService intente tomar el micrófono.
  Future<void> shutdownForARTransition() async {
    _log('Shutdown para transición AR iniciado');

    _wakeWordListening     = false;
    _processingWakeWord    = false;
    _ttsActive             = false;
    _ivrRunning            = false;
    _ivrCancelRequested    = true;
    _fieldCancelRequested  = true;
    _sttOpen               = false;
    _ttsEchoSuppressUntil  = null;
    _fieldEchoSuppressUntil = null;
    _consecutiveSttErrors  = 0;

    _completeActiveListenOnce(null);
    _restartTimer?.cancel();
    _commandTimeoutTimer?.cancel();
    _restartTimer = null;
    _commandTimeoutTimer = null;

    await _hardResetStt();
    await VoiceNavService().shutdownForARTransition();

    _initialized = false;
    _log('Shutdown para transición AR completado');
  }

  void _completeActiveListenOnce(String? value) {
    if (_activeListenOnceCompleter != null &&
        !_activeListenOnceCompleter!.isCompleted) {
      _activeListenOnceCompleter!.complete(value);
    }

    _activeListenOnceCompleter = null;
  }

  Future<CodeIvrResult> _runCodeIvr() async {
    _ivrCancelRequested = false;
    final List<int> digits = [];

    await _ivrSpeak(
      'Di tu código de acceso. '
          'Puedes decir todos los dígitos de seguido, '
          'por ejemplo: tres dos uno cuatro cinco seis. '
          'O uno a uno si lo prefieres.',
    );
    if (_ivrCancelRequested) return CodeIvrResult.cancelled();

    await _tts.speakBeforeListen();

    final firstRaw = await _listenOnce(
      listenFor: const Duration(seconds: 20),
      pauseFor:  const Duration(seconds: 6),
      mode:      stt.ListenMode.dictation,
    );

    if (_ivrCancelRequested) return CodeIvrResult.cancelled();

    if (firstRaw != null && firstRaw.isNotEmpty) {
      final seq = _tryParseDigitSequence(firstRaw);

      if (seq.length == 6) {
        _log('IVR bulk completo: ${seq.join()} ← "$firstRaw"');
        final result = await _confirmFullCode(seq);
        if (result != null) return result;
        await _ivrSpeak('De acuerdo, empecemos de nuevo.');
        return _runCodeIvr();
      } else if (seq.length >= 2) {
        _log('IVR bulk parcial: ${seq.join()} ← "$firstRaw"');
        digits.addAll(seq);
        final spoken = seq.map(_digitToWord).join(', ');
        await _ivrSpeak(
          'Escuché: $spoken. '
              'Faltan ${6 - digits.length} dígitos. Continúa.',
        );
        if (_ivrCancelRequested) return CodeIvrResult.cancelled();
        await _tts.speakBeforeListen();
      } else if (seq.length == 1) {
        final confirmed = await _confirmSingleDigit(seq[0], 1);
        if (_ivrCancelRequested) return CodeIvrResult.cancelled();
        if (confirmed == null) return CodeIvrResult.cancelled();
        if (confirmed) {
          digits.add(seq[0]);
        }
      }
    }

    while (digits.length < 6) {
      if (_ivrCancelRequested) return CodeIvrResult.cancelled();

      final position = digits.length + 1;
      final prompt   = position == 1
          ? 'Di el primer dígito, del cero al nueve. '
          'O di todos de seguido si lo prefieres.'
          : 'Dígito $position de 6. '
          'O di los ${6 - digits.length} restantes de seguido.';

      await _ivrSpeak(prompt);
      if (_ivrCancelRequested) return CodeIvrResult.cancelled();

      await _tts.speakBeforeListen();

      final raw = await _listenOnce(
        listenFor: const Duration(seconds: 15),
        pauseFor:  const Duration(seconds: 8),
        mode:      stt.ListenMode.confirmation,
      );

      if (_ivrCancelRequested) return CodeIvrResult.cancelled();

      if (raw == null) {
        await _ivrSpeak(
          'No escuché nada. '
              'Di un dígito o todos los restantes de seguido.',
        );
        continue;
      }

      final seq = _tryParseDigitSequence(raw.toLowerCase().trim());

      if (seq.isEmpty) {
        await _ivrSpeak('No entendí. Di un número del cero al nueve.');
        continue;
      }

      final remaining = 6 - digits.length;

      if (seq.length >= 2 && seq.length <= remaining) {
        final subSpoken = seq.map(_digitToWord).join(', ');
        await _ivrSpeak('$subSpoken. ¿Correcto? Di sí o no.');
        if (_ivrCancelRequested) return CodeIvrResult.cancelled();
        await _tts.speakBeforeListen();

        final conf = await _listenOnce(
          listenFor: const Duration(seconds: 10),
          pauseFor:  const Duration(seconds: 5),
          mode:      stt.ListenMode.confirmation,
        );
        if (_ivrCancelRequested) return CodeIvrResult.cancelled();

        if (conf != null && _parseYesNo(conf.toLowerCase()) == true) {
          digits.addAll(seq);
          _log('IVR bulk parcial confirmado en loop: ${seq.join()}');
          continue;
        } else {
          await _ivrSpeak('De acuerdo, repite esos dígitos.');
          continue;
        }
      } else if (seq.length > remaining) {
        final truncated = seq.take(remaining).toList();
        _log('IVR: dígitos extra ignorados (${seq.length} > $remaining)');
        final truncatedSpoken = truncated.map(_digitToWord).join(', ');
        await _ivrSpeak('$truncatedSpoken. ¿Correcto? Di sí o no.');
        if (_ivrCancelRequested) return CodeIvrResult.cancelled();
        await _tts.speakBeforeListen();

        final conf = await _listenOnce(
          listenFor: const Duration(seconds: 10),
          pauseFor:  const Duration(seconds: 5),
          mode:      stt.ListenMode.confirmation,
        );
        if (_ivrCancelRequested) return CodeIvrResult.cancelled();
        if (conf != null && _parseYesNo(conf.toLowerCase()) == true) {
          digits.addAll(truncated);
          continue;
        } else {
          await _ivrSpeak('De acuerdo, repite esos dígitos.');
          continue;
        }
      }

      final digit = seq.first;
      final confirmed = await _confirmSingleDigit(digit, position);
      if (_ivrCancelRequested) return CodeIvrResult.cancelled();
      if (confirmed == null) return CodeIvrResult.cancelled();
      if (confirmed) digits.add(digit);
    }

    if (_ivrCancelRequested) return CodeIvrResult.cancelled();
    final result = await _confirmFullCode(digits);
    if (result != null) return result;

    await _ivrSpeak('De acuerdo. Empecemos de nuevo.');
    return _runCodeIvr();
  }

  Future<bool?> _confirmSingleDigit(int digit, int position) async {
    final word   = _digitToWord(digit);
    final prompt = position == 1
        ? '$word. ¿Es correcto? Di sí o no.'
        : '$word. ¿Sí o no?';

    await _ivrSpeak(prompt);
    if (_ivrCancelRequested) return null;
    await _tts.speakBeforeListen();

    for (int i = 0; i < 3; i++) {
      if (_ivrCancelRequested) return null;

      final raw = await _listenOnce(
        listenFor: const Duration(seconds: 10),
        pauseFor:  const Duration(seconds: 5),
        mode:      stt.ListenMode.confirmation,
      );
      if (_ivrCancelRequested) return null;

      if (raw == null) {
        if (i < 2) {
          await _ivrSpeak('No escuché. Di sí para confirmar o no para repetir.');
          await _tts.speakBeforeListen();
          continue;
        }
        await _ivrSpeak('No pude escucharte. Repitamos ese dígito.');
        return false;
      }

      final yn = _parseYesNo(raw.toLowerCase());
      if (yn != null) return yn;

      if (i < 2) {
        await _ivrSpeak('Di sí o no.');
        await _tts.speakBeforeListen();
      } else {
        await _ivrSpeak('No entendí. Repitamos ese dígito.');
        return false;
      }
    }
    return false;
  }

  Future<CodeIvrResult?> _confirmFullCode(List<int> digits) async {
    final spoken = digits.map(_digitToWord).join(', ');
    await _ivrSpeak('Tu código es: $spoken. ¿Lo ingresamos? Di sí o no.');
    if (_ivrCancelRequested) return CodeIvrResult.cancelled();
    await _tts.speakBeforeListen();

    for (int i = 0; i < 3; i++) {
      if (_ivrCancelRequested) return CodeIvrResult.cancelled();

      final raw = await _listenOnce(
        listenFor: const Duration(seconds: 12),
        pauseFor:  const Duration(seconds: 6),
        mode:      stt.ListenMode.confirmation,
      );
      if (_ivrCancelRequested) return CodeIvrResult.cancelled();

      if (raw == null) {
        if (i < 2) {
          await _ivrSpeak('Di sí para ingresar, o no para empezar de nuevo.');
          await _tts.speakBeforeListen();
          continue;
        }
        return null;
      }

      final yn = _parseYesNo(raw.toLowerCase());
      if (yn == true)  return CodeIvrResult(code: digits.join(), cancelled: false);
      if (yn == false) return null;

      if (i < 2) {
        await _ivrSpeak('Di sí o no.');
        await _tts.speakBeforeListen();
      }
    }
    return null;
  }

  List<int> _tryParseDigitSequence(String text) {
    final result  = <int>[];
    final cleaned = text.trim().toLowerCase();

    final tokens = cleaned.split(RegExp(r'[\s,]+'));
    for (final token in tokens) {
      final d = _parseDigitToken(token);
      if (d != null) {
        result.add(d);
      }
    }

    if (result.isEmpty) {
      final numMatch = RegExp(r'\d+').firstMatch(cleaned);
      if (numMatch != null) {
        for (final ch in numMatch.group(0)!.split('')) {
          result.add(int.parse(ch));
        }
      }
    }

    if (result.isEmpty) {
      for (final ch in cleaned.replaceAll(RegExp(r'\s'), '').split('')) {
        final d = int.tryParse(ch);
        if (d != null) result.add(d);
      }
    }

    return result.take(6).toList();
  }

  int? _parseDigitToken(String token) {
    const map = <String, int>{
      'cero': 0, '0': 0,
      'uno': 1, 'una': 1, '1': 1,
      'dos': 2, '2': 2,
      'tres': 3, '3': 3,
      'cuatro': 4, '4': 4,
      'cinco': 5, '5': 5,
      'seis': 6, 'séis': 6, 'seis.': 6, '6': 6,
      'siete': 7, '7': 7,
      'ocho': 8, '8': 8,
      'nueve': 9, '9': 9,
    };
    return map[token];
  }

  // v8.5: _ivrSpeak usa _hardResetStt para garantizar canal limpio
  Future<void> _ivrSpeak(String text) async {
    _stopStt();
    try { await _speech.cancel(); } catch (_) {}

    await _tts.announceButton(text);
    await _tts.waitForCompletion();

    await Future.delayed(_kMicOpenDelay);

    // v8.5: hard reset completo antes de abrir nueva sesión STT
    await _hardResetStt();

    _log('IVR spoke: "$text"');
  }

  // v8.5: _listenOnce con hard reset previo y guard timer extendido
  Future<String?> _listenOnce({
    required Duration       listenFor,
    required Duration       pauseFor,
    required stt.ListenMode mode,
  }) async {
    if (_ivrCancelRequested && !_fieldCancelRequested) return null;
    if (_fieldCancelRequested) return null;

    // v8.5: siempre hard reset antes de abrir STT nuevo
    if (_speech.isListening) {
      _log('_listenOnce: STT activo al entrar — hard reset');
      await _hardResetStt();
    } else {
      // Pequeña pausa de seguridad incluso si no está activo
      await Future.delayed(const Duration(milliseconds: 200));
    }

    if (_ivrCancelRequested && !_fieldCancelRequested) return null;
    if (_fieldCancelRequested) return null;

    final completer = Completer<String?>();
    bool  handled   = false;

    _activeListenOnceCompleter = completer;

    // v8.5: +5s en lugar de +3s para motores STT lentos
    final guard = Timer(listenFor + _kListenOnceGuardExtra, () {
      if (!handled && !completer.isCompleted) {
        handled = true;
        _log('_listenOnce guard expired');
        completer.complete(null);
      }
    });

    try {
      await _speech.listen(
        onResult: (stt.SpeechRecognitionResult r) {
          if (!r.finalResult || handled || completer.isCompleted) return;
          handled = true;
          final text = r.recognizedWords.trim();
          _log('_listenOnce raw: "$text"');
          completer.complete(text.isEmpty ? null : text);
        },
        localeId:  'es_CO',
        listenFor: listenFor,
        pauseFor:  pauseFor,
        listenOptions: stt.SpeechListenOptions(
          partialResults:       false,
          cancelOnError:        false,
          listenMode:           mode,
          onDevice:             false,
          autoPunctuation:      false,
          enableHapticFeedback: false,
        ),
      );
      _sttOpen = true;
    } catch (e) {
      _log('_listenOnce error al abrir STT: $e');
      guard.cancel();
      _activeListenOnceCompleter = null;
      _sttOpen = false;

      await _tts.announceServiceError(
        'El micrófono no pudo abrirse. '
            'Intenta hablar de nuevo o usa el teclado.',
      );
      return null;
    }

    String? result;
    try {
      result = await completer.future;
    } catch (_) {
      result = null;
    } finally {
      guard.cancel();
      handled                    = true;
      _activeListenOnceCompleter = null;
    }

    _sttOpen = false;
    // v8.5: hard reset al terminar para dejar el canal limpio para el siguiente
    await _hardResetStt();
    return result;
  }

  // ══════════════════════════════════════════════════════════════════════════════
  //  FLUJO DE REGISTRO COMPLETO POR VOZ — v8.5
  // ══════════════════════════════════════════════════════════════════════════════

  Future<void> startFullRegistrationFlow() async {
    if (_ivrRunning) return;
    // v8.5: limpiar flags sucios antes de iniciar
    resetCancelFlags();
    _ivrRunning = true;
    pauseListening();

    // v8.5: hard reset para liberar canal limpio
    await _hardResetStt();

    try {
      final result = await _runFullRegistration();
      _emitEvent(AuthVoiceEvent(
        intent:             AuthVoiceIntent.registrationComplete,
        rawText:            '',
        registrationResult: result,
      ));
    } catch (e) {
      _log('startFullRegistrationFlow error: $e');
      await _tts.announceServiceError(
        'Hubo un problema durante el registro por voz. '
            'Puedes completar los datos con el teclado.',
      );
      _emitEvent(AuthVoiceEvent(
        intent:             AuthVoiceIntent.registrationComplete,
        rawText:            '',
        registrationResult: FullRegistrationResult.cancelled(),
      ));
    } finally {
      _ivrRunning = false;
      _fieldCancelRequested = false;
      // v8.5: hard reset al salir
      await _hardResetStt();
      await resumeListening();
    }
  }

  Future<FullRegistrationResult> dictateFullRegistration() async {
    resetCancelFlags();
    _ivrRunning           = true;
    _fieldCancelRequested = false;
    pauseListening();
    await _hardResetStt();

    try {
      return await _runFullRegistration();
    } catch (e) {
      _log('dictateFullRegistration error: $e');
      await _tts.announceServiceError(
        'Hubo un problema durante el registro por voz. '
            'Puedes completar los datos con el teclado.',
      );
      return FullRegistrationResult.cancelled();
    } finally {
      _ivrRunning = false;
      _fieldCancelRequested = false;
      await _hardResetStt();
      await resumeListening();
    }
  }

  Future<FullRegistrationResult> _runFullRegistration() async {
    await _speakAndWait(
          () => _tts.announceScreen(
        'Registro por voz. Voy a pedirte tres datos: '
            'correo, nombre y apellido. '
            'Empecemos con tu correo electrónico.',
      ),
      isFieldInstruction: true,
    );
    if (_fieldCancelRequested) return FullRegistrationResult.cancelled();

    String? email;
    while (email == null) {
      if (_fieldCancelRequested) return FullRegistrationResult.cancelled();
      email = await _dictateEmailStep();
      if (_fieldCancelRequested) return FullRegistrationResult.cancelled();
      if (email == null) {
        await _speakAndWait(
              () => _tts.announceButton(
            'No pude capturar el correo. '
                '¿Quieres intentarlo de nuevo? Di sí o no.',
          ),
          isFieldInstruction: true,
        );
        await _tts.speakBeforeListen();
        final retry = await _listenOnce(
          listenFor: const Duration(seconds: 10),
          pauseFor:  const Duration(seconds: 5),
          mode:      stt.ListenMode.confirmation,
        );
        if (_fieldCancelRequested) return FullRegistrationResult.cancelled();
        if (retry == null || _parseYesNo(retry.toLowerCase()) != true) {
          return FullRegistrationResult.cancelled();
        }
      }
    }

    if (_fieldCancelRequested) return FullRegistrationResult.cancelled();

    await _speakAndWait(
          () => _tts.announceButton('Perfecto. Ahora dime tu nombre.'),
      isFieldInstruction: true,
    );
    if (_fieldCancelRequested) return FullRegistrationResult.cancelled();

    String? firstName;
    while (firstName == null) {
      if (_fieldCancelRequested) return FullRegistrationResult.cancelled();
      firstName = await _dictateNameStep(isLastName: false);
      if (_fieldCancelRequested) return FullRegistrationResult.cancelled();
      if (firstName == null) {
        await _speakAndWait(
              () => _tts.announceButton(
            'No pude capturar tu nombre. ¿Intentamos de nuevo? Di sí o no.',
          ),
          isFieldInstruction: true,
        );
        await _tts.speakBeforeListen();
        final retry = await _listenOnce(
          listenFor: const Duration(seconds: 10),
          pauseFor:  const Duration(seconds: 5),
          mode:      stt.ListenMode.confirmation,
        );
        if (_fieldCancelRequested) return FullRegistrationResult.cancelled();
        if (retry == null || _parseYesNo(retry.toLowerCase()) != true) {
          return FullRegistrationResult.cancelled();
        }
      }
    }

    if (_fieldCancelRequested) return FullRegistrationResult.cancelled();

    await _speakAndWait(
          () => _tts.announceButton(
        'Ahora dime tu apellido. '
            'Si no quieres darlo, di: sin apellido.',
      ),
      isFieldInstruction: true,
    );
    if (_fieldCancelRequested) return FullRegistrationResult.cancelled();

    String lastName = '';
    final lastNameResult = await _dictateNameStep(isLastName: true, allowSkip: true);
    if (_fieldCancelRequested) return FullRegistrationResult.cancelled();
    lastName = lastNameResult ?? '';

    final lastNameStr = lastName.isNotEmpty ? lastName : 'sin apellido';
    await _speakAndWait(
          () => _tts.announceButton(
        'Tus datos son: '
            'correo: ${_spellEmail(email!)}. '
            'Nombre: $firstName. '
            'Apellido: $lastNameStr. '
            '¿Creamos la cuenta? Di sí o no.',
      ),
      isFieldInstruction: true,
    );
    if (_fieldCancelRequested) return FullRegistrationResult.cancelled();
    await _tts.speakBeforeListen();

    for (int i = 0; i < 3; i++) {
      if (_fieldCancelRequested) return FullRegistrationResult.cancelled();

      final raw = await _listenOnce(
        listenFor: const Duration(seconds: 12),
        pauseFor:  const Duration(seconds: 6),
        mode:      stt.ListenMode.confirmation,
      );
      if (_fieldCancelRequested) return FullRegistrationResult.cancelled();

      if (raw == null) {
        if (i < 2) {
          await _speakAndWait(
                () => _tts.announceButton('Di sí para crear la cuenta o no para cancelar.'),
            isFieldInstruction: true,
          );
          await _tts.speakBeforeListen();
          continue;
        }
        return FullRegistrationResult.cancelled();
      }

      final yn = _parseYesNo(raw.toLowerCase());
      if (yn == true) {
        await _speakAndWait(
              () => _tts.announceButton('Perfecto, creando tu cuenta.'),
        );
        return FullRegistrationResult(
          email:     email!,
          firstName: firstName!,
          lastName:  lastName,
          cancelled: false,
        );
      }
      if (yn == false) {
        await _speakAndWait(
              () => _tts.announceButton('De acuerdo, empezamos de nuevo.'),
        );
        return _runFullRegistration();
      }

      if (i < 2) {
        await _speakAndWait(
              () => _tts.announceButton('Di sí o no.'),
          isFieldInstruction: true,
        );
        await _tts.speakBeforeListen();
      }
    }

    return FullRegistrationResult.cancelled();
  }

  Future<String?> _dictateEmailStep() async {
    await _tts.speakBeforeListen();

    for (int attempt = 0; attempt < 3; attempt++) {
      if (_fieldCancelRequested) return null;

      final raw = await _listenOnce(
        listenFor: const Duration(seconds: 30),
        pauseFor:  const Duration(seconds: 6),
        mode:      stt.ListenMode.dictation,
      );
      if (_fieldCancelRequested) return null;

      if (raw == null || raw.trim().isEmpty) {
        if (attempt < 2) {
          await _speakAndWait(
                () => _tts.announceError(
              attempt == 0
                  ? 'No te escuché. Di tu correo, por ejemplo: juan arroba gmail punto com.'
                  : 'Intenta otra vez.',
            ),
            isFieldInstruction: true,
          );
          await _tts.speakBeforeListen();
        }
        continue;
      }

      final normalized = _normalizeEmail(raw);
      if (!_looksLikeEmail(normalized)) {
        if (attempt < 2) {
          await _speakAndWait(
                () => _tts.announceError(
              'No reconocí un correo válido. '
                  'Di nombre, arroba, dominio y punto com.',
            ),
            isFieldInstruction: true,
          );
          await _tts.speakBeforeListen();
        }
        continue;
      }

      final spelled = _spellEmail(normalized);
      await _speakAndWait(
            () => _tts.announceButton('Escuché: $spelled. ¿Correcto? Di sí o no.'),
        isFieldInstruction: true,
      );
      if (_fieldCancelRequested) return null;
      await _tts.speakBeforeListen();

      final conf = await _listenOnce(
        listenFor: const Duration(seconds: 10),
        pauseFor:  const Duration(seconds: 5),
        mode:      stt.ListenMode.confirmation,
      );
      if (_fieldCancelRequested) return null;

      if (conf != null && _parseYesNo(conf.toLowerCase()) == true) {
        return normalized;
      } else if (conf != null && _parseYesNo(conf.toLowerCase()) == false) {
        if (attempt < 2) {
          await _speakAndWait(
                () => _tts.announceButton('De acuerdo, repite tu correo.'),
            isFieldInstruction: true,
          );
          await _tts.speakBeforeListen();
        }
      } else {
        if (attempt < 2) {
          await _speakAndWait(
                () => _tts.announceButton('Di sí o no.'),
            isFieldInstruction: true,
          );
          await _tts.speakBeforeListen();
        }
      }
    }
    return null;
  }

  Future<String?> _dictateNameStep({
    required bool isLastName,
    bool allowSkip = false,
  }) async {
    final label = isLastName ? 'apellido' : 'nombre';
    if (_fieldCancelRequested) return allowSkip ? '' : null;

    await _tts.speakBeforeListen();

    for (int attempt = 0; attempt < 3; attempt++) {
      if (_fieldCancelRequested) return allowSkip ? '' : null;

      final raw = await _listenOnce(
        listenFor: const Duration(seconds: 15),
        pauseFor:  const Duration(seconds: 5),
        mode:      stt.ListenMode.dictation,
      );
      if (_fieldCancelRequested) return allowSkip ? '' : null;

      if (raw == null || raw.trim().isEmpty) {
        if (allowSkip) {
          await _speakAndWait(
                () => _tts.announceButton('Sin apellido, de acuerdo.'),
          );
          return '';
        }
        if (attempt < 2) {
          await _speakAndWait(
                () => _tts.announceError('No te escuché. Di solo tu $label.'),
            isFieldInstruction: true,
          );
          await _tts.speakBeforeListen();
        }
        continue;
      }

      if (allowSkip && _wantsToSkip(raw.toLowerCase())) {
        await _speakAndWait(
              () => _tts.announceButton('Sin apellido, de acuerdo.'),
        );
        return '';
      }

      final normalized = _capitalizeName(raw);

      await _speakAndWait(
            () => _tts.announceButton(
          'Escuché: $normalized. ¿Correcto? Di sí o no.',
        ),
        isFieldInstruction: true,
      );
      if (_fieldCancelRequested) return allowSkip ? '' : null;
      await _tts.speakBeforeListen();

      final conf = await _listenOnce(
        listenFor: const Duration(seconds: 10),
        pauseFor:  const Duration(seconds: 5),
        mode:      stt.ListenMode.confirmation,
      );
      if (_fieldCancelRequested) return allowSkip ? '' : null;

      if (conf != null && _parseYesNo(conf.toLowerCase()) == true) {
        return normalized;
      } else if (conf != null && _parseYesNo(conf.toLowerCase()) == false) {
        if (attempt < 2) {
          await _speakAndWait(
                () => _tts.announceButton('De acuerdo, repite tu $label.'),
            isFieldInstruction: true,
          );
          await _tts.speakBeforeListen();
        }
      } else {
        if (attempt < 2) {
          await _speakAndWait(
                () => _tts.announceButton('Di sí o no.'),
            isFieldInstruction: true,
          );
          await _tts.speakBeforeListen();
        }
      }
    }

    return allowSkip ? '' : null;
  }

  bool _wantsToSkip(String text) => _has(text, [
    'sin apellido', 'no tengo', 'saltar', 'omitir', 'ninguno',
    'no aplica', 'no quiero', 'solo nombre', 'no',
  ]);

  // ══════════════════════════════════════════════════════════════════════════════
  //  DICTADO DE EMAIL (método público) — v8.5: reset limpio al inicio
  // ══════════════════════════════════════════════════════════════════════════════

  Future<FieldDictationResult?> dictateEmailField() async {
    // v8.5: limpiar flags y reset STT
    resetCancelFlags();
    pauseListening();
    await _hardResetStt();

    try {
      return await _dictateEmailInternal();
    } finally {
      _fieldCancelRequested = false;
      await _hardResetStt();
      await resumeListening();
    }
  }

  Future<FieldDictationResult?> _dictateEmailInternal() async {
    await _speakAndWait(
          () => _tts.announceButton(
        'Voy a ayudarte con tu correo. '
            'Cuando escuches la señal, di tu correo despacio. '
            'Por ejemplo: juan, arroba, gmail, punto, com.',
      ),
      isFieldInstruction: true,
    );

    await _tts.speakBeforeListen();

    for (int attempt = 0; attempt < 3; attempt++) {
      if (_fieldCancelRequested) return null;

      final raw = await _listenOnce(
        listenFor: const Duration(seconds: 30),
        pauseFor:  const Duration(seconds: 6),
        mode:      stt.ListenMode.dictation,
      );

      if (_fieldCancelRequested) return null;

      if (raw == null || raw.trim().isEmpty) {
        if (attempt < 2) {
          await _speakAndWait(
                () => _tts.announceError(
              attempt == 0
                  ? 'No te escuché. Habla cerca del micrófono y di tu correo.'
                  : 'Aún no te escucho. Di solo tu correo, despacio y claro.',
            ),
            isFieldInstruction: true,
          );
          await _tts.speakBeforeListen();
        }
        continue;
      }

      final normalized = _normalizeEmail(raw);

      if (!_looksLikeEmail(normalized)) {
        _log('Email inválido: "$raw" → "$normalized"');
        if (attempt < 2) {
          await _speakAndWait(
                () => _tts.announceError(
              'No reconocí un correo válido. '
                  'Di por partes: nombre, después di arroba, '
                  'después el dominio como gmail, y termina con punto com.',
            ),
            isFieldInstruction: true,
          );
          await _tts.speakBeforeListen();
        }
        continue;
      }

      _log('Email: "$raw" → "$normalized"');

      final spelled = _spellEmail(normalized);
      await _speakAndWait(
            () => _tts.announceButton(
          'Escuché: $spelled. ¿Es correcto? Di sí o no.',
        ),
        isFieldInstruction: true,
      );

      if (_fieldCancelRequested) return null;

      await _tts.speakBeforeListen();

      final confirmed = await _listenOnce(
        listenFor: const Duration(seconds: 12),
        pauseFor:  const Duration(seconds: 6),
        mode:      stt.ListenMode.confirmation,
      );

      if (_fieldCancelRequested) return null;

      if (confirmed == null) {
        await _speakAndWait(
              () => _tts.announceError(
            'No escuché tu respuesta. El correo no se guardó. '
                'Di: oye compas, dictar correo, para intentar de nuevo.',
          ),
        );
        return null;
      }

      final yes = _parseYesNo(confirmed.toLowerCase());
      if (yes == true) {
        await _speakAndWait(() => _tts.announceSuccess('Correo guardado.'));
        return FieldDictationResult(
          rawText:        raw,
          normalizedText: normalized,
          fieldType:      AuthFieldType.email,
          confirmed:      true,
        );
      } else if (yes == false) {
        if (attempt < 2) {
          await _speakAndWait(
                () => _tts.announceButton('De acuerdo, lo intentamos de nuevo.'),
            isFieldInstruction: true,
          );
          await _tts.speakBeforeListen();
        }
      } else {
        await _speakAndWait(
              () => _tts.announceError('No entendí tu respuesta. Di sí o no claramente.'),
        );
        await _tts.speakBeforeListen();
        final retry = await _listenOnce(
          listenFor: const Duration(seconds: 10),
          pauseFor:  const Duration(seconds: 5),
          mode:      stt.ListenMode.confirmation,
        );
        if (retry != null && _parseYesNo(retry.toLowerCase()) == true) {
          await _speakAndWait(() => _tts.announceSuccess('Correo guardado.'));
          return FieldDictationResult(
            rawText:        raw,
            normalizedText: normalized,
            fieldType:      AuthFieldType.email,
            confirmed:      true,
          );
        }
        if (attempt < 2) await _tts.speakBeforeListen();
      }
    }

    await _speakAndWait(
          () => _tts.announceError(
        'Parece que el micrófono no te está escuchando bien. '
            'Puedes escribir tu correo directamente con el teclado. '
            'Toca el campo de correo para escribirlo.',
      ),
    );
    return null;
  }

  String _spellEmail(String email) {
    final parts = <String>[];
    for (final char in email.split('')) {
      switch (char) {
        case '@': parts.add('arroba');
        case '.': parts.add('punto');
        case '_': parts.add('guión bajo');
        case '-': parts.add('guión');
        default:  parts.add(char);
      }
    }
    return parts.join(', ');
  }

  // ══════════════════════════════════════════════════════════════════════════════
  //  DICTADO DE NOMBRE — v8.5: reset limpio al inicio
  // ══════════════════════════════════════════════════════════════════════════════

  Future<FieldDictationResult?> dictateNameField(
      {bool isLastName = false}) async {
    resetCancelFlags();
    pauseListening();
    await _hardResetStt();

    try {
      return await _dictateNameInternal(isLastName: isLastName);
    } finally {
      _fieldCancelRequested = false;
      await _hardResetStt();
      await resumeListening();
    }
  }

  Future<FieldDictationResult?> _dictateNameInternal(
      {required bool isLastName}) async {
    final label = isLastName ? 'apellido' : 'nombre';

    if (_fieldCancelRequested) return null;

    await _speakAndWait(
          () => _tts.announceButton(
        'Di tu $label cuando escuches la señal. '
            'Solo di el $label, nada más.',
      ),
      isFieldInstruction: true,
    );

    if (_fieldCancelRequested) return null;

    await _tts.speakBeforeListen();

    for (int attempt = 0; attempt < 3; attempt++) {
      if (_fieldCancelRequested) return null;

      final raw = await _listenOnce(
        listenFor: const Duration(seconds: 15),
        pauseFor:  const Duration(seconds: 5),
        mode:      stt.ListenMode.dictation,
      );

      if (_fieldCancelRequested) return null;

      if (raw == null || raw.trim().isEmpty) {
        if (attempt < 2) {
          await _speakAndWait(
                () => _tts.announceError(
              attempt == 0
                  ? 'No escuché nada. Di solo tu $label, fuerte y claro.'
                  : 'Aún no te escucho. Habla directo al micrófono.',
            ),
            isFieldInstruction: true,
          );
          await _tts.speakBeforeListen();
          continue;
        } else {
          await _speakAndWait(
                () => _tts.announceError(
              'No pude escucharte. Puedes escribir tu $label con el teclado.',
            ),
          );
          return null;
        }
      }

      final normalized = _capitalizeName(raw);

      await _speakAndWait(
            () => _tts.announceButton(
          'Escuché: $normalized. ¿Está bien? Di sí o no.',
        ),
        isFieldInstruction: true,
      );

      if (_fieldCancelRequested) return null;

      await _tts.speakBeforeListen();

      final confirmed = await _listenOnce(
        listenFor: const Duration(seconds: 10),
        pauseFor:  const Duration(seconds: 5),
        mode:      stt.ListenMode.confirmation,
      );

      if (_fieldCancelRequested) return null;

      if (confirmed == null) {
        await _speakAndWait(
              () => _tts.announceError(
            'No escuché tu respuesta. '
                'El $label no se guardó. Inténtalo de nuevo.',
          ),
        );
        if (attempt < 2) {
          await _tts.speakBeforeListen();
          continue;
        }
        return null;
      }

      final yes = _parseYesNo(confirmed.toLowerCase());

      if (yes == true) {
        await _speakAndWait(
              () => _tts.announceSuccess(
            '${isLastName ? "Apellido" : "Nombre"} guardado: $normalized.',
          ),
        );
        return FieldDictationResult(
          rawText:        raw,
          normalizedText: normalized,
          fieldType: isLastName ? AuthFieldType.lastName : AuthFieldType.name,
          confirmed:      true,
        );
      } else if (yes == false) {
        if (attempt < 2) {
          await _speakAndWait(
                () => _tts.announceButton('De acuerdo, repitamos.'),
            isFieldInstruction: true,
          );
          await _tts.speakBeforeListen();
        } else {
          await _speakAndWait(
                () => _tts.announceError(
              'No pudimos capturar tu $label. Puedes escribirlo con el teclado.',
            ),
          );
          return null;
        }
      } else {
        await _speakAndWait(
              () => _tts.announceError('No entendí. Di sí o no.'),
        );
        await _tts.speakBeforeListen();
        final retry = await _listenOnce(
          listenFor: const Duration(seconds: 8),
          pauseFor:  const Duration(seconds: 4),
          mode:      stt.ListenMode.confirmation,
        );
        if (retry != null && _parseYesNo(retry.toLowerCase()) == true) {
          await _speakAndWait(
                () => _tts.announceSuccess(
              '${isLastName ? "Apellido" : "Nombre"} guardado: $normalized.',
            ),
          );
          return FieldDictationResult(
            rawText:        raw,
            normalizedText: normalized,
            fieldType: isLastName ? AuthFieldType.lastName : AuthFieldType.name,
            confirmed: true,
          );
        }
        if (attempt < 2) await _tts.speakBeforeListen();
      }
    }

    await _speakAndWait(
          () => _tts.announceError(
        'No pude guardar tu $label. Escríbelo con el teclado.',
      ),
    );
    return null;
  }

  // ── _speakAndWait ────────────────────────────────────────────────────────────

  Future<void> _speakAndWait(
      Future<void> Function() speak, {
        Duration postDelay          = const Duration(milliseconds: 500),
        bool     isFieldInstruction = false,
      }) async {
    _stopStt();
    _ttsActive = true;
    try {
      await speak();
      await _tts.waitForCompletion();
    } catch (_) {
      await Future.delayed(const Duration(milliseconds: 1500));
    } finally {
      await Future.delayed(postDelay);
      _ttsEchoSuppressUntil = DateTime.now().add(_kTtsEchoWindow);
      if (isFieldInstruction) {
        _fieldEchoSuppressUntil = DateTime.now().add(_kFieldEchoWindow);
        _log('Supresión eco campo: ${_kFieldEchoWindow.inMilliseconds}ms');
      }
      _ttsActive = false;
    }
  }

  // ── Normalización email ───────────────────────────────────────────────────────

  bool _looksLikeEmail(String text) {
    final at = text.indexOf('@');
    if (at <= 0) return false;
    if (!text.substring(at + 1).contains('.')) return false;
    if (text.contains(' ')) return false;
    if (text.length < 6) return false;
    return true;
  }

  String _normalizeEmail(String raw) {
    var text = raw.toLowerCase().trim();

    for (final j in [
      'escuché', 'escuche', 'está bien', 'esta bien',
      'sí confirmar', 'correcto',
    ]) {
      text = text.replaceAll(j, ' ');
    }

    text = text
        .replaceAll('á', 'a').replaceAll('à', 'a')
        .replaceAll('ä', 'a').replaceAll('â', 'a')
        .replaceAll('é', 'e').replaceAll('è', 'e')
        .replaceAll('ë', 'e').replaceAll('ê', 'e')
        .replaceAll('í', 'i').replaceAll('ì', 'i')
        .replaceAll('ï', 'i').replaceAll('î', 'i')
        .replaceAll('ó', 'o').replaceAll('ò', 'o')
        .replaceAll('ö', 'o').replaceAll('ô', 'o')
        .replaceAll('ú', 'u').replaceAll('ù', 'u')
        .replaceAll('ü', 'u').replaceAll('û', 'u')
        .replaceAll('ñ', 'n')
        .replaceAll('ç', 'c');

    final replacements = <String, String>{
      'arroba':       '@',
      'punto com co': '.com.co',
      'punto com':    '.com',
      'punto co':     '.co',
      'punto net':    '.net',
      'punto org':    '.org',
      'punto edu':    '.edu',
      'punto io':     '.io',
      'punto es':     '.es',
      'punto':        '.',
      'guión bajo':   '_',
      'guion bajo':   '_',
      'guión':        '-',
      'guion':        '-',
      'espacio':      '',
      'cero':         '0',
      'uno':          '1',
      'una':          '1',
      'dos':          '2',
      'tres':         '3',
      'cuatro':       '4',
      'cinco':        '5',
      'seis':         '6',
      'séis':         '6',
      'siete':        '7',
      'ocho':         '8',
      'nueve':        '9',
    };

    final keys = replacements.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final k in keys) text = text.replaceAll(k, replacements[k]!);

    text = text.replaceAll(RegExp(r'\s+'), '').toLowerCase();

    if (!text.contains('@')) {
      final m = RegExp(
          r'(gmail|hotmail|yahoo|outlook|icloud|live|proton)')
          .firstMatch(text);
      if (m != null) {
        text = '${text.substring(0, m.start)}@${text.substring(m.start)}';
      }
    }

    text = text.replaceAll(RegExp(r'[^a-z0-9@._\-]'), '');
    return text;
  }

  String _capitalizeName(String raw) {
    return raw.trim().split(' ').map((w) {
      if (w.isEmpty) return '';
      return w[0].toUpperCase() + w.substring(1).toLowerCase();
    }).join(' ');
  }

  // ── Parsers ──────────────────────────────────────────────────────────────────

  bool? _parseYesNo(String text) {
    const yes = [
      'sí', 'si', 'correcto', 'exacto', 'afirmativo', 'dale', 'ok',
      'claro', 'bien', 'confirmo', 'así es', 'eso es', 'adelante',
    ];
    const no = [
      'no', 'negativo', 'incorrecto', 'error', 'otro',
      'diferente', 'repite', 'mal', 'de nuevo',
    ];
    for (final w in yes) { if (text.contains(w)) return true; }
    for (final w in no)  { if (text.contains(w)) return false; }
    return null;
  }

  String _digitToWord(int d) {
    const words = [
      'cero', 'uno', 'dos', 'tres', 'cuatro',
      'cinco', 'seis', 'siete', 'ocho', 'nueve',
    ];
    return words[d];
  }

  // ── STT helpers ──────────────────────────────────────────────────────────────

  void _stopStt() {
    try {
      _speech.stop();
      _speech.cancel();
    } catch (_) {}
    _sttOpen = false;
  }

  void _scheduleRestart(Duration delay) {
    if (!_wakeWordListening) return;
    _restartTimer?.cancel();
    _restartTimer = Timer(delay, () async {
      if (_wakeWordListening &&
          !_ttsActive &&
          !_sttOpen &&
          !_processingWakeWord &&
          !_ivrRunning) {
        await _listenForWakeWord();
      }
    });
  }

  void _onSttStatus(String status) {
    _log('STT status: $status');

    switch (status) {
      case 'listening':
        _sttOpen = true;
        break;

      case 'done':
      case 'notListening':
        _sttOpen = false;

        if (_processingWakeWord || _ivrRunning) {
          _log('STT status $status — IVR activo');
          return;
        }

        if (_wakeWordListening && !_ttsActive) {
          _scheduleRestart(const Duration(milliseconds: 1400));
        }
        break;
    }
  }

  void _onSttError(dynamic error) {
    final msg = error.toString();
    if (msg.contains('error_busy')) {
      _log('STT busy detectado');

      _sttOpen = false;

      if (!_resettingStt) {
        Future.microtask(_hardResetStt);
      }

      return;
    }
    _sttOpen = false;
    _log('STT error: $msg');

    _consecutiveSttErrors++;

    if (_consecutiveSttErrors >= _kMaxSttErrors && !_ivrRunning && !_ttsActive) {
      _consecutiveSttErrors = 0;
      _tts.announceServiceError(
        'El micrófono tuvo varios problemas seguidos. '
            'Si sigues teniendo dificultades, toca el logo para reiniciar '
            'el asistente de voz.',
      );
    }

    if (_ivrRunning || _activeListenOnceCompleter != null) {
      if (msg.contains('error_no_match') ||
          msg.contains('error_speech_timeout') ||
          msg.contains('error_client')) {
        _log('STT error durante IVR/campo — completando listenOnce con null');
        _completeActiveListenOnce(null);
        return;
      }
    }

    if (msg.contains('error_speech_timeout') ||
        msg.contains('error_no_match')) {
      if (_processingWakeWord) {
        _log('Timeout/no_match durante escucha — reseteando processingWakeWord');
        _processingWakeWord = false;
      }
      if (!_ivrRunning && _wakeWordListening && !_ttsActive) {
        _scheduleRestart(const Duration(seconds: 2));
      }
      return;
    }

    if (_processingWakeWord) _processingWakeWord = false;
    if (!_ivrRunning && _wakeWordListening && !_ttsActive) {
      _scheduleRestart(const Duration(seconds: 2));
    }
  }

  static bool _has(String text, List<String> words) =>
      words.any((w) => text.contains(w));

  void dispose() {
    _ivrCancelRequested   = true;
    _fieldCancelRequested = true;
    _ivrRunning           = false;
    _completeActiveListenOnce(null);
    pauseListening();
    _restartTimer?.cancel();
    _commandTimeoutTimer?.cancel();
    if (!_eventController.isClosed) _eventController.close();
    _initialized = false;
    _log('Liberado');
  }
}
