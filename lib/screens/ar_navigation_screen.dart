// lib/screens/ar_navigation_screen.dart
//
// ✅ v9.12 — Bienvenida breve + tutorial opcional bajo demanda
//
// CAMBIOS v9.11 → v9.12:
//
//   1. _playWelcomeGreeting() completamente rediseñado.
//
//      PROBLEMA con v9.11:
//        El tutorial de primera vez se reproducía automáticamente y no había
//        forma de saltárselo ni detenerlo. El usuario quedaba atrapado
//        escuchando explicaciones aunque ya supiera usar la app o no tuviera
//        paciencia en ese momento.
//
//      SOLUCIÓN v9.12 — Tutorial siempre opcional:
//
//        Primera vez Y visitas siguientes → mismo flujo breve:
//          1. Bienvenida: "Hola[, Nombre]. Soy Compas, tu guía."
//          2. Opción: "Di 'oye compas, preséntate' para conocerme,
//                      o empieza directamente con lo que necesitas."
//
//        El tutorial largo (presentación de Compas) solo se reproduce si
//        el usuario lo pide explícitamente con "oye compas, preséntate".
//        Eso dispara el intent _UnityAction.introduce → playIntroductionSequence()
//        que ya existe en VoiceNavigationService v6.8.
//
//      Por qué es mejor:
//        • El usuario tiene control total desde el primer segundo
//        • No hay audio largo que bloquee la interacción
//        • La presentación sigue disponible siempre, no solo la primera vez
//        • Es consistente con la UX de auth: el usuario ya sabe usar el wake word
//
//   2. Sin otros cambios funcionales. Todo lo de v9.11 permanece intacto.

import 'dart:async';

import 'package:flutter/material.dart' hide NavigationMode;
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_unity_widget/flutter_unity_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../controllers/ar_navigation_controller.dart';
import '../services/guest_session.dart';
import '../services/voice_navigation_service.dart';
import '../widgets/ar_overlays.dart';
import '../widgets/ar_voice_overlay.dart';
import '../widgets/ar_calibration_overlay.dart';
import 'auth/welcome_screen.dart';

class ArNavigationScreen extends StatefulWidget {
  final bool showWelcomeTutorial;
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
  late final ArNavigationController _ctrl;

  late AnimationController _pulseController;
  late AnimationController _waveController;
  late AnimationController _testPanelController;
  late Animation<double>   _pulseAnimation;
  late Animation<double>   _waveAnimation;
  late Animation<double>   _testPanelAnimation;

  bool _showCalibrationOverlay = false;

  bool _isGuest    = false;
  bool _isFirstTime = false;

  // Badge micrófono
  bool   _micHealthVisible = false;
  String _micHealthMessage = '';
  Timer? _micHealthTimer;

  // Segmentación
  bool _segmentationAnnouncedLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupAnimations();

    _isGuest = GuestSession().isGuest;

    _ctrl = ArNavigationController();
    _ctrl.onShowSnackBar          = _showSnackBar;
    _ctrl.onShowTrackingSnackBar  = _showTrackingSnackBar;
    _ctrl.onHideTrackingSnackBar  = () =>
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
    _ctrl.onReadyForTutorial      = null;
    _ctrl.addListener(_onControllerChanged);

    _initAsync();
  }

  Future<void> _initAsync() async {
    final prefs        = await SharedPreferences.getInstance();
    final tutorialDone = prefs.getBool(kTutorialDoneKey) ?? false;

    _isFirstTime = !tutorialDone || widget.showWelcomeTutorial;

    _ctrl.showWelcomeTutorial = _isFirstTime;
    _ctrl.initializeServices();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final voiceNav = VoiceNavigationService();
      await voiceNav.speak('Iniciando Compas, un momento.');
      _hookMicHealth();
      _hookSegmentation();
    });
  }

  // ─── Hook salud del micrófono ─────────────────────────────────────────────

  void _hookMicHealth() {
    VoiceNavigationService().onMicHealthEvent = (String event) {
      _log('MicHealth: $event');
      _showMicHealthBadge('Reconectando el micrófono…');
    };
  }

  void _showMicHealthBadge(String message) {
    if (!mounted) return;
    setState(() {
      _micHealthVisible = true;
      _micHealthMessage = message;
    });
    _micHealthTimer?.cancel();
    _micHealthTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _micHealthVisible = false);
    });
  }

  // ─── Hook segmentación ────────────────────────────────────────────────────

  void _hookSegmentation() {
    final bridge   = _ctrl.unityBridge;
    final voiceNav = VoiceNavigationService();

    bridge.onSegmentationActiveChanged = (bool active) {
      if (active) {
        if (_segmentationAnnouncedLoading) {
          _segmentationAnnouncedLoading = false;
          voiceNav.announceSegmentationReady();
        }
      } else {
        if (!_segmentationAnnouncedLoading) {
          _segmentationAnnouncedLoading = true;
          voiceNav.announceSegmentationLoading();
        }
      }
    };
  }

  // ─── Saludo de bienvenida — siempre breve, tutorial siempre opcional ────────
  //
  // DISEÑO v9.12:
  //
  // El mismo flujo para primera vez y visitas siguientes:
  //
  //   "Hola[, Nombre]. Soy Compas, tu guía en la biblioteca."
  //   → pausa breve →
  //   "Di 'oye compas, preséntate' para conocerme,
  //    o empieza directamente con lo que necesitas."
  //
  // El tutorial largo (presentación de Compas) SOLO se reproduce si el
  // usuario lo pide con "oye compas, preséntate". Eso dispara el intent
  // introduce → playIntroductionSequence() en VoiceNavigationService.
  //
  // Así el usuario tiene control total desde el primer segundo.
  // La presentación sigue disponible siempre, no solo la primera vez.

  Future<void> _playWelcomeGreeting() async {
    final voiceNav = VoiceNavigationService();
    final name     = widget.userName.trim();

    // Bienvenida breve — siempre igual
    final saludo = name.isNotEmpty
        ? 'Hola, $name. Soy Compas, tu guía en la biblioteca.'
        : 'Hola. Soy Compas, tu guía en la biblioteca.';
    await voiceNav.speak(saludo);

    // Pausa antes de la invitación
    await Future.delayed(const Duration(milliseconds: 700));

    // Invitación a conocer Compas o empezar directamente
    await voiceNav.speak(
      'Di: oye compas, preséntate, para conocerme. '
          'O empieza directamente con lo que necesitas.',
    );
  }

  // ─── Listener del controlador ─────────────────────────────────────────────

  AppReadyState? _lastState;

  void _onControllerChanged() {
    final newState = _ctrl.appState;
    if (newState == _lastState) return;
    _lastState = newState;

    switch (newState) {
      case AppReadyState.initializing:
        break;

      case AppReadyState.waitingSession:
        if (!_showCalibrationOverlay) {
          setState(() => _showCalibrationOverlay = true);
        }
        _announceCalibration();
        break;

      case AppReadyState.waitingUser:
        _announceWaitingUser();
        break;

      case AppReadyState.ready:
        if (_showCalibrationOverlay) {
          setState(() => _showCalibrationOverlay = false);
        }
        _playWelcomeGreeting();
        break;

      default:
        break;
    }
  }

  // ─── Avisos de estado ────────────────────────────────────────────────────

  Future<void> _announceCalibration() async {
    await Future.delayed(const Duration(milliseconds: 400));
    await VoiceNavigationService().speak(
      'Preparando la cámara. Apunta el teléfono hacia el suelo un momento.',
    );
  }

  Future<void> _announceWaitingUser() async {
    await Future.delayed(const Duration(milliseconds: 300));
    await VoiceNavigationService().speak(
      'Listo. Toca la pantalla cuando quieras comenzar.',
    );
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
    _micHealthTimer?.cancel();
    _ctrl.dispose();

    if (_isGuest) GuestSession().clearGuestSession();
    VoiceNavigationService().onMicHealthEvent = null;

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

  static void _log(String msg) {
    assert(() { debugPrint('[ArNavScreen] $msg'); return true; }());
  }

  // ─── Salir del modo invitado ──────────────────────────────────────────────

  void _exitGuestMode() {
    HapticFeedback.lightImpact();
    SemanticsService.announce('Saliendo del modo invitado.', TextDirection.ltr);
    GuestSession().clearGuestSession();
    _isGuest = false;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const WelcomeScreen()),
          (_) => false,
    );
  }

  // ─── SnackBars ────────────────────────────────────────────────────────────

  void _showSnackBar(String msg, {bool isError = false}) {
    if (!mounted) return;
    SemanticsService.announce(msg, TextDirection.ltr);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.check_circle_outline,
              color: Colors.white,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(msg, style: const TextStyle(fontSize: 15))),
          ],
        ),
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
        content: Row(
          children: [
            const Icon(Icons.warning_amber_rounded,
                color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _ctrl.trackingReasonToMessage(reason),
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFFE65100),
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
        margin:
        const EdgeInsets.only(bottom: 80, left: 16, right: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  // ─── Panel de debug ───────────────────────────────────────────────────────

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

            // Unity cargando
            if (!_ctrl.unityLoaded)
              Container(
                color: const Color(0xFF00162D),
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: Color(0xFFFF6B00)),
                      SizedBox(height: 16),
                      Text(
                        'Cargando…',
                        style:
                        TextStyle(color: Colors.white, fontSize: 18),
                      ),
                    ],
                  ),
                ),
              ),

            // Calibración de cámara
            if (_ctrl.unityLoaded && _showCalibrationOverlay)
              Positioned.fill(
                child: ArCalibrationOverlay(
                  showVoiceHint: _ctrl.wakeWordAvailable,
                  onDismiss: () =>
                      setState(() => _showCalibrationOverlay = false),
                ),
              ),

            // Inicializando internos
            if (_ctrl.unityLoaded &&
                _ctrl.appState == AppReadyState.initializing)
              const ArInitializingOverlay(),

            // Esperando sesión (sin overlay de calibración visible)
            if (_ctrl.unityLoaded &&
                _ctrl.appState == AppReadyState.waitingSession &&
                !_showCalibrationOverlay)
              const ArWaitingSessionOverlay(),

            // Esperando que el usuario confirme
            if (_ctrl.unityLoaded &&
                _ctrl.appState == AppReadyState.waitingUser)
              ArWaitingUserOverlay(
                wakeWordAvailable: _ctrl.wakeWordAvailable,
                onReady: _ctrl.onUserReady,
              ),

            // Overlay de voz (estado ready)
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

            // Badge tracking inestable
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

            // Controles en estado ready
            if (_ctrl.unityLoaded && _ctrl.appState == AppReadyState.ready)
              ..._buildReadyControls(context),

            // Badge invitado
            if (_isGuest) _buildGuestBadge(context),

            // Badge salud del micrófono
            if (_micHealthVisible) _buildMicHealthBadge(context),
          ],
        ),
      ),
    );
  }

  // ─── Badge micrófono ──────────────────────────────────────────────────────

  Widget _buildMicHealthBadge(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    return Positioned(
      bottom: bottom + 100,
      left: 0,
      right: 0,
      child: Center(
        child: Semantics(
          liveRegion: true,
          label: _micHealthMessage,
          child: AnimatedOpacity(
            opacity: _micHealthVisible ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 300),
            child: Container(
              padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFE65100).withOpacity(0.88),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _micHealthMessage,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ─── Badge invitado ───────────────────────────────────────────────────────

  Widget _buildGuestBadge(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Positioned(
      top: top + 8,
      left: 12,
      child: Semantics(
        label: 'Modo invitado. Toca para salir.',
        button: true,
        child: GestureDetector(
          onTap: _exitGuestMode,
          child: Container(
            padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.65),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white24),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.person_outline_rounded,
                    color: Colors.white70, size: 15),
                SizedBox(width: 5),
                Text(
                  'Invitado',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(width: 8),
                Icon(Icons.close_rounded, color: Colors.white54, size: 14),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─── Controles en estado ready ────────────────────────────────────────────

  List<Widget> _buildReadyControls(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    final top    = MediaQuery.of(context).padding.top;
    return [
      // Botón mostrar/ocultar overlay de voz (top-right)
      Positioned(
        top: top + 8,
        right: 12,
        child: _ToggleOverlayButton(
          visible: _ctrl.showVoiceOverlay,
          onTap: _ctrl.toggleVoiceOverlay,
        ),
      ),

      // Botón debug (bottom-left)
      Positioned(
        bottom: bottom + 24,
        left: 16,
        child: _TestButton(
            open: _ctrl.showTestPanel, onTap: _toggleTestPanel),
      ),

      // Panel de debug animado
      AnimatedBuilder(
        animation: _testPanelAnimation,
        builder: (context, child) => Positioned(
          bottom: bottom + 80,
          left: 16,
          child: Transform.translate(
            offset:
            Offset(-300 * (1 - _testPanelAnimation.value), 0),
            child: Opacity(
                opacity: _testPanelAnimation.value, child: child),
          ),
        ),
        child: ArTestPanel(controller: _ctrl),
      ),
    ];
  }
}

// ─── Botón toggle overlay ─────────────────────────────────────────────────────

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
            Icon(
              visible ? Icons.visibility_off : Icons.mic,
              color: Colors.white,
              size: 16,
            ),
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

// ─── Botón debug ──────────────────────────────────────────────────────────────

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
        padding:
        const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: open
              ? const Color(0xFF7B1FA2).withOpacity(0.92)
              : Colors.black.withOpacity(0.72),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: open
                ? const Color(0xFFCE93D8)
                : Colors.white30,
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
              color: open
                  ? const Color(0xFFCE93D8)
                  : Colors.white70,
              size: 18,
            ),
            const SizedBox(width: 6),
            Text(
              open ? 'Cerrar' : 'Debug',
              style: TextStyle(
                color: open
                    ? const Color(0xFFCE93D8)
                    : Colors.white70,
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