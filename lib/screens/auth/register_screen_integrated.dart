// lib/screens/auth/register_screen_integrated.dart
//
// ── Cambios TTS v1.0 ──────────────────────────────────────────────────────────
//
//  • initState: anuncia "Paso 1 de 3: email" al montar.
//  • _validateAndMoveToStep1/2: anuncia paso nuevo al avanzar.
//  • _createAccount:
//      - Éxito  → announceSuccess() y libera AuthTTSService antes de navegar.
//      - Error  → announceError() con detalle de campo fallido.
//  • _previousStep: anuncia "Paso anterior".
//  • _buildActionButton.onTap: anuncia "Verificando" / "Continuando".
//  • AppBar back button: anuncia la acción.
//  • Errores de validación inline: todos pasan por announceError().
//  • _buildPasswordStrengthIndicator: anuncia el nivel de fortaleza cuando
//    cambia (débil → media → fuerte) para guiar al usuario ciego.
//  • SemanticsService.announce() se mantiene en paralelo para TalkBack.
// ──────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import '../../services/auth_service.dart';
import '../../services/auth_tts_service.dart';
import '../../utils/password_validator.dart';
import 'login_screen_integrated.dart';

class RegisterScreenIntegrated extends StatefulWidget {
  const RegisterScreenIntegrated({super.key});

  @override
  State<RegisterScreenIntegrated> createState() =>
      _RegisterScreenIntegratedState();
}

class _RegisterScreenIntegratedState extends State<RegisterScreenIntegrated>
    with TickerProviderStateMixin {
  int _currentStep = 0;

  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
  TextEditingController();
  final TextEditingController _firstNameController = TextEditingController();
  final TextEditingController _lastNameController = TextEditingController();

  final FocusNode _emailFocusNode = FocusNode();
  final FocusNode _passwordFocusNode = FocusNode();
  final FocusNode _confirmPasswordFocusNode = FocusNode();
  final FocusNode _firstNameFocusNode = FocusNode();
  final FocusNode _lastNameFocusNode = FocusNode();

  final AuthService _authService = AuthService();

  // ✅ TTS
  final AuthTTSService _tts = AuthTTSService();

  bool _isLoading = false;
  String? _errorMessage;
  String _visualImpairmentLevel = 'none';
  bool _screenReaderUser = false;

  PasswordValidationResult? _passwordValidation;
  String? _lastAnnouncedStrength; // ✅ evitar repetir el mismo nivel de fortaleza

  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;
  late AnimationController _shakeController;
  late Animation<double> _shakeAnimation;
  late AnimationController _progressController;

  // ─────────────────────────────────────────────────────────────────────────────

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

    _progressController = AnimationController(
        duration: const Duration(milliseconds: 400), vsync: this);

    _emailController.addListener(() {
      if (_errorMessage != null && _currentStep == 0)
        setState(() => _errorMessage = null);
    });

    _passwordController.addListener(_onPasswordChanged);

    _confirmPasswordController.addListener(() {
      if (_errorMessage != null && _currentStep == 1)
        setState(() => _errorMessage = null);
    });

    _firstNameController.addListener(() {
      if (_errorMessage != null && _currentStep == 2)
        setState(() => _errorMessage = null);
    });

    _lastNameController.addListener(() {
      if (_errorMessage != null && _currentStep == 2)
        setState(() => _errorMessage = null);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _tts.initialize();
      await Future.delayed(const Duration(milliseconds: 350));
      await _tts.announceScreen(
        'Crear cuenta. Paso 1 de 3: ingrese su correo electrónico.',
      );
      SemanticsService.announce(
        'Crear cuenta. Paso 1 de 3: ingrese su correo electrónico.',
        TextDirection.ltr,
      );
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.removeListener(_onPasswordChanged);
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailFocusNode.dispose();
    _passwordFocusNode.dispose();
    _confirmPasswordFocusNode.dispose();
    _firstNameFocusNode.dispose();
    _lastNameFocusNode.dispose();
    _fadeController.dispose();
    _shakeController.dispose();
    _progressController.dispose();
    super.dispose();
  }

  // ── Password listener ──────────────────────────────────────────────────────

  void _onPasswordChanged() {
    if (_currentStep != 1) return;

    final text = _passwordController.text;
    final validation = PasswordValidator.validate(text);

    setState(() {
      if (_errorMessage != null) _errorMessage = null;
      _passwordValidation = validation;
    });

    // ✅ Anunciar cambio de nivel de fortaleza (no repetir el mismo nivel)
    if (text.isNotEmpty) {
      final level = validation.strengthLevel;
      if (level != _lastAnnouncedStrength) {
        _lastAnnouncedStrength = level;
        _tts.announceButton('Contraseña: $level');
      }
    }
  }

  // ── Navegación de pasos ────────────────────────────────────────────────────

  void _nextStep() {
    if (_currentStep == 0) {
      _validateAndMoveToStep1();
    } else if (_currentStep == 1) {
      _validateAndMoveToStep2();
    } else {
      _createAccount();
    }
  }

  void _validateAndMoveToStep1() {
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

    final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
    if (!emailRegex.hasMatch(email)) {
      const msg = 'Formato de email inválido';
      setState(() => _errorMessage = msg);
      _emailFocusNode.requestFocus();
      _shakeController.forward(from: 0);
      _tts.announceError(msg);
      SemanticsService.announce(msg, TextDirection.ltr);
      return;
    }

    setState(() {
      _currentStep = 1;
      _errorMessage = null;
    });
    _progressController.animateTo(0.5);
    HapticFeedback.lightImpact();

    const announcement = 'Paso 2 de 3: cree su contraseña. '
        'Debe tener mayúsculas, minúsculas, números y símbolos.';
    _tts.announceScreen(announcement);
    SemanticsService.announce(announcement, TextDirection.ltr);

    Future.delayed(
        const Duration(milliseconds: 300), _passwordFocusNode.requestFocus);
  }

  void _validateAndMoveToStep2() {
    final password = _passwordController.text;
    final confirm = _confirmPasswordController.text;

    if (password.isEmpty || confirm.isEmpty) {
      const msg = 'Complete ambos campos de contraseña';
      setState(() => _errorMessage = msg);
      (password.isEmpty ? _passwordFocusNode : _confirmPasswordFocusNode)
          .requestFocus();
      _shakeController.forward(from: 0);
      _tts.announceError(msg);
      SemanticsService.announce(msg, TextDirection.ltr);
      return;
    }

    final validation = PasswordValidator.validate(password);
    if (!validation.isValid) {
      final msg =
          '${validation.message}. ${validation.suggestions.join('. ')}';
      setState(() {
        _errorMessage = validation.message;
        _passwordValidation = validation;
      });
      _tts.announceError(msg);
      SemanticsService.announce(msg, TextDirection.ltr);
      _passwordFocusNode.requestFocus();
      _shakeController.forward(from: 0);
      return;
    }

    final matchError =
    PasswordValidator.validatePasswordMatch(password, confirm);
    if (matchError != null) {
      setState(() => _errorMessage = matchError);
      _confirmPasswordFocusNode.requestFocus();
      _shakeController.forward(from: 0);
      _tts.announceError(matchError);
      SemanticsService.announce(matchError, TextDirection.ltr);
      return;
    }

    setState(() {
      _currentStep = 2;
      _errorMessage = null;
    });
    _progressController.animateTo(1.0);
    HapticFeedback.lightImpact();

    const announcement =
        'Paso 3 de 3: ingrese su nombre. El apellido es opcional.';
    _tts.announceScreen(announcement);
    SemanticsService.announce(announcement, TextDirection.ltr);

    Future.delayed(
        const Duration(milliseconds: 300), _firstNameFocusNode.requestFocus);
  }

  void _createAccount() async {
    final firstName = _firstNameController.text.trim();
    final lastName = _lastNameController.text.trim();

    if (firstName.isEmpty) {
      const msg = 'Ingrese su nombre';
      setState(() => _errorMessage = msg);
      _firstNameFocusNode.requestFocus();
      _shakeController.forward(from: 0);
      _tts.announceError(msg);
      SemanticsService.announce(msg, TextDirection.ltr);
      return;
    }

    // ✅ Feedback antes de la petición
    await _tts.announceButton('Creando su cuenta. Por favor espere.');

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await _authService.register(
        email: _emailController.text.trim(),
        password: _passwordController.text,
        confirmPassword: _confirmPasswordController.text,
        firstName: firstName,
        lastName: lastName.isNotEmpty ? lastName : null,
        visualImpairmentLevel: _visualImpairmentLevel,
        screenReaderUser: _screenReaderUser,
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

        // ✅ Liberar AuthTTSService — LoginScreen lo re-inicializará si es necesario
        _tts.dispose();

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const LoginScreenIntegrated()),
        );
      } else {
        setState(() {
          _errorMessage = response.message;
          _isLoading = false;
        });

        final announcement =
            response.accessibilityInfo?.announcement ?? response.message;
        await _tts.announceError(announcement);
        SemanticsService.announce(announcement, TextDirection.ltr);
        _showSnackBar(_errorMessage!, isError: true);
        _shakeController.forward(from: 0);

        // Ir al paso del campo con error
        if (response.errors != null && response.errors!.isNotEmpty) {
          final firstError = response.errors!.first;
          if (firstError.field == 'email') {
            _goToStep(0);
            _emailFocusNode.requestFocus();
          } else if (firstError.field == 'password' ||
              firstError.field == 'confirm_password') {
            _goToStep(1);
            _passwordFocusNode.requestFocus();
          } else {
            _firstNameFocusNode.requestFocus();
          }
        }
      }
    } catch (e) {
      if (!mounted) return;
      const msg = 'Error de conexión. Intente nuevamente.';
      setState(() {
        _errorMessage = msg;
        _isLoading = false;
      });
      await _tts.announceError(msg);
      _showSnackBar(msg, isError: true);
      _shakeController.forward(from: 0);
    }
  }

  void _goToStep(int step) {
    setState(() {
      _currentStep = step;
      _errorMessage = null;
    });
    _progressController.animateTo(step / 2);
  }

  void _previousStep() {
    if (_currentStep == 0) {
      _tts.announceButton('Volver');
      Navigator.pop(context);
    } else {
      setState(() {
        _currentStep--;
        _errorMessage = null;
      });
      _progressController.animateTo(_currentStep / 2);
      final stepName = _currentStep == 0 ? 'correo electrónico' : 'contraseña';
      final announcement = 'Paso ${_currentStep + 1}: $stepName.';
      _tts.announceButton(announcement);
      SemanticsService.announce(announcement, TextDirection.ltr);
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
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(message,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        backgroundColor: isError
            ? Theme.of(context).colorScheme.error
            : Theme.of(context).colorScheme.secondary,
        behavior: SnackBarBehavior.floating,
        shape:
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
        duration: Duration(seconds: isError ? 4 : 2),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Semantics(
          label: _currentStep == 0 ? 'Volver atrás' : 'Paso anterior',
          button: true,
          child: IconButton(
            icon: const Icon(Icons.arrow_back_rounded, size: 28),
            onPressed: _isLoading ? null : _previousStep,
          ),
        ),
        title: Semantics(
          header: true,
          child: const Text('Crear Cuenta',
              style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ),
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 24, 32, 0),
                child: _buildProgressIndicator(theme),
              ),
              const SizedBox(height: 32),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: _currentStep == 0
                      ? _buildEmailStep(theme)
                      : _currentStep == 1
                      ? _buildPasswordStep(theme)
                      : _buildNameStep(theme),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(32),
                child: Semantics(
                  label: _currentStep == 2
                      ? 'Crear mi cuenta'
                      : 'Continuar al siguiente paso',
                  button: true,
                  child: _buildActionButton(
                    label: _currentStep == 2 ? 'Crear Cuenta' : 'Continuar',
                    icon: _currentStep == 2
                        ? Icons.check_circle_rounded
                        : Icons.arrow_forward_rounded,
                    onPressed: _isLoading ? null : _nextStep,
                    isLoading: _isLoading,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Indicador de progreso ─────────────────────────────────────────────────

  Widget _buildProgressIndicator(ThemeData theme) {
    return Semantics(
      label: 'Paso ${_currentStep + 1} de 3',
      child: Column(
        children: [
          Row(
            children: List.generate(3, (i) {
              final filled = _currentStep >= i;
              return Expanded(
                child: Container(
                  height: 6,
                  margin: EdgeInsets.only(right: i < 2 ? 8 : 0),
                  decoration: BoxDecoration(
                    color: filled
                        ? theme.colorScheme.primary
                        : theme.colorScheme.primary.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _stepLabel(theme, '1. Email', 0),
              _stepLabel(theme, '2. Contraseña', 1),
              _stepLabel(theme, '3. Nombre', 2),
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
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: active
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurface.withOpacity(0.35),
      ),
    );
  }

  // ─── Paso 1: Email ─────────────────────────────────────────────────────────

  Widget _buildEmailStep(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Semantics(
          header: true,
          child: Text('¿Cuál es tu email?',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontSize: 26, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center),
        ),
        const SizedBox(height: 10),
        Text(
          'Le enviaremos su código de acceso.',
          style: theme.textTheme.bodyLarge?.copyWith(
              fontSize: 16,
              color: theme.colorScheme.onSurface.withOpacity(0.6)),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 40),
        _buildTextField(
          controller: _emailController,
          focusNode: _emailFocusNode,
          label: 'Correo electrónico',
          hint: 'ejemplo@correo.com',
          icon: Icons.email_rounded,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          onSubmitted: (_) => _nextStep(),
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: 16),
          _buildErrorMessage(theme),
        ],
      ],
    );
  }

  // ─── Paso 2: Contraseña ────────────────────────────────────────────────────

  Widget _buildPasswordStep(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Semantics(
          header: true,
          child: Text('Crea tu contraseña',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontSize: 26, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center),
        ),
        const SizedBox(height: 10),
        Text(
          'Debe tener mayúsculas, minúsculas, números y símbolos.',
          style: theme.textTheme.bodyLarge?.copyWith(
              fontSize: 16,
              color: theme.colorScheme.onSurface.withOpacity(0.6)),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 40),
        _buildTextField(
          controller: _passwordController,
          focusNode: _passwordFocusNode,
          label: 'Contraseña',
          hint: 'Tu contraseña segura',
          icon: Icons.lock_rounded,
          obscureText: true,
          textInputAction: TextInputAction.next,
          onSubmitted: (_) => _confirmPasswordFocusNode.requestFocus(),
        ),
        if (_passwordController.text.isNotEmpty &&
            _passwordValidation != null) ...[
          const SizedBox(height: 14),
          _buildPasswordStrengthIndicator(theme),
        ],
        const SizedBox(height: 20),
        _buildTextField(
          controller: _confirmPasswordController,
          focusNode: _confirmPasswordFocusNode,
          label: 'Confirmar contraseña',
          hint: 'Repite tu contraseña',
          icon: Icons.lock_outline_rounded,
          obscureText: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _nextStep(),
        ),
        const SizedBox(height: 20),
        _buildPasswordRequirements(theme),
        if (_errorMessage != null) ...[
          const SizedBox(height: 16),
          _buildErrorMessage(theme),
        ],
      ],
    );
  }

  Widget _buildPasswordStrengthIndicator(ThemeData theme) {
    final validation = _passwordValidation!;
    final color = _strengthColor(theme, validation.strengthScore);
    final progress = (validation.strengthScore / 6).clamp(0.0, 1.0);

    return Semantics(
      label: 'Fortaleza de contraseña: ${validation.strengthLevel}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 8,
                    backgroundColor:
                    theme.colorScheme.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Icon(_strengthIcon(validation.strengthScore),
                  color: color, size: 22),
            ],
          ),
          const SizedBox(height: 6),
          Text(validation.strengthMessage,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: color)),
        ],
      ),
    );
  }

  Widget _buildPasswordRequirements(ThemeData theme) {
    final requirements = PasswordValidator.getRequirements();
    final password = _passwordController.text;

    return Semantics(
      label: 'Requisitos de contraseña',
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: theme.colorScheme.outline.withOpacity(0.2), width: 2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.checklist_rounded,
                  size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text('Requisitos:',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface)),
            ]),
            const SizedBox(height: 10),
            ...List.generate(requirements.length, (index) {
              final req = requirements[index];
              final met =
              PasswordValidator.checkRequirement(password, index);
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Semantics(
                  label: '${req.text}, ${met ? "cumplido" : "pendiente"}',
                  child: Row(children: [
                    Icon(
                      met
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      size: 16,
                      color: met
                          ? theme.colorScheme.secondary
                          : theme.colorScheme.onSurface.withOpacity(0.3),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(req.text,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: met
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                              color: met
                                  ? theme.colorScheme.onSurface
                                  : theme.colorScheme.onSurface
                                  .withOpacity(0.55))),
                    ),
                  ]),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Color _strengthColor(ThemeData theme, int score) {
    if (score >= 5) return Colors.green;
    if (score >= 4) return Colors.lightGreen;
    if (score >= 3) return Colors.orange;
    if (score >= 2) return Colors.deepOrange;
    return theme.colorScheme.error;
  }

  IconData _strengthIcon(int score) {
    if (score >= 5) return Icons.verified_user_rounded;
    if (score >= 4) return Icons.shield_rounded;
    if (score >= 3) return Icons.warning_amber_rounded;
    return Icons.error_rounded;
  }

  // ─── Paso 3: Nombre ────────────────────────────────────────────────────────

  Widget _buildNameStep(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Semantics(
          header: true,
          child: Text('¿Cómo te llamas?',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontSize: 26, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center),
        ),
        const SizedBox(height: 10),
        Text(
          'Así le llamaremos dentro de la aplicación.',
          style: theme.textTheme.bodyLarge?.copyWith(
              fontSize: 16,
              color: theme.colorScheme.onSurface.withOpacity(0.6)),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 40),
        _buildTextField(
          controller: _firstNameController,
          focusNode: _firstNameFocusNode,
          label: 'Nombre',
          hint: 'Tu nombre',
          icon: Icons.person_rounded,
          keyboardType: TextInputType.name,
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.words,
          onSubmitted: (_) => _lastNameFocusNode.requestFocus(),
        ),
        const SizedBox(height: 20),
        _buildTextField(
          controller: _lastNameController,
          focusNode: _lastNameFocusNode,
          label: 'Apellido (opcional)',
          hint: 'Tu apellido',
          icon: Icons.person_outline_rounded,
          keyboardType: TextInputType.name,
          textInputAction: TextInputAction.done,
          textCapitalization: TextCapitalization.words,
          onSubmitted: (_) => _nextStep(),
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: 16),
          _buildErrorMessage(theme),
        ],
      ],
    );
  }

  // ─── Widgets compartidos ───────────────────────────────────────────────────

  Widget _buildTextField({
    required TextEditingController controller,
    required FocusNode focusNode,
    required String label,
    required String hint,
    required IconData icon,
    bool obscureText = false,
    TextInputType? keyboardType,
    TextInputAction? textInputAction,
    TextCapitalization textCapitalization = TextCapitalization.none,
    void Function(String)? onSubmitted,
  }) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: _shakeAnimation,
      builder: (context, child) => Transform.translate(
          offset: Offset(_shakeAnimation.value, 0), child: child),
      child: Semantics(
        label: label,
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
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 12,
                  offset: const Offset(0, 4)),
            ],
          ),
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            obscureText: obscureText,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            keyboardType: keyboardType,
            textInputAction: textInputAction,
            textCapitalization: textCapitalization,
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(
                  fontSize: 18,
                  color: theme.colorScheme.onSurface.withOpacity(0.3)),
              prefixIcon:
              Icon(icon, size: 26, color: theme.colorScheme.primary),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.all(20),
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
      label: 'Error: $_errorMessage',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.error.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: theme.colorScheme.error.withOpacity(0.3), width: 2),
        ),
        child: Row(children: [
          Icon(Icons.warning_rounded,
              size: 20, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(_errorMessage!,
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.error)),
          ),
        ]),
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
        child: SizedBox(
          width: double.infinity,
          height: 72,
          child: isLoading
              ? const Center(
            child: SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                  strokeWidth: 4,
                  valueColor:
                  AlwaysStoppedAnimation<Color>(Colors.white)),
            ),
          )
              : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 28, color: Colors.white),
            const SizedBox(width: 16),
            Text(label,
                style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 0.5)),
          ]),
        ),
      ),
    );
  }
}