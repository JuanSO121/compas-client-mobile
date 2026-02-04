// lib/screens/auth/login_screen_integrated.dart
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import '../../services/auth_service.dart';
import '../../main.dart';
import '../voice_navigation_screen.dart';

class LoginScreenIntegrated extends StatefulWidget {
  const LoginScreenIntegrated({super.key});

  @override
  State<LoginScreenIntegrated> createState() => _LoginScreenIntegratedState();
}

class _LoginScreenIntegratedState extends State<LoginScreenIntegrated>
    with TickerProviderStateMixin {
  final TextEditingController _emailController = TextEditingController();
  final FocusNode _emailFocusNode = FocusNode();
  final TextEditingController _passwordController = TextEditingController();
  final FocusNode _passwordFocusNode = FocusNode();

  final AuthService _authService = AuthService();

  bool _isLoading = false;
  String? _errorMessage;
  bool _rememberMe = false;

  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;
  late AnimationController _shakeController;
  late Animation<double> _shakeAnimation;

  @override
  void initState() {
    super.initState();

    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeInOut,
    );
    _fadeController.forward();

    _shakeController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _shakeAnimation = Tween<double>(begin: 0, end: 10).animate(
      CurvedAnimation(parent: _shakeController, curve: Curves.elasticIn),
    );

    _emailController.addListener(() {
      if (_errorMessage != null) {
        setState(() => _errorMessage = null);
      }
    });

    _passwordController.addListener(() {
      if (_errorMessage != null) {
        setState(() => _errorMessage = null);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      SemanticsService.announce(
        'Pantalla de inicio de sesión. Ingrese su correo electrónico y contraseña',
        TextDirection.ltr,
      );
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _emailFocusNode.dispose();
    _passwordFocusNode.dispose();
    _fadeController.dispose();
    _shakeController.dispose();
    super.dispose();
  }

  void _login() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() => _errorMessage = 'Por favor complete todos los campos');
      _showAccessibleSnackBar(_errorMessage!, isError: true);
      if (email.isEmpty) {
        _emailFocusNode.requestFocus();
      } else {
        _passwordFocusNode.requestFocus();
      }
      _shakeController.forward(from: 0);
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Llamar al servicio de autenticación
      final response = await _authService.login(
        email: email,
        password: password,
        rememberMe: _rememberMe,
      );

      if (!mounted) return;

      if (response.success && response.data != null) {
        // Login exitoso
        HapticFeedback.heavyImpact();

        final userName = response.data!.user.profile?.firstName ?? '';
        final announcement = response.accessibilityInfo?.announcement ??
            'Sesión iniciada exitosamente';

        SemanticsService.announce(announcement, TextDirection.ltr);
        _showAccessibleSnackBar('¡Bienvenido${userName.isNotEmpty ? ", $userName" : ""}!');

        await Future.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const VoiceNavigationScreen()),
        );
      } else {
        // Error en login
        setState(() {
          _errorMessage = response.message;
          _isLoading = false;
        });

        final announcement = response.accessibilityInfo?.announcement ??
            response.message;

        SemanticsService.announce(announcement, TextDirection.ltr);
        _showAccessibleSnackBar(_errorMessage!, isError: true);
        _shakeController.forward(from: 0);

        // Focus en el campo apropiado según el error
        if (response.errors != null && response.errors!.isNotEmpty) {
          final firstError = response.errors!.first;
          if (firstError.field == 'email') {
            _emailFocusNode.requestFocus();
          } else {
            _passwordFocusNode.requestFocus();
          }
        } else {
          _passwordFocusNode.requestFocus();
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Error de conexión. Intente nuevamente.';
        _isLoading = false;
      });
      _showAccessibleSnackBar(_errorMessage!, isError: true);
      _shakeController.forward(from: 0);
    }
  }

  void _showAccessibleSnackBar(String message, {bool isError = false}) {
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
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style:
                const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        backgroundColor: isError
            ? Theme.of(context).colorScheme.error
            : Theme.of(context).colorScheme.secondary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
        duration: Duration(seconds: isError ? 4 : 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Semantics(
          label: 'Volver atrás',
          button: true,
          child: IconButton(
            icon: const Icon(Icons.arrow_back_rounded, size: 28),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        title: Semantics(
          header: true,
          label: 'Iniciar Sesión',
          child: const Text(
            'Iniciar Sesión',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ),
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              children: [
                const SizedBox(height: 40),

                // TÍTULO
                Semantics(
                  label: 'Ingrese sus credenciales para acceder',
                  child: Text(
                    'Bienvenido de nuevo',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),

                const SizedBox(height: 16),

                Semantics(
                  label: 'Ingrese su email y contraseña para continuar',
                  child: Text(
                    'Accede a tu cuenta',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontSize: 17,
                      color: theme.colorScheme.onSurface.withOpacity(0.6),
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),

                const SizedBox(height: 48),

                // CAMPO EMAIL
                _buildTextField(
                  controller: _emailController,
                  focusNode: _emailFocusNode,
                  label: 'Correo electrónico',
                  hint: 'ejemplo@correo.com',
                  icon: Icons.email_rounded,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => _passwordFocusNode.requestFocus(),
                ),

                const SizedBox(height: 20),

                // CAMPO CONTRASEÑA
                _buildTextField(
                  controller: _passwordController,
                  focusNode: _passwordFocusNode,
                  label: 'Contraseña',
                  hint: 'Tu contraseña',
                  icon: Icons.lock_rounded,
                  obscureText: true,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _login(),
                ),

                // MENSAJE DE ERROR
                if (_errorMessage != null) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    label: 'Error: $_errorMessage',
                    liveRegion: true,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
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
                          Icon(
                            Icons.warning_rounded,
                            size: 20,
                            color: theme.colorScheme.error,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _errorMessage!,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.error,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],

                const SizedBox(height: 32),

                // BOTÓN LOGIN
                Semantics(
                  label: 'Botón: Iniciar sesión',
                  hint: 'Presione para ingresar a su cuenta',
                  button: true,
                  child: _buildActionButton(
                    label: 'Iniciar Sesión',
                    icon: Icons.login_rounded,
                    onPressed: _isLoading ? null : _login,
                    isLoading: _isLoading,
                  ),
                ),

                const SizedBox(height: 24),

                // INFO DE SEGURIDAD
                Semantics(
                  label:
                  'Información: Conexión segura con encriptación de extremo a extremo',
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondary.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: theme.colorScheme.secondary.withOpacity(0.3),
                        width: 2,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.security_rounded,
                          size: 24,
                          color: theme.colorScheme.secondary,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Conexión segura. Tus datos están protegidos.',
                            style: TextStyle(
                              fontSize: 15,
                              color: theme.colorScheme.onSurface,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required FocusNode focusNode,
    required String label,
    required String hint,
    required IconData icon,
    bool obscureText = false,
    TextInputType? keyboardType,
    TextInputAction? textInputAction,
    void Function(String)? onSubmitted,
  }) {
    final theme = Theme.of(context);

    return AnimatedBuilder(
      animation: _shakeAnimation,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(_shakeAnimation.value, 0),
          child: child,
        );
      },
      child: Semantics(
        label: 'Campo de texto para $label',
        textField: true,
        hint: hint,
        child: Container(
          decoration: BoxDecoration(
            color: theme.cardColor,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: _errorMessage != null
                  ? theme.colorScheme.error
                  : theme.colorScheme.primary.withOpacity(0.3),
              width: 3,
            ),
            boxShadow: [
              BoxShadow(
                color: _errorMessage != null
                    ? theme.colorScheme.error.withOpacity(0.2)
                    : Colors.black.withOpacity(0.05),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            obscureText: obscureText,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            keyboardType: keyboardType,
            textInputAction: textInputAction,
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(
                fontSize: 18,
                color: theme.colorScheme.onSurface.withOpacity(0.3),
              ),
              prefixIcon: Icon(
                _errorMessage != null ? Icons.error_outline_rounded : icon,
                size: 26,
                color: _errorMessage != null
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.all(20),
            ),
            onSubmitted: onSubmitted,
          ),
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
    bool isLoading = false,
  }) {
    final theme = Theme.of(context);
    final isEnabled = onPressed != null && !isLoading;

    return Material(
      color: isEnabled
          ? theme.colorScheme.primary
          : theme.colorScheme.primary.withOpacity(0.5),
      borderRadius: BorderRadius.circular(20),
      elevation: isEnabled ? 2 : 0,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: double.infinity,
          height: 72,
          child: isLoading
              ? const Center(
            child: SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                strokeWidth: 4,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
          )
              : Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 28, color: Colors.white),
              const SizedBox(width: 16),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
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