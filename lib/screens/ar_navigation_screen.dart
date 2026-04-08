// lib/screens/ar_navigation_screen.dart
//
// ✅ v9.0 — Screen slim: solo orquesta build, animaciones y lifecycle.
// Toda la lógica vive en ArNavigationController.
// UI delegada a ArVoiceOverlay, ArTestPanel y los overlays de ar_overlays.dart.

import 'package:flutter/material.dart' hide NavigationMode;
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_unity_widget/flutter_unity_widget.dart';

import '../controllers/ar_navigation_controller.dart';
import '../widgets/ar_overlays.dart';
import '../widgets/ar_voice_overlay.dart';

class ArNavigationScreen extends StatefulWidget {
  const ArNavigationScreen({super.key});

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

  // ─── Lifecycle ────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupAnimations();

    _ctrl = ArNavigationController();
    _ctrl.onShowSnackBar      = _showSnackBar;
    _ctrl.onShowTrackingSnackBar = _showTrackingSnackBar;
    _ctrl.onHideTrackingSnackBar = () =>
        ScaffoldMessenger.of(context).hideCurrentSnackBar();

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
            // Unity siempre corriendo en background
            Positioned.fill(
              child: UnityWidget(
                onUnityCreated: _ctrl.onUnityCreated,
                onUnityMessage: _ctrl.onUnityMessage,
                fullscreen: true,
                useAndroidViewSurface: true,
              ),
            ),

            // Cargando Unity (widget no creado aún)
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
                          style: TextStyle(
                              color: Colors.white, fontSize: 18)),
                    ],
                  ),
                ),
              ),

            // Initializing: antes de scene_ready
            if (_ctrl.unityLoaded &&
                _ctrl.appState == AppReadyState.initializing)
              const ArInitializingOverlay(),

            // WaitingSession: scene_ready llegó, sesión cargando
            if (_ctrl.unityLoaded &&
                _ctrl.appState == AppReadyState.waitingSession)
              const ArWaitingSessionOverlay(),

            // WaitingUser: sin sesión previa
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

            // Botones de control (overlay/test) — solo en ready
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
      // Botón toggle overlay (top-right)
      Positioned(
        top: top + 8,
        right: 12,
        child: _ToggleOverlayButton(
          visible: _ctrl.showVoiceOverlay,
          onTap: _ctrl.toggleVoiceOverlay,
        ),
      ),
      // Botón abrir/cerrar test panel (bottom-left)
      Positioned(
        bottom: bottom + 24,
        left: 16,
        child: _TestButton(
          open: _ctrl.showTestPanel,
          onTap: _toggleTestPanel,
        ),
      ),
      // Test panel animado (bottom-left, sobre el botón)
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