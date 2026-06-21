// lib/screens/auth/request_new_code_screen.dart
//
// ── v2.1 — Pausa AuthVoiceNavigationService mientras esta pantalla está activa
// ─────────────────────────────────────────────────────────────────────────────
//
//  CAMBIO v2.0 → v2.1:
//    • Se importa AuthVoiceNavigationService.
//    • initState() llama _voiceNav.pauseListening() para que el wake word
//      no interfiera mientras el usuario escribe su email aquí.
//    • dispose() llama _voiceNav.resumeListening() para que al volver a
//      LoginScreen el asistente de voz retome automáticamente.
//    • Sin cambios funcionales: la pantalla sigue siendo solo teclado,
//      no tiene flujo de dictado propio (el email de recuperación es
//      un caso edge; el dictado se puede añadir en v2.2 si se solicita).
//
//  TODO lo demás es idéntico a v2.0.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import '../../services/auth_service.dart';
import '../../services/auth_tts_service.dart';
import '../../services/auth_voice_navigation_service.dart';

class RequestNewCodeScreen extends StatefulWidget {
  const RequestNewCodeScreen({super.key});

  @override
  State<RequestNewCodeScreen> createState() => _RequestNewCodeScreenState();
}

class _RequestNewCodeScreenState extends State<RequestNewCodeScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _emailController = TextEditingController();
  final FocusNode _emailFocusNode = FocusNode();

  final AuthService _authService = AuthService();
  final AuthTTSService _tts = AuthTTSService();

  // v2.1: pausar la escucha del wake word mientras estamos aquí
  final AuthVoiceNavigationService _voiceNav = AuthVoiceNavigationService();

  bool _isLoading = false;
  bool _success = false;
  String? _errorMessage;

  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  // ─────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();

    _fadeController = AnimationController(
        duration: const Duration(milliseconds: 300), vsync: this);
    _fadeAnimation =
        CurvedAnimation(parent: _fadeController, curve: Curves.easeInOut);
    _fadeController.forward();

    _emailController.addListener(() {
      if (_errorMessage != null) setState(() => _errorMessage = null);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // v2.1: silenciar el asistente de voz para evitar falsos positivos
      // mientras el usuario escribe su email de recuperación.
      _voiceNav.pauseListening();

      await _tts.initialize();
      await Future.delayed(const Duration(milliseconds: 350));
      await _tts.announceScreen(
        'Solicitar nuevo código de acceso. '
            'Ingrese su correo electrónico y le enviaremos un nuevo código.',
      );
      SemanticsService.announce(
        'Solicitar nuevo código. Ingrese su correo electrónico.',
        TextDirection.ltr,
      );
      if (mounted) _emailFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _emailFocusNode.dispose();
    _fadeController.dispose();
    _tts.dispose();

    // v2.1: reanudar la escucha al salir para que LoginScreen la retome
    _voiceNav.resumeListening();

    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // LÓGICA
  // ─────────────────────────────────────────────────────────────────────────

  void _requestNewCode() async {
    final email = _emailController.text.trim();

    if (email.isEmpty) {
      const msg = 'Ingrese su correo electrónico';
      setState(() => _errorMessage = msg);
      _tts.announceError(msg);
      SemanticsService.announce(msg, TextDirection.ltr);
      _emailFocusNode.requestFocus();
      return;
    }

    final emailRegex = RegExp(r'^[\w\-\.]+@([\w\-]+\.)+[\w\-]{2,4}$');
    if (!emailRegex.hasMatch(email)) {
      const msg = 'Formato de email inválido';
      setState(() => _errorMessage = msg);
      _tts.announceError(msg);
      SemanticsService.announce(msg, TextDirection.ltr);
      _emailFocusNode.requestFocus();
      return;
    }

    await _tts.announceButton('Enviando código. Por favor espere.');

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await _authService.requestNewCode(email: email);

      if (!mounted) return;

      if (response.success) {
        HapticFeedback.heavyImpact();
        setState(() {
          _success = true;
          _isLoading = false;
        });
        const successMsg =
            'Si el email está registrado, recibirá su nuevo código en unos momentos. '
            'Revise su bandeja de entrada y la carpeta de spam.';
        await _tts.announceSuccess(successMsg);
        SemanticsService.announce(successMsg, TextDirection.ltr);
      } else {
        setState(() {
          _errorMessage = response.message;
          _isLoading = false;
        });
        final announcement =
            response.accessibilityInfo?.announcement ?? response.message;
        await _tts.announceError(announcement);
        SemanticsService.announce(announcement, TextDirection.ltr);
        _emailFocusNode.requestFocus();
      }
    } catch (e) {
      if (!mounted) return;
      const msg = 'Error de conexión. Intente nuevamente.';
      setState(() {
        _errorMessage = msg;
        _isLoading = false;
      });
      await _tts.announceError(msg);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Semantics(
          label: 'Volver',
          button: true,
          child: IconButton(
            icon: const Icon(Icons.arrow_back_rounded, size: 28),
            onPressed: () {
              _tts.announceButton('Volver');
              Navigator.pop(context);
            },
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

  // ── Vista de éxito ────────────────────────────────────────────────────────

  Widget _buildSuccessView(ThemeData theme) {
    return Column(
      children: [
        const SizedBox(height: 60),
        Semantics(
          excludeSemantics: true,
          child: Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.12),
                shape: BoxShape.circle),
            child: const Icon(Icons.mark_email_read_rounded,
                size: 52, color: Colors.green),
          ),
        ),
        const SizedBox(height: 32),
        Semantics(
          header: true,
          child: Text(
            '¡Código enviado!',
            style: theme.textTheme.titleLarge
                ?.copyWith(fontSize: 28, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Si el email está registrado, recibirá su nuevo código en unos momentos.\n'
              'Revise también la carpeta de spam.\n\n'
              'El código anterior ya no funciona — use el nuevo.',
          style: theme.textTheme.bodyLarge?.copyWith(
              fontSize: 16,
              height: 1.6,
              color: theme.colorScheme.onSurface.withOpacity(0.7)),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 48),
        Semantics(
          label: 'Ir a ingresar mi código',
          button: true,
          child: Material(
            color: theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              onTap: () {
                _tts.announceButton('Ingresar código.');
                Navigator.pop(context);
              },
              borderRadius: BorderRadius.circular(20),
              child: const SizedBox(
                width: double.infinity,
                height: 72,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.vpn_key_rounded, size: 28, color: Colors.white),
                    SizedBox(width: 16),
                    Text('Ingresar mi código',
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            letterSpacing: 0.5)),
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

  // ── Formulario ────────────────────────────────────────────────────────────

  Widget _buildFormView(ThemeData theme) {
    return Column(
      children: [
        const SizedBox(height: 32),

        Semantics(
          excludeSemantics: true,
          child: Container(
            width: 90,
            height: 90,
            decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.1),
                shape: BoxShape.circle),
            child: Icon(Icons.email_rounded,
                size: 44, color: theme.colorScheme.primary),
          ),
        ),

        const SizedBox(height: 28),

        Semantics(
          header: true,
          child: Text(
            '¿Olvidó su código?',
            style: theme.textTheme.titleLarge
                ?.copyWith(fontSize: 26, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
        ),

        const SizedBox(height: 12),

        Text(
          'Ingrese su correo electrónico y le enviaremos un nuevo código.\n'
              'El código anterior dejará de funcionar.',
          style: theme.textTheme.bodyLarge?.copyWith(
              fontSize: 15,
              color: theme.colorScheme.onSurface.withOpacity(0.6),
              height: 1.6),
          textAlign: TextAlign.center,
        ),

        const SizedBox(height: 40),

        Semantics(
          label: 'Correo electrónico',
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
              controller: _emailController,
              focusNode: _emailFocusNode,
              style:
              const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                hintText: 'ejemplo@correo.com',
                hintStyle: TextStyle(
                    fontSize: 18,
                    color: theme.colorScheme.onSurface.withOpacity(0.3)),
                prefixIcon: Icon(Icons.email_rounded,
                    size: 26, color: theme.colorScheme.primary),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.all(20),
              ),
              onSubmitted: (_) => _requestNewCode(),
            ),
          ),
        ),

        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withOpacity(0.07),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: theme.colorScheme.primary.withOpacity(0.2), width: 1.5),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded,
                  size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'No necesita contraseña. Solo su correo electrónico registrado.',
                  style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.primary,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),

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
          ),
        ],

        const SizedBox(height: 32),

        Semantics(
          label: 'Enviar nuevo código',
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
                        valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.white)),
                  ),
                )
                    : const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.send_rounded,
                        size: 28, color: Colors.white),
                    SizedBox(width: 16),
                    Text('Enviar nuevo código',
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            letterSpacing: 0.5)),
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
}