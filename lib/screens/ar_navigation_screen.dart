// lib/screens/ar_navigation_screen.dart
// ✅ v8.5 — Botón Mask · Fix status message · Barras de segmentación via push automático
//
// ============================================================================
// CAMBIOS v8.4 → v8.5
// ============================================================================
//
//  FIX #1 — Barras de segmentación (ya funcional con UnityBridgeService v3.7
//    + SegmentationController v9.2 que hace PUSH automático en cada inferencia).
//    No hay cambio de código aquí: el callback onSegmentationRatioReceived
//    ya estaba conectado en _setupUnityBridgeCallbacks(). El bug era en Unity.
//
//  FIX #2 — Botón "Mask" en sección SEGMENTACIÓN del panel de testing.
//    • Estado local _segMaskVisible (bool, default true).
//    • Botón alterna entre "Máscara ON" y "Máscara OFF" con icono y color
//      distintos según el estado.
//    • Al pulsar llama _unityBridge.toggleSegMask() y alterna _segMaskVisible.
//
//  FIX #3 — Status message al final de _onSessionLoadResponse.
//    ANTES: el mensaje final era inútil porque aparecía cuando ya no importaba
//    y no comunicaba qué debe hacer el usuario.
//    AHORA:
//      • Sin wake word → 'Presiona el micrófono para hablar'  (accionable)
//      • Con wake word → 'Di "Oye COMPAS" para navegar'       (accionable)
//    El mensaje intermedio "Cargando sesión..." en _onUserReady se mantiene
//    porque es el estado del overlay de carga, que es transitorio y correcto.
//
//  TODO LO DEMÁS ES IDÉNTICO A v8.4.

import 'dart:async';
import 'package:flutter/material.dart' hide NavigationMode;
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_unity_widget/flutter_unity_widget.dart';
import 'package:logger/logger.dart';

import '../models/shared_models.dart';
import '../services/AI/navigation_coordinator.dart';
import '../services/AI/ai_mode_controller.dart';
import '../services/AI/waypoint_context_service.dart';
import '../services/unity_bridge_service.dart';
import '../services/voice_navigation_service.dart';

// ─── Etapas de inicialización ─────────────────────────────────────────────

enum _AppReadyState {
  initializing,
  waitingUser,
  loadingSession,
  ready,
}

// ─── Screen ───────────────────────────────────────────────────────────────

class ArNavigationScreen extends StatefulWidget {
  const ArNavigationScreen({super.key});

  @override
  State<ArNavigationScreen> createState() => _ArNavigationScreenState();
}

class _ArNavigationScreenState extends State<ArNavigationScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {

  // ─── Servicios ────────────────────────────────────────────
  final NavigationCoordinator  _coordinator      = NavigationCoordinator();
  final AIModeController       _aiModeController = AIModeController();
  final UnityBridgeService     _unityBridge      = UnityBridgeService();
  final VoiceNavigationService _voiceNav         = VoiceNavigationService();
  final WaypointContextService _waypointContext  = WaypointContextService();
  final Logger                 _logger           = Logger();

  // ─── Estado de inicialización por etapas ──────────────────
  _AppReadyState _appState             = _AppReadyState.initializing;
  bool           _flutterServicesReady = false;
  bool           _unityReady           = false;
  Timer?         _sessionLoadTimeout;

  // ─── Estado de voz ────────────────────────────────────────
  bool              _isInitialized     = false;
  bool              _isActive          = false;
  String            _statusMessage     = 'Inicializando...';
  NavigationMode    _currentMode       = NavigationMode.eventBased;
  AIMode            _aiMode            = AIMode.auto;
  NavigationIntent? _currentIntent;
  bool              _wakeWordAvailable = false;

  // ─── Estado Unity ─────────────────────────────────────────
  bool _unityLoaded      = false;
  bool _showVoiceOverlay = true;

  // ─── Estado de tracking AR ────────────────────────────────
  bool   _arTrackingStable = true;
  String _arTrackingState  = '';
  String _arTrackingReason = '';
  Timer? _trackingWarningTimer;

  // ─── Panel de testing ─────────────────────────────────────
  bool _showTestPanel = false;
  final TextEditingController _waypointNameController =
      TextEditingController(text: 'Baliza 1');
  final TextEditingController _navigateTargetController =
      TextEditingController(text: 'Entrada');
  final TextEditingController _ttsTestController =
      TextEditingController(text: 'Claro, ¿en qué puedo ayudarte?');
  int _waypointCounter = 1;

  // ─── Segmentación ────────────────────────────────────────
  double _segObstacle   = 0;
  double _segFloor      = 0;
  double _segWall       = 0;
  double _segBackground = 0;
  static const double _obstacleAlertThreshold = 0.12;

  // ✅ v8.5 FIX #2 — Estado local de la máscara de segmentación.
  // Refleja el estado del overlay en Unity (optimista: asumimos que
  // Unity arranca con _showOverlay=true en SegmentationController).
  bool _segMaskVisible = true;

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
    WidgetsBinding.instance.addObserver(this);
    _setupAnimations();
    _setupUnityBridgeCallbacks();
    _initializeServices();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (!_wakeWordAvailable || !_isInitialized) return;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
        _coordinator.wakeWordService.pause();
        _logger.d('[Lifecycle] App pausada — wake word pausado');
        break;
      case AppLifecycleState.resumed:
        Future.delayed(const Duration(milliseconds: 800), () {
          if (mounted && _isActive && _wakeWordAvailable) {
            _coordinator.wakeWordService.resume();
            _logger.d('[Lifecycle] App reanudada — wake word reanudado');
          }
        });
        break;
      default:
        break;
    }
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

  // ─── Unity bridge callbacks ───────────────────────────────────────────────

  void _setupUnityBridgeCallbacks() {
    _unityBridge.onResponse = (response) {
      if (!mounted) return;

      if (response.action == 'session_loaded' ||
          response.action == 'session_load_failed') {
        _sessionLoadTimeout?.cancel();
        _onSessionLoadResponse(
          success: response.ok,
          message: response.message,
        );
        return;
      }

      if (!response.ok) {
        _logger.w('[Bridge] ❌ ${response.action}: ${response.message}');
        _showSnackBar('⚠️ ${response.message}', isError: true);
        return;
      }

      _logger.i('[Bridge] ✅ ${response.action}: ${response.message}');

      if (response.action == 'navigation_arrived') {
        if (_voiceNav.isReady) {
          _voiceNav.speak(response.message);
        } else {
          _coordinator.speak(response.message);
        }
        _coordinator.resetNavigation();
        _showSnackBar('📍 ${response.message}');
        HapticFeedback.heavyImpact();
      }
    };

    _unityBridge.onWaypointsReceived = (waypoints) {
      if (!mounted) return;
      _logger.i('[Bridge] 📍 ${waypoints.length} waypoint(s) recibidos de Unity');
      _waypointContext.updateFromUnity(waypoints);
    };

    _unityBridge.onTrackingStateChanged = _onTrackingStateChanged;

    // ✅ Segmentación en tiempo real — ahora funciona porque SegmentationController
    // v9.2 hace PUSH automático después de cada inferencia completada.
    // Este callback recibe los datos y actualiza el estado del panel.
    _unityBridge.onSegmentationRatioReceived = (obs, floor, wall) {
      if (!mounted) return;
      setState(() {
        _segObstacle   = obs;
        _segFloor      = floor;
        _segWall       = wall;
        _segBackground = (1.0 - obs - floor - wall).clamp(0.0, 1.0);
      });
    };

    // v8.3: onVoiceStatusReceived se asigna en _onUnityCreated()
    // DESPUÉS de attachUnityBridge() para no sobreescribir el coordinator.
  }

  // ─── Máquina de estados de inicialización ────────────────────────────────

  void _tryAdvanceToWaitingUser() {
    if (!mounted) return;
    if (_appState != _AppReadyState.initializing) return;
    if (!_flutterServicesReady || !_unityReady) return;

    _logger.i('[AppState] initializing → waitingUser');
    setState(() {
      _appState      = _AppReadyState.waitingUser;
      _statusMessage = '¿Listo para navegar?';
    });
    _coordinator.speak('Bienvenido. Di "Estoy listo" cuando quieras comenzar.');
  }

  void _onUserReady() {
    if (_appState != _AppReadyState.waitingUser) return;

    _logger.i('[AppState] waitingUser → loadingSession');
    setState(() {
      _appState      = _AppReadyState.loadingSession;
      _statusMessage = 'Cargando sesión...';
    });

    _unityBridge.loadSession();

    // Timeout de seguridad: si Unity no responde en 8s, avanzamos a ready
    // para no bloquear al usuario. Es la razón de ser de este timeout.
    _sessionLoadTimeout = Timer(const Duration(seconds: 8), () {
      _logger.w('[AppState] Timeout esperando session_loaded — avanzando a ready');
      _onSessionLoadResponse(
        success: false,
        message: 'No se encontró sesión guardada.',
      );
    });
  }

  void _onSessionLoadResponse({required bool success, required String message}) {
    if (!mounted) return;
    if (_appState != _AppReadyState.loadingSession) return;

    _logger.i('[AppState] loadingSession → ready (success: $success)');
    setState(() => _appState = _AppReadyState.ready);

    if (_unityBridge.isReady) {
      _unityBridge.listWaypoints();
    }

    final msg = success
        ? 'Sesión cargada. Listo para navegar.'
        : 'No hay sesión guardada. Puedes crear balizas.';

    _voiceNav.isReady ? _voiceNav.speak(msg) : _coordinator.speak(msg);

    // ✅ v8.5 FIX #3 — Status message accionable según si hay micrófono disponible.
    // ANTES: el mensaje era inútil ("Di Oye COMPAS..." cuando el micrófono
    //        no estaba activo aún, o "Presiona para hablar" que no indicaba qué).
    // AHORA: mensaje claro y accionable que refleja el estado real del sistema.
    setState(() => _statusMessage = _wakeWordAvailable
        ? 'Di "Oye COMPAS" para navegar'
        : 'Presiona el micrófono para hablar');
  }

  // ─── Tracking state ───────────────────────────────────────────────────────

  void _onTrackingStateChanged(bool isStable, String state, String reason) {
    if (!mounted) return;
    setState(() {
      _arTrackingStable = isStable;
      _arTrackingState  = state;
      _arTrackingReason = reason;
    });
    if (!isStable) {
      _showTrackingSnackBar(reason.isNotEmpty ? reason : state);
      _trackingWarningTimer?.cancel();
      _trackingWarningTimer = Timer(const Duration(seconds: 6), () {
        if (mounted && !_arTrackingStable) {
          _showTrackingSnackBar(
            _arTrackingReason.isNotEmpty ? _arTrackingReason : _arTrackingState,
          );
        }
      });
    } else {
      _trackingWarningTimer?.cancel();
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
    }
  }

  void _showTrackingSnackBar(String reason) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _trackingReasonToMessage(reason),
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFFE65100),
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  String _trackingReasonToMessage(String reason) {
    switch (reason) {
      case 'ExcessiveMotion':      return 'Movimiento muy rápido — mueve el dispositivo más despacio.';
      case 'InsufficientFeatures': return 'Superficie sin textura — apunta la cámara a una zona con detalles.';
      case 'InsufficientLight':    return 'Poca luz — busca una zona más iluminada.';
      case 'Relocalizing':         return 'Relocalizando — mantén el dispositivo quieto un momento.';
      case 'Initializing':
      case 'SessionInitializing':  return 'Iniciando tracking AR — mueve lentamente el dispositivo.';
      case 'Unsupported':          return 'Tracking AR no disponible en este dispositivo.';
      default:                     return 'Tracking AR inestable — mueve el dispositivo lentamente.';
    }
  }

  // ─── initializeServices ──────────────────────────────────────────────────

  Future<void> _initializeServices() async {
    try {
      setState(() => _statusMessage = 'Inicializando servicios...');

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

        if (intent.type == IntentType.navigate &&
            !intent.target.startsWith('__unity:')) {
          _voiceNav.resetDeduplication();
        }
        if (intent.type == IntentType.stop) {
          _voiceNav.stop();
        }

        if (intent.target == '__app:user_ready' &&
            _appState == _AppReadyState.waitingUser) {
          _onUserReady();
        }
      };

      _coordinator.onCommandRejected = (reason) {
        if (!mounted) return;
        _showSnackBar('⛔ $reason', isError: true);
        HapticFeedback.heavyImpact();
      };

      _aiModeController.onModeChanged = (mode) {
        if (mounted) setState(() => _aiMode = mode);
      };

      await _voiceNav.initialize(_coordinator.ttsService);
      _voiceNav.attachToUnityBridge(_unityBridge);

      if (_coordinator.wakeWordAvailable) {
        _voiceNav.attachWakeWordService(_coordinator.wakeWordService);
      }

      _logger.i('[Screen] ✅ VoiceNavigationService inicializado.');

      setState(() => _isInitialized = true);
      _flutterServicesReady = true;
      _tryAdvanceToWaitingUser();

    } catch (e) {
      _logger.e('[Screen] Error inicializando servicios: $e');
      if (mounted) {
        setState(() {
          _statusMessage = 'Error: $e';
          _isInitialized = false;
        });
      }
    }
  }

  // ─── Unity callbacks ──────────────────────────────────────────────────────

  void _onUnityCreated(UnityWidgetController controller) {
    _unityBridge.setController(controller);
    _voiceNav.setUnityController(controller);

    // v8.3 FIX: attachUnityBridge() PRIMERO, luego envolver el callback.
    _coordinator.attachUnityBridge(_unityBridge);

    final coordinatorCallback = _unityBridge.onVoiceStatusReceived;

    _unityBridge.onVoiceStatusReceived = (info) {
      coordinatorCallback?.call(info);
      if (!mounted) return;
      final msg = info.isGuiding
          ? '📊 Guiando → ${info.destination} (${info.remainingSteps} pasos)'
          : info.isPreprocessing
              ? '📊 Calculando ruta...'
              : '📊 Sin navegación activa';
      _showSnackBar(msg);
    };

    setState(() => _unityLoaded = true);
    _logger.i('✅ Unity AR lista — bridge conectado (v8.5)');

    _unityReady = true;
    _tryAdvanceToWaitingUser();
  }

  void _onUnityMessage(message) {
    _unityBridge.handleUnityMessage(message);
  }

  // ─── Controles de voz ─────────────────────────────────────────────────────

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

  // ─── Testing panel helpers ────────────────────────────────────────────────

  void _toggleTestPanel() {
    setState(() => _showTestPanel = !_showTestPanel);
    _showTestPanel
        ? _testPanelController.forward()
        : _testPanelController.reverse();
    HapticFeedback.selectionClick();
  }

  void _fireTestIntent(NavigationIntent intent) {
    _unityBridge.handleIntent(intent);
    _addToHistory(intent);
    _showSnackBar('🧪 ${intent.suggestedResponse}');
    HapticFeedback.lightImpact();
    setState(() => _currentIntent = intent);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _currentIntent = null);
    });
  }

  // Auto-guardado de sesión después de crear baliza
  void _testCreateWaypoint() {
    final name = _waypointNameController.text.trim();
    if (name.isEmpty) {
      _showSnackBar('⚠️ Escribe un nombre', isError: true);
      return;
    }
    _fireTestIntent(NavigationIntent(
      type: IntentType.navigate,
      target: '__unity:create_waypoint:$name',
      priority: 6,
      suggestedResponse: 'Creando baliza "$name"',
    ));
    // Auto-guardado: espera a que Unity procese create_waypoint
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) {
        _unityBridge.saveSession();
        _logger.i('[Test] Auto-guardado tras crear baliza "$name"');
      }
    });
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
    _voiceNav.resetDeduplication();
    _fireTestIntent(NavigationIntent(
      type: IntentType.navigate,
      target: target,
      priority: 8,
      suggestedResponse: 'Navegando a $target',
    ));
  }

  void _testStop() {
    _voiceNav.stop();
    _coordinator.resetNavigation();
    _fireTestIntent(NavigationIntent(
      type: IntentType.stop,
      target: '',
      priority: 10,
      suggestedResponse: 'Navegación detenida',
    ));
  }

  void _testRepeatInstruction() {
    if (!_unityBridge.isReady) {
      _showSnackBar('⚠️ Unity no lista', isError: true);
      return;
    }
    _unityBridge.repeatInstruction();
    _showSnackBar('🔁 Repetir instrucción enviado');
    HapticFeedback.lightImpact();
  }

  void _testStopVoice() {
    if (!_unityBridge.isReady) {
      _showSnackBar('⚠️ Unity no lista', isError: true);
      return;
    }
    _unityBridge.stopVoice();
    _showSnackBar('🔇 Silenciar guía enviado');
    HapticFeedback.lightImpact();
  }

  void _testVoiceStatus() {
    if (!_unityBridge.isReady) {
      _showSnackBar('⚠️ Unity no lista', isError: true);
      return;
    }
    _unityBridge.requestVoiceStatus();
    _showSnackBar('📊 voice_status solicitado');
    HapticFeedback.lightImpact();
  }

  void _testTTSSpeak() {
    if (!_unityBridge.isReady) {
      _showSnackBar('⚠️ Unity no lista', isError: true);
      return;
    }
    final text = _ttsTestController.text.trim();
    if (text.isEmpty) {
      _showSnackBar('⚠️ Escribe un texto', isError: true);
      return;
    }
    _unityBridge.speakArbitraryText(text, priority: 1, interrupt: false);
    _showSnackBar('💬 tts_speak enviado');
    HapticFeedback.lightImpact();
  }

  // ✅ v8.5 FIX #2 — Toggle máscara de segmentación
  void _testToggleSegMask() {
    if (!_unityBridge.isReady) {
      _showSnackBar('⚠️ Unity no lista', isError: true);
      return;
    }
    _unityBridge.toggleSegMask();
    setState(() => _segMaskVisible = !_segMaskVisible);
    _showSnackBar(_segMaskVisible ? '🎭 Máscara activada' : '🎭 Máscara desactivada');
    HapticFeedback.lightImpact();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sessionLoadTimeout?.cancel();
    _trackingWarningTimer?.cancel();
    _pulseController.dispose();
    _waveController.dispose();
    _testPanelController.dispose();
    _waypointNameController.dispose();
    _navigateTargetController.dispose();
    _ttsTestController.dispose();
    _coordinator.dispose();
    _aiModeController.dispose();
    _unityBridge.dispose();
    _voiceNav.dispose();
    _waypointContext.dispose();
    super.dispose();
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: UnityWidget(
              onUnityCreated:        _onUnityCreated,
              onUnityMessage:        _onUnityMessage,
              fullscreen:            true,
              useAndroidViewSurface: true,
            ),
          ),

          if (!_unityLoaded)
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

          if (_unityLoaded && _appState == _AppReadyState.waitingUser)
            _buildWaitingUserOverlay(),

          if (_unityLoaded && _appState == _AppReadyState.loadingSession)
            _buildLoadingSessionOverlay(),

          if (_unityLoaded && _appState == _AppReadyState.ready && _showVoiceOverlay)
            _buildVoiceOverlay(),

          // Tracking inestable
          if (_unityLoaded && _appState == _AppReadyState.ready && !_arTrackingStable)
            Positioned(
              top: MediaQuery.of(context).padding.top + 50,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE65100).withOpacity(0.92),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.3),
                        blurRadius: 8,
                      )
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.sync_problem, color: Colors.white, size: 15),
                      const SizedBox(width: 6),
                      Text(
                        _arTrackingReason.isNotEmpty
                            ? 'Tracking: $_arTrackingReason'
                            : 'Tracking inestable',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Botones superiores + panel de testing
          if (_unityLoaded && _appState == _AppReadyState.ready) ...[
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              right: 12,
              child: _buildToggleOverlayButton(),
            ),
            Positioned(
              bottom: MediaQuery.of(context).padding.bottom + 24,
              left: 16,
              child: _buildTestButton(),
            ),
            AnimatedBuilder(
              animation: _testPanelAnimation,
              builder: (context, child) => Positioned(
                bottom: MediaQuery.of(context).padding.bottom + 80,
                left: 16,
                child: Transform.translate(
                  offset: Offset(-300 * (1 - _testPanelAnimation.value), 0),
                  child: Opacity(
                    opacity: _testPanelAnimation.value,
                    child: child,
                  ),
                ),
              ),
              child: _buildTestPanel(),
            ),
          ],
        ],
      ),
    );
  }

  // ─── Overlays ─────────────────────────────────────────────────────────────

  Widget _buildWaitingUserOverlay() {
    return Container(
      color: Colors.black.withOpacity(0.78),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFFF6B00).withOpacity(0.15),
                    border: Border.all(
                      color: const Color(0xFFFF6B00).withOpacity(0.6),
                      width: 2,
                    ),
                  ),
                  child: const Icon(Icons.navigation_rounded,
                      color: Color(0xFFFF6B00), size: 40),
                ),
                const SizedBox(height: 24),
                const Text(
                  'COMPAS listo',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'El entorno AR está preparado.\nConfirma cuando estés listo para cargar tu sesión.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 15,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 36),
                GestureDetector(
                  onTap: _onUserReady,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 32, vertical: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF6B00),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFFF6B00).withOpacity(0.4),
                          blurRadius: 20,
                          spreadRadius: 2,
                        )
                      ],
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_circle_outline_rounded,
                            color: Colors.white, size: 22),
                        SizedBox(width: 10),
                        Text(
                          'Estoy listo',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (_wakeWordAvailable)
                  Text(
                    'o di "Oye COMPAS: Estoy listo"',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.45),
                      fontSize: 13,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingSessionOverlay() {
    return Container(
      color: Colors.black.withOpacity(0.78),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFFFF6B00)),
            SizedBox(height: 20),
            Text(
              'Cargando sesión...',
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Overlay de voz ──────────────────────────────────────────────────────

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
          boxShadow: _showTestPanel
              ? [
                  BoxShadow(
                    color: const Color(0xFF7B1FA2).withOpacity(0.4),
                    blurRadius: 12,
                    spreadRadius: 2,
                  )
                ]
              : [],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _showTestPanel
                  ? Icons.close_rounded
                  : Icons.bug_report_rounded,
              color: _showTestPanel
                  ? const Color(0xFFCE93D8)
                  : Colors.white70,
              size: 18,
            ),
            const SizedBox(width: 6),
            Text(
              _showTestPanel ? 'Cerrar' : 'Test',
              style: TextStyle(
                color: _showTestPanel
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

  // ─── Panel de testing ─────────────────────────────────────────────────────

  Widget _buildTestPanel() {
    return ValueListenableBuilder<bool>(
      valueListenable: _unityBridge.isReadyNotifier,
      builder: (context, isReady, _) {
        return Container(
          width: 290,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.70,
          ),
          decoration: BoxDecoration(
            color: const Color(0xFF0D0D1A).withOpacity(0.96),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: const Color(0xFF7B1FA2).withOpacity(0.6),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF7B1FA2).withOpacity(0.25),
                blurRadius: 20,
                spreadRadius: 2,
              )
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

                  // ── Header ───────────────────────────────────────────────
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF7B1FA2).withOpacity(0.3),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.bug_report_rounded,
                            color: Color(0xFFCE93D8), size: 16),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Panel de testing',
                        style: TextStyle(
                          color: Color(0xFFCE93D8),
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const Spacer(),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildStatusBadge(
                              label: isReady ? 'AR ✓' : 'AR ⏳',
                              active: isReady),
                          const SizedBox(width: 4),
                          ValueListenableBuilder<bool>(
                            valueListenable: _voiceNav.isReadyNotifier,
                            builder: (_, ttsReady, __) => _buildStatusBadge(
                                label: ttsReady ? 'TTS ✓' : 'TTS ⏳',
                                active: ttsReady),
                          ),
                          const SizedBox(width: 4),
                          _buildStatusBadge(
                            label: _arTrackingStable ? 'AR📡✓' : 'AR📡⚠',
                            active: _arTrackingStable,
                          ),
                        ],
                      ),
                    ],
                  ),

                  // ── NAVEGACIÓN ───────────────────────────────────────────
                  const SizedBox(height: 14),
                  _testSectionDivider('NAVEGACIÓN'),
                  const SizedBox(height: 10),
                  _buildTestInputRow(
                    controller: _navigateTargetController,
                    hint: 'Nombre del destino',
                    buttonLabel: 'Ir',
                    buttonIcon: Icons.navigation_rounded,
                    color: const Color(0xFF1565C0),
                    accentColor: const Color(0xFF64B5F6),
                    onPressed: isReady ? _testNavigateTo : null,
                  ),
                  const SizedBox(height: 8),
                  _buildTestActionButton(
                    label: 'Detener navegación',
                    icon: Icons.stop_circle_rounded,
                    color: const Color(0xFFB71C1C),
                    accentColor: const Color(0xFFEF9A9A),
                    onPressed: isReady ? _testStop : null,
                  ),

                  // ── BALIZAS ──────────────────────────────────────────────
                  const SizedBox(height: 14),
                  _testSectionDivider('BALIZAS'),
                  const SizedBox(height: 10),

                  StreamBuilder<List<WaypointEntry>>(
                    stream: _waypointContext.onWaypointsChanged,
                    builder: (_, __) {
                      if (!_waypointContext.hasWaypoints) {
                        return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 7),
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: Colors.blue.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: Colors.blue.withOpacity(0.2)),
                          ),
                          child: const Row(children: [
                            Icon(Icons.info_outline,
                                color: Colors.lightBlueAccent, size: 13),
                            SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Sin balizas aún. Crea una para comenzar.',
                                style: TextStyle(
                                    color: Colors.lightBlueAccent,
                                    fontSize: 11),
                              ),
                            ),
                          ]),
                        );
                      }
                      final names = _waypointContext.navigableWaypoints
                          .map((w) => w.name)
                          .join(', ');
                      return Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 7),
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: Colors.green.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: Colors.green.withOpacity(0.2)),
                        ),
                        child: Row(children: [
                          const Icon(Icons.location_on,
                              color: Colors.greenAccent, size: 13),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              names,
                              style: const TextStyle(
                                  color: Colors.greenAccent, fontSize: 11),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ]),
                      );
                    },
                  ),

                  _buildTestInputRow(
                    controller: _waypointNameController,
                    hint: 'Nombre de la baliza',
                    buttonLabel: 'Crear',
                    buttonIcon: Icons.add_location_alt_rounded,
                    color: const Color(0xFF1B5E20),
                    accentColor: const Color(0xFFA5D6A7),
                    onPressed: isReady ? _testCreateWaypoint : null,
                  ),

                  // ── GUÍA DE VOZ ──────────────────────────────────────────
                  const SizedBox(height: 14),
                  _testSectionDivider('GUÍA DE VOZ'),
                  const SizedBox(height: 10),

                  _buildTestInputRow(
                    controller: _ttsTestController,
                    hint: 'Texto para COMPAS TTS',
                    buttonLabel: 'Hablar',
                    buttonIcon: Icons.record_voice_over_rounded,
                    color: const Color(0xFF4A148C),
                    accentColor: const Color(0xFFCE93D8),
                    onPressed: isReady ? _testTTSSpeak : null,
                  ),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                      child: _buildTestActionButton(
                        label: 'Repetir',
                        icon: Icons.replay_rounded,
                        color: const Color(0xFF004D40),
                        accentColor: const Color(0xFF80CBC4),
                        onPressed: isReady ? _testRepeatInstruction : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildTestActionButton(
                        label: 'Silenciar',
                        icon: Icons.voice_over_off_rounded,
                        color: const Color(0xFF37474F),
                        accentColor: const Color(0xFFB0BEC5),
                        onPressed: isReady ? _testStopVoice : null,
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  _buildTestActionButton(
                    label: 'Estado de guía',
                    icon: Icons.info_outline_rounded,
                    color: const Color(0xFF1A237E),
                    accentColor: const Color(0xFF90CAF9),
                    onPressed: isReady ? _testVoiceStatus : null,
                  ),

                  // ── SEGMENTACIÓN ─────────────────────────────────────────
                  const SizedBox(height: 14),
                  _testSectionDivider('SEGMENTACIÓN'),
                  const SizedBox(height: 10),

                  // ✅ v8.5 FIX #2 — Botón toggle máscara de segmentación
                  _buildTestActionButton(
                    label: _segMaskVisible ? 'Ocultar máscara AR' : 'Mostrar máscara AR',
                    icon: _segMaskVisible ? Icons.layers_clear : Icons.layers,
                    color: _segMaskVisible
                        ? const Color(0xFF4A148C)
                        : const Color(0xFF1B5E20),
                    accentColor: _segMaskVisible
                        ? const Color(0xFFCE93D8)
                        : const Color(0xFFA5D6A7),
                    onPressed: isReady ? _testToggleSegMask : null,
                  ),
                  const SizedBox(height: 10),

                  _buildSegmentationBars(),

                  const SizedBox(height: 4),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ─── Barras de segmentación ───────────────────────────────────────────────

  Widget _buildSegmentationBars() {
    final isAlert = _segObstacle >= _obstacleAlertThreshold;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isAlert
              ? Colors.red.withOpacity(0.4)
              : Colors.white.withOpacity(0.08),
        ),
      ),
      child: Column(
        children: [
          _buildSegBar(
            label: 'Background',
            value: _segBackground,
            color: const Color(0xFF888780),
          ),
          const SizedBox(height: 6),
          _buildSegBar(
            label: 'Obstacle',
            value: _segObstacle,
            color: const Color(0xFFE24B4A),
            alert: isAlert,
          ),
          const SizedBox(height: 6),
          _buildSegBar(
            label: 'Floor',
            value: _segFloor,
            color: const Color(0xFF1D9E75),
          ),
          const SizedBox(height: 6),
          _buildSegBar(
            label: 'Wall',
            value: _segWall,
            color: const Color(0xFF378ADD),
          ),
        ],
      ),
    );
  }

  Widget _buildSegBar({
    required String label,
    required double value,
    required Color color,
    bool alert = false,
  }) {
    final pct = (value * 100).toStringAsFixed(1);
    return Row(
      children: [
        SizedBox(
          width: 68,
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: alert ? Colors.red[200] : Colors.grey[500],
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: value.clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: Colors.white.withOpacity(0.08),
              valueColor: AlwaysStoppedAnimation<Color>(
                alert ? const Color(0xFFE24B4A) : color,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 40,
          child: Text(
            '$pct%',
            style: TextStyle(
              fontSize: 11,
              color: alert ? Colors.red[300] : Colors.grey[500],
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            textAlign: TextAlign.right,
          ),
        ),
        if (alert) ...[
          const SizedBox(width: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: const Color(0xFFB71C1C).withOpacity(0.6),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text(
              '⚠',
              style: TextStyle(fontSize: 9, color: Color(0xFFEF9A9A)),
            ),
          ),
        ],
      ],
    );
  }

  // ─── Widgets helpers del panel ────────────────────────────────────────────

  Widget _buildStatusBadge({required String label, required bool active}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: active
            ? Colors.green.withOpacity(0.2)
            : Colors.orange.withOpacity(0.2),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(
          color: active ? Colors.greenAccent : Colors.orange,
          width: 0.8,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: active ? Colors.greenAccent : Colors.orange,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _testSectionDivider(String label) {
    return Row(children: [
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
      Expanded(child: Container(height: 0.5, color: Colors.white12)),
    ]);
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
    return Row(children: [
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
              hintStyle: TextStyle(
                color: Colors.white.withOpacity(0.35),
                fontSize: 12,
              ),
              border: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
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
              border:
                  Border.all(color: accentColor.withOpacity(0.5)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
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
            ]),
          ),
        ),
      ),
    ]);
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
          child: Row(mainAxisSize: MainAxisSize.min, children: [
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
          ]),
        ),
      ),
    );
  }

  // ─── Status bar ───────────────────────────────────────────────────────────

  Widget _buildStatusBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.65),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 8,
              height: 8,
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
          ]),
        ),
        const Spacer(),
        Row(mainAxisSize: MainAxisSize.min, children: [
          ValueListenableBuilder<bool>(
            valueListenable: _unityBridge.isReadyNotifier,
            builder: (context, isConnected, _) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.65),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
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
              ]),
            ),
          ),
          const SizedBox(width: 6),
          ValueListenableBuilder<bool>(
            valueListenable: _voiceNav.isReadyNotifier,
            builder: (_, ttsReady, __) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.65),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                ttsReady
                    ? Icons.record_voice_over_rounded
                    : Icons.voice_over_off_rounded,
                color: ttsReady ? Colors.greenAccent : Colors.grey,
                size: 14,
              ),
            ),
          ),
        ]),
      ]),
    );
  }

  // ─── Comando actual ───────────────────────────────────────────────────────

  Widget _buildCurrentCommand() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFFF6B00).withOpacity(0.85),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(children: [
          Icon(_getIntentIcon(_currentIntent!.type),
              color: Colors.white, size: 22),
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
        ]),
      ),
    );
  }

  // ─── Historial compacto ───────────────────────────────────────────────────

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
            final diff = DateTime.now().difference(item.time);
            final timeStr = diff.inSeconds < 60
                ? 'hace ${diff.inSeconds}s'
                : 'hace ${diff.inMinutes}m';
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Icon(_getIntentIcon(item.intent.type),
                    color: Colors.white70, size: 14),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item.intent.suggestedResponse,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  timeStr,
                  style: const TextStyle(
                      color: Colors.white38, fontSize: 11),
                ),
              ]),
            );
          }).toList(),
        ),
      ),
    );
  }

  // ─── Botón de voz principal ───────────────────────────────────────────────

  Widget _buildMainVoiceButton() {
    return GestureDetector(
      onTap: _isInitialized ? _toggleVoice : null,
      child: AnimatedBuilder(
        animation: _pulseAnimation,
        builder: (context, child) => Transform.scale(
          scale: _isActive ? _pulseAnimation.value : 1.0,
          child: Container(
            width: 100,
            height: 100,
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
                          : const Color(0xFFFF6B00))
                      .withOpacity(0.4),
                  blurRadius: 24,
                  spreadRadius: 4,
                )
              ],
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (_isActive)
                  AnimatedBuilder(
                    animation: _waveAnimation,
                    builder: (context, _) => Container(
                      width: 100 + (30 * _waveAnimation.value),
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
        ),
      ),
    );
  }

  // ─── Utilidades ───────────────────────────────────────────────────────────

  IconData _getIntentIcon(IntentType type) {
    return switch (type) {
      IntentType.navigate => Icons.navigation_rounded,
      IntentType.stop     => Icons.stop_circle_rounded,
      IntentType.describe => Icons.description_rounded,
      IntentType.help     => Icons.help_rounded,
      _                   => Icons.question_mark_rounded,
    };
  }
}

// ─── Modelo interno ───────────────────────────────────────────────────────

class _CommandItem {
  final NavigationIntent intent;
  final DateTime         time;
  _CommandItem({required this.intent, required this.time});
}