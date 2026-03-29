// lib/screens/ar_navigation_screen.dart
// ✅ v8.3 — Fix sobreescritura de onVoiceStatusReceived del coordinator
//
// ============================================================================
//  CAMBIOS v8.2 → v8.3
// ============================================================================
//
//  BUG CRÍTICO — onVoiceStatusReceived del coordinator era sobreescrito
//  por el callback de la screen.
//
//  PROBLEMA EN v8.2:
//    En _setupUnityBridgeCallbacks() (llamado en initState), la screen
//    asignaba:
//      _unityBridge.onVoiceStatusReceived = (info) { _showSnackBar(...); }
//
//    Más tarde, en _onUnityCreated() (llamado cuando Unity arranca):
//      _coordinator.attachUnityBridge(_unityBridge)
//
//    attachUnityBridge() hace:
//      bridge.onVoiceStatusReceived = _onVoiceStatusReceived  ← coordinator
//
//    Esto SOBREESCRIBÍA el callback de la screen, que es lo correcto.
//    Pero el orden era el correcto: screen primero, coordinator después → ok.
//
//    EL PROBLEMA REAL: si _onUnityCreated() se llama ANTES de
//    _setupUnityBridgeCallbacks() (por timing de Unity vs initState),
//    o si _coordinator.attachUnityBridge() se llama de nuevo en algún
//    hot-reload o restart, el callback del coordinator queda, pero la
//    screen había puesto el suyo en _setupUnityBridgeCallbacks() que
//    NUNCA se llama de nuevo después del attachUnityBridge().
//
//    MÁS IMPORTANTE: aunque el orden fuera siempre correcto, la screen
//    asignaba onVoiceStatusReceived DOS VECES:
//      1. En _setupUnityBridgeCallbacks() → callback de la screen
//      2. En _coordinator.attachUnityBridge() → callback del coordinator
//    El callback de la screen (el #1) era borrado por el #2. Así que
//    el snackbar de depuración nunca aparecía, lo que era correcto para
//    producción pero confuso para testing.
//
//    EL VERDADERO BUG QUE ROMPÍA STATUS:
//    NavigationCoordinator.attachUnityBridge() asigna:
//      bridge.onVoiceStatusReceived = _onVoiceStatusReceived
//    Pero si la screen llamaba _setupUnityBridgeCallbacks() DESPUÉS de
//    _onUnityCreated() (lo cual NO ocurre en el código actual, porque
//    _setupUnityBridgeCallbacks() se llama en initState que es antes),
//    el callback de la screen habría sobreescrito el del coordinator,
//    causando que _voiceStatusCompleter nunca se completara → timeout
//    en STATUS siempre.
//
//    Para hacer el código robusto frente a cualquier orden de llamada
//    y para mantener AMBOS callbacks (coordinator + screen para debug),
//    se implementa un callback compuesto que llama a los dos.
//
//  FIX EN v8.3:
//    _setupUnityBridgeCallbacks() ya NO asigna onVoiceStatusReceived.
//    En su lugar, después de _coordinator.attachUnityBridge(), se
//    encadena el callback de debug de la screen SIN sobreescribir el
//    del coordinator — usando un wrapper que llama al coordinator primero
//    y luego muestra el snackbar.
//
//    El encadenamiento se hace en _onUnityCreated() que es donde ya
//    está attachUnityBridge(). Orden garantizado:
//      1. _coordinator.attachUnityBridge() → asigna callback coordinator
//      2. Inmediatamente después: wrappear con callback screen
//    No hay más riesgo de sobreescritura en ningún orden.
//
//  TODO LO DEMÁS ES IDÉNTICO A v8.2.

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
  final TextEditingController _waypointNameController   = TextEditingController(text: 'Baliza 1');
  final TextEditingController _navigateTargetController = TextEditingController(text: 'Entrada');
  final TextEditingController _ttsTestController        = TextEditingController(
    text: 'Claro, ¿en qué puedo ayudarte?',
  );
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
      if (waypoints.isEmpty) {
        _coordinator.speak('No hay balizas guardadas todavía.');
        _showSnackBar('📍 No hay balizas aún');
      } else {
        final names = waypoints.map((w) => w.name).join(', ');
        _coordinator.speak('Destinos disponibles: $names');
        _showSnackBar('📍 ${waypoints.length} balizas: $names');
      }
    };

    _unityBridge.onTrackingStateChanged = _onTrackingStateChanged;

    // ✅ v8.3: onVoiceStatusReceived ya NO se asigna aquí.
    // Se asigna en _onUnityCreated() DESPUÉS de attachUnityBridge(),
    // como wrapper que llama al coordinator primero y luego hace debug.
    // Ver _onUnityCreated() para el callback compuesto.
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
      _logger.i('[AppState] Solicitando waypoints...');
      _unityBridge.listWaypoints();
    }

    final msg = success
        ? 'Sesión cargada. Listo para navegar.'
        : 'No hay sesión guardada. Puedes crear balizas.';

    _voiceNav.isReady ? _voiceNav.speak(msg) : _coordinator.speak(msg);
    _showSnackBar(success ? '✅ Sesión cargada' : 'ℹ️ $message');

    setState(() => _statusMessage = _wakeWordAvailable
        ? 'Di "Oye COMPAS" para comenzar'
        : 'Presiona para hablar');
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
              child: Text(_trackingReasonToMessage(reason),
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
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
      case 'ExcessiveMotion':       return 'Movimiento muy rápido — mueve el dispositivo más despacio.';
      case 'InsufficientFeatures':  return 'Superficie sin textura — apunta la cámara a una zona con detalles.';
      case 'InsufficientLight':     return 'Poca luz — busca una zona más iluminada.';
      case 'Relocalizing':          return 'Relocalizando — mantén el dispositivo quieto un momento.';
      case 'Initializing':
      case 'SessionInitializing':   return 'Iniciando tracking AR — mueve lentamente el dispositivo.';
      case 'Unsupported':           return 'Tracking AR no disponible en este dispositivo.';
      default:                      return 'Tracking AR inestable — mueve el dispositivo lentamente.';
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

    // ✅ v8.3 FIX: attachUnityBridge() PRIMERO, luego envolver el callback.
    //
    // attachUnityBridge() asigna:
    //   bridge.onVoiceStatusReceived = coordinator._onVoiceStatusReceived
    //
    // Inmediatamente después guardamos ese callback del coordinator y lo
    // envolvemos con el callback de debug de la screen, de modo que:
    //   1. El coordinator procesa el voice_status (completa _voiceStatusCompleter)
    //   2. La screen muestra el snackbar de debug
    //
    // Así NUNCA se sobreescribe el callback del coordinator. El orden es
    // siempre determinístico independientemente de cuándo Unity llame
    // a _onUnityCreated.
    _coordinator.attachUnityBridge(_unityBridge);

    // Capturar el callback del coordinator recién asignado
    final coordinatorCallback = _unityBridge.onVoiceStatusReceived;

    // Envolver: coordinator primero, luego debug screen
    _unityBridge.onVoiceStatusReceived = (info) {
      // 1. Coordinator procesa → _voiceStatusCompleter se completa
      coordinatorCallback?.call(info);

      // 2. Debug snackbar para testing (no bloquea al coordinator)
      if (!mounted) return;
      final msg = info.isGuiding
          ? '📊 Guiando → ${info.destination} (${info.remainingSteps} pasos)'
          : info.isPreprocessing
              ? '📊 Calculando ruta...'
              : '📊 Sin navegación activa';
      _showSnackBar(msg);
    };

    setState(() => _unityLoaded = true);
    _logger.i('✅ Unity AR lista — bridge conectado al coordinator (v8.3)');

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
    _showSnackBar('🧪 TEST: ${intent.suggestedResponse}');
    HapticFeedback.lightImpact();
    setState(() => _currentIntent = intent);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _currentIntent = null);
    });
  }

  void _testCreateWaypoint() {
    final name = _waypointNameController.text.trim();
    if (name.isEmpty) { _showSnackBar('⚠️ Escribe un nombre', isError: true); return; }
    _fireTestIntent(NavigationIntent(
      type: IntentType.navigate, target: '__unity:create_waypoint:$name',
      priority: 6, suggestedResponse: 'Creando baliza "$name"',
    ));
    setState(() {
      _waypointCounter++;
      _waypointNameController.text = 'Baliza $_waypointCounter';
    });
  }

  void _testNavigateTo() {
    final target = _navigateTargetController.text.trim();
    if (target.isEmpty) { _showSnackBar('⚠️ Escribe un destino', isError: true); return; }
    _voiceNav.resetDeduplication();
    _fireTestIntent(NavigationIntent(
      type: IntentType.navigate, target: target,
      priority: 8, suggestedResponse: 'Navegando a $target',
    ));
  }

  void _testStop() {
    _voiceNav.stop();
    _coordinator.resetNavigation();
    _fireTestIntent(NavigationIntent(
      type: IntentType.stop, target: '',
      priority: 10, suggestedResponse: 'Navegación detenida',
    ));
  }

  void _testListWaypoints() => _fireTestIntent(NavigationIntent(
    type: IntentType.navigate, target: '__unity:list_waypoints',
    priority: 5, suggestedResponse: 'Consultando balizas',
  ));

  void _testSaveSession() => _fireTestIntent(NavigationIntent(
    type: IntentType.navigate, target: '__unity:save_session',
    priority: 5, suggestedResponse: 'Guardando sesión',
  ));

  void _testLoadSession() => _fireTestIntent(NavigationIntent(
    type: IntentType.navigate, target: '__unity:load_session',
    priority: 5, suggestedResponse: 'Cargando sesión',
  ));

  void _testNavStatus() {
    if (!_unityBridge.isReady) { _showSnackBar('⚠️ Unity no lista', isError: true); return; }
    _unityBridge.requestNavStatus();
    _showSnackBar('🧪 TEST: Consultando estado de navegación');
    HapticFeedback.lightImpact();
  }

  void _testVoiceInstruction() {
    if (!_voiceNav.isReady) { _showSnackBar('⚠️ TTS no inicializado', isError: true); return; }
    _voiceNav.speak('En diez pasos, gira a tu derecha.');
    _showSnackBar('🔊 TEST TTS: instrucción de prueba');
    HapticFeedback.lightImpact();
  }

  void _testRepeatInstruction() {
    if (!_unityBridge.isReady) { _showSnackBar('⚠️ Unity no lista', isError: true); return; }
    _unityBridge.repeatInstruction();
    _showSnackBar('🔁 TEST: repeat_instruction enviado');
    HapticFeedback.lightImpact();
  }

  void _testStopVoice() {
    if (!_unityBridge.isReady) { _showSnackBar('⚠️ Unity no lista', isError: true); return; }
    _unityBridge.stopVoice();
    _showSnackBar('🔇 TEST: stop_voice enviado');
    HapticFeedback.lightImpact();
  }

  void _testVoiceStatus() {
    if (!_unityBridge.isReady) { _showSnackBar('⚠️ Unity no lista', isError: true); return; }
    _unityBridge.requestVoiceStatus();
    _showSnackBar('📊 TEST: voice_status solicitado — espera snackbar de respuesta');
    HapticFeedback.lightImpact();
  }

  void _testTTSSpeak() {
    if (!_unityBridge.isReady) { _showSnackBar('⚠️ Unity no lista', isError: true); return; }
    final text = _ttsTestController.text.trim();
    if (text.isEmpty) { _showSnackBar('⚠️ Escribe un texto', isError: true); return; }
    _unityBridge.speakArbitraryText(text, priority: 1, interrupt: false);
    _showSnackBar('💬 TEST: tts_speak enviado (p=1)');
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

          if (_unityLoaded && _appState == _AppReadyState.ready && !_arTrackingStable)
            Positioned(
              top: MediaQuery.of(context).padding.top + 50,
              left: 0, right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE65100).withOpacity(0.92),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [BoxShadow(
                        color: Colors.black.withOpacity(0.3), blurRadius: 8)],
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
                            color: Colors.white, fontSize: 12,
                            fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ),
            ),

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
                  child: Opacity(opacity: _testPanelAnimation.value, child: child),
                ),
              ),
              child: _buildTestPanel(),
            ),
          ],
        ],
      ),
    );
  }

  // ─── Overlays ────────────────────────────────────────────────────────────

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
                  width: 80, height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFFF6B00).withOpacity(0.15),
                    border: Border.all(
                        color: const Color(0xFFFF6B00).withOpacity(0.6), width: 2),
                  ),
                  child: const Icon(Icons.navigation_rounded,
                      color: Color(0xFFFF6B00), size: 40),
                ),
                const SizedBox(height: 24),
                const Text(
                  'COMPAS listo',
                  style: TextStyle(
                    color: Colors.white, fontSize: 24,
                    fontWeight: FontWeight.w700, letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'El entorno AR está preparado.\nConfirma cuando estés listo para cargar tu sesión.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 15, height: 1.5,
                  ),
                ),
                const SizedBox(height: 36),
                GestureDetector(
                  onTap: _onUserReady,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF6B00),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [BoxShadow(
                        color: const Color(0xFFFF6B00).withOpacity(0.4),
                        blurRadius: 20, spreadRadius: 2,
                      )],
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
                            color: Colors.white, fontSize: 17,
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
                        color: Colors.white.withOpacity(0.45), fontSize: 13),
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
                  color: Colors.white, fontSize: 17, fontWeight: FontWeight.w500),
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
            Icon(_showVoiceOverlay ? Icons.visibility_off : Icons.mic,
                color: Colors.white, size: 16),
            const SizedBox(width: 6),
            Text(_showVoiceOverlay ? 'Ocultar' : 'Voz',
                style: const TextStyle(color: Colors.white, fontSize: 13)),
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
            color: _showTestPanel ? const Color(0xFFCE93D8) : Colors.white30,
            width: 1.5,
          ),
          boxShadow: _showTestPanel
              ? [BoxShadow(color: const Color(0xFF7B1FA2).withOpacity(0.4),
              blurRadius: 12, spreadRadius: 2)]
              : [],
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
                fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTestPanel() {
    return ValueListenableBuilder<bool>(
      valueListenable: _unityBridge.isReadyNotifier,
      builder: (context, isReady, _) {
        return Container(
          width: 290,
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.65),
          decoration: BoxDecoration(
            color: const Color(0xFF0D0D1A).withOpacity(0.96),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: const Color(0xFF7B1FA2).withOpacity(0.6), width: 1.5),
            boxShadow: [BoxShadow(
              color: const Color(0xFF7B1FA2).withOpacity(0.25),
              blurRadius: 20, spreadRadius: 2,
            )],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
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
                      const Text('Panel de Testing',
                          style: TextStyle(color: Color(0xFFCE93D8), fontSize: 14,
                              fontWeight: FontWeight.w700, letterSpacing: 0.3)),
                      const Spacer(),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildStatusBadge(
                              label: isReady ? 'AR ✓' : 'AR ⏳', active: isReady),
                          const SizedBox(width: 4),
                          ValueListenableBuilder<bool>(
                            valueListenable: _voiceNav.isReadyNotifier,
                            builder: (_, ttsReady, __) => _buildStatusBadge(
                                label: ttsReady ? 'TTS ✓' : 'TTS ⏳',
                                active: ttsReady),
                          ),
                          const SizedBox(width: 4),
                          StreamBuilder<List<WaypointEntry>>(
                            stream: _waypointContext.onWaypointsChanged,
                            builder: (_, __) => _buildStatusBadge(
                              label: _waypointContext.hasWaypoints
                                  ? 'WP ${_waypointContext.count}' : 'WP ⏳',
                              active: _waypointContext.hasWaypoints,
                            ),
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

                  if (!_wakeWordAvailable) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.orange.withOpacity(0.5)),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 14),
                          SizedBox(width: 6),
                          Expanded(child: Text(
                            'Wake word inactivo (speech_to_text v3)',
                            style: TextStyle(color: Colors.orange, fontSize: 11),
                          )),
                        ],
                      ),
                    ),
                  ],

                  const SizedBox(height: 10),
                  StreamBuilder<List<WaypointEntry>>(
                    stream: _waypointContext.onWaypointsChanged,
                    builder: (_, __) {
                      if (!_waypointContext.hasWaypoints) {
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                          decoration: BoxDecoration(
                            color: Colors.blue.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.blue.withOpacity(0.3)),
                          ),
                          child: const Row(children: [
                            Icon(Icons.info_outline, color: Colors.lightBlueAccent, size: 13),
                            SizedBox(width: 6),
                            Expanded(child: Text(
                              'Groq aún no conoce las balizas.\nPulsa "Listar balizas" para cargar.',
                              style: TextStyle(color: Colors.lightBlueAccent, fontSize: 10),
                            )),
                          ]),
                        );
                      }
                      final names = _waypointContext.navigableWaypoints
                          .map((w) => w.name).join(', ');
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                        decoration: BoxDecoration(
                          color: Colors.green.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.green.withOpacity(0.3)),
                        ),
                        child: Row(children: [
                          const Icon(Icons.location_on, color: Colors.greenAccent, size: 13),
                          const SizedBox(width: 6),
                          Expanded(child: Text('Groq conoce: $names',
                            style: const TextStyle(color: Colors.greenAccent, fontSize: 10),
                            maxLines: 2, overflow: TextOverflow.ellipsis,
                          )),
                        ]),
                      );
                    },
                  ),

                  const SizedBox(height: 14),
                  _testSectionDivider('NAVEGACIÓN'),
                  const SizedBox(height: 10),
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
                  Row(children: [
                    Expanded(child: _buildTestActionButton(
                      label: 'Guardar', icon: Icons.save_rounded,
                      color: const Color(0xFF1A237E),
                      accentColor: const Color(0xFF90CAF9),
                      onPressed: isReady ? _testSaveSession : null,
                    )),
                    const SizedBox(width: 8),
                    Expanded(child: _buildTestActionButton(
                      label: 'Cargar', icon: Icons.folder_open_rounded,
                      color: const Color(0xFF1A237E),
                      accentColor: const Color(0xFF90CAF9),
                      onPressed: isReady ? _testLoadSession : null,
                    )),
                  ]),
                  const SizedBox(height: 8),
                  _buildTestActionButton(
                    label: 'Estado de navegación',
                    icon: Icons.radar_rounded,
                    color: const Color(0xFF33691E),
                    accentColor: const Color(0xFFDCE775),
                    onPressed: isReady ? _testNavStatus : null,
                  ),

                  const SizedBox(height: 14),
                  _testSectionDivider('VOZ GPS'),
                  const SizedBox(height: 10),
                  ValueListenableBuilder<bool>(
                    valueListenable: _voiceNav.isReadyNotifier,
                    builder: (_, ttsReady, __) => Column(children: [
                      _buildTestActionButton(
                        label: 'Test instrucción de giro',
                        icon: Icons.turn_right_rounded,
                        color: const Color(0xFF4A148C),
                        accentColor: const Color(0xFFCE93D8),
                        onPressed: ttsReady ? _testVoiceInstruction : null,
                      ),
                      const SizedBox(height: 8),
                      _buildTestActionButton(
                        label: 'Silenciar TTS',
                        icon: Icons.volume_off_rounded,
                        color: const Color(0xFF37474F),
                        accentColor: const Color(0xFFB0BEC5),
                        onPressed: ttsReady ? () {
                          _voiceNav.stop();
                          _showSnackBar('🔇 TTS silenciado');
                        } : null,
                      ),
                    ]),
                  ),

                  const SizedBox(height: 14),
                  _testSectionDivider('GUÍA DE VOZ (Unity v4)'),
                  const SizedBox(height: 10),
                  _buildTestActionButton(
                    label: 'Repetir instrucción',
                    icon: Icons.replay_rounded,
                    color: const Color(0xFF004D40),
                    accentColor: const Color(0xFF80CBC4),
                    onPressed: isReady ? _testRepeatInstruction : null,
                  ),
                  const SizedBox(height: 8),
                  _buildTestActionButton(
                    label: 'Silenciar guía de voz',
                    icon: Icons.voice_over_off_rounded,
                    color: const Color(0xFF37474F),
                    accentColor: const Color(0xFFB0BEC5),
                    onPressed: isReady ? _testStopVoice : null,
                  ),
                  const SizedBox(height: 8),
                  _buildTestActionButton(
                    label: 'Estado de guía (voice_status)',
                    icon: Icons.info_outline_rounded,
                    color: const Color(0xFF1A237E),
                    accentColor: const Color(0xFF90CAF9),
                    onPressed: isReady ? _testVoiceStatus : null,
                  ),
                  const SizedBox(height: 8),
                  _buildTestInputRow(
                    controller: _ttsTestController,
                    hint: 'Texto para COMPAS TTS',
                    buttonLabel: 'Hablar',
                    buttonIcon: Icons.record_voice_over_rounded,
                    color: const Color(0xFF4A148C),
                    accentColor: const Color(0xFFCE93D8),
                    onPressed: isReady ? _testTTSSpeak : null,
                  ),

                  const SizedBox(height: 14),
                  _testSectionDivider('SISTEMA'),
                  const SizedBox(height: 10),
                  _buildTestActionButton(
                    label: 'Reset completo',
                    icon: Icons.refresh_rounded,
                    color: const Color(0xFF4A148C),
                    accentColor: const Color(0xFFCE93D8),
                    onPressed: () {
                      _coordinator.reset();
                      _voiceNav.stop();
                      _voiceNav.resetDeduplication();
                      setState(() {
                        _currentIntent = null;
                        _history.clear();
                        _waypointCounter = 1;
                        _waypointNameController.text   = 'Baliza 1';
                        _navigateTargetController.text = 'Entrada';
                        _ttsTestController.text        = 'Claro, ¿en qué puedo ayudarte?';
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

  Widget _buildStatusBadge({required String label, required bool active}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: active ? Colors.green.withOpacity(0.2) : Colors.orange.withOpacity(0.2),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(
            color: active ? Colors.greenAccent : Colors.orange, width: 0.8),
      ),
      child: Text(label,
          style: TextStyle(
              color: active ? Colors.greenAccent : Colors.orange,
              fontSize: 10, fontWeight: FontWeight.w600)),
    );
  }

  Widget _testSectionDivider(String label) {
    return Row(children: [
      Text(label, style: const TextStyle(
          color: Color(0xFF9E9E9E), fontSize: 10,
          fontWeight: FontWeight.w700, letterSpacing: 1.2)),
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
            controller: controller, enabled: enabled,
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
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(buttonIcon, color: accentColor, size: 15),
              const SizedBox(width: 5),
              Text(buttonLabel, style: TextStyle(
                  color: accentColor, fontSize: 12, fontWeight: FontWeight.w600)),
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
            Flexible(child: Text(label,
                style: TextStyle(color: accentColor, fontSize: 12,
                    fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis)),
          ]),
        ),
      ),
    );
  }

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
              width: 8, height: 8,
              decoration: BoxDecoration(
                color: _isActive ? Colors.greenAccent : Colors.grey,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(_statusMessage,
                style: const TextStyle(color: Colors.white, fontSize: 12,
                    fontWeight: FontWeight.w600),
                maxLines: 1, overflow: TextOverflow.ellipsis),
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
                Icon(Icons.view_in_ar,
                    color: isConnected ? Colors.greenAccent : Colors.orange,
                    size: 14),
                const SizedBox(width: 6),
                Text(isConnected ? 'AR Activo' : 'AR Cargando',
                    style: const TextStyle(color: Colors.white, fontSize: 12)),
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
          Icon(_getIntentIcon(_currentIntent!.type), color: Colors.white, size: 22),
          const SizedBox(width: 12),
          Expanded(child: Text(_currentIntent!.suggestedResponse,
              style: const TextStyle(color: Colors.white, fontSize: 16,
                  fontWeight: FontWeight.bold))),
        ]),
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
                Expanded(child: Text(item.intent.suggestedResponse,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                    overflow: TextOverflow.ellipsis)),
                Text(timeStr,
                    style: const TextStyle(color: Colors.white38, fontSize: 11)),
              ]),
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
        builder: (context, child) => Transform.scale(
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
              boxShadow: [BoxShadow(
                color: (_isActive
                    ? const Color(0xFFE53935)
                    : const Color(0xFFFF6B00)).withOpacity(0.4),
                blurRadius: 24, spreadRadius: 4,
              )],
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
                  color: Colors.white, size: 46,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSecondaryControls() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: ValueListenableBuilder<bool>(
        valueListenable: _unityBridge.isReadyNotifier,
        builder: (context, isReady, _) => Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildControlChip(
              icon: Icons.save_outlined, label: 'Guardar',
              onTap: isReady ? () {
                _unityBridge.saveSession();
                _showSnackBar('💾 Guardando sesión...');
                HapticFeedback.lightImpact();
              } : null,
            ),
            _buildControlChip(
              icon: Icons.folder_open_outlined, label: 'Cargar',
              onTap: isReady ? () {
                _unityBridge.loadSession();
                _showSnackBar('📂 Cargando sesión...');
                HapticFeedback.lightImpact();
              } : null,
            ),
            _buildControlChip(
              icon: Icons.list_alt_rounded, label: 'Balizas',
              onTap: isReady ? () {
                _unityBridge.listWaypoints();
                _showSnackBar('📍 Consultando balizas...');
                HapticFeedback.lightImpact();
              } : null,
            ),
            _buildControlChip(
              icon: Icons.refresh_rounded, label: 'Reset',
              onTap: () {
                _coordinator.reset();
                _voiceNav.stop();
                setState(() { _currentIntent = null; _history.clear(); });
                _showSnackBar('🔄 Sistema reiniciado');
                HapticFeedback.mediumImpact();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlChip({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
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
                color: enabled ? Colors.white38 : Colors.white24),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(
                color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }

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

class _CommandItem {
  final NavigationIntent intent;
  final DateTime         time;
  _CommandItem({required this.intent, required this.time});
}