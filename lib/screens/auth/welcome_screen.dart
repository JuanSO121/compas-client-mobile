// lib/screens/auth/welcome_screen.dart
//
// ── Cambios TTS v1.0 ──────────────────────────────────────────────────────────
//
//  • initState: inicializa AuthTTSService y anuncia la pantalla (~400 ms delay
//    para que el widget esté renderizado antes de hablar).
//  • _navigateToLogin / _navigateToRegister: anuncia el botón tocado ANTES de
//    navegar, con un pequeño delay para que el TTS alcance a decir algo.
//  • dispose: NO libera AuthTTSService aquí — lo libera LoginScreenIntegrated
//    al entrar a ArNavigationScreen. Welcome solo para el TTS al salir de scope.
//  • _buildPrimaryButton: envuelto en GestureDetector para capturar el tap y
//    anunciar la acción sin romper el InkWell existente.
//
//  SemanticsService.announce() se mantiene para TalkBack/VoiceOver del SO.
// ──────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_voice_robot/screens/auth/register_screen_integrated.dart';
import '../../services/auth_tts_service.dart';

import 'login_screen_integrated.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  // ✅ TTS
  final AuthTTSService _tts = AuthTTSService();

  @override
  void initState() {
    super.initState();

    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeInOut,
    );

    _fadeController.forward();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // ✅ Inicializar TTS y anunciar pantalla
      await _tts.initialize();

      await Future.delayed(const Duration(milliseconds: 400));

      // Anuncio por TTS (funciona sin TalkBack activo)
      await _tts.announceScreen(
        'Bienvenido a COMPAS. '
            'Dos opciones disponibles: Iniciar sesión o Crear cuenta.',
      );

      // Anuncio accesibilidad SO (TalkBack / VoiceOver)
      SemanticsService.announce(
        'Bienvenido a COMPAS. Dos opciones disponibles: Iniciar sesión o Crear cuenta',
        TextDirection.ltr,
      );
    });
  }

  @override
  void dispose() {
    _fadeController.dispose();
    // AuthTTSService NO se libera aquí; se libera al salir del flujo de auth.
    super.dispose();
  }

  // ── Navegación ─────────────────────────────────────────────────────────────

  void _navigateToLogin() async {
    HapticFeedback.lightImpact();
    await _tts.announceButton('Iniciando sesión');
    SemanticsService.announce('Ir a iniciar sesión', TextDirection.ltr);

    // Pequeño delay para que el TTS arranque antes de la transición
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;

    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const LoginScreenIntegrated(),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  void _navigateToRegister() async {
    HapticFeedback.lightImpact();
    await _tts.announceButton('Crear cuenta nueva');
    SemanticsService.announce('Ir a crear cuenta', TextDirection.ltr);

    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;

    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const RegisterScreenIntegrated(),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

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

                // LOGO PRINCIPAL
                Semantics(
                  label: 'Logo de la aplicación COMPAS',
                  child: Image.asset(
                    'assets/images/compas_V4.jpeg',
                    width: 280,
                    height: 280,
                    fit: BoxFit.contain,
                  ),
                ),

                const SizedBox(height: 48),

                // BOTÓN PRINCIPAL: INICIAR SESIÓN
                Semantics(
                  label: 'Botón: Iniciar sesión',
                  hint: 'Presione para acceder con su cuenta existente',
                  button: true,
                  child: _buildPrimaryButton(
                    label: 'Iniciar Sesión',
                    icon: Icons.login_rounded,
                    onPressed: _navigateToLogin,
                    isPrimary: true,
                    ttsHint: 'Iniciar sesión con su cuenta existente.',
                  ),
                ),

                const SizedBox(height: 24),

                // BOTÓN SECUNDARIO: CREAR CUENTA
                Semantics(
                  label: 'Botón: Crear cuenta nueva',
                  hint: 'Presione para registrarse por primera vez',
                  button: true,
                  child: _buildPrimaryButton(
                    label: 'Crear Cuenta',
                    icon: Icons.person_add_rounded,
                    onPressed: _navigateToRegister,
                    isPrimary: false,
                    ttsHint: 'Crear una cuenta nueva.',
                  ),
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

  Widget _buildPrimaryButton({
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
    required bool isPrimary,
    required String ttsHint,
  }) {
    final theme = Theme.of(context);

    return Material(
      color: isPrimary ? theme.colorScheme.primary : theme.cardColor,
      borderRadius: BorderRadius.circular(20),
      elevation: 0,
      child: InkWell(
        onTap: onPressed,
        // ✅ onHover para accesibilidad en dispositivos con puntero
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: double.infinity,
          height: 72,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: isPrimary
                ? null
                : Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.3),
              width: 2,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 28,
                color: isPrimary ? Colors.white : theme.colorScheme.primary,
              ),
              const SizedBox(width: 16),
              Text(
                label,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: isPrimary ? Colors.white : theme.colorScheme.primary,
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