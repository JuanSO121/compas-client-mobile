// lib/screens/auth/register_screen_integrated.dart
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import '../../services/auth_service.dart';
import '../../utils/password_validator.dart';
import 'login_screen_integrated.dart';

class RegisterScreenIntegrated extends StatefulWidget {
  const RegisterScreenIntegrated({super.key});

  @override
  State<RegisterScreenIntegrated> createState() => _RegisterScreenIntegratedState();
}

class _RegisterScreenIntegratedState extends State<RegisterScreenIntegrated>
    with TickerProviderStateMixin {
  int _currentStep = 0;

  // Controllers
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();
  final TextEditingController _firstNameController = TextEditingController();
  final TextEditingController _lastNameController = TextEditingController();

  // Focus nodes
  final FocusNode _emailFocusNode = FocusNode();
  final FocusNode _passwordFocusNode = FocusNode();
  final FocusNode _confirmPasswordFocusNode = FocusNode();
  final FocusNode _firstNameFocusNode = FocusNode();
  final FocusNode _lastNameFocusNode = FocusNode();

  // Service
  final AuthService _authService = AuthService();

  // State
  bool _isLoading = false;
  String? _errorMessage;
  String _visualImpairmentLevel = 'none';
  bool _screenReaderUser = false;

  // Validación de contraseña
  PasswordValidationResult? _passwordValidation;
  bool _showPasswordRequirements = false;

  // Animations
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;
  late AnimationController _shakeController;
  late Animation<double> _shakeAnimation;
  late AnimationController _progressController;
  late Animation<double> _progressAnimation;

  @override
  void initState() {
    super.initState();

    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(parent: _fadeController, curve: Curves.easeInOut);
    _fadeController.forward();

    _shakeController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _shakeAnimation = Tween<double>(begin: 0, end: 10).animate(
      CurvedAnimation(parent: _shakeController, curve: Curves.elasticIn),
    );

    _progressController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _progressAnimation = CurvedAnimation(
      parent: _progressController,
      curve: Curves.easeInOut,
    );

    // Listeners para limpiar errores
    _emailController.addListener(() {
      if (_errorMessage != null && _currentStep == 0) {
        setState(() => _errorMessage = null);
      }
    });

    _passwordController.addListener(() {
      if (_currentStep == 1) {
        setState(() {
          _errorMessage = null;
          _passwordValidation = PasswordValidator.validate(_passwordController.text);
        });
      }
    });

    _confirmPasswordController.addListener(() {
      if (_errorMessage != null && _currentStep == 1) {
        setState(() => _errorMessage = null);
      }
    });

    _firstNameController.addListener(() {
      if (_errorMessage != null && _currentStep == 2) {
        setState(() => _errorMessage = null);
      }
      if (_currentStep == 2) setState(() {});
    });

    _lastNameController.addListener(() {
      if (_errorMessage != null && _currentStep == 2) {
        setState(() => _errorMessage = null);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      SemanticsService.announce(
        'Crear cuenta nueva. Paso 1 de 3: Ingrese su correo electrónico',
        TextDirection.ltr,
      );
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
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
      setState(() => _errorMessage = 'Por favor ingrese su correo electrónico');
      _showAccessibleSnackBar(_errorMessage!, isError: true);
      _emailFocusNode.requestFocus();
      _shakeController.forward(from: 0);
      return;
    }

    // Validación básica de email
    final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
    if (!emailRegex.hasMatch(email)) {
      setState(() => _errorMessage = 'Formato de email inválido');
      _showAccessibleSnackBar(_errorMessage!, isError: true);
      _emailFocusNode.requestFocus();
      _shakeController.forward(from: 0);
      return;
    }

    setState(() {
      _currentStep = 1;
      _errorMessage = null;
      _showPasswordRequirements = true;
    });

    _progressController.animateTo(0.5);

    HapticFeedback.lightImpact();
    SemanticsService.announce(
      'Paso 2 de 3: Cree una contraseña segura con mayúsculas, minúsculas, números y símbolos',
      TextDirection.ltr,
    );

    Future.delayed(const Duration(milliseconds: 300), () {
      _passwordFocusNode.requestFocus();
    });
  }

  void _validateAndMoveToStep2() {
    final password = _passwordController.text;
    final confirmPassword = _confirmPasswordController.text;

    // Validar que no estén vacíos
    if (password.isEmpty || confirmPassword.isEmpty) {
      setState(() => _errorMessage = 'Por favor complete ambos campos de contraseña');
      _showAccessibleSnackBar(_errorMessage!, isError: true);
      if (password.isEmpty) {
        _passwordFocusNode.requestFocus();
      } else {
        _confirmPasswordFocusNode.requestFocus();
      }
      _shakeController.forward(from: 0);
      return;
    }

    // Validar fortaleza de contraseña
    final validation = PasswordValidator.validate(password);
    if (!validation.isValid) {
      setState(() {
        _errorMessage = validation.message;
        _passwordValidation = validation;
      });

      // Anuncio accesible con todas las sugerencias
      final announcement = '${validation.message}. ${validation.suggestions.join('. ')}';
      SemanticsService.announce(announcement, TextDirection.ltr);
      _showAccessibleSnackBar(_errorMessage!, isError: true);
      _passwordFocusNode.requestFocus();
      _shakeController.forward(from: 0);
      return;
    }

    // Validar que coincidan
    final matchError = PasswordValidator.validatePasswordMatch(password, confirmPassword);
    if (matchError != null) {
      setState(() => _errorMessage = matchError);
      _showAccessibleSnackBar(_errorMessage!, isError: true);
      _confirmPasswordFocusNode.requestFocus();
      _shakeController.forward(from: 0);
      return;
    }

    setState(() {
      _currentStep = 2;
      _errorMessage = null;
      _showPasswordRequirements = false;
    });

    _progressController.animateTo(1.0);

    HapticFeedback.lightImpact();
    SemanticsService.announce(
      'Paso 3 de 3: Ingrese su nombre',
      TextDirection.ltr,
    );

    Future.delayed(const Duration(milliseconds: 300), () {
      _firstNameFocusNode.requestFocus();
    });
  }

  void _createAccount() async {
    final firstName = _firstNameController.text.trim();
    final lastName = _lastNameController.text.trim();

    if (firstName.isEmpty) {
      setState(() => _errorMessage = 'Por favor ingrese su nombre');
      _showAccessibleSnackBar(_errorMessage!, isError: true);
      _firstNameFocusNode.requestFocus();
      _shakeController.forward(from: 0);
      return;
    }

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
        // Registro exitoso
        HapticFeedback.heavyImpact();

        final announcement = response.accessibilityInfo?.announcement ??
            'Cuenta creada exitosamente. Revise su email.';

        SemanticsService.announce(announcement, TextDirection.ltr);
        _showAccessibleSnackBar(
          '¡Cuenta creada! ${response.data?['email_sent'] == true ? "Revise su email" : ""}',
        );

        await Future.delayed(const Duration(milliseconds: 1500));
        if (!mounted) return;

        // Navegar al login
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const LoginScreenIntegrated()),
        );
      } else {
        // Error en registro
        setState(() {
          _errorMessage = response.message;
          _isLoading = false;
        });

        final announcement = response.accessibilityInfo?.announcement ??
            response.message;

        SemanticsService.announce(announcement, TextDirection.ltr);
        _showAccessibleSnackBar(_errorMessage!, isError: true);
        _shakeController.forward(from: 0);

        // Determinar a qué paso volver según el error
        if (response.errors != null && response.errors!.isNotEmpty) {
          final firstError = response.errors!.first;

          if (firstError.field == 'email') {
            _goToStep(0);
            _emailFocusNode.requestFocus();
          } else if (firstError.field == 'password' || firstError.field == 'confirm_password') {
            _goToStep(1);
            _passwordFocusNode.requestFocus();
          } else {
            _firstNameFocusNode.requestFocus();
          }
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

  void _goToStep(int step) {
    setState(() {
      _currentStep = step;
      _errorMessage = null;
      _showPasswordRequirements = (step == 1);
    });
    _progressController.animateTo(step / 2);
  }

  void _previousStep() {
    if (_currentStep == 0) {
      Navigator.pop(context);
    } else {
      setState(() {
        _currentStep--;
        _errorMessage = null;
        _showPasswordRequirements = (_currentStep == 1);
      });
      _progressController.animateTo(_currentStep / 2);

      final stepName = _currentStep == 0 ? 'email' : 'contraseña';
      SemanticsService.announce(
        'Paso ${_currentStep + 1} de 3: Ingrese su $stepName',
        TextDirection.ltr,
      );
    }
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
          label: _currentStep == 0 ? 'Volver atrás' : 'Paso anterior',
          button: true,
          child: IconButton(
            icon: const Icon(Icons.arrow_back_rounded, size: 28),
            onPressed: _isLoading ? null : _previousStep,
          ),
        ),
        title: Semantics(
          header: true,
          label: 'Crear Cuenta',
          child: const Text(
            'Crear Cuenta',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ),
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  children: [
                    const SizedBox(height: 24),
                    _buildProgressIndicator(theme),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
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
                      ? 'Botón: Crear mi cuenta'
                      : 'Botón: Continuar al siguiente paso',
                  hint: _currentStep == 2
                      ? 'Presione para finalizar registro'
                      : 'Presione para ir al paso ${_currentStep + 2}',
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

  // ... [Los métodos _buildProgressIndicator y _buildEmailStep permanecen igual]

  Widget _buildPasswordStep(ThemeData theme) {
    return Column(
      children: [
        Semantics(
          label: 'Paso 2: Crea una contraseña segura',
          child: Text(
            'Crea tu contraseña',
            style: theme.textTheme.titleLarge?.copyWith(
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 16),
        Semantics(
          label: 'Debe incluir mayúsculas, minúsculas, números y símbolos especiales',
          child: Text(
            'Incluye mayúsculas, minúsculas, números y símbolos',
            style: theme.textTheme.bodyLarge?.copyWith(
              fontSize: 17,
              color: theme.colorScheme.onSurface.withOpacity(0.6),
            ),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 40),

        // Campo de contraseña
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

        // Indicador de fortaleza de contraseña
        if (_passwordController.text.isNotEmpty && _passwordValidation != null) ...[
          const SizedBox(height: 16),
          _buildPasswordStrengthIndicator(theme),
        ],

        const SizedBox(height: 20),

        // Campo de confirmar contraseña
        _buildTextField(
          controller: _confirmPasswordController,
          focusNode: _confirmPasswordFocusNode,
          label: 'Confirmar contraseña',
          hint: 'Repite tu contraseña',
          icon: Icons.lock_outline_rounded,
          obscureText: true,
          textInputAction: TextInputAction.next,
          onSubmitted: (_) => _nextStep(),
        ),

        // Requisitos de contraseña
        if (_showPasswordRequirements) ...[
          const SizedBox(height: 24),
          _buildPasswordRequirements(theme),
        ],

        if (_errorMessage != null) ...[
          const SizedBox(height: 16),
          _buildErrorMessage(theme),
        ],
      ],
    );
  }

  Widget _buildPasswordStrengthIndicator(ThemeData theme) {
    final validation = _passwordValidation!;
    final strengthColor = _getStrengthColor(theme, validation.strengthScore);
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
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation<Color>(strengthColor),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Icon(
                _getStrengthIcon(validation.strengthScore),
                color: strengthColor,
                size: 24,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            validation.strengthMessage,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: strengthColor,
            ),
          ),
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
            color: theme.colorScheme.outline.withOpacity(0.2),
            width: 2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.checklist_rounded,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Requisitos de seguridad:',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...List.generate(requirements.length, (index) {
              final requirement = requirements[index];
              final isMet = PasswordValidator.checkRequirement(password, index);

              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Semantics(
                  label: '${requirement.text}, ${isMet ? "cumplido" : "pendiente"}',
                  child: Row(
                    children: [
                      Icon(
                        isMet ? Icons.check_circle : Icons.radio_button_unchecked,
                        size: 18,
                        color: isMet
                            ? theme.colorScheme.secondary
                            : theme.colorScheme.onSurface.withOpacity(0.3),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          requirement.text,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: isMet ? FontWeight.w600 : FontWeight.normal,
                            color: isMet
                                ? theme.colorScheme.onSurface
                                : theme.colorScheme.onSurface.withOpacity(0.6),
                            decoration: isMet ? null : TextDecoration.none,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Color _getStrengthColor(ThemeData theme, int score) {
    if (score >= 5) return Colors.green;
    if (score >= 4) return Colors.lightGreen;
    if (score >= 3) return Colors.orange;
    if (score >= 2) return Colors.deepOrange;
    return theme.colorScheme.error;
  }

  IconData _getStrengthIcon(int score) {
    if (score >= 5) return Icons.verified_user_rounded;
    if (score >= 4) return Icons.shield_rounded;
    if (score >= 3) return Icons.warning_amber_rounded;
    if (score >= 2) return Icons.warning_rounded;
    return Icons.error_rounded;
  }

  // ... [Resto de métodos permanecen igual: _buildNameStep, _buildTextField, etc.]

  Widget _buildProgressIndicator(ThemeData theme) {
    return Semantics(
      label: 'Progreso: Paso ${_currentStep + 1} de 3',
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: _currentStep >= 1
                        ? theme.colorScheme.primary
                        : theme.colorScheme.primary.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: _currentStep >= 2
                        ? theme.colorScheme.primary
                        : theme.colorScheme.primary.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('1. Email', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: theme.colorScheme.primary)),
              Text('2. Contraseña', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _currentStep >= 1 ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.4))),
              Text('3. Nombre', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _currentStep >= 2 ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.4))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEmailStep(ThemeData theme) {
    return Column(
      children: [
        Semantics(
          label: 'Paso 1: Ingresa tu correo electrónico',
          child: Text('¿Cuál es tu email?', style: theme.textTheme.titleLarge?.copyWith(fontSize: 28, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
        ),
        const SizedBox(height: 16),
        Semantics(
          label: 'Te enviaremos un código de verificación',
          child: Text('Te enviaremos un código de verificación', style: theme.textTheme.bodyLarge?.copyWith(fontSize: 17, color: theme.colorScheme.onSurface.withOpacity(0.6)), textAlign: TextAlign.center),
        ),
        const SizedBox(height: 60),
        _buildTextField(controller: _emailController, focusNode: _emailFocusNode, label: 'Correo electrónico', hint: 'ejemplo@correo.com', icon: Icons.email_rounded, keyboardType: TextInputType.emailAddress, textInputAction: TextInputAction.next, onSubmitted: (_) => _nextStep()),
        if (_errorMessage != null) ...[const SizedBox(height: 16), _buildErrorMessage(theme)],
        const SizedBox(height: 40),
        _buildInfoBox(theme, icon: Icons.info_outline_rounded, text: 'Usaremos este email para enviarte actualizaciones importantes', color: theme.colorScheme.secondary),
      ],
    );
  }

  Widget _buildNameStep(ThemeData theme) {
    final hasText = _firstNameController.text.trim().isNotEmpty;

    return Column(
      children: [
        Semantics(
          label: 'Paso 3: Ingresa tu nombre',
          child: Text(
            '¿Cómo te llamas?',
            style: theme.textTheme.titleLarge?.copyWith(
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 16),
        Semantics(
          label: 'Ingresa el nombre con el que quieres que te llamemos',
          child: Text(
            'Así te llamaremos',
            style: theme.textTheme.bodyLarge?.copyWith(
              fontSize: 17,
              color: theme.colorScheme.onSurface.withOpacity(0.6),
            ),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 60),
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
        const SizedBox(height: 40),
        AnimatedOpacity(
          duration: const Duration(milliseconds: 300),
          opacity: hasText ? 1.0 : 0.0,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: theme.colorScheme.secondary.withOpacity(hasText ? 0.4 : 0.2),
                width: 2,
              ),
            ),
            child: hasText
                ? Semantics(
              label: 'Vista previa: Hola ${_firstNameController.text.trim()}',
              child: Row(
                children: [
                  Icon(
                    Icons.waving_hand_rounded,
                    size: 28,
                    color: theme.colorScheme.secondary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '¡Hola ${_firstNameController.text.trim()}!',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.secondary,
                      ),
                    ),
                  ),
                ],
              ),
            )
                : const SizedBox(height: 56),
          ),
        ),
        const SizedBox(height: 20),
        _buildInfoBox(
          theme,
          icon: Icons.check_circle_rounded,
          text: 'Cuenta asociada a: ${_emailController.text.trim()}',
          color: theme.colorScheme.primary,
        ),
      ],
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
    TextCapitalization textCapitalization = TextCapitalization.none,
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
            textCapitalization: textCapitalization,
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

  Widget _buildErrorMessage(ThemeData theme) {
    return Semantics(
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
    );
  }

  Widget _buildInfoBox(ThemeData theme, {
    required IconData icon,
    required String text,
    required Color color,
  }) {
    return Semantics(
      label: 'Información: $text',
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: color.withOpacity(0.3),
            width: 2,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ),
          ],
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