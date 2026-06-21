// lib/screens/auth/login_screen_integrated.dart
//
// ============================================================================
//  LoginScreenIntegrated  v5.1 — Fix transición AR: shutdown + delay limpio
// ============================================================================
//
//  CAMBIOS v5.0 → v5.1
//
//  FIX — Pelea de micrófonos al navegar a ArNavigationScreen
//  ─────────────────────────────────────────────────────────────────────────────
//  SÍNTOMA: al entrar a la pantalla de AR, el VoiceNavigationService (AR) no
//  podía tomar el micrófono porque AuthVoiceNavigationService todavía tenía
//  el canal STT de Android ocupado, o porque sus callbacks _onSttStatus /
//  _onSttError volvían a abrir STT después del shutdown.
//
//  CAUSA RAÍZ (3 problemas encadenados):
//
//    1. shutdownForARTransition() en v8.5 llamaba internamente a
//       VoiceNavService().shutdownForARTransition() — duplicando el shutdown
//       y dejando el VoiceNavService en estado inconsistente antes de que
//       AR lo inicializara.
//       → v8.6 ya corrigió esto: su shutdownForARTransition() NO llama
//         a VoiceNavService internamente. Pero v5.0 de este screen no
//         aprovechaba el cambio porque el flujo era idéntico visualmente.
//
//    2. No había ningún delay entre shutdownForARTransition() y
//       Navigator.pushReplacement(). El hard reset STT de auth tarda ~900ms
//       (250ms stop + 650ms kSttHardResetDelay). Sin esperar, la navegación
//       ocurría antes de que Android liberara el canal, y el AR arrancaba
//       con el micrófono todavía bloqueado.
//
//    3. _tts.dispose() se llamaba ANTES de shutdownForARTransition(), lo que
//       podía interrumpir el último TTS del servicio de voz mientras el
//       shutdown intentaba hablar ("canal de audio liberado" o similar),
//       dejando el engine TTS en estado sucio.
//
//  FIX v5.1:
//    • Se reordena la secuencia de cierre:
//        1. shutdownForARTransition() — libera STT de auth con await completo
//        2. await Future.delayed(_kArTransitionDelay) — margen extra para
//           que Android libere el canal (1200ms cubre el hard reset + buffer)
//        3. _tts.dispose() — solo después de que STT ya está libre
//        4. Navigator.pushReplacement() — AR arranca con canal libre
//    • Se añade la constante _kArTransitionDelay = 1200ms.
//    • Sin ningún otro cambio funcional. Todo lo de v5.0 permanece intacto.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../services/auth_service.dart';
import '../../services/auth_tts_service.dart';
import '../../services/auth_voice_navigation_service.dart';
import '../ar_navigation_screen.dart';
import 'request_new_code_screen.dart';

// ── Timing de transición a AR ─────────────────────────────────────────────────
//
// Debe cubrir el hard reset STT de auth (≈900ms) más un buffer de seguridad
// para dispositivos lentos (Android 10, Snapdragon 400-series).
// 1200ms es suficiente en todos los dispositivos probados.
const Duration _kArTransitionDelay = Duration(milliseconds: 1200);

// Estado simplificado del IVR: sólo idle o running.
enum _IvrState { idle, running }

class LoginScreenIntegrated extends StatefulWidget {
  const LoginScreenIntegrated({super.key});

  @override
  State<LoginScreenIntegrated> createState() => _LoginScreenIntegratedState();
}

class _LoginScreenIntegratedState extends State<LoginScreenIntegrated>
    with TickerProviderStateMixin {

  final TextEditingController _codeController = TextEditingController();
  final FocusNode             _codeFocusNode  = FocusNode();

  final AuthService                _authService = AuthService();
  final AuthTTSService             _tts         = AuthTTSService();
  final AuthVoiceNavigationService _voiceNav    = AuthVoiceNavigationService();

  bool _speechInitialized = false;

  _IvrState _ivrState = _IvrState.idle;
  String    _ivrPrompt = '';

  StreamSubscription<AuthVoiceEvent>? _voiceSub;

  bool    _isLoading       = false;
  String? _errorMessage;
  bool    _codeWasComplete = false;

  late AnimationController _fadeController;
  late Animation<double>   _fadeAnimation;
  late AnimationController _shakeController;
  late Animation<double>   _shakeAnimation;
  late AnimationController _pulseController;
  late Animation<double>   _pulseAnimation;

  // ── initState ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();

    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync:    this,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve:  Curves.easeInOut,
    );
    _fadeController.forward();

    _shakeController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync:    this,
    );
    _shakeAnimation = Tween<double>(begin: 0, end: 10).animate(
      CurvedAnimation(parent: _shakeController, curve: Curves.elasticIn),
    );

    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 900),
      vsync:    this,
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.08).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _codeController.addListener(_onCodeChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _tts.initialize();
      final ok = await _voiceNav.initialize();
      if (mounted) {
        setState(() => _speechInitialized = ok);
        _setupVoiceNav();
        await _voiceNav.announceLoginScreen();
      }
    });
  }

  // ── dispose ────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _voiceNav.cancelCodeIvr();
    _voiceSub?.cancel();
    _voiceNav.pauseListening();
    _codeController.removeListener(_onCodeChanged);
    _codeController.dispose();
    _codeFocusNode.dispose();
    _fadeController.dispose();
    _shakeController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  // ── Setup del servicio de voz ──────────────────────────────────────────────

  void _setupVoiceNav() {
    _voiceNav.setCurrentScreen('login');

    _voiceSub = _voiceNav.events.listen((event) async {
      if (!mounted) return;

      switch (event.intent) {
        case AuthVoiceIntent.dictateCode:
          if (!_isIvrActive && !_isLoading) {
            await _tts.waitForCompletion();
            await Future.delayed(const Duration(milliseconds: 300));
            if (mounted && !_isIvrActive) {
              _startIvr();
            }
          }
        case AuthVoiceIntent.back:
          if (!_isIvrActive) {
            _voiceNav.cancelCodeIvr();
            await _tts.announceButton('Volviendo.');
            if (mounted) Navigator.pop(context);
          }
        case AuthVoiceIntent.repeat:
          if (!_isIvrActive) {
            await _tts.announceButton(_ivrStatusText());
          }
        default:
          break;
      }
    });

    if (_speechInitialized) {
      _voiceNav.resumeListening();
    }
  }

  // ── IVR helpers ─────────────────────────────────────────────────────────────

  String _getCode()       => _codeController.text.replaceAll(' ', '');
  bool get _isIvrActive   => _ivrState != _IvrState.idle;

  void _onCodeChanged() {
    final code = _getCode();
    if (_errorMessage != null) setState(() => _errorMessage = null);
    setState(() {});

    if (code.length == 6 && !_codeWasComplete) {
      _codeWasComplete = true;
      if (!_isIvrActive) {
        _tts.announceButton('Código completo. Presiona Ingresar.');
      }
    } else if (code.length < 6) {
      _codeWasComplete = false;
    }
  }

  void _cancelIvr() {
    _voiceNav.cancelCodeIvr();
    _setIvrState(_IvrState.idle);
    if (mounted) _voiceNav.resumeListening();
  }

  void _setIvrState(_IvrState state) {
    if (!mounted) return;
    setState(() {
      _ivrState  = state;
      _ivrPrompt = state == _IvrState.running ? 'Dictando código… escucho.' : '';
    });
    if (state == _IvrState.running) {
      if (!_pulseController.isAnimating) {
        _pulseController.repeat(reverse: true);
      }
    } else {
      _pulseController.stop();
      _pulseController.reset();
    }
  }

  void _startIvr() {
    if (!mounted || !_speechInitialized) return;
    if (_tts.isSpeaking) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted && !_isIvrActive) _startIvr();
      });
      return;
    }

    _voiceNav.pauseListening();
    _codeController.clear();
    _codeWasComplete = false;
    if (_errorMessage != null) setState(() => _errorMessage = null);

    _setIvrState(_IvrState.running);

    _voiceNav.dictateCodeIvr().then((result) {
      if (!mounted) return;
      if (result.cancelled) {
        _setIvrState(_IvrState.idle);
        _voiceNav.resumeListening();
      } else {
        _codeController.text = result.code;
        _setIvrState(_IvrState.idle);
        Future.delayed(const Duration(milliseconds: 600), () {
          if (mounted) _login();
        });
      }
    });
  }

  // ── Login ─────────────────────────────────────────────────────────────────
  //
  // FIX v5.1 — Secuencia de cierre corregida:
  //   1. shutdownForARTransition()   → libera STT de auth (hard reset con await)
  //   2. _kArTransitionDelay (1200ms) → margen para que Android libere el canal
  //   3. _tts.dispose()              → cierra TTS solo después de que STT está libre
  //   4. Navigator.pushReplacement() → AR arranca con canal libre

  void _login() async {
    _cancelIvr();

    final code = _getCode();

    if (code.length != 6) {
      const msg = 'Ingresa los 6 dígitos de tu código de acceso.';
      setState(() => _errorMessage = msg);
      _shakeController.forward(from: 0);
      await _tts.announceError(msg);
      SemanticsService.announce(msg, TextDirection.ltr);
      _codeFocusNode.requestFocus();
      return;
    }

    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      const msg = 'El código solo debe contener números.';
      setState(() => _errorMessage = msg);
      _shakeController.forward(from: 0);
      await _tts.announceError(msg);
      return;
    }

    await _tts.announceButton('Verificando. Por favor espera.');

    setState(() {
      _isLoading    = true;
      _errorMessage = null;
    });

    try {
      final response = await _authService.loginWithCode(code: code);
      if (!mounted) return;

      if (response.success && response.data != null) {
        HapticFeedback.heavyImpact();

        final user         = response.data!.user;
        final name         = user.profile?.firstName ?? '';
        final isFirstLogin = response.data!.firstLogin ?? false;

        final ttsMsg = isFirstLogin
            ? 'Cuenta verificada. Bienvenido${name.isNotEmpty ? ", $name" : ""}.'
            : 'Bienvenido de vuelta${name.isNotEmpty ? ", $name" : ""}.';

        await _tts.announceSuccess(ttsMsg);
        SemanticsService.announce(ttsMsg, TextDirection.ltr);

        await Future.delayed(const Duration(milliseconds: 800));
        if (!mounted) return;

        // ── FIX v5.1: shutdown correcto antes de navegar ───────────────────
        //
        // PASO 1: shutdownForARTransition() libera el canal STT de auth.
        //   - Cancela timers, flags, completa listenOnce pendientes.
        //   - Hard reset STT con await (stop + cancel + 900ms de espera).
        //   - Marca _initialized = false para cortar el ciclo de auto-restart.
        //   - En v8.6 ya NO llama a VoiceNavService internamente (era el bug
        //     de v8.5 que dejaba VoiceNavService en estado inconsistente).
        await _voiceNav.shutdownForARTransition();

        // PASO 2: delay de seguridad.
        //   Android puede tardar hasta ~300ms adicionales en liberar el canal
        //   de audio después de que el hard reset termina. Este delay lo cubre.
        //   Sin él, ArNavigationController.initializeServices() arrancaba
        //   VoiceNavigationService/WakeWordService antes de que el canal
        //   estuviera libre → error_no_match permanent:true → mic muerto en AR.
        await Future.delayed(_kArTransitionDelay);
        if (!mounted) return;

        // PASO 3: dispose del TTS de auth.
        //   Se hace DESPUÉS del shutdown STT para evitar que _tts.dispose()
        //   interrumpa cualquier operación interna del servicio de voz.
        _tts.dispose();

        // PASO 4: navegar — el canal de audio ya está completamente libre.
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => ArNavigationScreen(
              showWelcomeTutorial: isFirstLogin,
              userName:            name,
            ),
          ),
        );

      } else {
        setState(() {
          _errorMessage = response.message;
          _isLoading    = false;
        });

        final announcement =
            response.accessibilityInfo?.announcement ?? response.message;
        await _tts.announceError(announcement);
        SemanticsService.announce(announcement, TextDirection.ltr);
        _shakeController.forward(from: 0);
        _codeController.clear();
        _codeWasComplete = false;
        _codeFocusNode.requestFocus();
        _voiceNav.resumeListening();
      }
    } catch (e) {
      if (!mounted) return;
      const msg = 'Error de conexión. Intenta nuevamente.';
      setState(() {
        _errorMessage = msg;
        _isLoading    = false;
      });
      await _tts.announceError(msg);
      _shakeController.forward(from: 0);
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    SemanticsService.announce(message, TextDirection.ltr);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              isError
                  ? Icons.error_outline_rounded
                  : Icons.check_circle_outline_rounded,
              color: Colors.white,
              size:  28,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        backgroundColor: isError
            ? Theme.of(context).colorScheme.error
            : Theme.of(context).colorScheme.secondary,
        behavior:  SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12)),
        margin:   const EdgeInsets.all(16),
        duration: Duration(seconds: isError ? 4 : 2),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation:       0,
        leading: Semantics(
          label:  'Volver atrás',
          button: true,
          child: IconButton(
            icon: const Icon(Icons.arrow_back_rounded, size: 32),
            onPressed: () {
              _cancelIvr();
              _tts.announceButton('Volviendo.');
              Navigator.pop(context);
            },
          ),
        ),
        title: Semantics(
          header: true,
          child: const Text(
            'Iniciar Sesión',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
        ),
        actions: [
          if (_speechInitialized)
            Semantics(
              label: _isIvrActive
                  ? 'Cancelar dictado por voz'
                  : 'Activar dictado por voz. Di oye compas, dictar código.',
              button: true,
              child: AnimatedBuilder(
                animation: _pulseAnimation,
                builder: (_, child) => Transform.scale(
                  scale: _isIvrActive ? _pulseAnimation.value : 1.0,
                  child: child,
                ),
                child: IconButton(
                  icon: Icon(
                    _isIvrActive
                        ? Icons.mic_rounded
                        : Icons.mic_none_rounded,
                    size:  28,
                    color: _isIvrActive
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface.withOpacity(0.45),
                  ),
                  tooltip: _isIvrActive ? 'Cancelar dictado' : 'Dictar código',
                  onPressed: _isLoading
                      ? null
                      : () {
                    HapticFeedback.lightImpact();
                    if (_isIvrActive) {
                      _cancelIvr();
                      _tts.announceButton('Dictado cancelado.');
                    } else {
                      _startIvr();
                    }
                  },
                ),
              ),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              children: [
                const SizedBox(height: 32),

                Semantics(
                  header: true,
                  child: Text(
                    'Tu código de acceso',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontSize:   30,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),

                const SizedBox(height: 12),

                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Text(
                    _ivrStatusText(),
                    key:   ValueKey(_ivrState),
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontSize:   18,
                      color:      _isIvrActive
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface.withOpacity(0.6),
                      height:     1.5,
                      fontWeight: _isIvrActive
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),

                const SizedBox(height: 36),

                AnimatedBuilder(
                  animation: _shakeAnimation,
                  builder: (_, child) => Transform.translate(
                    offset: Offset(_shakeAnimation.value, 0),
                    child:  child,
                  ),
                  child: _buildCodeField(theme),
                ),

                if (_isIvrActive) ...[
                  const SizedBox(height: 20),
                  _buildIvrRunningIndicator(theme),
                ],

                if (_errorMessage != null) ...[
                  const SizedBox(height: 24),
                  Semantics(
                    liveRegion: true,
                    label:      'Error: $_errorMessage',
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.error.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: theme.colorScheme.error.withOpacity(0.3),
                          width: 2,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.warning_rounded,
                              size: 24, color: theme.colorScheme.error),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _errorMessage!,
                              style: TextStyle(
                                fontSize:   16,
                                fontWeight: FontWeight.w600,
                                color:      theme.colorScheme.error,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],

                const SizedBox(height: 32),

                Semantics(
                  label:  'Botón Ingresar',
                  hint:   'Presiona para entrar con tu código de acceso',
                  button: true,
                  child:  _buildLoginButton(theme),
                ),

                const SizedBox(height: 24),

                Semantics(
                  label:  'Olvidé mi código. Solicitar un código nuevo.',
                  button: true,
                  child: TextButton.icon(
                    onPressed: _isLoading
                        ? null
                        : () async {
                      _cancelIvr();
                      HapticFeedback.lightImpact();
                      await _tts.announceButton('Solicitar nuevo código.');
                      if (!mounted) return;
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => RequestNewCodeScreen(),
                        ),
                      ).then((_) {
                        if (mounted) {
                          _voiceNav.setCurrentScreen('login');
                          _voiceNav.resumeListening();
                        }
                      });
                    },
                    icon: Icon(
                      Icons.refresh_rounded,
                      size:  22,
                      color: theme.colorScheme.primary,
                    ),
                    label: Text(
                      'Olvidé mi código — Solicitar uno nuevo',
                      style: TextStyle(
                        fontSize:   17,
                        fontWeight: FontWeight.w600,
                        color:      theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── IVR status text ───────────────────────────────────────────────────────

  String _ivrStatusText() {
    if (_ivrState == _IvrState.running) {
      return _ivrPrompt.isNotEmpty
          ? _ivrPrompt
          : 'Escuchando… di tu dígito';
    }
    return 'Ingresa el código de 6 dígitos\nque recibiste en tu email';
  }

  // ── Indicador visual IVR en curso ─────────────────────────────────────────

  Widget _buildIvrRunningIndicator(ThemeData theme) {
    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (_, child) => Transform.scale(
        scale: _pulseAnimation.value,
        child: child,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color:        theme.colorScheme.primary.withOpacity(0.12),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: theme.colorScheme.primary.withOpacity(0.35),
            width: 2,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mic_rounded,
                size: 22, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Text(
              'Dictado en curso',
              style: TextStyle(
                fontSize:   16,
                fontWeight: FontWeight.w700,
                color:      theme.colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Widgets ───────────────────────────────────────────────────────────────

  Widget _buildCodeField(ThemeData theme) {
    return Semantics(
      label:     'Campo de código de acceso. Ingresa los 6 dígitos.',
      textField: true,
      child: Container(
        decoration: BoxDecoration(
          color:        theme.cardColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _errorMessage != null
                ? theme.colorScheme.error
                : _isIvrActive
                ? theme.colorScheme.primary
                : theme.colorScheme.primary.withOpacity(0.3),
            width: _isIvrActive ? 4 : 3,
          ),
          boxShadow: [
            BoxShadow(
              color: _isIvrActive
                  ? theme.colorScheme.primary.withOpacity(0.15)
                  : Colors.black.withOpacity(0.05),
              blurRadius: _isIvrActive ? 20 : 12,
              offset:     const Offset(0, 4),
            ),
          ],
        ),
        child: TextField(
          controller:    _codeController,
          focusNode:     _codeFocusNode,
          enabled:       !_isIvrActive,
          keyboardType:  TextInputType.number,
          textAlign:     TextAlign.center,
          maxLength:     6,
          style: const TextStyle(
            fontSize:      34,
            fontWeight:    FontWeight.bold,
            letterSpacing: 16,
          ),
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            hintText: '• • • • • •',
            hintStyle: TextStyle(
              fontSize:      26,
              letterSpacing: 12,
              color: theme.colorScheme.onSurface.withOpacity(0.2),
            ),
            counterText:    '',
            border:         InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 24, vertical: 22),
            prefixIcon: Icon(
              _isIvrActive ? Icons.mic_rounded : Icons.dialpad_rounded,
              size:  28,
              color: theme.colorScheme.primary,
            ),
          ),
          onSubmitted: (_) {
            if (!_isIvrActive) _login();
          },
        ),
      ),
    );
  }

  Widget _buildLoginButton(ThemeData theme) {
    final code       = _getCode();
    final isComplete = code.length == 6;
    final isEnabled  = !_isLoading && isComplete && !_isIvrActive;

    return Material(
      color: isEnabled
          ? theme.colorScheme.primary
          : theme.colorScheme.primary.withOpacity(0.45),
      borderRadius: BorderRadius.circular(20),
      elevation:    isEnabled ? 2 : 0,
      child: InkWell(
        onTap:        isEnabled ? _login : null,
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(
          width:  double.infinity,
          height: 76,
          child: _isLoading
              ? const Center(
            child: SizedBox(
              width:  36,
              height: 36,
              child: CircularProgressIndicator(
                strokeWidth: 4,
                valueColor:
                AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
          )
              : Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _isIvrActive ? Icons.mic_rounded : Icons.login_rounded,
                size:  32,
                color: Colors.white,
              ),
              const SizedBox(width: 16),
              Text(
                _isIvrActive
                    ? 'Dictando código...'
                    : isComplete
                    ? 'Ingresar'
                    : 'Ingresa tu código',
                style: const TextStyle(
                  fontSize:      22,
                  fontWeight:    FontWeight.bold,
                  color:         Colors.white,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}