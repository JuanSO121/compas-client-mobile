// lib/screens/ar_navigation_screen.dart
//
// ✅ v9.4 — Calibración AR + botón Pruebas + tutorial wake-word mejorado
//
// ════════════════════════════════════════════════════════════════════════════
// CAMBIOS v9.1 → v9.4
// ════════════════════════════════════════════════════════════════════════════
//
//  1. ArCalibrationOverlay — nuevo overlay que se muestra durante
//     AppReadyState.waitingSession (Unity cargado pero sesión no confirmada).
//     Guía al usuario para mover la cámara lentamente y calibrar el tracking.
//     Se autocierra con AppReadyState.ready. También puede cerrarse
//     manualmente al tocar "Comenzar navegación" en el paso final.
//     Solo se muestra cuando _showCalibrationOverlay == true.
//
//  2. Botón "Pruebas" (bottom-right) — visible solo en AppReadyState.ready.
//     Navega con push a SystemTestScreen. Reemplaza el antiguo botón de Test
//     con el ícono de laboratorio que ya existía. No usa replace para que
//     el usuario pueda volver con el botón de retroceso.
//
//  3. Tutorial mejorado (_playWelcomeTutorial) — la invitación al tutorial
//     incluye instrucciones sobre el delay de escucha del wake word:
//     "Después de decir Oye COMPAS, espera el tono antes de hablar."
//     El tutorial completo (playTutorialContent) también fue actualizado.
//
//  TODO LO DEMÁS ES IDÉNTICO A v9.1.

import 'package:flutter/material.dart' hide NavigationMode;
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_unity_widget/flutter_unity_widget.dart';

import '../controllers/ar_navigation_controller.dart';
import '../widgets/ar_overlays.dart';
import '../widgets/ar_voice_overlay.dart';
import '../widgets/ar_calibration_overlay.dart';
import 'system_test_screen.dart';

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

  // ─── ✅ v9.4: Calibración AR ─────────────────────────────────────────────

  /// Controla si el overlay de calibración se muestra.
  /// Se activa cuando Unity carga y se desactiva al entrar en ready
  /// o cuando el usuario toca "Comenzar navegación".
  bool _showCalibrationOverlay = false;

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

    // ✅ v9.4: cuando el estado cambia, ajustar overlay de calibración
    _ctrl.addListener(_onControllerChanged);

    _ctrl.initializeServices();
  }

  // ─── Listener del controller ─────────────────────────────────────────────

  AppReadyState? _lastState;

  void _onControllerChanged() {
    final newState = _ctrl.appState;
    if (newState == _lastState) return;
    _lastState = newState;

    switch (newState) {
      case AppReadyState.waitingSession:
      // Unity cargó — mostrar calibración si el overlay no se cerró ya
        if (!_showCalibrationOverlay) {
          setState(() => _showCalibrationOverlay = true);
        }
        break;
      case AppReadyState.ready:
      // Sesión confirmada — cerrar overlay de calibración
        if (_showCalibrationOverlay) {
          setState(() => _showCalibrationOverlay = false);
        }
        break;
      default:
        break;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _ctrl.handleAppLifecycle(state);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ctrl.removeListener(_onControllerChanged);
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
  Future<void> _playWelcomeTutorial() async {
    if (_tutorialPlayed) return;
    _tutorialPlayed = true;

    final name = widget.userName.isNotEmpty ? widget.userName : '';

    // ── Saludo de bienvenida ──────────────────────────────────────────────
    final greeting = name.isNotEmpty
        ? 'Hola $name, bienvenido a COMPAS, tu asistente de navegación.'
        : 'Hola, bienvenido a COMPAS, tu asistente de navegación.';

    _ctrl.coordinator.speak(greeting);

    await Future.delayed(const Duration(milliseconds: 4000));
    if (!mounted) return;

    // ─── ✅ v9.4: invitación mejorada con instrucción de delay ────────────
    final tutorialInvite = _ctrl.wakeWordAvailable
        ? 'Para activarme, di: Oye COMPAS, y espera el tono antes de hablar. '
        'Si quieres saber todo lo que puedo hacer, di: Oye COMPAS, enséñame.'
        : 'Toca el botón ¿Qué puedo hacer? para saber todo lo que puedo hacer.';

    _ctrl.coordinator.speak(tutorialInvite);
  }

  /// Reproduce el tutorial completo de funciones.
  /// ✅ v9.4: incluye explicación del delay de escucha del wake word.
  void playTutorialContent() {
    // Idéntico a ArNavigationController.tutorialScript pero con las
    // correcciones de texto y las instrucciones de delay de wake word.
    const tutorial =
        'Te explico cómo funciono. '
        'Para activarme, di: Oye COMPAS, y luego tu destino. '
        'Importante: después de decir Oye COMPAS, espera un momento. '
        'Escucharás un tono suave que indica que el micrófono ya está listo. '
        'Recién entonces dices a dónde quieres ir. '
        'Por ejemplo: Oye COMPAS, llévame a la sala de lectura. '
        'También te aviso si hay un obstáculo en tu camino, '
        'y puedes pedirme que repita la última instrucción. '
        'Para detener la navegación di: Oye COMPAS, para. '
        '¡Eso es todo! Estoy listo para guiarte.';

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

  // ─── ✅ v9.4: Navegar a SystemTestScreen ─────────────────────────────────

  void _openTestScreen() {
    HapticFeedback.mediumImpact();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SystemTestScreen()),
    );
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

            // ✅ v9.4: Calibración AR — durante waitingSession
            // Se muestra sobre la imagen de Unity para que el usuario vea
            // la cámara mientras calibra.
            if (_ctrl.unityLoaded && _showCalibrationOverlay)
              Positioned.fill(
                child: ArCalibrationOverlay(
                  showVoiceHint: _ctrl.wakeWordAvailable,
                  onDismiss: () {
                    setState(() => _showCalibrationOverlay = false);
                  },
                ),
              ),

            // Initializing (antes de Unity)
            if (_ctrl.unityLoaded &&
                _ctrl.appState == AppReadyState.initializing)
              const ArInitializingOverlay(),

            // WaitingSession — solo si el overlay de calibración NO está activo
            if (_ctrl.unityLoaded &&
                _ctrl.appState == AppReadyState.waitingSession &&
                !_showCalibrationOverlay)
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

            // Controles — solo en ready
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

      // Botón tutorial manual — visible solo si NO hay WakeWord
      // o si el tutorial aún no se ha reproducido completo.
      if (!_ctrl.wakeWordAvailable || widget.showWelcomeTutorial)
        Positioned(
          top: top + 8,
          left: 12,
          child: _TutorialButton(onTap: playTutorialContent),
        ),

      // ✅ v9.4: Botón "Pruebas" (bottom-right)
      // Navega a SystemTestScreen con push para poder volver.
      Positioned(
        bottom: bottom + 24,
        right: 16,
        child: _TestScreenButton(onTap: _openTestScreen),
      ),

      // Botón test panel interno (bottom-left) — mantenido para debugging
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

// ─── ✅ v9.4: Botón "Pruebas" (navega a SystemTestScreen) ─────────────────

class _TestScreenButton extends StatelessWidget {
  final VoidCallback onTap;
  const _TestScreenButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Abrir pantalla de pruebas del sistema',
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF1565C0).withOpacity(0.88),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: const Color(0xFF90CAF9).withOpacity(0.5),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF1565C0).withOpacity(0.3),
                blurRadius: 10,
                spreadRadius: 1,
              ),
            ],
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.science_rounded,
                  color: Color(0xFF90CAF9), size: 18),
              SizedBox(width: 6),
              Text(
                'Pruebas',
                style: TextStyle(
                  color: Color(0xFF90CAF9),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Botón test panel interno ─────────────────────────────────────────────

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
              open ? 'Cerrar' : 'Debug',
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