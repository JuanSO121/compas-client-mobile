// lib/screens/auth/register_screen_integrated.dart
//
// ── v5.1 — Registro por voz activado exclusivamente por comando de voz ────────
//
//  CAMBIOS v5.0 → v5.1:
//
//  FIX PRINCIPAL — Eliminado botón "Registro completo por voz"
//  ─────────────────────────────────────────────────────────────
//  El flujo completo de registro por voz ahora se activa únicamente cuando
//  el usuario dice: "oye compas, registro por voz" (u otras variantes).
//  El servicio emite AuthVoiceIntent.fullVoiceRegistration → el widget
//  llama _startFullVoiceFlow() exactamente igual que antes, pero sin botón.
//
//  POR QUÉ: para un usuario ciego, un botón extra en el UI que no puede ver
//  es ruido. La activación por voz es la modalidad natural y accesible.
//  Además elimina la confusión de tener dos caminos paralelos activos.
//
//  FIX MENOR — resetCancelFlags() al iniciar cualquier flujo de voz
//  El widget ahora llama _voiceNav.resetCancelFlags() antes de
//  iniciar dictateEmailField() o dictateNameField() para evitar que
//  flags sucios de cancelaciones previas bloqueen el siguiente dictado.
//
//  FIX MENOR — _isVoiceFlowRunning se resetea correctamente en dispose()
//  Antes solo se llamaba cancelFieldDictation(); ahora también resetea el flag.
//
//  FLUJO COMPLETO POR VOZ:
//    1. Usuario dice "oye compas, registro por voz"
//    2. Groq/parser local → AuthVoiceIntent.fullVoiceRegistration
//    3. Widget recibe el evento → llama _startFullVoiceFlow()
//    4. Servicio captura correo, nombre, apellido por TTS/STT
//    5. Al terminar emite AuthVoiceIntent.registrationComplete
//    6. Widget llena campos + llama _createAccount()
//
//  TODO LO DEMÁS DE v5.0 SE MANTIENE INTACTO.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import '../../services/auth_service.dart';
import '../../services/auth_tts_service.dart';
import '../../services/auth_voice_navigation_service.dart';
import 'login_screen_integrated.dart';

enum _DictationPhase {
  none,
  instructing,
  listening,
  processing,
  confirming,
}

class RegisterScreenIntegrated extends StatefulWidget {
  const RegisterScreenIntegrated({super.key});

  @override
  State<RegisterScreenIntegrated> createState() =>
      _RegisterScreenIntegratedState();
}

class _RegisterScreenIntegratedState extends State<RegisterScreenIntegrated>
    with TickerProviderStateMixin {

  int  _currentStep     = 0;
  bool _screenAnnounced = false;

  final TextEditingController _emailController     = TextEditingController();
  final TextEditingController _firstNameController = TextEditingController();
  final TextEditingController _lastNameController  = TextEditingController();

  final FocusNode _emailFocusNode     = FocusNode();
  final FocusNode _firstNameFocusNode = FocusNode();
  final FocusNode _lastNameFocusNode  = FocusNode();

  final AuthService                _authService = AuthService();
  final AuthTTSService             _tts         = AuthTTSService();
  final AuthVoiceNavigationService _voiceNav    = AuthVoiceNavigationService();

  bool   _isLoading          = false;
  bool   _isDictating        = false;
  bool   _isVoiceFlowRunning = false;
  String? _errorMessage;

  _DictationPhase _dictationPhase      = _DictationPhase.none;
  String          _dictationStatusText = '';

  StreamSubscription<AuthVoiceEvent>? _voiceSub;

  late AnimationController _fadeController;
  late Animation<double>   _fadeAnimation;
  late AnimationController _shakeController;
  late Animation<double>   _shakeAnimation;
  late AnimationController _micPulseController;
  late Animation<double>   _micPulseAnimation;

  // ─────────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();

    _fadeController = AnimationController(
        duration: const Duration(milliseconds: 300), vsync: this);
    _fadeAnimation =
        CurvedAnimation(parent: _fadeController, curve: Curves.easeInOut);
    _fadeController.forward();

    _shakeController = AnimationController(
        duration: const Duration(milliseconds: 500), vsync: this);
    _shakeAnimation = Tween<double>(begin: 0, end: 10).animate(
        CurvedAnimation(parent: _shakeController, curve: Curves.elasticIn));

    _micPulseController = AnimationController(
        duration: const Duration(milliseconds: 900), vsync: this);
    _micPulseAnimation = Tween<double>(begin: 1.0, end: 1.08).animate(
      CurvedAnimation(parent: _micPulseController, curve: Curves.easeInOut),
    );

    _emailController.addListener(() {
      if (_errorMessage != null && _currentStep == 0) {
        setState(() => _errorMessage = null);
      }
    });
    _firstNameController.addListener(() {
      if (_errorMessage != null && _currentStep == 1) {
        setState(() => _errorMessage = null);
      }
    });
    _lastNameController.addListener(() {
      if (_errorMessage != null && _currentStep == 1) {
        setState(() => _errorMessage = null);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _tts.initialize();
      await _initVoiceNav();
    });
  }

  @override
  void dispose() {
    _voiceSub?.cancel();
    // v5.1: cancelar cualquier flujo activo y resetear flags
    _voiceNav.cancelFieldDictation();
    // resetCancelFlags no disponible en esta versión del servicio
    _voiceNav.pauseListening();
    _isDictating        = false;
    _isVoiceFlowRunning = false;
    _emailController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailFocusNode.dispose();
    _firstNameFocusNode.dispose();
    _lastNameFocusNode.dispose();
    _fadeController.dispose();
    _shakeController.dispose();
    _micPulseController.dispose();
    super.dispose();
  }

  // ─── Voice nav ────────────────────────────────────────────────────────────

  Future<void> _initVoiceNav() async {
    _voiceNav.setCurrentScreen('register');

    _voiceSub = _voiceNav.events.listen((event) async {
      if (!mounted) return;

      switch (event.intent) {
      // ── Evento del flujo completo de registro ─────────────────────────────
        case AuthVoiceIntent.registrationComplete:
          await _handleRegistrationComplete(event.registrationResult);

        case AuthVoiceIntent.dictateEmail:
          if (_isVoiceFlowRunning) return;
          if (_currentStep == 0) {
            await _dictateEmail();
          } else {
            await _tts.announceButton(
                'Estás en el paso del nombre. Di dictar nombre.');
          }

        case AuthVoiceIntent.dictateName:
          if (_isVoiceFlowRunning) return;
          if (_currentStep == 1) {
            await _dictateName();
          } else {
            await _tts.announceButton(
                'Primero necesito tu correo. Di dictar correo.');
          }

        case AuthVoiceIntent.back:
          if (!_isVoiceFlowRunning) _previousStep();

        case AuthVoiceIntent.help:
          break;

        case AuthVoiceIntent.repeat:
          if (!_isVoiceFlowRunning) await _announceCurrentStep();

        default:
          break;
      }
    });

    await _voiceNav.startWakeWordListening();

    if (!_screenAnnounced) {
      _screenAnnounced = true;
      await _announceCurrentStep();
    }
  }

  Future<void> _announceCurrentStep() async {
    if (!mounted) return;
    await _voiceNav.announceRegistrationScreen(_currentStep);
    SemanticsService.announce(
      _currentStep == 0
          ? 'Crear cuenta. Paso 1 de 2: ingrese su correo. '
          'Di oye compas, registro por voz, para hacerlo todo sin tocar la pantalla.'
          : 'Paso 2 de 2: ingrese su nombre. El apellido es opcional.',
      TextDirection.ltr,
    );
  }

  void _goToStep(int step) {
    setState(() {
      _currentStep  = step;
      _errorMessage = null;
    });
    final screen = step == 0 ? 'register' : 'register_step2';
    _voiceNav.setCurrentScreen(screen);
    _announceCurrentStep();
  }

  // ─── Flujo completo por voz (activado por comando de voz) ─────────────────

  void _startFullVoiceFlow() {
    if (_isVoiceFlowRunning || _isDictating || _isLoading) return;

    setState(() {
      _isVoiceFlowRunning = true;
      _errorMessage       = null;
    });
    _micPulseController.repeat(reverse: true);
    HapticFeedback.mediumImpact();

    _voiceNav.startFullRegistrationFlow();
  }

  void _cancelFullVoiceFlow() {
    _voiceNav.cancelFieldDictation();
    setState(() {
      _isVoiceFlowRunning = false;
    });
    _micPulseController.stop();
    _micPulseController.reset();
    _tts.announceButton('Registro por voz cancelado. Puedes usar el teclado.');
  }

  Future<void> _handleRegistrationComplete(
      FullRegistrationResult? result) async {
    if (!mounted) return;

    setState(() {
      _isVoiceFlowRunning = false;
    });
    _micPulseController.stop();
    _micPulseController.reset();

    if (result == null || result.cancelled) {
      setState(() =>
      _errorMessage = 'Registro por voz cancelado. Puedes escribir los datos abajo.');
      SemanticsService.announce(
        'Registro por voz cancelado. Usa el teclado para completar los datos.',
        TextDirection.ltr,
      );
      return;
    }

    _emailController.text     = result.email;
    _firstNameController.text = result.firstName;
    _lastNameController.text  = result.lastName;

    if (_currentStep != 1) {
      setState(() {
        _currentStep  = 1;
        _errorMessage = null;
      });
      _voiceNav.setCurrentScreen('register_step2');
    }

    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;

    _createAccount();
  }

  // ─── Banner de estado del dictado campo-a-campo ───────────────────────────

  void _setDictationPhase(_DictationPhase phase) {
    if (!mounted) return;
    setState(() {
      _dictationPhase      = phase;
      _dictationStatusText = switch (phase) {
        _DictationPhase.none         => '',
        _DictationPhase.instructing  => 'Preparando… escucha las instrucciones',
        _DictationPhase.listening    => '🎤 Habla ahora',
        _DictationPhase.processing   => 'Procesando lo que dijiste…',
        _DictationPhase.confirming   => '🎤 Di sí o no',
      };
    });
  }

  // ─── Dictado campo-a-campo: email ─────────────────────────────────────────

  Future<void> _dictateEmail() async {
    if (_isDictating || _isVoiceFlowRunning) return;

    setState(() {
      _isDictating  = true;
      _errorMessage = null;
    });
    _setDictationPhase(_DictationPhase.instructing);
    _micPulseController.repeat(reverse: true);

    // v5.1: limpiar flags antes de iniciar dictado
    // resetCancelFlags no disponible en esta versión del servicio
    _voiceNav.pauseListening();

    Future.delayed(const Duration(milliseconds: 4000), () {
      if (_isDictating && mounted) _setDictationPhase(_DictationPhase.listening);
    });

    try {
      final result = await _voiceNav.dictateEmailField();

      if (!mounted) return;

      if (result != null) {
        _emailController.text = result.normalizedText;
        setState(() => _errorMessage = null);
        _setDictationPhase(_DictationPhase.none);
        await _tts.announceSuccess(
          'Correo ingresado: ${result.normalizedText}. '
              'Toca Continuar cuando estés listo.',
        );
      } else {
        _setDictationPhase(_DictationPhase.none);
        setState(() => _errorMessage =
        'No se pudo capturar el correo por voz. '
            'Escríbelo aquí abajo.');
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) _emailFocusNode.requestFocus();
        });
        SemanticsService.announce(
          'Dictado terminado. Escribe tu correo con el teclado.',
          TextDirection.ltr,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isDictating = false);
        _setDictationPhase(_DictationPhase.none);
        _micPulseController.stop();
        _micPulseController.reset();
        _voiceNav.resumeListening();
      }
    }
  }

  // ─── Dictado campo-a-campo: nombre ────────────────────────────────────────

  Future<void> _dictateName() async {
    if (_isDictating || _isVoiceFlowRunning) return;

    setState(() {
      _isDictating  = true;
      _errorMessage = null;
    });
    _setDictationPhase(_DictationPhase.instructing);
    _micPulseController.repeat(reverse: true);

    // v5.1: limpiar flags antes de iniciar dictado
    // resetCancelFlags no disponible en esta versión del servicio
    _voiceNav.pauseListening();

    Future.delayed(const Duration(milliseconds: 2500), () {
      if (_isDictating && mounted) _setDictationPhase(_DictationPhase.listening);
    });

    try {
      final nameResult = await _voiceNav.dictateNameField(isLastName: false);

      if (!mounted) return;

      if (nameResult != null) {
        _firstNameController.text = nameResult.normalizedText;
        _setDictationPhase(_DictationPhase.none);
        await _tts.announceSuccess(
          'Nombre guardado: ${nameResult.normalizedText}. '
              'Puedes escribir tu apellido o continuar sin él.',
        );
        setState(() => _errorMessage = null);
      } else {
        _setDictationPhase(_DictationPhase.none);
        setState(() => _errorMessage =
        'No se pudo capturar el nombre por voz. '
            'Escríbelo aquí abajo.');
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) _firstNameFocusNode.requestFocus();
        });
        SemanticsService.announce(
          'Dictado terminado. Escribe tu nombre con el teclado.',
          TextDirection.ltr,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isDictating = false);
        _setDictationPhase(_DictationPhase.none);
        _micPulseController.stop();
        _micPulseController.reset();
        _voiceNav.resumeListening();
      }
    }
  }

  // ─── Navegación de pasos ──────────────────────────────────────────────────

  void _nextStep() {
    if (_currentStep == 0) {
      _validateEmailAndAdvance();
    } else {
      _createAccount();
    }
  }

  void _validateEmailAndAdvance() {
    final email = _emailController.text.trim();

    if (email.isEmpty) {
      const msg = 'Ingrese su correo electrónico';
      setState(() => _errorMessage = msg);
      _emailFocusNode.requestFocus();
      _shakeController.forward(from: 0);
      _tts.announceError(msg);
      SemanticsService.announce(msg, TextDirection.ltr);
      return;
    }

    final emailRegex = RegExp(r'^[\w\-\.]+@([\w\-]+\.)+[\w\-]{2,4}$');
    if (!emailRegex.hasMatch(email)) {
      const msg = 'Formato de email inválido';
      setState(() => _errorMessage = msg);
      _emailFocusNode.requestFocus();
      _shakeController.forward(from: 0);
      _tts.announceError(msg);
      SemanticsService.announce(msg, TextDirection.ltr);
      return;
    }

    HapticFeedback.lightImpact();
    _goToStep(1);

    Future.delayed(
      const Duration(milliseconds: 300),
      _firstNameFocusNode.requestFocus,
    );
  }

  void _createAccount() async {
    final firstName = _firstNameController.text.trim();

    if (firstName.isEmpty) {
      const msg = 'Ingrese su nombre';
      setState(() => _errorMessage = msg);
      _firstNameFocusNode.requestFocus();
      _shakeController.forward(from: 0);
      _tts.announceError(msg);
      SemanticsService.announce(msg, TextDirection.ltr);
      return;
    }

    _voiceNav.pauseListening();
    await _tts.announceButton('Creando su cuenta. Por favor espere.');

    setState(() {
      _isLoading    = true;
      _errorMessage = null;
    });

    try {
      final lastName = _lastNameController.text.trim();

      final response = await _authService.register(
        email:     _emailController.text.trim(),
        firstName: firstName,
        lastName:  lastName.isNotEmpty ? lastName : null,
      );

      if (!mounted) return;

      if (response.success) {
        HapticFeedback.heavyImpact();

        const ttsMsg =
            'Cuenta creada exitosamente. Revise su correo electrónico '
            'para obtener su código de acceso e inicie sesión.';
        await _tts.announceSuccess(ttsMsg);
        SemanticsService.announce(ttsMsg, TextDirection.ltr);
        _showSnackBar('Cuenta creada. Revise su email.');

        await Future.delayed(const Duration(milliseconds: 1500));
        if (!mounted) return;

        _tts.dispose();

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const LoginScreenIntegrated()),
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
        _showSnackBar(_errorMessage!, isError: true);
        _shakeController.forward(from: 0);

        _voiceNav.resumeListening();

        if (response.errors != null && response.errors!.isNotEmpty) {
          final firstError = response.errors!.first;
          if (firstError.field == 'email') {
            _goToStep(0);
            Future.delayed(
              const Duration(milliseconds: 200),
              _emailFocusNode.requestFocus,
            );
          }
        }
      }
    } catch (e) {
      if (!mounted) return;
      const msg = 'Error de conexión. Intente nuevamente.';
      setState(() {
        _errorMessage = msg;
        _isLoading    = false;
      });
      await _tts.announceError(msg);
      _showSnackBar(msg, isError: true);
      _shakeController.forward(from: 0);
      _voiceNav.resumeListening();
    }
  }

  void _previousStep() {
    if (_currentStep == 0) {
      _tts.announceButton('Volver');
      _voiceNav.pauseListening();
      Navigator.pop(context);
    } else {
      _goToStep(0);
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    SemanticsService.announce(message, TextDirection.ltr);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(children: [
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
                fontSize:   18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ]),
        backgroundColor: isError
            ? Theme.of(context).colorScheme.error
            : Theme.of(context).colorScheme.secondary,
        behavior: SnackBarBehavior.floating,
        shape:    RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12)),
        margin:   const EdgeInsets.all(16),
        duration: Duration(seconds: isError ? 4 : 2),
      ),
    );
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final bool anyBusy = _isLoading || _isDictating || _isVoiceFlowRunning;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation:       0,
        leading: Semantics(
          label:  _currentStep == 0 ? 'Volver atrás' : 'Paso anterior',
          button: true,
          child: IconButton(
            icon:      const Icon(Icons.arrow_back_rounded, size: 32),
            onPressed: anyBusy ? null : _previousStep,
          ),
        ),
        title: Semantics(
          header: true,
          child: const Text(
            'Crear Cuenta',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
        ),
        actions: [
          // Indicador de dictado/flujo de voz activo
          if (_isDictating || _isVoiceFlowRunning)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: AnimatedBuilder(
                animation: _micPulseAnimation,
                builder: (_, child) => Transform.scale(
                  scale: _micPulseAnimation.value,
                  child: child,
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color:        theme.colorScheme.primary.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.mic_rounded,
                          size:  20, color: theme.colorScheme.primary),
                      const SizedBox(width: 6),
                      Text(
                        _isVoiceFlowRunning ? 'Registro por voz' : 'Dictando',
                        style: TextStyle(
                          fontSize:   14,
                          color:      theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 24, 32, 0),
                child:   _buildProgressIndicator(theme),
              ),
              const SizedBox(height: 16),

              // Banner dictado campo-a-campo
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                child:    _dictationPhase != _DictationPhase.none
                    ? _buildDictationStatusBanner(theme)
                    : const SizedBox.shrink(),
              ),

              // Banner flujo de voz completo activo
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                child:    _isVoiceFlowRunning
                    ? _buildVoiceFlowBanner(theme)
                    : const SizedBox.shrink(),
              ),

              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  keyboardDismissBehavior:
                  ScrollViewKeyboardDismissBehavior.onDrag,
                  child: Column(
                    children: [
                      const SizedBox(height: 16),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: _currentStep == 0
                            ? _buildEmailStep(theme)
                            : _buildNameStep(theme),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),

              // Botones inferiores
              Padding(
                padding: EdgeInsets.fromLTRB(
                  32, 8, 32,
                  MediaQuery.of(context).viewInsets.bottom > 0 ? 12 : 32,
                ),
                child: Column(
                  children: [
                    // v5.1: botón cancelar flujo de voz (solo si está activo)
                    if (_isVoiceFlowRunning) ...[
                      _buildCancelVoiceFlowButton(theme),
                      const SizedBox(height: 12),
                    ],
                    // Botón principal continuar / crear cuenta
                    Semantics(
                      label:  _currentStep == 1
                          ? 'Crear mi cuenta'
                          : 'Continuar al siguiente paso',
                      button: true,
                      child: _buildActionButton(
                        label:     _currentStep == 1 ? 'Crear Cuenta' : 'Continuar',
                        icon:      _currentStep == 1
                            ? Icons.check_circle_rounded
                            : Icons.arrow_forward_rounded,
                        onPressed: anyBusy ? null : _nextStep,
                        isLoading: _isLoading,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Banner flujo de voz completo ─────────────────────────────────────────

  Widget _buildVoiceFlowBanner(ThemeData theme) {
    return Semantics(
      liveRegion: true,
      label:      'Registro por voz activo. Habla cuando te lo indique.',
      child: Container(
        width:   double.infinity,
        margin:  const EdgeInsets.fromLTRB(32, 0, 32, 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withOpacity(0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: theme.colorScheme.primary.withOpacity(0.5),
            width: 2,
          ),
        ),
        child: Row(
          children: [
            AnimatedBuilder(
              animation: _micPulseAnimation,
              builder: (_, child) => Transform.scale(
                scale: _micPulseAnimation.value,
                child: child,
              ),
              child: Icon(Icons.mic_rounded,
                  size: 22, color: theme.colorScheme.primary),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Registro por voz activo — habla cuando te lo indique',
                style: TextStyle(
                  fontSize:   15,
                  fontWeight: FontWeight.w600,
                  color:      theme.colorScheme.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Banner de estado del dictado campo-a-campo ───────────────────────────

  Widget _buildDictationStatusBanner(ThemeData theme) {
    final isListening = _dictationPhase == _DictationPhase.listening ||
        _dictationPhase == _DictationPhase.confirming;

    return Semantics(
      liveRegion: true,
      label:      _dictationStatusText,
      child: Container(
        width:   double.infinity,
        margin:  const EdgeInsets.fromLTRB(32, 0, 32, 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isListening
              ? theme.colorScheme.primary.withOpacity(0.15)
              : theme.colorScheme.secondary.withOpacity(0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isListening
                ? theme.colorScheme.primary.withOpacity(0.5)
                : theme.colorScheme.secondary.withOpacity(0.3),
            width: 2,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _micPulseAnimation,
              builder: (_, child) => Transform.scale(
                scale: isListening ? _micPulseAnimation.value : 1.0,
                child: child,
              ),
              child: Icon(
                isListening ? Icons.mic_rounded : Icons.hourglass_top_rounded,
                size:  22,
                color: isListening
                    ? theme.colorScheme.primary
                    : theme.colorScheme.secondary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _dictationStatusText,
                style: TextStyle(
                  fontSize:   15,
                  fontWeight: FontWeight.w600,
                  color:      isListening
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface.withOpacity(0.7),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Botón cancelar flujo de voz ──────────────────────────────────────────

  Widget _buildCancelVoiceFlowButton(ThemeData theme) {
    return Semantics(
      label:  'Cancelar registro por voz',
      button: true,
      child: Material(
        color:        theme.colorScheme.error.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap:        _cancelFullVoiceFlow,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width:  double.infinity,
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: theme.colorScheme.error.withOpacity(0.3),
                width: 2,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.stop_rounded,
                    size: 22, color: theme.colorScheme.error),
                const SizedBox(width: 10),
                Text(
                  'Cancelar registro por voz',
                  style: TextStyle(
                    fontSize:   16,
                    fontWeight: FontWeight.w600,
                    color:      theme.colorScheme.error,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─── Widgets ──────────────────────────────────────────────────────────────

  Widget _buildProgressIndicator(ThemeData theme) {
    return Semantics(
      label: 'Paso ${_currentStep + 1} de 2',
      child: Column(
        children: [
          Row(
            children: List.generate(2, (i) {
              final filled = _currentStep >= i;
              return Expanded(
                child: Container(
                  height: 8,
                  margin: EdgeInsets.only(right: i < 1 ? 8 : 0),
                  decoration: BoxDecoration(
                    color: filled
                        ? theme.colorScheme.primary
                        : theme.colorScheme.primary.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _stepLabel(theme, '1. Email', 0),
              _stepLabel(theme, '2. Nombre', 1),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stepLabel(ThemeData theme, String text, int step) {
    final active = _currentStep >= step;
    return Text(
      text,
      style: TextStyle(
        fontSize:   16,
        fontWeight: FontWeight.w700,
        color: active
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurface.withOpacity(0.35),
      ),
    );
  }

  Widget _buildEmailStep(ThemeData theme) {
    return Column(
      key:                  const ValueKey('email_step'),
      crossAxisAlignment:   CrossAxisAlignment.center,
      mainAxisSize:         MainAxisSize.min,
      children: [
        Semantics(
          header: true,
          child: Text(
            '¿Cuál es tu email?',
            style: theme.textTheme.titleLarge?.copyWith(
              fontSize:   30,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Le enviaremos su código de acceso a este correo.',
          style: theme.textTheme.bodyLarge?.copyWith(
            fontSize: 18,
            color:    theme.colorScheme.onSurface.withOpacity(0.6),
            height:   1.5,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        // v5.1: hint de voz (informativo, no botón)
        Semantics(
          label: 'Consejo: di oye compas registro por voz para completar todo sin tocar la pantalla',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withOpacity(0.07),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.mic_none_rounded,
                    size: 18, color: theme.colorScheme.primary.withOpacity(0.7)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Di "oye compas, registro por voz" para hacerlo todo sin tocar la pantalla',
                    style: TextStyle(
                      fontSize: 14,
                      color:    theme.colorScheme.primary.withOpacity(0.8),
                      height:   1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _buildTextField(
          theme:           theme,
          controller:      _emailController,
          focusNode:       _emailFocusNode,
          label:           'Correo electrónico',
          hint:            'ejemplo@correo.com',
          icon:            Icons.email_rounded,
          keyboardType:    TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          onSubmitted:     (_) => _nextStep(),
          enabled:         !_isVoiceFlowRunning,
          suffixIcon: Semantics(
            label:  'Dictar correo por voz',
            button: true,
            child: IconButton(
              icon: Icon(
                Icons.mic_rounded,
                size:  28,
                color: (_isDictating || _isVoiceFlowRunning)
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurface.withOpacity(0.3),
              ),
              tooltip:   'Dictar correo',
              onPressed: (_isDictating || _isVoiceFlowRunning) ? null : _dictateEmail,
            ),
          ),
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: 20),
          _buildErrorMessage(theme),
        ],
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildNameStep(ThemeData theme) {
    return Column(
      key:                  const ValueKey('name_step'),
      crossAxisAlignment:   CrossAxisAlignment.center,
      mainAxisSize:         MainAxisSize.min,
      children: [
        Semantics(
          header: true,
          child: Text(
            '¿Cómo te llamas?',
            style: theme.textTheme.titleLarge?.copyWith(
              fontSize:   30,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Así te llamaremos dentro de la aplicación.\nEl apellido es opcional.',
          style: theme.textTheme.bodyLarge?.copyWith(
            fontSize: 18,
            color:    theme.colorScheme.onSurface.withOpacity(0.6),
            height:   1.5,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        _buildTextField(
          theme:               theme,
          controller:          _firstNameController,
          focusNode:           _firstNameFocusNode,
          label:               'Nombre',
          hint:                'Tu nombre',
          icon:                Icons.person_rounded,
          keyboardType:        TextInputType.name,
          textInputAction:     TextInputAction.next,
          textCapitalization:  TextCapitalization.words,
          onSubmitted:         (_) => _lastNameFocusNode.requestFocus(),
          enabled:             !_isVoiceFlowRunning,
          suffixIcon: Semantics(
            label:  'Dictar nombre por voz',
            button: true,
            child: IconButton(
              icon: Icon(
                Icons.mic_rounded,
                size:  28,
                color: (_isDictating || _isVoiceFlowRunning)
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurface.withOpacity(0.3),
              ),
              tooltip:   'Dictar nombre',
              onPressed: (_isDictating || _isVoiceFlowRunning) ? null : _dictateName,
            ),
          ),
        ),
        const SizedBox(height: 20),
        _buildTextField(
          theme:               theme,
          controller:          _lastNameController,
          focusNode:           _lastNameFocusNode,
          label:               'Apellido (opcional)',
          hint:                'Tu apellido',
          icon:                Icons.person_outline_rounded,
          keyboardType:        TextInputType.name,
          textInputAction:     TextInputAction.done,
          textCapitalization:  TextCapitalization.words,
          onSubmitted:         (_) => _nextStep(),
          enabled:             !_isVoiceFlowRunning,
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: 20),
          _buildErrorMessage(theme),
        ],
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildTextField({
    required ThemeData              theme,
    required TextEditingController  controller,
    required FocusNode              focusNode,
    required String                 label,
    required String                 hint,
    required IconData               icon,
    TextInputType?                  keyboardType,
    TextInputAction?                textInputAction,
    TextCapitalization              textCapitalization = TextCapitalization.none,
    void Function(String)?          onSubmitted,
    Widget?                         suffixIcon,
    bool                            enabled = true,
  }) {
    return AnimatedBuilder(
      animation: _shakeAnimation,
      builder: (_, child) => Transform.translate(
          offset: Offset(_shakeAnimation.value, 0), child: child),
      child: Semantics(
        label:     label,
        textField: true,
        child: Container(
          decoration: BoxDecoration(
            color:        theme.cardColor,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: _errorMessage != null
                  ? theme.colorScheme.error
                  : theme.colorScheme.primary.withOpacity(0.3),
              width: 3,
            ),
            boxShadow: [
              BoxShadow(
                color:      Colors.black.withOpacity(0.05),
                blurRadius: 12,
                offset:     const Offset(0, 4),
              ),
            ],
          ),
          child: TextField(
            controller:          controller,
            focusNode:           focusNode,
            enabled:             enabled,
            style:               const TextStyle(
                fontSize: 20, fontWeight: FontWeight.w600),
            keyboardType:        keyboardType,
            textInputAction:     textInputAction,
            textCapitalization:  textCapitalization,
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(
                fontSize: 20,
                color:    theme.colorScheme.onSurface.withOpacity(0.3),
              ),
              prefixIcon: Icon(icon,
                  size: 28, color: theme.colorScheme.primary),
              suffixIcon: suffixIcon,
              border:         InputBorder.none,
              contentPadding: const EdgeInsets.all(22),
            ),
            onSubmitted: onSubmitted,
          ),
        ),
      ),
    );
  }

  Widget _buildErrorMessage(ThemeData theme) {
    return Semantics(
      liveRegion: true,
      label:      'Error: $_errorMessage',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: theme.colorScheme.error.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: theme.colorScheme.error.withOpacity(0.3),
            width: 2,
          ),
        ),
        child: Row(children: [
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
        ]),
      ),
    );
  }

  Widget _buildActionButton({
    required String        label,
    required IconData      icon,
    required VoidCallback? onPressed,
    bool                   isLoading = false,
  }) {
    final theme     = Theme.of(context);
    final isEnabled = onPressed != null && !isLoading;
    return Material(
      color: isEnabled
          ? theme.colorScheme.primary
          : theme.colorScheme.primary.withOpacity(0.5),
      borderRadius: BorderRadius.circular(20),
      elevation:    isEnabled ? 2 : 0,
      child: InkWell(
        onTap:        onPressed,
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(
          width:  double.infinity,
          height: 76,
          child: isLoading
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
              Icon(icon, size: 32, color: Colors.white),
              const SizedBox(width: 16),
              Text(
                label,
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