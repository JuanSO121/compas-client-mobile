// lib/screens/auth/welcome_screen.dart
//
// ── v4.1 — Sin fondo gris en logo · Anillo naranja conservado ────────────────
//
//  CAMBIOS v4.0 → v4.1:
//
//  FIX — El Container circular semitransparente (gris oscuro) que aparecía
//    detrás del logo cuando el micrófono estaba activo fue eliminado.
//    Se conserva únicamente el anillo/borde naranja (colorScheme.primary)
//    y el indicador de micrófono (badge inferior derecho).
//    El efecto de pulso también se mantiene intacto.
//
//  TODOS LOS FIXES v4.0 SE MANTIENEN INTACTOS:
//    FIX A — Micrófono automático al entrar a la pantalla
//    FIX B — _micActive refleja estado real del micrófono
//    FIX C — announceScreen espera a initialize() completar
//    FIX D — Texto de bienvenida conciso
//    FIX E — _guestLoading se resetea en dispose()

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/auth_tts_service.dart';
import '../../services/auth_voice_navigation_service.dart';
import '../../services/guest_session.dart';
import '../../controllers/ar_navigation_controller.dart' show kTutorialDoneKey;
import '../ar_navigation_screen.dart';
import 'login_screen_integrated.dart';
import 'register_screen_integrated.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with TickerProviderStateMixin {

  late AnimationController _fadeController;
  late Animation<double>   _fadeAnimation;

  final AuthTTSService             _tts      = AuthTTSService();
  final AuthVoiceNavigationService _voiceNav = AuthVoiceNavigationService();

  bool _guestLoading = false;

  // _micActive refleja el estado real del micrófono
  bool _micActive = false;

  StreamSubscription<AuthVoiceEvent>? _voiceSub;

  late AnimationController _pulseController;
  late Animation<double>   _pulseAnimation;

  @override
  void initState() {
    super.initState();

    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync:    this,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve:  Curves.easeInOut,
    );
    _fadeController.forward();

    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 900),
      vsync:    this,
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _tts.initialize();
      await _initVoiceAndAnnounce();
    });
  }

  Future<void> _initVoiceAndAnnounce() async {
    final ok = await _voiceNav.initialize();
    if (!mounted) return;

    _voiceNav.setCurrentScreen('welcome');
    _voiceSub = _voiceNav.events.listen(_onVoiceEvent);

    await _tts.announceScreen(
      'Bienvenido a Compas. '
          'Tienes tres opciones: Iniciar sesión, Crear cuenta, o Entrar como invitado. '
          'Di: oye compas, seguido de lo que quieres hacer.',
    );

    SemanticsService.announce(
      'Bienvenido a Compas. Opciones: Iniciar sesión, Crear cuenta, '
          'o Entrar como invitado. El asistente de voz está activo.',
      TextDirection.ltr,
    );

    if (ok && mounted) {
      setState(() {
        _micActive = true;
        _pulseController.repeat(reverse: true);
      });
      await _voiceNav.startWakeWordListening();
    }
  }

  @override
  void dispose() {
    _guestLoading = false; // FIX E
    _voiceSub?.cancel();
    _voiceNav.pauseListening();
    _fadeController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  // ─── Toggle manual del micrófono (tap en el logo) ─────────────────────────

  Future<void> _toggleMicrophone() async {
    HapticFeedback.mediumImpact();

    if (_micActive) {
      setState(() {
        _micActive = false;
        _pulseController.stop();
        _pulseController.reset();
      });
      _voiceNav.pauseListening();
      await _tts.announceButton('Micrófono desactivado. Toca el logo para reactivarlo.');
      SemanticsService.announce(
        'Micrófono desactivado.',
        TextDirection.ltr,
      );
    } else {
      setState(() {
        _micActive = true;
        _pulseController.repeat(reverse: true);
      });
      await _tts.announceButton(
        'Micrófono activado. Di: oye compas, seguido de tu opción.',
      );
      SemanticsService.announce(
        'Micrófono activado.',
        TextDirection.ltr,
      );
      await _voiceNav.startWakeWordListening();
    }
  }

  // ─── Eventos de voz ───────────────────────────────────────────────────────

  void _onVoiceEvent(AuthVoiceEvent event) {
    if (!mounted) return;
    switch (event.intent) {
      case AuthVoiceIntent.login:
        _navigateToLogin();
      case AuthVoiceIntent.register:
        _navigateToRegister();
      case AuthVoiceIntent.guest:
        _enterAsGuest();
      default:
        break;
    }
  }

  // ─── Navegación ────────────────────────────────────────────────────────────

  void _navigateToLogin() async {
    HapticFeedback.lightImpact();
    _voiceNav.pauseListening();
    await _tts.announceButton('Iniciando sesión.');
    SemanticsService.announce('Abriendo inicio de sesión.', TextDirection.ltr);

    if (!mounted) return;

    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder:        (_, __, ___) => const LoginScreenIntegrated(),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    ).then((_) {
      if (_micActive && mounted) {
        _voiceNav.setCurrentScreen('welcome');
        _voiceNav.resumeListening();
      }
    });
  }

  void _navigateToRegister() async {
    HapticFeedback.lightImpact();
    _voiceNav.pauseListening();
    await _tts.announceButton('Creando cuenta nueva.');
    SemanticsService.announce('Abriendo registro.', TextDirection.ltr);

    if (!mounted) return;

    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder:        (_, __, ___) => const RegisterScreenIntegrated(),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    ).then((_) {
      if (_micActive && mounted) {
        _voiceNav.setCurrentScreen('welcome');
        _voiceNav.resumeListening();
      }
    });
  }

  Future<void> _enterAsGuest() async {
    if (_guestLoading) return;
    HapticFeedback.lightImpact();
    setState(() => _guestLoading = true);

    _voiceNav.pauseListening();
    await _tts.announceButton('Entrando como invitado.');
    SemanticsService.announce('Entrando como invitado.', TextDirection.ltr);

    final prefs       = await SharedPreferences.getInstance();
    final tutorialDone = prefs.getBool(kTutorialDoneKey) ?? false;

    if (!mounted) return;

    GuestSession().startGuestSession();
    await _voiceNav.shutdownForARTransition();

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder:        (_, __, ___) => ArNavigationScreen(
          showWelcomeTutorial: !tutorialDone,
          userName:            'Invitado',
        ),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Spacer(),

                _buildLogo(theme),

                const SizedBox(height: 12),
                _buildMicStatusBadge(theme),

                const SizedBox(height: 40),

                Semantics(
                  label: 'Iniciar sesión. Presiona para acceder con tu cuenta.',
                  button: true,
                  child: _buildPrimaryButton(
                    label:     'Iniciar Sesión',
                    icon:      Icons.login_rounded,
                    onPressed: _navigateToLogin,
                    isPrimary: true,
                  ),
                ),

                const SizedBox(height: 20),

                Semantics(
                  label: 'Crear cuenta nueva. Presiona para registrarte.',
                  button: true,
                  child: _buildPrimaryButton(
                    label:     'Crear Cuenta',
                    icon:      Icons.person_add_rounded,
                    onPressed: _navigateToRegister,
                    isPrimary: false,
                  ),
                ),

                const SizedBox(height: 20),

                Row(
                  children: [
                    Expanded(
                      child: Divider(
                        color: theme.colorScheme.onSurface.withOpacity(0.15),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Text(
                        'o continúa sin cuenta',
                        style: TextStyle(
                          fontSize: 13,
                          color: theme.colorScheme.onSurface.withOpacity(0.4),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Divider(
                        color: theme.colorScheme.onSurface.withOpacity(0.15),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                Semantics(
                  label: 'Entrar como invitado. Usa la app sin registrarte.',
                  button: true,
                  child: _buildGuestButton(theme),
                ),

                const Spacer(),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─── Logo — tap para desactivar/reactivar micrófono ──────────────────────
  //
  // FIX v4.1: Se eliminó el Container circular de fondo (color primary con
  // opacity 0.08) que aparecía como un círculo gris oscuro/semitransparente
  // detrás del logo cuando _micActive era true.
  // Se conservan:
  //   • El anillo/borde naranja (Border.all con colorScheme.primary)
  //   • El badge de micrófono (posicionado en la esquina inferior derecha)
  //   • El efecto de pulso (Transform.scale con _pulseAnimation)

  Widget _buildLogo(ThemeData theme) {
    return Semantics(
      label: _micActive
          ? 'Logo Compas. El asistente de voz está activo. '
          'Toca para desactivar el micrófono.'
          : 'Logo Compas. El asistente de voz está desactivado. '
          'Toca para reactivar el micrófono.',
      button: true,
      child: GestureDetector(
        onTap: _toggleMicrophone,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _pulseAnimation,
              builder: (_, __) {
                return Transform.scale(
                  scale: _micActive ? _pulseAnimation.value : 1.0,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // FIX v4.1: el Container circular de fondo fue removido.
                      // Ya no hay ningún círculo semitransparente detrás del logo.
                      // Solo queda el anillo (border) naranja alrededor de la imagen.

                      Container(
                        decoration: _micActive
                            ? BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: theme.colorScheme.primary
                                .withOpacity(0.4),
                            width: 3,
                          ),
                        )
                            : null,
                        child: ClipOval(
                          child: Image.asset(
                            'assets/images/V6.png',
                            width:  240,
                            height: 240,
                            fit:    BoxFit.contain,
                          ),
                        ),
                      ),

                      // Badge de micrófono activo (esquina inferior derecha)
                      if (_micActive)
                        Positioned(
                          bottom: 10,
                          right:  10,
                          child: Container(
                            width:  48,
                            height: 48,
                            decoration: BoxDecoration(
                              color:  theme.colorScheme.primary,
                              shape:  BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: theme.colorScheme.primary
                                      .withOpacity(0.4),
                                  blurRadius:  12,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.mic_rounded,
                              color: Colors.white,
                              size:  24,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),

            const SizedBox(height: 10),

            Image.asset(
              'assets/images/Texto.png',
              width: 280,
              fit:   BoxFit.contain,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMicStatusBadge(ThemeData theme) {
    if (!_micActive) {
      return Text(
        'Toca el logo para activar el asistente de voz',
        style: TextStyle(
          fontSize: 13,
          color:    theme.colorScheme.onSurface.withOpacity(0.4),
        ),
        textAlign: TextAlign.center,
      );
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color:        theme.colorScheme.primary.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: theme.colorScheme.primary.withOpacity(0.3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.mic_rounded,
            size:  16,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Text(
            'Di "Oye compas" para comenzar',
            style: TextStyle(
              fontSize:   13,
              fontWeight: FontWeight.w600,
              color:      theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Botones ──────────────────────────────────────────────────────────────

  Widget _buildPrimaryButton({
    required String   label,
    required IconData icon,
    required VoidCallback onPressed,
    required bool     isPrimary,
  }) {
    final theme = Theme.of(context);

    return Material(
      color:        isPrimary ? theme.colorScheme.primary : Colors.white,
      borderRadius: BorderRadius.circular(20),
      elevation:    0,
      child: InkWell(
        onTap:        onPressed,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width:  double.infinity,
          height: 72,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: isPrimary
                ? null
                : Border.all(
              color: theme.colorScheme.primary.withOpacity(0.3),
              width: 2,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size:  28,
                color: isPrimary ? Colors.white : theme.colorScheme.primary,
              ),
              const SizedBox(width: 16),
              Text(
                label,
                style: TextStyle(
                  fontSize:      20,
                  fontWeight:    FontWeight.bold,
                  color:         isPrimary
                      ? Colors.white
                      : theme.colorScheme.primary,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGuestButton(ThemeData theme) {
    return Material(
      color:        Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap:        _guestLoading ? null : _enterAsGuest,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width:  double.infinity,
          height: 56,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: theme.colorScheme.onSurface.withOpacity(0.06),
          ),
          child: _guestLoading
              ? Center(
            child: SizedBox(
              width:  22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: theme.colorScheme.onSurface.withOpacity(0.5),
              ),
            ),
          )
              : Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.person_outline_rounded,
                size:  22,
                color: theme.colorScheme.onSurface.withOpacity(0.5),
              ),
              const SizedBox(width: 10),
              Text(
                'Entrar como invitado',
                style: TextStyle(
                  fontSize:   16,
                  fontWeight: FontWeight.w600,
                  color:      theme.colorScheme.onSurface.withOpacity(0.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
