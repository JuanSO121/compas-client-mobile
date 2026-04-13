// lib/screens/ar_navigation_screen.dart
//
// ✅ v9.1 — Tutorial de bienvenida integrado
//
// ════════════════════════════════════════════════════════════════════════════
// CAMBIOS v9.0 → v9.1
// ════════════════════════════════════════════════════════════════════════════
//
//  NUEVOS PARÁMETROS DE CONSTRUCTOR:
//    • showWelcomeTutorial (bool) — true solo en firstLogin.
//    • userName (String)          — nombre del usuario para personalizar saludo.
//
//  FLUJO DEL TUTORIAL:
//    El tutorial NO se lanza en initState ni en onUnityCreated.
//    Se lanza en _ctrl.onGoToReady() → que ya existe en el controller.
//    Usamos un hook: _ctrl.onReadyForTutorial callback (nuevo en controller).
//
//    Timing exacto:
//      1. AR entra en AppReadyState.ready
//      2. coordinator.speak() ya funciona (TTSService inicializado)
//      3. _goToReady() llama onReadyForTutorial si está registrado
//      4. ArNavigationScreen reproduce el saludo de bienvenida
//      5. Pausa 1.5s → reproduce pregunta del tutorial
//      6. WakeWord escucha "cuéntame más" → reproduce tutorial completo
//         (implementado como intent especial __app:tutorial en el coordinator)
//
//    Diseño de la frase de activación:
//      "Si quieres saber todo lo que puedo hacer, di: Oye COMPAS, enséñame"
//      Esto reutiliza el WakeWord existente — no requiere nueva keyword.
//      El coordinator ya detecta intents libres; "enséñame" se mapea en
//      el prompt del AI como intent tutorial.
//
//    Alternativa sin WakeWord (wakeWordAvailable == false):
//      Se ofrece un botón "¿Qué puedo hacer?" en el overlay de voz.
//      Al pulsarlo dispara _ctrl.playTutorial() directamente.
//
//  CONTENIDO DEL TUTORIAL (reproducido por coordinator.speak()):
//    "Puedo guiarte a cualquier lugar. Solo dime: Oye COMPAS, llévame al baño,
//     o a la cafetería, o a cualquier lugar que necesites.
//     También puedo avisarte si hay un obstáculo en tu camino,
//     y repetirte la última instrucción cuando quieras.
//     Para pausar la navegación di: Oye COMPAS, para.
//     ¡Eso es todo! Estoy lista para ayudarte."
//
//  NOTA: el tutorial se reproduce UNA SOLA VEZ. El flag se destruye con
//  el widget — no se persiste porque firstLogin ya viene del backend.

import 'package:flutter/material.dart' hide NavigationMode;
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_unity_widget/flutter_unity_widget.dart';

import '../controllers/ar_navigation_controller.dart';
import '../widgets/ar_overlays.dart';
import '../widgets/ar_voice_overlay.dart';

class ArNavigationScreen extends StatefulWidget {
  /// Si es true, reproduce saludo + tutorial al entrar en estado ready.
  /// Solo debe ser true en el primer login (firstLogin == true).
  final bool showWelcomeTutorial;

  /// Nombre del usuario para personalizar el saludo. Puede ser vacío.
  final String userName;

  const ArNavigationScreen({
    super.key,
    this.showWelcomeTutorial = false,
    this.userName = '',
  });

  @override
  State<ArNavigationScreen> createState() => _ArNavigationScreenState();
}

class _ArNavigationScreenState extends State<ArNavigationScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {

  // ─── Controller ───────────────────────────────────────────────────────────

  late final ArNavigationController _ctrl;

  // ─── Animaciones ──────────────────────────────────────────────────────────

  late AnimationController _pulseController;
  late AnimationController _waveController;
  late AnimationController _testPanelController;
  late Animation<double>   _pulseAnimation;
  late Animation<double>   _waveAnimation;
  late Animation<double>   _testPanelAnimation;

  // ─── Tutorial ─────────────────────────────────────────────────────────────

  /// Evita reproducir el tutorial más de una vez por sesión.
  bool _tutorialPlayed = false;

  // ─── Lifecycle ────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupAnimations();

    _ctrl = ArNavigationController();
    _ctrl.onShowSnackBar         = _showSnackBar;
    _ctrl.onShowTrackingSnackBar = _showTrackingSnackBar;
    _ctrl.onHideTrackingSnackBar = () =>
        ScaffoldMessenger.of(context).hideCurrentSnackBar();

    // ✅ v9.1: hook de tutorial — se dispara cuando AR entra en ready
    if (widget.showWelcomeTutorial) {
      _ctrl.onReadyForTutorial = _playWelcomeTutorial;
    }

    _ctrl.initializeServices();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _ctrl.handleAppLifecycle(state);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulseController.dispose();
    _waveController.dispose();
    _testPanelController.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _setupAnimations() {
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.1).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _waveController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    );
    _waveAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _waveController, curve: Curves.easeInOut),
    );

    _testPanelController = AnimationController(
      duration: const Duration(milliseconds: 280),
      vsync: this,
    );
    _testPanelAnimation = CurvedAnimation(
      parent: _testPanelController,
      curve: Curves.easeOutCubic,
    );
  }

  // ─── Tutorial de bienvenida ───────────────────────────────────────────────

  /// Se llama desde ArNavigationController.onReadyForTutorial cuando
  /// AppReadyState == ready y el TTSService de AR ya está operativo.
  ///
  /// Usa coordinator.speak() para que el audio pase por el mismo pipeline
  /// que las instrucciones de navegación (respeta WakeWord mutex, eco, etc.)
  Future<void> _playWelcomeTutorial() async {
    if (_tutorialPlayed) return;
    _tutorialPlayed = true;

    final name = widget.userName.isNotEmpty ? widget.userName : '';

    // ── Saludo de bienvenida ──────────────────────────────────────────────
    final greeting = name.isNotEmpty
        ? 'Hola $name, bienvenido a COMPAS, tu asistente de navegación.'
        : 'Hola, bienvenido a COMPAS, tu asistente de navegación.';

    _ctrl.coordinator.speak(greeting);

    // Pausa para que el saludo termine antes de la pregunta del tutorial.
    // waitForCompletion no está expuesto en coordinator.speak() así que
    // usamos un delay estimado generoso (el TTS es ~0.5x rate, ~3.5s por frase).
    await Future.delayed(const Duration(milliseconds: 4000));
    if (!mounted) return;

    // ── Invitación al tutorial ────────────────────────────────────────────
    final tutorialInvite = _ctrl.wakeWordAvailable
        ? 'Si quieres saber todo lo que puedo hacer, di: Oye COMPAS, enséñame.'
        : 'Toca el botón ¿Qué puedo hacer? para saber todo lo que puedo hacer.';

    _ctrl.coordinator.speak(tutorialInvite);
  }

  /// Reproduce el tutorial completo de funciones.
  /// Llamado cuando el usuario dice "Oye COMPAS, enséñame"
  /// o cuando toca el botón manual en el overlay.
  void playTutorialContent() {
    const tutorial =
        'Puedo guiarte a cualquier lugar. '
        'Solo dime: Oye COMPAS, llévame al baño, '
        'o a la cafetería, o a donde necesites. '
        'También puedo avisarte si hay un obstáculo en tu camino, '
        'y repetirte la última instrucción cuando quieras. '
        'Para pausar la navegación di: Oye COMPAS, para. '
        '¡Eso es todo! Estoy lista para ayudarte.';

    _ctrl.coordinator.speak(tutorial);
  }

  // ─── SnackBars ────────────────────────────────────────────────────────────

  void _showSnackBar(String msg, {bool isError = false}) {
    if (!mounted) return;
    SemanticsService.announce(msg, TextDirection.ltr);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(children: [
          Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            color: Colors.white,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(msg, style: const TextStyle(fontSize: 15))),
        ]),
        backgroundColor:
        isError ? const Color(0xFFE53935) : const Color(0xFF43A047),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: Duration(seconds: isError ? 4 : 2),
      ),
    );
  }

  void _showTrackingSnackBar(String reason) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(children: [
          const Icon(Icons.warning_amber_rounded,
              color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _ctrl.trackingReasonToMessage(reason),
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ]),
        backgroundColor: const Color(0xFFE65100),
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  // ─── Test panel helpers ───────────────────────────────────────────────────

  void _toggleTestPanel() {
    _ctrl.toggleTestPanel(() => HapticFeedback.selectionClick());
    _ctrl.showTestPanel
        ? _testPanelController.forward()
        : _testPanelController.reverse();
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: ListenableBuilder(
        listenable: _ctrl,
        builder: (context, _) => Stack(
          children: [
            // Unity siempre en background
            Positioned.fill(
              child: UnityWidget(
                onUnityCreated: _ctrl.onUnityCreated,
                onUnityMessage: _ctrl.onUnityMessage,
                fullscreen: true,
                useAndroidViewSurface: true,
              ),
            ),

            // Cargando Unity
            if (!_ctrl.unityLoaded)
              Container(
                color: const Color(0xFF00162D),
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: Color(0xFFFF6B00)),
                      SizedBox(height: 16),
                      Text('Cargando AR...',
                          style: TextStyle(color: Colors.white, fontSize: 18)),
                    ],
                  ),
                ),
              ),

            // Initializing
            if (_ctrl.unityLoaded &&
                _ctrl.appState == AppReadyState.initializing)
              const ArInitializingOverlay(),

            // WaitingSession
            if (_ctrl.unityLoaded &&
                _ctrl.appState == AppReadyState.waitingSession)
              const ArWaitingSessionOverlay(),

            // WaitingUser
            if (_ctrl.unityLoaded &&
                _ctrl.appState == AppReadyState.waitingUser)
              ArWaitingUserOverlay(
                wakeWordAvailable: _ctrl.wakeWordAvailable,
                onReady: _ctrl.onUserReady,
              ),

            // Ready: overlay de voz principal
            if (_ctrl.unityLoaded &&
                _ctrl.appState == AppReadyState.ready &&
                _ctrl.showVoiceOverlay)
              ArVoiceOverlay(
                controller: _ctrl,
                pulseController: _pulseController,
                waveController: _waveController,
                pulseAnimation: _pulseAnimation,
                waveAnimation: _waveAnimation,
              ),

            // Badge de tracking inestable
            if (_ctrl.unityLoaded &&
                _ctrl.appState == AppReadyState.ready &&
                !_ctrl.arTrackingStable)
              Positioned(
                top: MediaQuery.of(context).padding.top + 50,
                left: 0,
                right: 0,
                child: Center(
                  child: ArTrackingBadge(reason: _ctrl.arTrackingReason),
                ),
              ),

            // Botones de control — solo en ready
            if (_ctrl.unityLoaded && _ctrl.appState == AppReadyState.ready)
              ..._buildReadyControls(context),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildReadyControls(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    final top    = MediaQuery.of(context).padding.top;
    return [
      // Toggle overlay (top-right)
      Positioned(
        top: top + 8,
        right: 12,
        child: _ToggleOverlayButton(
          visible: _ctrl.showVoiceOverlay,
          onTap: _ctrl.toggleVoiceOverlay,
        ),
      ),

      // ✅ v9.1: Botón tutorial manual — visible solo si NO hay WakeWord
      //         o si el tutorial aún no se ha reproducido completo.
      if (!_ctrl.wakeWordAvailable || widget.showWelcomeTutorial)
        Positioned(
          top: top + 8,
          left: 12,
          child: _TutorialButton(onTap: playTutorialContent),
        ),

      // Botón test panel (bottom-left)
      Positioned(
        bottom: bottom + 24,
        left: 16,
        child: _TestButton(
          open: _ctrl.showTestPanel,
          onTap: _toggleTestPanel,
        ),
      ),

      // Test panel animado
      AnimatedBuilder(
        animation: _testPanelAnimation,
        builder: (context, child) => Positioned(
          bottom: bottom + 80,
          left: 16,
          child: Transform.translate(
            offset: Offset(-300 * (1 - _testPanelAnimation.value), 0),
            child: Opacity(
              opacity: _testPanelAnimation.value,
              child: child,
            ),
          ),
        ),
        child: ArTestPanel(controller: _ctrl),
      ),
    ];
  }
}

// ─── Botón toggle overlay ─────────────────────────────────────────────────

class _ToggleOverlayButton extends StatelessWidget {
  final bool visible;
  final VoidCallback onTap;
  const _ToggleOverlayButton({required this.visible, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.6),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(visible ? Icons.visibility_off : Icons.mic,
                color: Colors.white, size: 16),
            const SizedBox(width: 6),
            Text(
              visible ? 'Ocultar' : 'Voz',
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Botón tutorial manual ────────────────────────────────────────────────

class _TutorialButton extends StatelessWidget {
  final VoidCallback onTap;
  const _TutorialButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '¿Qué puedo hacer? Escuchar las funciones de COMPAS',
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFFFF6B00).withOpacity(0.85),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.orange.shade200.withOpacity(0.5)),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.help_outline_rounded, color: Colors.white, size: 16),
              SizedBox(width: 6),
              Text(
                '¿Qué puedo hacer?',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Botón test panel ─────────────────────────────────────────────────────

class _TestButton extends StatelessWidget {
  final bool open;
  final VoidCallback onTap;
  const _TestButton({required this.open, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: open
              ? const Color(0xFF7B1FA2).withOpacity(0.92)
              : Colors.black.withOpacity(0.72),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: open ? const Color(0xFFCE93D8) : Colors.white30,
            width: 1.5,
          ),
          boxShadow: open
              ? [
            BoxShadow(
              color: const Color(0xFF7B1FA2).withOpacity(0.4),
              blurRadius: 12,
              spreadRadius: 2,
            ),
          ]
              : [],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              open ? Icons.close_rounded : Icons.bug_report_rounded,
              color: open ? const Color(0xFFCE93D8) : Colors.white70,
              size: 18,
            ),
            const SizedBox(width: 6),
            Text(
              open ? 'Cerrar' : 'Test',
              style: TextStyle(
                color: open ? const Color(0xFFCE93D8) : Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}