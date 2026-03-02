// lib/screens/ar_navigation_screen.dart
// ✅ v4 — Feature: Panel de testing con comandos rápidos
//          Fix: botones Guardar/Cargar/Balizas reactivos con ValueListenableBuilder
//          Fix: _unityBridge.isReadyNotifier notifica a la UI cuando Unity carga
//          Fix: _onUnityCreated actualiza isReadyNotifier → rebuild automático

import 'package:flutter/material.dart' hide NavigationMode;
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_unity_widget/flutter_unity_widget.dart';
import 'package:logger/logger.dart';

import '../models/shared_models.dart';
import '../services/AI/navigation_coordinator.dart';
import '../services/AI/ai_mode_controller.dart';
import '../services/unity_bridge_service.dart';

class ArNavigationScreen extends StatefulWidget {
  const ArNavigationScreen({super.key});

  @override
  State<ArNavigationScreen> createState() => _ArNavigationScreenState();
}

class _ArNavigationScreenState extends State<ArNavigationScreen>
    with TickerProviderStateMixin {

  // ─── Servicios ────────────────────────────────────────────
  final NavigationCoordinator _coordinator = NavigationCoordinator();
  final AIModeController      _aiModeController = AIModeController();
  final UnityBridgeService    _unityBridge = UnityBridgeService();
  final Logger                _logger = Logger();

  // ─── Estado de voz ────────────────────────────────────────
  bool             _isInitialized    = false;
  bool             _isActive         = false;
  String           _statusMessage    = 'Inicializando...';
  NavigationMode   _currentMode      = NavigationMode.eventBased;
  AIMode           _aiMode           = AIMode.auto;
  NavigationIntent? _currentIntent;
  bool             _wakeWordAvailable = false;

  // ─── Estado Unity ─────────────────────────────────────────
  bool _unityLoaded    = false;
  bool _showVoiceOverlay = true;

  // ─── Panel de testing ─────────────────────────────────────
  bool _showTestPanel = false;
  final TextEditingController _waypointNameController = TextEditingController(text: 'Baliza 1');
  final TextEditingController _navigateTargetController = TextEditingController(text: 'Entrada');
  int _waypointCounter = 1;

  // ─── Historial ────────────────────────────────────────────
  final List<_CommandItem> _history = [];
  static const int _maxHistory = 5;

  // ─── Animaciones ──────────────────────────────────────────
  late AnimationController _pulseController;
  late AnimationController _waveController;
  late AnimationController _testPanelController;
  late Animation<double>   _pulseAnimation;
  late Animation<double>   _waveAnimation;
  late Animation<double>   _testPanelAnimation;

  // ─── Lifecycle ────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _setupAnimations();
    _setupUnityBridgeCallbacks();
    _initializeVoice();
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

  void _setupUnityBridgeCallbacks() {
    _unityBridge.onResponse = (response) {
      if (!mounted) return;

      if (!response.ok) {
        _logger.w('[Bridge] ❌ ${response.action}: ${response.message}');
        _showSnackBar('⚠️ ${response.message}', isError: true);
        return;
      }

      _logger.i('[Bridge] ✅ ${response.action}: ${response.message}');

      if (response.action == 'navigation_arrived') {
        _coordinator.speak(response.message);
        _showSnackBar('📍 ${response.message}');
        HapticFeedback.heavyImpact();
      }
    };

    _unityBridge.onWaypointsReceived = (waypoints) {
      if (!mounted) return;
      _logger.i('[Bridge] 📍 ${waypoints.length} waypoint(s) recibidos de Unity');
      if (waypoints.isEmpty) {
        _coordinator.speak('No hay balizas guardadas todavía.');
        _showSnackBar('📍 No hay balizas aún');
      } else {
        final names = waypoints.map((w) => w.name).join(', ');
        _coordinator.speak('Destinos disponibles: $names');
        _showSnackBar('📍 ${waypoints.length} balizas: $names');
      }
    };
  }

  Future<void> _initializeVoice() async {
    try {
      setState(() => _statusMessage = 'Inicializando voz...');

      await _aiModeController.initialize();
      _aiMode = _aiModeController.currentMode;

      await _coordinator.initialize();
      _wakeWordAvailable = _coordinator.wakeWordAvailable;

      _coordinator.onStatusUpdate = (status) {
        if (mounted) setState(() => _statusMessage = status);
      };

      _coordinator.onIntentDetected = (intent) {
        if (!mounted) return;
        setState(() => _currentIntent = intent);
        SemanticsService.announce(
          'Comando: ${intent.suggestedResponse}',
          TextDirection.ltr,
        );
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) setState(() => _currentIntent = null);
        });
      };

      _coordinator.onCommandExecuted = (intent) {
        if (!mounted) return;
        _unityBridge.handleIntent(intent);
        _addToHistory(intent);
        _showSnackBar('✅ ${intent.suggestedResponse}');
        HapticFeedback.lightImpact();
      };

      _coordinator.onCommandRejected = (reason) {
        if (!mounted) return;
        _showSnackBar('⛔ $reason', isError: true);
        HapticFeedback.heavyImpact();
      };

      _aiModeController.onModeChanged = (mode) {
        if (mounted) setState(() => _aiMode = mode);
      };

      setState(() {
        _isInitialized    = true;
        _statusMessage    = _wakeWordAvailable
            ? '✅ Di "Oye COMPAS"'
            : '✅ Presiona para hablar';
      });

    } catch (e) {
      _logger.e('Error inicializando voz: $e');
      if (mounted) {
        setState(() {
          _statusMessage = 'Error: $e';
          _isInitialized = false;
        });
      }
    }
  }

  // ─── Unity callbacks ──────────────────────────────────────

  void _onUnityCreated(UnityWidgetController controller) {
    _unityBridge.setController(controller);
    setState(() => _unityLoaded = true);
    _logger.i('✅ Unity AR lista');
  }

  void _onUnityMessage(message) {
    _unityBridge.handleUnityMessage(message);
  }

  // ─── Controles de voz ─────────────────────────────────────

  Future<void> _toggleVoice() async {
    if (!_isInitialized) return;

    try {
      if (_isActive) {
        await _coordinator.stop();
        _pulseController.stop();
        _waveController.stop();
        setState(() {
          _isActive      = false;
          _statusMessage = 'Voz detenida';
        });
      } else {
        await _coordinator.start(mode: _currentMode);
        _pulseController.repeat(reverse: true);
        _waveController.repeat();
        setState(() {
          _isActive      = true;
          _statusMessage = _wakeWordAvailable
              ? 'Esperando "Oye COMPAS"...'
              : 'Escuchando...';
        });
      }
      HapticFeedback.mediumImpact();
    } catch (e) {
      _showSnackBar('Error: $e', isError: true);
    }
  }

  void _addToHistory(NavigationIntent intent) {
    setState(() {
      _history.insert(0, _CommandItem(intent: intent, time: DateTime.now()));
      if (_history.length > _maxHistory) _history.removeLast();
    });
  }

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
        backgroundColor: isError ? const Color(0xFFE53935) : const Color(0xFF43A047),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: Duration(seconds: isError ? 4 : 2),
      ),
    );
  }

  // ─── Testing panel helpers ────────────────────────────────

  void _toggleTestPanel() {
    setState(() => _showTestPanel = !_showTestPanel);
    if (_showTestPanel) {
      _testPanelController.forward();
    } else {
      _testPanelController.reverse();
    }
    HapticFeedback.selectionClick();
  }

  /// Simula un intent como si viniera del coordinador de voz
  void _fireTestIntent(NavigationIntent intent) {
    _unityBridge.handleIntent(intent);
    _addToHistory(intent);
    _showSnackBar('🧪 TEST: ${intent.suggestedResponse}');
    HapticFeedback.lightImpact();
    setState(() => _currentIntent = intent);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _currentIntent = null);
    });
  }

  void _testCreateWaypoint() {
    final name = _waypointNameController.text.trim();
    if (name.isEmpty) {
      _showSnackBar('⚠️ Escribe un nombre para la baliza', isError: true);
      return;
    }
    _fireTestIntent(NavigationIntent(
      type: IntentType.navigate,
      target: '__unity:create_waypoint:$name',
      priority: 6,
      suggestedResponse: 'Creando baliza "$name"',
    ));
    // Auto-increment para el próximo
    setState(() {
      _waypointCounter++;
      _waypointNameController.text = 'Baliza $_waypointCounter';
    });
  }

  void _testNavigateTo() {
    final target = _navigateTargetController.text.trim();
    if (target.isEmpty) {
      _showSnackBar('⚠️ Escribe un destino', isError: true);
      return;
    }
    _fireTestIntent(NavigationIntent(
      type: IntentType.navigate,
      target: target,
      priority: 8,
      suggestedResponse: 'Navegando a $target',
    ));
  }

  void _testStop() {
    _fireTestIntent(NavigationIntent(
      type: IntentType.stop,
      target: '',
      priority: 10,
      suggestedResponse: 'Navegación detenida',
    ));
  }

  void _testListWaypoints() {
    _fireTestIntent(NavigationIntent(
      type: IntentType.navigate,
      target: '__unity:list_waypoints',
      priority: 5,
      suggestedResponse: 'Consultando balizas',
    ));
  }

  void _testSaveSession() {
    _fireTestIntent(NavigationIntent(
      type: IntentType.navigate,
      target: '__unity:save_session',
      priority: 5,
      suggestedResponse: 'Guardando sesión',
    ));
  }

  void _testLoadSession() {
    _fireTestIntent(NavigationIntent(
      type: IntentType.navigate,
      target: '__unity:load_session',
      priority: 5,
      suggestedResponse: 'Cargando sesión',
    ));
  }

  void _testNavStatus() {
    if (!_unityBridge.isReady) {
      _showSnackBar('⚠️ Unity no está lista', isError: true);
      return;
    }
    _unityBridge.requestNavStatus();
    _showSnackBar('🧪 TEST: Consultando estado de navegación');
    HapticFeedback.lightImpact();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _waveController.dispose();
    _testPanelController.dispose();
    _waypointNameController.dispose();
    _navigateTargetController.dispose();
    _coordinator.dispose();
    _aiModeController.dispose();
    _unityBridge.dispose();
    super.dispose();
  }

  // ─── Build ────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Capa 1: Unity AR (fondo completo) ──────────────
          Positioned.fill(
            child: UnityWidget(
              onUnityCreated:  _onUnityCreated,
              onUnityMessage:  _onUnityMessage,
              fullscreen:              true,
              useAndroidViewSurface:   true,
            ),
          ),

          // ── Capa 2: Splash mientras carga Unity ─────────────
          if (!_unityLoaded)
            Container(
              color: const Color(0xFF00162D),
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Color(0xFFFF6B00)),
                    SizedBox(height: 16),
                    Text(
                      'Cargando AR...',
                      style: TextStyle(color: Colors.white, fontSize: 18),
                    ),
                  ],
                ),
              ),
            ),

          // ── Capa 3: Overlay de voz ───────────────────────────
          if (_unityLoaded && _showVoiceOverlay) _buildVoiceOverlay(),

          // ── Capa 4: Botón toggle overlay ─────────────────────
          if (_unityLoaded)
            Positioned(
              top:   MediaQuery.of(context).padding.top + 8,
              right: 12,
              child: _buildToggleOverlayButton(),
            ),

          // ── Capa 5: Botón TEST (esquina inferior izquierda) ───
          if (_unityLoaded)
            Positioned(
              bottom: MediaQuery.of(context).padding.bottom + 24,
              left:   16,
              child: _buildTestButton(),
            ),

          // ── Capa 6: Panel de testing (slide desde la izquierda) ──
          if (_unityLoaded)
            AnimatedBuilder(
              animation: _testPanelAnimation,
              builder: (context, child) {
                return Positioned(
                  bottom: MediaQuery.of(context).padding.bottom + 80,
                  left:   16,
                  child: Transform.translate(
                    offset: Offset(-300 * (1 - _testPanelAnimation.value), 0),
                    child: Opacity(
                      opacity: _testPanelAnimation.value,
                      child: child,
                    ),
                  ),
                );
              },
              child: _buildTestPanel(),
            ),
        ],
      ),
    );
  }

  // ─── Overlay de voz ──────────────────────────────────────

  Widget _buildVoiceOverlay() {
    return SafeArea(
      child: Column(
        children: [
          const SizedBox(height: 48),
          _buildStatusBar(),
          const Spacer(),
          if (_currentIntent != null) ...[
            _buildCurrentCommand(),
            const SizedBox(height: 12),
          ],
          if (_history.isNotEmpty) _buildCompactHistory(),
          const SizedBox(height: 16),
          _buildMainVoiceButton(),
          const SizedBox(height: 24),
          _buildSecondaryControls(),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildToggleOverlayButton() {
    return GestureDetector(
      onTap: () => setState(() => _showVoiceOverlay = !_showVoiceOverlay),
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
              _showVoiceOverlay ? Icons.visibility_off : Icons.mic,
              color: Colors.white,
              size: 16,
            ),
            const SizedBox(width: 6),
            Text(
              _showVoiceOverlay ? 'Ocultar' : 'Voz',
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  // ─── TEST BUTTON ──────────────────────────────────────────

  Widget _buildTestButton() {
    return GestureDetector(
      onTap: _toggleTestPanel,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: _showTestPanel
              ? const Color(0xFF7B1FA2).withOpacity(0.92)
              : Colors.black.withOpacity(0.72),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _showTestPanel
                ? const Color(0xFFCE93D8)
                : Colors.white30,
            width: 1.5,
          ),
          boxShadow: _showTestPanel ? [
            BoxShadow(
              color: const Color(0xFF7B1FA2).withOpacity(0.4),
              blurRadius: 12,
              spreadRadius: 2,
            ),
          ] : [],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _showTestPanel ? Icons.close_rounded : Icons.bug_report_rounded,
              color: _showTestPanel ? const Color(0xFFCE93D8) : Colors.white70,
              size: 18,
            ),
            const SizedBox(width: 6),
            Text(
              _showTestPanel ? 'Cerrar' : 'TEST',
              style: TextStyle(
                color: _showTestPanel ? const Color(0xFFCE93D8) : Colors.white70,
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

  // ─── TEST PANEL ───────────────────────────────────────────

  Widget _buildTestPanel() {
    return ValueListenableBuilder<bool>(
      valueListenable: _unityBridge.isReadyNotifier,
      builder: (context, isReady, _) {
        return Container(
          width: 290,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.55,
          ),
          decoration: BoxDecoration(
            color: const Color(0xFF0D0D1A).withOpacity(0.96),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFF7B1FA2).withOpacity(0.6), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF7B1FA2).withOpacity(0.25),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── Header ──────────────────────────────────
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF7B1FA2).withOpacity(0.3),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.bug_report_rounded,
                          color: Color(0xFFCE93D8),
                          size: 16,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Panel de Testing',
                        style: TextStyle(
                          color: Color(0xFFCE93D8),
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const Spacer(),
                      // Estado Unity
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: isReady
                              ? Colors.green.withOpacity(0.2)
                              : Colors.orange.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isReady ? Colors.greenAccent : Colors.orange,
                            width: 0.8,
                          ),
                        ),
                        child: Text(
                          isReady ? 'Unity ✓' : 'Unity ⏳',
                          style: TextStyle(
                            color: isReady ? Colors.greenAccent : Colors.orange,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 14),
                  _testSectionDivider('NAVEGACIÓN'),
                  const SizedBox(height: 10),

                  // ── Navegar a destino ────────────────────────
                  _buildTestInputRow(
                    controller: _navigateTargetController,
                    hint: 'Nombre del destino',
                    buttonLabel: 'Navegar',
                    buttonIcon: Icons.navigation_rounded,
                    color: const Color(0xFF1565C0),
                    accentColor: const Color(0xFF64B5F6),
                    onPressed: isReady ? _testNavigateTo : null,
                  ),

                  const SizedBox(height: 8),

                  // ── Stop ────────────────────────────────────
                  _buildTestActionButton(
                    label: 'Detener navegación',
                    icon: Icons.stop_circle_rounded,
                    color: const Color(0xFFB71C1C),
                    accentColor: const Color(0xFFEF9A9A),
                    onPressed: isReady ? _testStop : null,
                  ),

                  const SizedBox(height: 14),
                  _testSectionDivider('BALIZAS'),
                  const SizedBox(height: 10),

                  // ── Crear baliza ─────────────────────────────
                  _buildTestInputRow(
                    controller: _waypointNameController,
                    hint: 'Nombre de la baliza',
                    buttonLabel: 'Crear',
                    buttonIcon: Icons.add_location_alt_rounded,
                    color: const Color(0xFF1B5E20),
                    accentColor: const Color(0xFFA5D6A7),
                    onPressed: isReady ? _testCreateWaypoint : null,
                  ),

                  const SizedBox(height: 8),

                  // ── Listar balizas ───────────────────────────
                  _buildTestActionButton(
                    label: 'Listar balizas',
                    icon: Icons.list_alt_rounded,
                    color: const Color(0xFF0E4749),
                    accentColor: const Color(0xFF80CBC4),
                    onPressed: isReady ? _testListWaypoints : null,
                  ),

                  const SizedBox(height: 14),
                  _testSectionDivider('SESIÓN'),
                  const SizedBox(height: 10),

                  Row(
                    children: [
                      Expanded(
                        child: _buildTestActionButton(
                          label: 'Guardar',
                          icon: Icons.save_rounded,
                          color: const Color(0xFF1A237E),
                          accentColor: const Color(0xFF90CAF9),
                          onPressed: isReady ? _testSaveSession : null,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildTestActionButton(
                          label: 'Cargar',
                          icon: Icons.folder_open_rounded,
                          color: const Color(0xFF1A237E),
                          accentColor: const Color(0xFF90CAF9),
                          onPressed: isReady ? _testLoadSession : null,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 8),

                  // ── Estado de navegación ─────────────────────
                  _buildTestActionButton(
                    label: 'Estado de navegación',
                    icon: Icons.radar_rounded,
                    color: const Color(0xFF33691E),
                    accentColor: const Color(0xFFDCE775),
                    onPressed: isReady ? _testNavStatus : null,
                  ),

                  const SizedBox(height: 14),
                  _testSectionDivider('SISTEMA'),
                  const SizedBox(height: 10),

                  // ── Reset ────────────────────────────────────
                  _buildTestActionButton(
                    label: 'Reset completo',
                    icon: Icons.refresh_rounded,
                    color: const Color(0xFF4A148C),
                    accentColor: const Color(0xFFCE93D8),
                    onPressed: () {
                      _coordinator.reset();
                      setState(() {
                        _currentIntent = null;
                        _history.clear();
                        _waypointCounter = 1;
                        _waypointNameController.text = 'Baliza 1';
                        _navigateTargetController.text = 'Entrada';
                      });
                      _showSnackBar('🔄 Reset completo del sistema');
                      HapticFeedback.mediumImpact();
                    },
                  ),

                  const SizedBox(height: 4),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _testSectionDivider(String label) {
    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF9E9E9E),
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            height: 0.5,
            color: Colors.white12,
          ),
        ),
      ],
    );
  }

  Widget _buildTestInputRow({
    required TextEditingController controller,
    required String hint,
    required String buttonLabel,
    required IconData buttonIcon,
    required Color color,
    required Color accentColor,
    VoidCallback? onPressed,
  }) {
    final enabled = onPressed != null;
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 38,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(enabled ? 0.07 : 0.03),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white.withOpacity(0.12)),
            ),
            child: TextField(
              controller: controller,
              enabled: enabled,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(color: Colors.white.withOpacity(0.35), fontSize: 12),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                isDense: true,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: onPressed,
          child: AnimatedOpacity(
            opacity: enabled ? 1.0 : 0.35,
            duration: const Duration(milliseconds: 200),
            child: Container(
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: color.withOpacity(0.85),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: accentColor.withOpacity(0.5)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(buttonIcon, color: accentColor, size: 15),
                  const SizedBox(width: 5),
                  Text(
                    buttonLabel,
                    style: TextStyle(
                      color: accentColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTestActionButton({
    required String label,
    required IconData icon,
    required Color color,
    required Color accentColor,
    VoidCallback? onPressed,
  }) {
    final enabled = onPressed != null;
    return GestureDetector(
      onTap: onPressed,
      child: AnimatedOpacity(
        opacity: enabled ? 1.0 : 0.35,
        duration: const Duration(milliseconds: 200),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: color.withOpacity(0.75),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: accentColor.withOpacity(0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: accentColor, size: 16),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    color: accentColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Status bar + controles existentes ───────────────────

  Widget _buildStatusBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.65),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8, height: 8,
                  decoration: BoxDecoration(
                    color: _isActive ? Colors.greenAccent : Colors.grey,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _statusMessage,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const Spacer(),
          ValueListenableBuilder<bool>(
            valueListenable: _unityBridge.isReadyNotifier,
            builder: (context, isConnected, _) {
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.65),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.view_in_ar,
                      color: isConnected ? Colors.greenAccent : Colors.orange,
                      size: 14,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      isConnected ? 'AR Activo' : 'AR Cargando',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentCommand() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFFF6B00).withOpacity(0.85),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Icon(_getIntentIcon(_currentIntent!.type), color: Colors.white, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _currentIntent!.suggestedResponse,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactHistory() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.6),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _history.take(3).map((item) {
            final diff    = DateTime.now().difference(item.time);
            final timeStr = diff.inSeconds < 60
                ? 'hace ${diff.inSeconds}s'
                : 'hace ${diff.inMinutes}m';
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Icon(_getIntentIcon(item.intent.type), color: Colors.white70, size: 14),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      item.intent.suggestedResponse,
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    timeStr,
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildMainVoiceButton() {
    return GestureDetector(
      onTap: _isInitialized ? _toggleVoice : null,
      child: AnimatedBuilder(
        animation: _pulseAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: _isActive ? _pulseAnimation.value : 1.0,
            child: Container(
              width: 100, height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: !_isInitialized
                    ? Colors.grey.withOpacity(0.7)
                    : (_isActive
                    ? const Color(0xFFE53935).withOpacity(0.9)
                    : const Color(0xFFFF6B00).withOpacity(0.9)),
                boxShadow: [
                  BoxShadow(
                    color: (_isActive
                        ? const Color(0xFFE53935)
                        : const Color(0xFFFF6B00)).withOpacity(0.4),
                    blurRadius: 24,
                    spreadRadius: 4,
                  ),
                ],
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (_isActive)
                    AnimatedBuilder(
                      animation: _waveAnimation,
                      builder: (context, _) => Container(
                        width:  100 + (30 * _waveAnimation.value),
                        height: 100 + (30 * _waveAnimation.value),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withOpacity(
                                0.3 * (1 - _waveAnimation.value)),
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  Icon(
                    _isActive ? Icons.stop_rounded : Icons.mic_rounded,
                    color: Colors.white,
                    size: 46,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSecondaryControls() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: ValueListenableBuilder<bool>(
        valueListenable: _unityBridge.isReadyNotifier,
        builder: (context, isReady, _) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildControlChip(
                icon:  Icons.save_outlined,
                label: 'Guardar',
                onTap: isReady ? () {
                  _unityBridge.saveSession();
                  _showSnackBar('💾 Guardando sesión...');
                  HapticFeedback.lightImpact();
                } : null,
              ),
              _buildControlChip(
                icon:  Icons.folder_open_outlined,
                label: 'Cargar',
                onTap: isReady ? () {
                  _unityBridge.loadSession();
                  _showSnackBar('📂 Cargando sesión...');
                  HapticFeedback.lightImpact();
                } : null,
              ),
              _buildControlChip(
                icon:  Icons.list_alt_rounded,
                label: 'Balizas',
                onTap: isReady ? () {
                  _unityBridge.listWaypoints();
                  _showSnackBar('📍 Consultando balizas...');
                  HapticFeedback.lightImpact();
                } : null,
              ),
              _buildControlChip(
                icon:  Icons.refresh_rounded,
                label: 'Reset',
                onTap: () {
                  _coordinator.reset();
                  setState(() {
                    _currentIntent = null;
                    _history.clear();
                  });
                  _showSnackBar('🔄 Sistema reiniciado');
                  HapticFeedback.mediumImpact();
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildControlChip({
    required IconData icon,
    required String   label,
    VoidCallback?     onTap,
  }) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedOpacity(
        opacity: enabled ? 1.0 : 0.4,
        duration: const Duration(milliseconds: 300),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.65),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: enabled ? Colors.white38 : Colors.white24,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 22),
              const SizedBox(height: 4),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Helpers ──────────────────────────────────────────────

  IconData _getIntentIcon(IntentType type) {
    return switch (type) {
      IntentType.navigate  => Icons.navigation_rounded,
      IntentType.stop      => Icons.stop_circle_rounded,
      IntentType.describe  => Icons.description_rounded,
      IntentType.help      => Icons.help_rounded,
      _                    => Icons.question_mark_rounded,
    };
  }
}

// ─── Modelo interno ───────────────────────────────────────

class _CommandItem {
  final NavigationIntent intent;
  final DateTime         time;
  _CommandItem({required this.intent, required this.time});
}