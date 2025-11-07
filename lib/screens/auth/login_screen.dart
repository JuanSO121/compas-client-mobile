// lib/screens/auth/login_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../main.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with TickerProviderStateMixin {
  final TextEditingController _phoneController = TextEditingController();
  final FocusNode _phoneFocusNode = FocusNode();

  bool _isLoading = false;
  bool _otpSent = false;
  String _phoneNumber = '';
  String? _errorMessage;
  int _resendCount = 0;

  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;
  late AnimationController _shakeController;
  late Animation<double> _shakeAnimation;

  @override
  void initState() {
    super.initState();
    
    // Animación de fade
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeInOut,
    );
    _fadeController.forward();

    // Animación de shake para errores
    _shakeController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _shakeAnimation = Tween<double>(begin: 0, end: 10).animate(
      CurvedAnimation(parent: _shakeController, curve: Curves.elasticIn),
    );

    // Listener para limpiar errores al escribir
    _phoneController.addListener(() {
      if (_errorMessage != null) {
        setState(() => _errorMessage = null);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      SemanticsService.announce(
        'Pantalla de inicio de sesión. Ingrese su número de teléfono o correo electrónico',
        TextDirection.ltr,
      );
    });
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _phoneFocusNode.dispose();
    _fadeController.dispose();
    _shakeController.dispose();
    super.dispose();
  }

  bool _validateInput(String input) {
    if (input.isEmpty) {
      return false;
    }

    // Validar si es email
    final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
    if (emailRegex.hasMatch(input)) {
      return true;
    }

    // Validar si es teléfono (números y símbolos básicos)
    final phoneRegex = RegExp(r'^[\d\s\+\-\(\)]+$');
    if (phoneRegex.hasMatch(input) && input.replaceAll(RegExp(r'\D'), '').length >= 7) {
      return true;
    }

    return false;
  }

  void _sendOTP() async {
    final phone = _phoneController.text.trim();

    if (phone.isEmpty) {
      setState(() => _errorMessage = 'Por favor ingrese su teléfono o email');
      _showAccessibleSnackBar(_errorMessage!, isError: true);
      _phoneFocusNode.requestFocus();
      _shakeController.forward(from: 0);
      return;
    }

    if (!_validateInput(phone)) {
      setState(() => _errorMessage = 'Formato inválido. Use email o teléfono válido');
      _showAccessibleSnackBar(_errorMessage!, isError: true);
      _phoneFocusNode.requestFocus();
      _shakeController.forward(from: 0);
      return;
    }

    setState(() {
      _isLoading = true;
      _phoneNumber = phone;
      _errorMessage = null;
    });

    // Simular envío de OTP
    await Future.delayed(const Duration(seconds: 2));

    if (!mounted) return;

    setState(() {
      _isLoading = false;
      _otpSent = true;
      _resendCount++;
    });

    HapticFeedback.heavyImpact();
    SemanticsService.announce(
      'Código enviado a $phone. ¿Recibiste el código?',
      TextDirection.ltr,
    );
    _showAccessibleSnackBar('✓ Código enviado a $phone');
  }

  void _confirmOTP() async {
    setState(() => _isLoading = true);

    await Future.delayed(const Duration(seconds: 1));

    if (!mounted) return;

    HapticFeedback.heavyImpact();
    SemanticsService.announce(
      'Sesión iniciada correctamente. Bienvenido',
      TextDirection.ltr,
    );
    _showAccessibleSnackBar('¡Bienvenido!');

    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const AccessibleVoiceControlScreen()),
    );

  }

  void _resendOTP() {
    setState(() => _otpSent = false);
    SemanticsService.announce(
      'Reenviar código. Intento ${_resendCount + 1}',
      TextDirection.ltr,
    );
    _sendOTP();
  }

  void _showAccessibleSnackBar(String message, {bool isError = false}) {
    SemanticsService.announce(message, TextDirection.ltr);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              isError ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
              color: Colors.white,
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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
          label: _otpSent ? 'Volver a ingresar teléfono' : 'Volver atrás',
          button: true,
          child: IconButton(
            icon: const Icon(Icons.arrow_back_rounded, size: 28),
            onPressed: () {
              if (_otpSent) {
                setState(() {
                  _otpSent = false;
                  _errorMessage = null;
                });
                SemanticsService.announce(
                  'Volver a ingresar teléfono o email',
                  TextDirection.ltr,
                );
              } else {
                Navigator.pop(context);
              }
            },
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
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              children: [
                const SizedBox(height: 40),

                // TÍTULO PRINCIPAL
                Semantics(
                  label: _otpSent 
                      ? '¿Recibiste el código de acceso?' 
                      : 'Ingrese su teléfono o correo para recibir un código',
                  child: Text(
                    _otpSent ? '¿Recibiste el código?' : 'Ingresa tu teléfono o correo',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),

                const SizedBox(height: 16),

                // SUBTÍTULO
                Semantics(
                  label: _otpSent
                      ? 'Revisa tu WhatsApp o mensajes de texto'
                      : 'Te enviaremos un código temporal por seguridad',
                  child: Text(
                    _otpSent ? 'Revisa tu WhatsApp o SMS' : 'Te enviaremos un código temporal',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontSize: 17,
                      color: theme.colorScheme.onSurface.withOpacity(0.6),
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),

                const SizedBox(height: 48),

                // CONTENIDO SEGÚN ESTADO
                Expanded(
                  child: _otpSent ? _buildOTPSentState(theme) : _buildPhoneInputState(theme),
                ),

                // INFORMACIÓN DE SEGURIDAD
                Semantics(
                  label: 'Información de seguridad: Usamos códigos temporales, no necesitas contraseña',
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
                            'Usamos códigos temporales por seguridad. No necesitas contraseña.',
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

  Widget _buildPhoneInputState(ThemeData theme) {
    return Column(
      children: [
        // CAMPO DE TELÉFONO CON ANIMACIÓN DE SHAKE
        AnimatedBuilder(
          animation: _shakeAnimation,
          builder: (context, child) {
            return Transform.translate(
              offset: Offset(_shakeAnimation.value, 0),
              child: child,
            );
          },
          child: Semantics(
            label: 'Campo de texto para teléfono o correo electrónico',
            textField: true,
            hint: 'Ingrese su número de teléfono o email',
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
                controller: _phoneController,
                focusNode: _phoneFocusNode,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.send,
                decoration: InputDecoration(
                  hintText: 'Email o +57 300 123 4567',
                  hintStyle: TextStyle(
                    fontSize: 20,
                    color: theme.colorScheme.onSurface.withOpacity(0.3),
                  ),
                  prefixIcon: Icon(
                    _errorMessage != null 
                        ? Icons.error_outline_rounded 
                        : Icons.alternate_email_rounded,
                    size: 28,
                    color: _errorMessage != null 
                        ? theme.colorScheme.error 
                        : theme.colorScheme.primary,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.all(24),
                ),
                onSubmitted: (_) => _sendOTP(),
              ),
            ),
          ),
        ),

        // MENSAJE DE ERROR
        if (_errorMessage != null) ...[
          const SizedBox(height: 16),
          Semantics(
            label: 'Error: $_errorMessage',
            liveRegion: true,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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

        // BOTÓN ENVIAR CÓDIGO
        Semantics(
          label: 'Botón: Enviar código de acceso',
          hint: 'Presione para recibir el código temporal en su teléfono o email',
          button: true,
          child: _buildActionButton(
            label: 'Enviar Código',
            icon: Icons.send_rounded,
            onPressed: _isLoading ? null : _sendOTP,
            isLoading: _isLoading,
          ),
        ),

        const Spacer(),
      ],
    );
  }

  Widget _buildOTPSentState(ThemeData theme) {
    return Column(
      children: [
        // CONFIRMACIÓN VISUAL
        Semantics(
          label: 'Código enviado exitosamente a $_phoneNumber',
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: theme.colorScheme.secondary.withOpacity(0.4),
                width: 3,
              ),
            ),
            child: Column(
              children: [
                Icon(
                  Icons.mark_email_read_rounded,
                  size: 56,
                  color: theme.colorScheme.secondary,
                ),
                const SizedBox(height: 16),
                Text(
                  'Código enviado a:',
                  style: TextStyle(
                    fontSize: 16,
                    color: theme.colorScheme.onSurface.withOpacity(0.7),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _phoneNumber,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.secondary,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 40),

        // BOTÓN CONFIRMAR
        Semantics(
          label: 'Botón: Sí, usar código recibido',
          hint: 'Presione para confirmar y acceder a su cuenta',
          button: true,
          child: _buildActionButton(
            label: 'Sí, Usar Código',
            icon: Icons.check_circle_rounded,
            onPressed: _isLoading ? null : _confirmOTP,
            isLoading: _isLoading,
          ),
        ),

        const SizedBox(height: 20),

        // BOTÓN REENVIAR
        Semantics(
          label: 'Botón: Reenviar código',
          hint: 'Presione si no recibió el código',
          button: true,
          child: TextButton.icon(
            onPressed: _isLoading ? null : _resendOTP,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              backgroundColor: theme.cardColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: theme.colorScheme.primary.withOpacity(0.3),
                  width: 2,
                ),
              ),
            ),
            icon: Icon(
              Icons.refresh_rounded,
              size: 24,
              color: theme.colorScheme.primary,
            ),
            label: Text(
              'Reenviar Código',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ),

        if (_resendCount > 1) ...[
          const SizedBox(height: 16),
          Semantics(
            label: 'Ha reenviado el código $_resendCount veces',
            child: Text(
              'Código reenviado ${_resendCount - 1} ${_resendCount == 2 ? "vez" : "veces"}',
              style: TextStyle(
                fontSize: 14,
                color: theme.colorScheme.onSurface.withOpacity(0.5),
              ),
            ),
          ),
        ],

        const Spacer(),
      ],
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