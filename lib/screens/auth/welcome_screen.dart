// lib/screens/auth/welcome_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_voice_robot/screens/auth/register_screen_integrated.dart';

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
      await Future.delayed(const Duration(milliseconds: 300));
      SemanticsService.announce(
        'Bienvenido a COMPAS. Dos opciones disponibles: Iniciar sesión o Crear cuenta',
        TextDirection.ltr,
      );
    });
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  void _navigateToLogin() {
    HapticFeedback.lightImpact();
    SemanticsService.announce('Ir a iniciar sesión', TextDirection.ltr);
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const LoginScreenIntegrated(),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  void _navigateToRegister() {
    HapticFeedback.lightImpact();
    SemanticsService.announce('Ir a crear cuenta', TextDirection.ltr);
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const RegisterScreenIntegrated(),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

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
                    'assets/images/compas_V3.png',
                    width: 180,
                    height: 180,
                    fit: BoxFit.contain,
                  ),
                ),

                const SizedBox(height: 48),

                // TÍTULO PRINCIPAL
                Semantics(
                  header: true,
                  label: 'COMPAS',
                  child: Text(
                    'COMPAS',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),

                const SizedBox(height: 16),

                // SUBTÍTULO
                Semantics(
                  label: 'Tecnología que te escucha',
                  child: Text(
                    'Tecnología que te escucha',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontSize: 18,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),

                const SizedBox(height: 80),

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
  }) {
    final theme = Theme.of(context);

    return Material(
      color: isPrimary ? theme.colorScheme.primary : theme.cardColor,
      borderRadius: BorderRadius.circular(20),
      elevation: 0,
      child: InkWell(
        onTap: onPressed,
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