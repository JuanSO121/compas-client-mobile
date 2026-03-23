// lib/screens/auth/login_screen_integrated.dart
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import '../../services/auth_service.dart';
import '../ar_navigation_screen.dart';
import 'request_new_code_screen.dart';

class LoginScreenIntegrated extends StatefulWidget {
  const LoginScreenIntegrated({super.key});

  @override
  State<LoginScreenIntegrated> createState() => _LoginScreenIntegratedState();
}

class _LoginScreenIntegratedState extends State<LoginScreenIntegrated>
    with TickerProviderStateMixin {
  // ── Cada dígito del código tiene su propio controller y focusNode ──────
  // Esto permite que el foco salte automáticamente al siguiente campo al
  // escribir, lo que es más natural para todos pero especialmente para
  // personas con discapacidad motriz que usan teclado externo o switch.
  final List<TextEditingController> _digitControllers =
      List.generate(6, (_) => TextEditingController());
  final List<FocusNode> _digitFocusNodes =
      List.generate(6, (_) => FocusNode());

  // Controller alternativo: campo único (para quien prefiera pegar el código)
  final TextEditingController _singleCodeController = TextEditingController();
  final FocusNode _singleCodeFocusNode = FocusNode();

  final AuthService _authService = AuthService();

  bool _isLoading = false;
  String? _errorMessage;

  // Modo de entrada: true = un campo por dígito, false = campo único
  bool _useDigitFields = true;

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
    _fadeAnimation =
        CurvedAnimation(parent: _fadeController, curve: Curves.easeInOut);
    _fadeController.forward();

    _shakeController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _shakeAnimation = Tween<double>(begin: 0, end: 10).animate(
      CurvedAnimation(parent: _shakeController, curve: Curves.elasticIn),
    );

    // Cuando el campo único cambia, sincronizar con los boxes individuales
    _singleCodeController.addListener(_syncSingleToBoxes);

    // Limpiar error al escribir
    for (final c in _digitControllers) {
      c.addListener(() {
        if (_errorMessage != null) setState(() => _errorMessage = null);
      });
    }
    _singleCodeController.addListener(() {
      if (_errorMessage != null) setState(() => _errorMessage = null);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      SemanticsService.announce(
        'Pantalla de inicio de sesión. '
        'Ingrese el código de acceso de 6 dígitos que recibió en su email.',
        TextDirection.ltr,
      );
    });
  }

  @override
  void dispose() {
    for (final c in _digitControllers) c.dispose();
    for (final f in _digitFocusNodes) f.dispose();
    _singleCodeController.dispose();
    _singleCodeFocusNode.dispose();
    _fadeController.dispose();
    _shakeController.dispose();
    super.dispose();
  }

  // ── Sincronización entre modos de entrada ────────────────────────────────

  void _syncSingleToBoxes() {
    final text = _singleCodeController.text.replaceAll(' ', '');
    for (int i = 0; i < 6; i++) {
      _digitControllers[i].text = i < text.length ? text[i] : '';
    }
  }

  String _getCodeFromBoxes() {
    return _digitControllers.map((c) => c.text).join();
  }

  String _getCode() {
    if (_useDigitFields) {
      return _getCodeFromBoxes();
    } else {
      return _singleCodeController.text.replaceAll(' ', '');
    }
  }

  // ── Manejar entrada en cada caja de dígito ──────────────────────────────

  void _onDigitChanged(int index, String value) {
    if (value.length > 1) {
      // El usuario pegó más de un dígito — distribuir en los campos restantes
      _handlePaste(value, startIndex: index);
      return;
    }

    if (value.isNotEmpty && index < 5) {
      // Avanzar al siguiente campo automáticamente
      _digitFocusNodes[index + 1].requestFocus();
    }

    // Si se borra con backspace y el campo está vacío, retroceder
    if (value.isEmpty && index > 0) {
      _digitFocusNodes[index - 1].requestFocus();
    }

    // Si el último dígito se llenó, hacer login automáticamente
    if (index == 5 && value.isNotEmpty) {
      final code = _getCodeFromBoxes();
      if (code.length == 6) {
        Future.delayed(const Duration(milliseconds: 100), _login);
      }
    }

    setState(() {});
  }

  void _handlePaste(String pasted, {int startIndex = 0}) {
    final digits = pasted.replaceAll(RegExp(r'\D'), '');
    for (int i = 0; i < digits.length && (startIndex + i) < 6; i++) {
      _digitControllers[startIndex + i].text = digits[i];
    }

    // Foco al último campo llenado
    final lastFilled = (startIndex + digits.length - 1).clamp(0, 5);
    _digitFocusNodes[lastFilled].requestFocus();

    setState(() {});

    // Si se completó el código, hacer login
    final code = _getCodeFromBoxes();
    if (code.length == 6) {
      Future.delayed(const Duration(milliseconds: 200), _login);
    }
  }

  // ── Login principal ──────────────────────────────────────────────────────

  void _login() async {
    final code = _getCode();

    if (code.length != 6) {
      setState(
          () => _errorMessage = 'Ingrese los 6 dígitos de su código de acceso');
      _shakeController.forward(from: 0);
      SemanticsService.announce(
        'Error: Ingrese los 6 dígitos del código',
        TextDirection.ltr,
      );
      _digitFocusNodes[code.length.clamp(0, 5)].requestFocus();
      return;
    }

    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _errorMessage = 'El código solo debe contener números');
      _shakeController.forward(from: 0);
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await _authService.loginWithCode(code: code);

      if (!mounted) return;

      if (response.success && response.data != null) {
        HapticFeedback.heavyImpact();

        final user = response.data!.user;
        final name = user.profile?.firstName ?? '';
        final isFirstLogin = response.data!.firstLogin ?? false;

        final announcement = isFirstLogin
            ? 'Cuenta verificada. Bienvenido${name.isNotEmpty ? " $name" : ""}.'
            : 'Sesión iniciada. Bienvenido de vuelta${name.isNotEmpty ? " $name" : ""}.';

        SemanticsService.announce(announcement, TextDirection.ltr);
        _showSnackBar(
          isFirstLogin
              ? '¡Cuenta verificada! Bienvenido${name.isNotEmpty ? ", $name" : ""}!'
              : 'Bienvenido de vuelta${name.isNotEmpty ? ", $name" : ""}!',
          isError: false,
        );

        await Future.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const ArNavigationScreen()),
        );
      } else {
        setState(() {
          _errorMessage = response.message;
          _isLoading = false;
        });

        final announcement =
            response.accessibilityInfo?.announcement ?? response.message;
        SemanticsService.announce(announcement, TextDirection.ltr);
        _showSnackBar(_errorMessage!, isError: true);
        _shakeController.forward(from: 0);

        // Limpiar los campos para que el usuario reintente fácilmente
        _clearDigits();
        _digitFocusNodes[0].requestFocus();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Error de conexión. Intente nuevamente.';
        _isLoading = false;
      });
      _showSnackBar(_errorMessage!, isError: true);
      _shakeController.forward(from: 0);
    }
  }

  void _clearDigits() {
    for (final c in _digitControllers) {
      c.clear();
    }
    _singleCodeController.clear();
    setState(() {});
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
        duration: Duration(seconds: isError ? 4 : 2),
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────

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
          child: const Text('Iniciar Sesión',
              style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        actions: [
          // Botón para cambiar entre modo caja y modo campo único
          Semantics(
            label: _useDigitFields
                ? 'Cambiar a campo único para pegar el código'
                : 'Cambiar a cajas individuales por dígito',
            button: true,
            child: IconButton(
              icon: Icon(
                _useDigitFields ? Icons.input_rounded : Icons.grid_view_rounded,
                size: 24,
              ),
              tooltip: _useDigitFields ? 'Modo campo único' : 'Modo cajas',
              onPressed: () {
                setState(() => _useDigitFields = !_useDigitFields);
                SemanticsService.announce(
                  _useDigitFields
                      ? 'Modo cajas individuales activado'
                      : 'Puedes dicar tu código.',
                  TextDirection.ltr,
                );
              },
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              children: [
                const SizedBox(height: 32),

                // ── ÍCONO ────────────────────────────────────────────
                Semantics(
                  label: 'Llave de acceso',
                  excludeSemantics: true,
                  child: Container(
                    width: 90,
                    height: 90,
                    decoration: BoxDecoration(
                      color:
                          theme.colorScheme.primary.withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.vpn_key_rounded,
                      size: 44,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),

                const SizedBox(height: 28),

                // ── TÍTULO ───────────────────────────────────────────
                Semantics(
                  header: true,
                  label: 'Ingrese su código de acceso de 6 dígitos',
                  child: Text(
                    'Tu código de acceso',
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
                      'Ingrese el código de 6 dígitos que recibió en su email al registrarse',
                  child: Text(
                    'Ingrese el código de 6 dígitos\nque recibió en su email',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontSize: 16,
                      color: theme.colorScheme.onSurface.withOpacity(0.6),
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),

                const SizedBox(height: 40),

                // ── ENTRADA DE CÓDIGO ────────────────────────────────
                AnimatedBuilder(
                  animation: _shakeAnimation,
                  builder: (context, child) => Transform.translate(
                    offset: Offset(_shakeAnimation.value, 0),
                    child: child,
                  ),
                  child: _useDigitFields
                      ? _buildDigitBoxes(theme)
                      : _buildSingleField(theme),
                ),

                const SizedBox(height: 8),

                // Hint de modo
                Text(
                  _useDigitFields
                      ? 'También puede pegar el código — toque el ícono ↗ para cambiar'
                      : 'Modo campo único. Puede pegar directamente el código.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.4),
                    fontSize: 12,
                  ),
                  textAlign: TextAlign.center,
                ),

                // ── ERROR ────────────────────────────────────────────
                if (_errorMessage != null) ...[
                  const SizedBox(height: 20),
                  Semantics(
                    liveRegion: true,
                    label: 'Error: $_errorMessage',
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color:
                            theme.colorScheme.error.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: theme.colorScheme.error.withOpacity(0.3),
                          width: 2,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.warning_rounded,
                              size: 20,
                              color: theme.colorScheme.error),
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

                // ── BOTÓN INGRESAR ───────────────────────────────────
                Semantics(
                  label: 'Botón: Ingresar a la aplicación',
                  hint: 'Presione para ingresar con su código de acceso',
                  button: true,
                  child: _buildLoginButton(theme),
                ),

                const SizedBox(height: 24),

                // ── LINK: OLVIDÉ MI CÓDIGO ───────────────────────────
                Semantics(
                  label: 'Olvidé mi código. Solicitar nuevo código de acceso.',
                  button: true,
                  child: TextButton.icon(
                    onPressed: _isLoading
                        ? null
                        : () {
                            HapticFeedback.lightImpact();
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    const RequestNewCodeScreen(),
                              ),
                            );
                          },
                    icon: Icon(Icons.refresh_rounded,
                        size: 20,
                        color: theme.colorScheme.primary),
                    label: Text(
                      'Olvidé mi código — Solicitar uno nuevo',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Widgets de entrada ───────────────────────────────────────────────────

  Widget _buildDigitBoxes(ThemeData theme) {
    return Semantics(
      label: 'Código de acceso. 6 cajas para ingresar cada dígito.',
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(6, (index) {
          return Padding(
            padding: EdgeInsets.only(right: index < 5 ? 10 : 0),
            child: _buildSingleDigitBox(theme, index),
          );
        }),
      ),
    );
  }

  Widget _buildSingleDigitBox(ThemeData theme, int index) {
    final hasValue = _digitControllers[index].text.isNotEmpty;
    final hasError = _errorMessage != null;

    return Semantics(
      label: 'Dígito ${index + 1} de 6',
      textField: true,
      child: SizedBox(
        width: 48,
        height: 64,
        child: Container(
          decoration: BoxDecoration(
            color: hasValue
                ? theme.colorScheme.primary.withOpacity(0.1)
                : theme.cardColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: hasError
                  ? theme.colorScheme.error
                  : hasValue
                      ? theme.colorScheme.primary
                      : theme.colorScheme.primary.withOpacity(0.3),
              width: hasValue ? 3 : 2,
            ),
          ),
          child: TextField(
            controller: _digitControllers[index],
            focusNode: _digitFocusNodes[index],
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            maxLength: 1,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
            ],
            decoration: const InputDecoration(
              border: InputBorder.none,
              counterText: '',
              contentPadding: EdgeInsets.zero,
            ),
            onChanged: (value) => _onDigitChanged(index, value),
          ),
        ),
      ),
    );
  }

  Widget _buildSingleField(ThemeData theme) {
    return Semantics(
      label: 'Campo de código de acceso. Ingrese o pegue los 6 dígitos.',
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
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: TextField(
          controller: _singleCodeController,
          focusNode: _singleCodeFocusNode,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          maxLength: 6,
          style: const TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.bold,
            letterSpacing: 16,
          ),
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            hintText: '000000',
            hintStyle: TextStyle(
              fontSize: 32,
              letterSpacing: 16,
              color: theme.colorScheme.onSurface.withOpacity(0.2),
            ),
            counterText: '',
            border: InputBorder.none,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            prefixIcon: Icon(
              Icons.dialpad_rounded,
              size: 26,
              color: theme.colorScheme.primary,
            ),
          ),
          onSubmitted: (_) => _login(),
        ),
      ),
    );
  }

  Widget _buildLoginButton(ThemeData theme) {
    final code = _getCode();
    final isComplete = code.length == 6;
    final isEnabled = !_isLoading && isComplete;

    return Material(
      color: isEnabled
          ? theme.colorScheme.primary
          : theme.colorScheme.primary.withOpacity(0.45),
      borderRadius: BorderRadius.circular(20),
      elevation: isEnabled ? 2 : 0,
      child: InkWell(
        onTap: isEnabled ? _login : null,
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
                  children: [
                    const Icon(Icons.login_rounded,
                        size: 28, color: Colors.white),
                    const SizedBox(width: 16),
                    Text(
                      isComplete ? 'Ingresar' : 'Ingrese su código',
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