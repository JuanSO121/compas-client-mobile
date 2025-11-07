// lib/screens/auth/register_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> with TickerProviderStateMixin {
  int _currentStep = 0;
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final FocusNode _phoneFocusNode = FocusNode();
  final FocusNode _nameFocusNode = FocusNode();

  bool _isLoading = false;
  String _phoneNumber = '';
  String _userName = '';
  String? _errorMessage;

  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;
  late AnimationController _shakeController;
  late Animation<double> _shakeAnimation;
  late AnimationController _progressController;
  late Animation<double> _progressAnimation;

  @override
  void initState() {
    super.initState();

    // Animación de fade
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(parent: _fadeController, curve: Curves.easeInOut);
    _fadeController.forward();

    // Animación de shake para errores
    _shakeController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _shakeAnimation = Tween<double>(begin: 0, end: 10).animate(
      CurvedAnimation(parent: _shakeController, curve: Curves.elasticIn),
    );

    // Animación de progreso
    _progressController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _progressAnimation = CurvedAnimation(
      parent: _progressController,
      curve: Curves.easeInOut,
    );

    // Listeners para limpiar errores
    _phoneController.addListener(() {
      if (_errorMessage != null && _currentStep == 0) {
        setState(() => _errorMessage = null);
      }
    });

    _nameController.addListener(() {
      if (_errorMessage != null && _currentStep == 1) {
        setState(() => _errorMessage = null);
      }
      // Actualizar preview del nombre en tiempo real
      if (_currentStep == 1) {
        setState(() {});
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      SemanticsService.announce(
        'Crear cuenta nueva. Paso 1 de 2: Ingrese su número de teléfono',
        TextDirection.ltr,
      );
    });
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _nameController.dispose();
    _phoneFocusNode.dispose();
    _nameFocusNode.dispose();
    _fadeController.dispose();
    _shakeController.dispose();
    _progressController.dispose();
    super.dispose();
  }

  bool _validatePhone(String phone) {
    if (phone.isEmpty) return false;

    // Validar email
    final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
    if (emailRegex.hasMatch(phone)) return true;

    // Validar teléfono
    final phoneRegex = RegExp(r'^[\d\s\+\-\(\)]+$');
    if (phoneRegex.hasMatch(phone) && phone.replaceAll(RegExp(r'\D'), '').length >= 7) {
      return true;
    }

    return false;
  }

  bool _validateName(String name) {
    if (name.isEmpty) return false;
    if (name.length < 2) return false;

    // Solo letras, espacios y algunos caracteres especiales
    final nameRegex = RegExp(r'^[a-zA-ZáéíóúÁÉÍÓÚñÑüÜ\s\-]+$');
    return nameRegex.hasMatch(name);
  }

  void _nextStep() {
    if (_currentStep == 0) {
      final phone = _phoneController.text.trim();

      if (phone.isEmpty) {
        setState(() => _errorMessage = 'Por favor ingrese su teléfono o email');
        _showAccessibleSnackBar(_errorMessage!, isError: true);
        _phoneFocusNode.requestFocus();
        _shakeController.forward(from: 0);
        return;
      }

      if (!_validatePhone(phone)) {
        setState(() => _errorMessage = 'Formato inválido. Use email o teléfono válido');
        _showAccessibleSnackBar(_errorMessage!, isError: true);
        _phoneFocusNode.requestFocus();
        _shakeController.forward(from: 0);
        return;
      }

      setState(() {
        _phoneNumber = phone;
        _currentStep = 1;
        _errorMessage = null;
      });

      // Animar progreso
      _progressController.forward();

      HapticFeedback.lightImpact();
      SemanticsService.announce(
        'Paso 2 de 2: ¿Cómo te gustaría que te llamemos?',
        TextDirection.ltr,
      );

      Future.delayed(const Duration(milliseconds: 300), () {
        _nameFocusNode.requestFocus();
      });
    } else {
      _createAccount();
    }
  }

  void _createAccount() async {
    final name = _nameController.text.trim();

    if (name.isEmpty) {
      setState(() => _errorMessage = 'Por favor ingrese su nombre');
      _showAccessibleSnackBar(_errorMessage!, isError: true);
      _nameFocusNode.requestFocus();
      _shakeController.forward(from: 0);
      return;
    }

    if (!_validateName(name)) {
      setState(() => _errorMessage = 'Nombre inválido. Solo letras y espacios');
      _showAccessibleSnackBar(_errorMessage!, isError: true);
      _nameFocusNode.requestFocus();
      _shakeController.forward(from: 0);
      return;
    }

    if (name.length < 2) {
      setState(() => _errorMessage = 'El nombre debe tener al menos 2 caracteres');
      _showAccessibleSnackBar(_errorMessage!, isError: true);
      _nameFocusNode.requestFocus();
      _shakeController.forward(from: 0);
      return;
    }

    setState(() {
      _isLoading = true;
      _userName = name;
      _errorMessage = null;
    });

    // Simular creación de cuenta
    await Future.delayed(const Duration(seconds: 2));

    if (!mounted) return;

    HapticFeedback.heavyImpact();
    SemanticsService.announce(
      'Cuenta creada exitosamente. Bienvenido $_userName',
      TextDirection.ltr,
    );
    _showAccessibleSnackBar('¡Cuenta creada! Bienvenido $_userName');

    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;

    Navigator.pop(context);
  }

  void _previousStep() {
    if (_currentStep == 0) {
      Navigator.pop(context);
    } else {
      setState(() {
        _currentStep = 0;
        _errorMessage = null;
      });
      _progressController.reverse();
      SemanticsService.announce(
        'Paso 1 de 2: Ingrese su teléfono',
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
            onPressed: _previousStep,
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
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              children: [
                const SizedBox(height: 24),

                // INDICADOR DE PROGRESO MEJORADO
                _buildProgressIndicator(theme),

                const SizedBox(height: 40),

                // CONTENIDO POR PASO
                Expanded(
                  child: _currentStep == 0
                      ? _buildPhoneStep(theme)
                      : _buildNameStep(theme),
                ),

                // BOTÓN DE ACCIÓN
                Semantics(
                  label: _currentStep == 0
                      ? 'Botón: Continuar al siguiente paso'
                      : 'Botón: Crear mi cuenta',
                  hint: _currentStep == 0
                      ? 'Presione para ir al paso 2'
                      : 'Presione para finalizar registro',
                  button: true,
                  child: _buildActionButton(
                    label: _currentStep == 0 ? 'Continuar' : 'Crear Cuenta',
                    icon: _currentStep == 0
                        ? Icons.arrow_forward_rounded
                        : Icons.check_circle_rounded,
                    onPressed: _isLoading ? null : _nextStep,
                    isLoading: _isLoading,
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

  Widget _buildProgressIndicator(ThemeData theme) {
    return Semantics(
      label: 'Progreso: Paso ${_currentStep + 1} de 2',
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
                child: AnimatedBuilder(
                  animation: _progressAnimation,
                  builder: (context, child) {
                    return Container(
                      height: 6,
                      decoration: BoxDecoration(
                        color: Color.lerp(
                          theme.colorScheme.primary.withOpacity(0.2),
                          theme.colorScheme.primary,
                          _progressAnimation.value,
                        ),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '1. Teléfono',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.primary,
                ),
              ),
              Text(
                '2. Nombre',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: _currentStep >= 1
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface.withOpacity(0.4),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPhoneStep(ThemeData theme) {
    return Column(
      children: [
        Semantics(
          label: 'Paso 1: Ingresa tu número de teléfono o correo electrónico',
          child: Text(
            '¿Cuál es tu número?',
            style: theme.textTheme.titleLarge?.copyWith(
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
        ),

        const SizedBox(height: 16),

        Semantics(
          label: 'Te enviaremos un código de verificación para confirmar tu identidad',
          child: Text(
            'Te enviaremos un código de verificación',
            style: theme.textTheme.bodyLarge?.copyWith(
              fontSize: 17,
              color: theme.colorScheme.onSurface.withOpacity(0.6),
            ),
            textAlign: TextAlign.center,
          ),
        ),

        const SizedBox(height: 60),

        // CAMPO DE TELÉFONO CON ANIMACIÓN
        AnimatedBuilder(
          animation: _shakeAnimation,
          builder: (context, child) {
            return Transform.translate(
              offset: Offset(_shakeAnimation.value, 0),
              child: child,
            );
          },
          child: Semantics(
            label: 'Campo de texto para número de teléfono o email',
            textField: true,
            hint: 'Ingrese su número de teléfono o correo electrónico',
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
                textInputAction: TextInputAction.next,
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
                onSubmitted: (_) => _nextStep(),
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

        const Spacer(),

        // INFO ADICIONAL
        Semantics(
          label: 'Información: Puedes usar teléfono o correo electrónico',
          child: Container(
            padding: const EdgeInsets.all(16),
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
                  Icons.info_outline_rounded,
                  size: 22,
                  color: theme.colorScheme.secondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Acepta teléfono o email',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.secondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 20),
      ],
    );
  }

  Widget _buildNameStep(ThemeData theme) {
    final hasText = _nameController.text.trim().isNotEmpty;

    return Column(
      children: [
        Semantics(
          label: 'Paso 2: Ingresa tu nombre',
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
          label: 'Ingresa el nombre con el que quieres que el robot te llame',
          child: Text(
            'Así te llamará el robot',
            style: theme.textTheme.bodyLarge?.copyWith(
              fontSize: 17,
              color: theme.colorScheme.onSurface.withOpacity(0.6),
            ),
            textAlign: TextAlign.center,
          ),
        ),

        const SizedBox(height: 60),

        // CAMPO DE NOMBRE CON ANIMACIÓN
        AnimatedBuilder(
          animation: _shakeAnimation,
          builder: (context, child) {
            return Transform.translate(
              offset: Offset(_shakeAnimation.value, 0),
              child: child,
            );
          },
          child: Semantics(
            label: 'Campo de texto para tu nombre',
            textField: true,
            hint: 'Ingrese su nombre completo o primer nombre',
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
                controller: _nameController,
                focusNode: _nameFocusNode,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                keyboardType: TextInputType.name,
                textInputAction: TextInputAction.done,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  hintText: 'Tu nombre',
                  hintStyle: TextStyle(
                    fontSize: 20,
                    color: theme.colorScheme.onSurface.withOpacity(0.3),
                  ),
                  prefixIcon: Icon(
                    _errorMessage != null
                        ? Icons.error_outline_rounded
                        : Icons.person_rounded,
                    size: 28,
                    color: _errorMessage != null
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.all(24),
                ),
                onSubmitted: (_) => _nextStep(),
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

        const Spacer(),

        // PREVIEW DEL SALUDO CON ANIMACIÓN
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
              label: 'Vista previa: Hola ${_nameController.text.trim()}',
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
                      '¡Hola ${_nameController.text.trim()}!',
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

        // INFORMACIÓN DEL TELÉFONO INGRESADO
        Semantics(
          label: 'Cuenta asociada a: $_phoneNumber',
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: theme.colorScheme.primary.withOpacity(0.3),
                width: 2,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.check_circle_rounded,
                  size: 22,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Cuenta asociada a:',
                        style: TextStyle(
                          fontSize: 13,
                          color: theme.colorScheme.onSurface.withOpacity(0.6),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _phoneNumber,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 20),
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