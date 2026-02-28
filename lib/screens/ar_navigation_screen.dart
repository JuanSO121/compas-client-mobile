// lib/screens/ar_navigation_screen.dart
// ✅ v2 — Unity AR de fondo + overlay de voz encima
//   Cambios respecto a v1:
//   • _onUnityMessage conectado a _unityBridge.handleUnityMessage()
//   • _unityBridge.onResponse escucha confirmaciones de Unity (waypoint alcanzado, etc.)
//   • Chips "Guardar/Cargar" usan las acciones correctas del bridge v2
//   • _onUnityMessage era un stub vacío — ahora procesa respuestas reales

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

  // ─── Historial ────────────────────────────────────────────
  final List<_CommandItem> _history = [];
  static const int _maxHistory = 5;

  // ─── Animaciones ──────────────────────────────────────────
  late AnimationController _pulseController;
  late AnimationController _waveController;
  late Animation<double>   _pulseAnimation;
  late Animation<double>   _waveAnimation;

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
  }

  /// Registrar callbacks del bridge ANTES de que Unity cargue.
  void _setupUnityBridgeCallbacks() {
    _unityBridge.onResponse = (response) {
      if (!mounted) return;

      if (!response.ok) {
        _logger.w('[Bridge] ❌ ${response.action}: ${response.message}');
        _showSnackBar('⚠️ ${response.message}', isError: true);
        return;
      }

      _logger.i('[Bridge] ✅ ${response.action}: ${response.message}');

      // ✅ Unity avisa que el agente llegó → TTS anuncia automáticamente
      if (response.action == 'navigation_arrived') {
        _coordinator.speak(response.message);
        _showSnackBar('📍 ${response.message}');
        HapticFeedback.heavyImpact();
      }
    };

    // ✅ Lista de waypoints → TTS anuncia los destinos disponibles
    _unityBridge.onWaypointsReceived = (waypoints) {
      if (!mounted) return;
      _logger.i('[Bridge] 📍 ${waypoints.length} waypoint(s) recibidos de Unity');
      if (waypoints.isEmpty) {
        _coordinator.speak('No hay balizas guardadas todavía.');
      } else {
        final names = waypoints.map((w) => w.name).join(', ');
        _coordinator.speak('Destinos disponibles: $names');
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

      // ─── Callbacks voz ────────────────────────────────────
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

        // ✅ Delegar a Unity bridge — usa las acciones correctas del bridge v2
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

  /// ✅ CORREGIDO: era un stub vacío; ahora pasa el mensaje al bridge
  /// para que lo parsee y dispare onResponse / onWaypointsReceived.
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

  @override
  void dispose() {
    _pulseController.dispose();
    _waveController.dispose();
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

  Widget _buildStatusBar() {
    final isConnected = _unityBridge.isReady;
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
          Container(
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
            final diff   = DateTime.now().difference(item.time);
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
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildControlChip(
            icon:  Icons.save_outlined,
            label: 'Guardar',
            // ✅ Usa saveSession del bridge v2
            onTap: _unityBridge.isReady ? () => _unityBridge.saveSession() : null,
          ),
          _buildControlChip(
            icon:  Icons.folder_open_outlined,
            label: 'Cargar',
            // ✅ Usa loadSession del bridge v2
            onTap: _unityBridge.isReady ? () => _unityBridge.loadSession() : null,
          ),
          _buildControlChip(
            icon:  Icons.list_alt_rounded,
            label: 'Balizas',
            // ✅ NUEVO: consultar waypoints disponibles en Unity
            onTap: _unityBridge.isReady ? () => _unityBridge.listWaypoints() : null,
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
            },
          ),
        ],
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
      child: Opacity(
        opacity: enabled ? 1.0 : 0.4,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.65),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white24),
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