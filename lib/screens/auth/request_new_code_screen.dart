// lib/screens/auth/request_new_code_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import '../../services/auth_service.dart';
import '../../utils/password_validator.dart';

/// Pantalla para cuando el usuario olvidó o perdió su código de acceso.
/// Verifica identidad con email + contraseña y genera un nuevo código permanente.
class RequestNewCodeScreen extends StatefulWidget {
  const RequestNewCodeScreen({super.key});

  @override
  State<RequestNewCodeScreen> createState() => _RequestNewCodeScreenState();
}

class _RequestNewCodeScreenState extends State<RequestNewCodeScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final FocusNode _emailFocusNode = FocusNode();
  final FocusNode _passwordFocusNode = FocusNode();

  final AuthService _authService = AuthService();

  bool _isLoading = false;
  bool _success = false;
  String? _errorMessage;
  bool _obscurePassword = true;

  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fadeAnimation =
        CurvedAnimation(parent: _fadeController, curve: Curves.easeInOut);
    _fadeController.forward();

    _emailController.addListener(() {
      if (_errorMessage != null) setState(() => _errorMessage = null);
    });
    _passwordController.addListener(() {
      if (_errorMessage != null) setState(() => _errorMessage = null);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      SemanticsService.announce(
        'Solicitar nuevo código de acceso. '
        'Ingrese su email y contraseña para verificar su identidad.',
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
    super.dispose();
  }

  void _requestNewCode() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(
          () => _errorMessage = 'Por favor complete el email y la contraseña');
      SemanticsService.announce(_errorMessage!, TextDirection.ltr);
      if (email.isEmpty) {
        _emailFocusNode.requestFocus();
      } else {
        _passwordFocusNode.requestFocus();
      }
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await _authService.requestNewCode(
        email: email,
        password: password,
      );

      if (!mounted) return;

      if (response.success) {
        HapticFeedback.heavyImpact();
        setState(() {
          _success = true;
          _isLoading = false;
        });

        SemanticsService.announce(
          'Nuevo código enviado a su email. '
          'Revise su bandeja de entrada. El código anterior ya no funciona.',
          TextDirection.ltr,
        );
      } else {
        setState(() {
          _errorMessage = response.message;
          _isLoading = false;
        });

        final announcement =
            response.accessibilityInfo?.announcement ?? response.message;
        SemanticsService.announce(announcement, TextDirection.ltr);
        _passwordFocusNode.requestFocus();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Error de conexión. Intente nuevamente.';
        _isLoading = false;
      });
    }
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
          label: 'Volver a inicio de sesión',
          button: true,
          child: IconButton(
            icon: const Icon(Icons.arrow_back_rounded, size: 28),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        title: Semantics(
          header: true,
          child: const Text('Nuevo Código de Acceso',
              style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ),
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: _success ? _buildSuccessView(theme) : _buildFormView(theme),
          ),
        ),
      ),
    );
  }

  // ── Vista de éxito ───────────────────────────────────────────────────────

  Widget _buildSuccessView(ThemeData theme) {
    return Column(
      children: [
        const SizedBox(height: 60),
        Semantics(
          label: 'Éxito',
          excludeSemantics: true,
          child: Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child:
                const Icon(Icons.mark_email_read_rounded, size: 52, color: Colors.green),
          ),
        ),
        const SizedBox(height: 32),
        Semantics(
          header: true,
          label: '¡Código enviado exitosamente!',
          child: Text(
            '¡Código enviado!',
            style: theme.textTheme.titleLarge?.copyWith(
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 20),
        Semantics(
          label:
              'Revise su bandeja de entrada. El nuevo código fue enviado a su email. '
              'El código anterior ya no funciona. Use el nuevo código para ingresar.',
          child: Text(
            'Revise su bandeja de entrada.\n\n'
            'Su nuevo código de 6 dígitos fue enviado al email registrado.\n\n'
            'El código anterior ya no funciona. Use el nuevo código para ingresar a la aplicación.',
            style: theme.textTheme.bodyLarge?.copyWith(
              fontSize: 16,
              height: 1.6,
              color: theme.colorScheme.onSurface.withOpacity(0.75),
            ),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 48),
        Semantics(
          label: 'Botón: Ir a ingresar mi código',
          button: true,
          child: Material(
            color: theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              onTap: () => Navigator.pop(context),
              borderRadius: BorderRadius.circular(20),
              child: SizedBox(
                width: double.infinity,
                height: 72,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    Icon(Icons.vpn_key_rounded, size: 28, color: Colors.white),
                    SizedBox(width: 16),
                    Text(
                      'Ingresar mi código',
                      style: TextStyle(
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
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  // ── Vista del formulario ─────────────────────────────────────────────────

  Widget _buildFormView(ThemeData theme) {
    return Column(
      children: [
        const SizedBox(height: 32),

        // ── ÍCONO ──────────────────────────────────────────────────
        Semantics(
          excludeSemantics: true,
          child: Container(
            width: 90,
            height: 90,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.refresh_rounded,
                size: 44, color: theme.colorScheme.primary),
          ),
        ),

        const SizedBox(height: 28),

        // ── TÍTULO ────────────────────────────────────────────────
        Semantics(
          header: true,
          label: '¿Olvidó su código de acceso?',
          child: Text(
            '¿Olvidó su código?',
            style: theme.textTheme.titleLarge?.copyWith(
              fontSize: 26,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
        ),

        const SizedBox(height: 12),

        Semantics(
          label:
              'Ingrese su email y contraseña. Le enviaremos un nuevo código de acceso. '
              'El código anterior dejará de funcionar.',
          child: Text(
            'Verifique su identidad y le enviaremos\nun nuevo código de acceso.\n'
            'El código anterior dejará de funcionar.',
            style: theme.textTheme.bodyLarge?.copyWith(
              fontSize: 15,
              color: theme.colorScheme.onSurface.withOpacity(0.6),
              height: 1.6,
            ),
            textAlign: TextAlign.center,
          ),
        ),

        const SizedBox(height: 40),

        // ── EMAIL ─────────────────────────────────────────────────
        _buildTextField(
          theme: theme,
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

        // ── CONTRASEÑA ────────────────────────────────────────────
        _buildPasswordField(theme),

        // ── ERROR ─────────────────────────────────────────────────
        if (_errorMessage != null) ...[
          const SizedBox(height: 16),
          Semantics(
            liveRegion: true,
            label: 'Error: $_errorMessage',
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                      size: 20, color: theme.colorScheme.error),
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

        // ── BOTÓN ENVIAR ──────────────────────────────────────────
        Semantics(
          label: 'Botón: Enviar nuevo código a mi email',
          hint: 'Presione para verificar identidad y recibir nuevo código',
          button: true,
          child: Material(
            color: _isLoading
                ? theme.colorScheme.primary.withOpacity(0.5)
                : theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(20),
            elevation: _isLoading ? 0 : 2,
            child: InkWell(
              onTap: _isLoading ? null : _requestNewCode,
              borderRadius: BorderRadius.circular(20),
              child: SizedBox(
                width: double.infinity,
                height: 72,
                child: _isLoading
                    ? const Center(
                        child: SizedBox(
                          width: 32,
                          height: 32,
                          child: CircularProgressIndicator(
                            strokeWidth: 4,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        ),
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(Icons.send_rounded,
                              size: 28, color: Colors.white),
                          SizedBox(width: 16),
                          Text(
                            'Enviar nuevo código',
                            style: TextStyle(
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
          ),
        ),

        const SizedBox(height: 24),

      ],
    );
  }

  Widget _buildTextField({
    required ThemeData theme,
    required TextEditingController controller,
    required FocusNode focusNode,
    required String label,
    required String hint,
    required IconData icon,
    TextInputType? keyboardType,
    TextInputAction? textInputAction,
    void Function(String)? onSubmitted,
  }) {
    return Semantics(
      label: 'Campo de texto para $label',
      textField: true,
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
        ),
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
              fontSize: 18,
              color: theme.colorScheme.onSurface.withOpacity(0.3),
            ),
            prefixIcon: Icon(icon, size: 26, color: theme.colorScheme.primary),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.all(20),
          ),
          onSubmitted: onSubmitted,
        ),
      ),
    );
  }

  Widget _buildPasswordField(ThemeData theme) {
    return Semantics(
      label: 'Campo de contraseña',
      textField: true,
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
        ),
        child: TextField(
          controller: _passwordController,
          focusNode: _passwordFocusNode,
          obscureText: _obscurePassword,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            hintText: 'Tu contraseña',
            hintStyle: TextStyle(
              fontSize: 18,
              color: theme.colorScheme.onSurface.withOpacity(0.3),
            ),
            prefixIcon: Icon(Icons.lock_rounded,
                size: 26, color: theme.colorScheme.primary),
            suffixIcon: Semantics(
              label: _obscurePassword
                  ? 'Mostrar contraseña'
                  : 'Ocultar contraseña',
              button: true,
              child: IconButton(
                icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                  color: theme.colorScheme.onSurface.withOpacity(0.5),
                ),
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.all(20),
          ),
          onSubmitted: (_) => _requestNewCode(),
        ),
      ),
    );
  }
}