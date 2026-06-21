// lib/controllers/ar_navigation_controller.dart
//
// ✅ v9.8 — Tutorial largo bloqueante en scene_ready · micrófono diferido
//
// ════════════════════════════════════════════════════════════════════════════
// COMPORTAMIENTO
// ════════════════════════════════════════════════════════════════════════════
//
//  Primera vez (showWelcomeTutorial == true):
//    1. scene_ready llega → se lanza _playTutorialBlockingAsync()
//    2. TTS habla el tutorial completo (tutorialScriptCompleto)
//    3. Se espera waitForCompletion() + 800ms de buffer anti-eco de hardware
//    4. Solo entonces _tutorialCompleter se completa
//    5. _startWakeWordWhenReady() estaba bloqueado en ese Completer → se desbloquea
//    6. El micrófono (WakeWord / STT) se activa
//
//  Segunda vez en adelante (showWelcomeTutorial == false):
//    _tutorialCompleter se completa inmediatamente → sin demora.
//
//  La bandera SharedPreferences ("compas_tutorial_done") se escribe al inicio
//  de _playTutorialBlockingAsync(), antes de hablar, para que un crash durante
//  el tutorial no lo repita indefinidamente.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' as flutter_widgets;
import 'package:flutter_unity_widget/flutter_unity_widget.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/shared_models.dart';
import '../services/AI/ai_mode_controller.dart';
import '../services/AI/navigation_coordinator.dart';
import '../services/AI/waypoint_context_service.dart';
import '../services/unity_bridge_service.dart';
import '../services/voice_navigation_service.dart';

// ─── Clave SharedPreferences ──────────────────────────────────────────────
const String kTutorialDoneKey = 'compas_tutorial_done';

// ─── Etapas de inicialización ─────────────────────────────────────────────
enum AppReadyState { initializing, waitingSession, waitingUser, ready }

// ─── Modelo interno de historial ──────────────────────────────────────────
class CommandItem {
  final NavigationIntent intent;
  final DateTime time;
  CommandItem({required this.intent, required this.time});
}

// ─── Controller ───────────────────────────────────────────────────────────
class ArNavigationController extends ChangeNotifier {

  // ─── Servicios ────────────────────────────────────────────────────────────
  final NavigationCoordinator coordinator = NavigationCoordinator();
  final AIModeController aiModeController = AIModeController();
  final UnityBridgeService unityBridge = UnityBridgeService();
  final VoiceNavigationService voiceNav = VoiceNavigationService();
  final WaypointContextService waypointContext = WaypointContextService();
  final Logger _logger = Logger();

  // ─── Tutorial — Completer que bloquea el micrófono ────────────────────────
  //
  // Se inicializa en initializeServices().
  // Si showWelcomeTutorial == false → se completa inmediatamente.
  // Si showWelcomeTutorial == true  → se completa al final del tutorial TTS.
  late final Completer<void> _tutorialCompleter;

  bool _showWelcomeTutorial = false;

  /// Llamado desde ArNavigationScreen ANTES de initializeServices().
  set showWelcomeTutorial(bool value) => _showWelcomeTutorial = value;

  // ─── Estado de inicialización ─────────────────────────────────────────────
  AppReadyState _appState = AppReadyState.initializing;
  bool _flutterServicesReady = false;
  bool _sceneReadyReceived = false;

  AppReadyState get appState => _appState;

  // ─── Estado de voz ────────────────────────────────────────────────────────
  bool _isInitialized = false;
  bool _isActive = false;
  String _statusMessage = 'Inicializando...';
  final NavigationMode _currentMode = NavigationMode.eventBased;
  AIMode _aiMode = AIMode.auto;
  NavigationIntent? _currentIntent;
  bool _wakeWordAvailable = false;

  bool get isInitialized => _isInitialized;
  bool get isActive => _isActive;
  String get statusMessage => _statusMessage;
  NavigationMode get currentMode => _currentMode;
  AIMode get aiMode => _aiMode;
  NavigationIntent? get currentIntent => _currentIntent;
  bool get wakeWordAvailable => _wakeWordAvailable;

  // ─── Estado Unity ─────────────────────────────────────────────────────────
  bool _unityLoaded = false;
  bool _showVoiceOverlay = true;

  bool get unityLoaded => _unityLoaded;
  bool get showVoiceOverlay => _showVoiceOverlay;

  void toggleVoiceOverlay() {
    _showVoiceOverlay = !_showVoiceOverlay;
    notifyListeners();
  }

  // ─── Tracking AR ──────────────────────────────────────────────────────────
  bool _arTrackingStable = true;
  String _arTrackingState = '';
  String _arTrackingReason = '';

  Timer? _trackingWarningTimer;
  Timer? _trackingDebounceTimer;
  bool _lastReportedTrackingStable = true;

  bool get arTrackingStable => _arTrackingStable;
  String get arTrackingState => _arTrackingState;
  String get arTrackingReason => _arTrackingReason;

  // ─── Datos de sesión ──────────────────────────────────────────────────────
  bool _sessionLoaded = false;
  int _sessionWaypointCount = 0;
  bool _sessionHasNavMesh = false;

  bool get sessionLoaded => _sessionLoaded;
  int get sessionWaypointCount => _sessionWaypointCount;
  bool get sessionHasNavMesh => _sessionHasNavMesh;

  // ─── Panel de testing ─────────────────────────────────────────────────────
  bool _showTestPanel = false;
  int _waypointCounter = 1;

  bool get showTestPanel => _showTestPanel;
  int get waypointCounter => _waypointCounter;

  void toggleTestPanel(VoidCallback haptic) {
    _showTestPanel = !_showTestPanel;
    haptic();
    notifyListeners();
  }

  // ─── Segmentación ─────────────────────────────────────────────────────────
  double _segObstacle = 0;
  double _segFloor = 0;
  double _segWall = 0;
  double _segBackground = 0;
  bool _segMaskVisible = true;
  bool _segmentationActive = false;

  double get segObstacle => _segObstacle;
  double get segFloor => _segFloor;
  double get segWall => _segWall;
  double get segBackground => _segBackground;
  bool get segMaskVisible => _segMaskVisible;
  bool get segmentationActive => _segmentationActive;

  static const double obstacleAlertThreshold = 0.12;

  // ─── Historial ────────────────────────────────────────────────────────────
  final List<CommandItem> history = [];
  static const int _maxHistory = 5;

  // ─── Callbacks para el Screen ─────────────────────────────────────────────
  void Function(String msg, {bool isError})? onShowSnackBar;
  void Function(String reason)? onShowTrackingSnackBar;
  VoidCallback? onHideTrackingSnackBar;

  // ─── Callback de tutorial manual (botón "¿Cómo funciono?") ───────────────
  VoidCallback? onReadyForTutorial;
  bool _tutorialCallbackFired = false;

  // ─── Scripts de tutorial ──────────────────────────────────────────────────
  static const String tutorialScriptCompleto =
      'Hola. Soy Compas, tu asistente de navegación interior. '
      'Voy a explicarte cómo usarme. '
      'Para activarme, di: oye Compas. '
      'Espera el tono. Ese tono te avisa que el micrófono está listo. '
      'Solo entonces dime a dónde quieres ir. '
      'Por ejemplo: llévame a la recepción. '
      'Te guío usando direcciones de reloj. '
      'Al frente son las doce. A tu derecha son las tres. '
      'A tu izquierda son las nueve. Atrás tuyo son las seis. '
      'Si te digo: gira hacia las tres, debes girar a tu derecha. '
      'Algo importante al iniciar. '
      'En cuanto me pidas ir a un lugar, mantén el celular quieto '
      'y apuntando al frente, hasta que escuches mi primera indicación. '
      'También te aviso si hay un obstáculo cerca. '
      'Puedes pedirme que repita la última indicación cuando lo necesites. '
      'Y para detener la navegación, di: oye Compas, para. '
      'Estoy listo. Dime a dónde vamos.';

  /// Alias usado por el intent "__app:tutorial"
  static const String tutorialScript = tutorialScriptCompleto;

  // ─── Delay de boot del WakeWord ───────────────────────────────────────────
  static const Duration _wakeWordBootDelay = Duration(seconds: 3);

  // ═══════════════════════════════════════════════════════════════════════════
  // TUTORIAL BLOQUEANTE (primera vez)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Reproduce el tutorial completo y bloquea el micrófono hasta que termine.
  /// Solo se llama cuando _showWelcomeTutorial == true.
  Future<void> _playTutorialBlockingAsync() async {
    _logger.i('[Tutorial] ▶️ Iniciando tutorial de primera vez...');

    try {
      // 1. Marcar como visto ANTES de hablar para evitar repetición en crash
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kTutorialDoneKey, true);
      _logger.i('[Tutorial] ✅ Bandera "$kTutorialDoneKey" guardada.');

      // 2. Actualizar UI
      _statusMessage = 'Escucha las instrucciones...';
      notifyListeners();

      // 3. Hablar el tutorial completo
      coordinator.speak(tutorialScriptCompleto);

      // 4. Esperar a que el TTS termine realmente
      await coordinator.ttsService.waitForCompletion();

      // 5. Buffer anti-eco: tiempo para que el hardware de audio vacíe
      //    su cola interna antes de abrir el micrófono.
      //    800ms es suficiente incluso en dispositivos lentos.
      await Future.delayed(const Duration(milliseconds: 800));

      _logger.i('[Tutorial] ✅ Tutorial completo — desbloqueando micrófono.');
    } catch (e) {
      // Si algo falla, desbloquear igualmente para no dejar la app colgada.
      _logger.e('[Tutorial] ❌ Error durante tutorial: $e — desbloqueando mic.');
    } finally {
      if (!_tutorialCompleter.isCompleted) {
        _tutorialCompleter.complete();
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // WAKE WORD — diferido hasta fin de tutorial
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _startWakeWordWhenReady() async {
    if (!_wakeWordAvailable) return;

    // Bloquear aquí hasta que el tutorial termine (o sea noop si ya completó)
    _logger.i('[WakeWord] ⏳ Esperando fin de tutorial (si aplica)...');
    await _tutorialCompleter.future;
    _logger.i('[WakeWord] ✅ Tutorial OK — continuando con arranque de WakeWord.');

    // Esperar a que el bridge de Unity esté listo
    if (!unityBridge.isSceneReady) {
      final bridgeReady = await _waitForBridgeReady(
        timeout: const Duration(seconds: 15),
      );
      if (!bridgeReady) {
        _logger.w('[WakeWord] Bridge no listo — iniciando sin esperar.');
      }
    }

    _logger.i(
      '[WakeWord] Bridge listo — esperando ${_wakeWordBootDelay.inSeconds}s '
          'de margen AR antes de activar STT...',
    );
    await Future.delayed(_wakeWordBootDelay);

    _logger.i('[WakeWord] Iniciando WakeWordService y coordinator...');
    _statusMessage = 'Di "oye Compas" para navegar';
    notifyListeners();

    try {
      if (!_isActive) {
        await coordinator.start(mode: _currentMode);
        _isActive = true;
        notifyListeners();
      }
    } catch (e) {
      _logger.e('[WakeWord] Error iniciando coordinator: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MÁQUINA DE ESTADOS
  // ═══════════════════════════════════════════════════════════════════════════

  void onSceneReady() {
    _sceneReadyReceived = true;
    if (!_flutterServicesReady) {
      _logger.i('[AppState] scene_ready antes que Flutter — esperando servicios.');
      return;
    }

    // Si es primera vez: arrancar tutorial ahora que Unity está listo.
    // Corre en paralelo; el micrófono se bloquea internamente.
    if (_showWelcomeTutorial && !_tutorialCompleter.isCompleted) {
      _logger.i('[AppState] scene_ready + primera vez → lanzando tutorial.');
      _playTutorialBlockingAsync(); // sin await — no bloquea la UI
    }

    _advanceToWaitingSession();
  }

  void _checkFlutterReady() {
    if (_appState != AppReadyState.initializing) return;
    if (_sceneReadyReceived) _advanceToWaitingSession();
  }

  void _advanceToWaitingSession() {
    if (_appState != AppReadyState.initializing) return;
    _logger.i('[AppState] initializing → waitingSession');
    _appState = AppReadyState.waitingSession;
    _statusMessage = 'Cargando sesión AR...';
    notifyListeners();
    SemanticsService.announce('Cargando sesión AR', TextDirection.ltr);
  }

  void onSessionLoaded(SessionLoadedInfo info) {
    _sessionLoaded = info.loaded;
    _sessionWaypointCount = info.waypointCount;
    _sessionHasNavMesh = info.hasNavMesh;
    notifyListeners();

    _logger.i(
      '[AppState] session_loaded: '
          'loaded=${info.loaded} wp=${info.waypointCount} navmesh=${info.hasNavMesh}',
    );

    if (_appState == AppReadyState.initializing) _advanceToWaitingSession();

    if (_appState != AppReadyState.waitingSession) {
      _logger.i('[AppState] session_loaded en estado $_appState — solo actualizando.');
      return;
    }

    if (info.loaded) {
      _logger.i('[AppState] waitingSession → ready (${info.waypointCount} balizas)');
      _goToReady(info: info);
    } else {
      _logger.i('[AppState] waitingSession → waitingUser');
      _appState = AppReadyState.waitingUser;
      _statusMessage = '¿Listo para navegar?';
      notifyListeners();
      _enterWaitingUser();
    }
  }

  Future<void> _enterWaitingUser() async {
    const welcomeMsg = 'Bienvenido. Di: estoy listo, cuando quieras comenzar.';

    if (_wakeWordAvailable) {
      try {
        if (!_isActive) {
          await coordinator.start(mode: _currentMode);
          _isActive = true;
          notifyListeners();
        }
      } catch (e) {
        _logger.e('[waitingUser] Error iniciando coordinator: $e');
      }
      coordinator.speak(welcomeMsg);
      _statusMessage = 'Di "oye Compas" para comenzar';
    } else {
      coordinator.speak(welcomeMsg);
      _statusMessage = '¿Listo para navegar?';

      await Future.delayed(const Duration(milliseconds: 3500));
      if (_appState == AppReadyState.waitingUser && !_isActive) {
        try {
          await coordinator.start(mode: _currentMode);
          _isActive = true;
          _statusMessage = 'Escuchando...';
          notifyListeners();
        } catch (e) {
          _logger.e('[waitingUser] Error iniciando coordinator sin WakeWord: $e');
        }
      }
    }

    notifyListeners();
  }

  void onUserReady() {
    if (_appState != AppReadyState.waitingUser) return;
    _logger.i('[AppState] waitingUser → ready (confirmación de usuario)');
    _goToReady(info: null);
  }

  void _goToReady({required SessionLoadedInfo? info}) {
    _appState = AppReadyState.ready;
    notifyListeners();

    if (unityBridge.isReady) unityBridge.listWaypoints();

    final hadSession = info?.loaded ?? false;
    final waypointCount = info?.waypointCount ?? 0;

    final msg = hadSession
        ? (waypointCount > 0
        ? 'Sesión cargada. $waypointCount ${waypointCount == 1 ? "baliza disponible" : "balizas disponibles"}.'
        : 'Sesión cargada. Listo para navegar.')
        : 'Listo para navegar.';

    // Si hay tutorial activo, no hablar el msg de sesión para no solaparse.
    if (!_showWelcomeTutorial) {
      if (onReadyForTutorial != null && !_tutorialCallbackFired) {
        _tutorialCallbackFired = true;
        Future.microtask(() => onReadyForTutorial?.call());
      } else {
        voiceNav.isReady ? voiceNav.speak(msg) : coordinator.speak(msg);
      }
    }

    if (_wakeWordAvailable) {
      if (!_isActive) {
        _statusMessage = 'Inicializando voz...';
        notifyListeners();
        _startWakeWordWhenReady();
      } else {
        _statusMessage = 'Di "oye Compas" para navegar';
        notifyListeners();
      }
    } else {
      _statusMessage = 'Presiona el micrófono para hablar';
      notifyListeners();
    }
  }

  // ─── Tracking con debounce ────────────────────────────────────────────────
  void onTrackingStateChanged(bool isStable, String state, String reason) {
    _arTrackingStable = isStable;
    _arTrackingState = state;
    _arTrackingReason = reason;

    if (isStable) {
      _trackingDebounceTimer?.cancel();
      _trackingWarningTimer?.cancel();
      if (!_lastReportedTrackingStable) {
        _lastReportedTrackingStable = true;
        notifyListeners();
        onHideTrackingSnackBar?.call();
      }
    } else {
      _trackingDebounceTimer?.cancel();
      _trackingDebounceTimer = Timer(const Duration(milliseconds: 500), () {
        if (_arTrackingStable) return;
        _lastReportedTrackingStable = false;
        notifyListeners();
        final msg = _arTrackingReason.isNotEmpty ? _arTrackingReason : _arTrackingState;
        onShowTrackingSnackBar?.call(msg);
        _trackingWarningTimer?.cancel();
        _trackingWarningTimer = Timer(const Duration(seconds: 6), () {
          if (!_arTrackingStable) {
            onShowTrackingSnackBar?.call(
              _arTrackingReason.isNotEmpty ? _arTrackingReason : _arTrackingState,
            );
          }
        });
      });
    }
  }

  String trackingReasonToMessage(String reason) {
    return switch (reason) {
      'ExcessiveMotion'      => 'Movimiento muy rápido — mueve el dispositivo más despacio.',
      'InsufficientFeatures' => 'Superficie sin textura — apunta a una zona con detalles.',
      'InsufficientLight'    => 'Poca luz — busca una zona más iluminada.',
      'Relocalizing'         => 'Relocalizando — mantén el dispositivo quieto.',
      'Initializing' || 'SessionInitializing' =>
      'Iniciando tracking AR — mueve lentamente el dispositivo.',
      'Unsupported' => 'Tracking AR no disponible en este dispositivo.',
      _ => 'Tracking AR inestable — mueve el dispositivo lentamente.',
    };
  }

  // ─── Esperar bridge ready ─────────────────────────────────────────────────
  Future<bool> _waitForBridgeReady({Duration timeout = const Duration(seconds: 8)}) async {
    if (unityBridge.isSceneReady) return true;

    _logger.i('[Nav] Bridge no listo — esperando (max ${timeout.inSeconds}s)...');

    final completer = Completer<bool>();
    Timer? timer;
    VoidCallback? listener;

    timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        _logger.w('[Nav] Timeout esperando bridge ready');
        completer.complete(false);
      }
    });

    listener = () {
      if (unityBridge.isSceneReady && !completer.isCompleted) {
        timer?.cancel();
        completer.complete(true);
      }
    };

    unityBridge.bridgeStateNotifier.addListener(listener!);
    final result = await completer.future;
    unityBridge.bridgeStateNotifier.removeListener(listener);
    return result;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // INICIALIZACIÓN DE SERVICIOS
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> initializeServices() async {
    // Inicializar el Completer ANTES de todo.
    // Si no hay tutorial → completar ya para que el mic no espere.
    _tutorialCompleter = Completer<void>();
    if (!_showWelcomeTutorial) {
      _tutorialCompleter.complete();
      _logger.i('[Tutorial] Sin tutorial de primera vez — mic no bloqueado.');
    } else {
      _logger.i('[Tutorial] Primera vez — mic bloqueado hasta fin de tutorial.');
    }

    try {
      _statusMessage = 'Inicializando servicios...';
      notifyListeners();

      await aiModeController.initialize();
      _aiMode = aiModeController.currentMode;

      await coordinator.initialize();
      _wakeWordAvailable = coordinator.wakeWordAvailable;

      coordinator.onStatusUpdate = (status) {
        _statusMessage = status;
        notifyListeners();
      };

      coordinator.onIntentDetected = (intent) {
        _currentIntent = intent;
        notifyListeners();
        SemanticsService.announce(
          'Comando: ${intent.suggestedResponse}',
          TextDirection.ltr,
        );
        Future.delayed(const Duration(seconds: 3), () {
          _currentIntent = null;
          notifyListeners();
        });
      };

      coordinator.onCommandExecuted = (intent) async {
        if (intent.target == '__app:tutorial') {
          coordinator.speak(tutorialScriptCompleto);
          addToHistory(intent);
          onShowSnackBar?.call('Tutorial activado');
          return;
        }

        final isNavigation =
            intent.type == IntentType.navigate &&
                !intent.target.startsWith('__unity:') &&
                !intent.target.startsWith('__app:');

        if (isNavigation) {
          final ready = await _waitForBridgeReady();
          if (!ready) {
            _logger.w('[Nav] navigate_to cancelado — bridge no listo');
            const errorMsg = 'El sistema AR está calibrando. Intenta de nuevo en un momento.';
            coordinator.speak(errorMsg);
            onShowSnackBar?.call('⏳ AR calibrando — intenta en un momento.', isError: true);
            return;
          }
        }

        unityBridge.handleIntent(intent);
        addToHistory(intent);
        onShowSnackBar?.call('✅ ${intent.suggestedResponse}');
        HapticFeedback.lightImpact();

        if (intent.type == IntentType.navigate && !intent.target.startsWith('__unity:')) {
          voiceNav.resetDeduplication();
        }
        if (intent.type == IntentType.stop) voiceNav.stop();
        if (intent.target == '__app:user_ready' && _appState == AppReadyState.waitingUser) {
          onUserReady();
        }
      };

      coordinator.onCommandRejected = (reason) {
        onShowSnackBar?.call('⛔ $reason', isError: true);
        HapticFeedback.heavyImpact();
      };

      aiModeController.onModeChanged = (mode) {
        _aiMode = mode;
        notifyListeners();
      };

      await voiceNav.initialize(coordinator.ttsService);
      voiceNav.attachToUnityBridge(unityBridge);
      if (coordinator.wakeWordAvailable) {
        voiceNav.attachWakeWordService(coordinator.wakeWordService);
      }

      _isInitialized = true;
      _statusMessage = 'Conectando con AR...';
      notifyListeners();

      _flutterServicesReady = true;
      _checkFlutterReady();
    } catch (e) {
      _logger.e('[Controller] Error inicializando servicios: $e');
      _statusMessage = 'Error: $e';
      _isInitialized = false;

      // Desbloquear mic para no dejar la app colgada
      if (!_tutorialCompleter.isCompleted) _tutorialCompleter.complete();

      notifyListeners();
    }
  }

  // ─── Unity callbacks ──────────────────────────────────────────────────────
  void onUnityCreated(UnityWidgetController controller) {
    unityBridge.setController(controller);
    voiceNav.setUnityController(controller);
    coordinator.attachUnityBridge(unityBridge);

    _setupUnityBridgeCallbacks();

    _unityLoaded = true;
    notifyListeners();
    _logger.i('[Controller] UnityWidget creado — esperando scene_ready...');

    unityBridge.waitForSceneReady().then((_) {
      _logger.i('[Controller] ✅ scene_ready confirmado');
      onSceneReady();
    });
  }

  void onUnityMessage(dynamic message) {
    unityBridge.handleUnityMessage(message);
  }

  void _setupUnityBridgeCallbacks() {
    unityBridge.onResponse = (response) {
      if (!response.ok) {
        _logger.w('[Bridge] ❌ ${response.action}: ${response.message}');

        const actionsThatMatter = {
          'navigate', 'nav_status', 'load_session',
          'save_session', 'create_waypoint', 'remove_waypoint',
        };
        if (actionsThatMatter.contains(response.action)) {
          coordinator.speak('No pude completar el comando. ${response.message}');
        }

        onShowSnackBar?.call('⚠️ ${response.message}', isError: true);
        return;
      }

      _logger.i('[Bridge] ✅ ${response.action}: ${response.message}');

      if (response.action == 'navigation_arrived') {
        // Unity ya habló el mensaje de llegada — Flutter solo feedback visual/háptico
        coordinator.resetNavigation();
        onShowSnackBar?.call('📍 ${response.message}');
        HapticFeedback.heavyImpact();
      }
    };

    unityBridge.onWaypointsReceived = (waypoints) {
      _logger.i('[Bridge] 📍 ${waypoints.length} waypoint(s) recibidos de Unity');
      waypointContext.updateFromUnity(waypoints);
    };

    unityBridge.onTrackingStateChanged = onTrackingStateChanged;

    unityBridge.onSegmentationRatioReceived = (obs, floor, wall) {
      const threshold = 0.02;
      if ((_segObstacle - obs).abs() < threshold &&
          (_segFloor - floor).abs() < threshold &&
          (_segWall - wall).abs() < threshold) return;
      _segObstacle = obs;
      _segFloor = floor;
      _segWall = wall;
      _segBackground = (1.0 - obs - floor - wall).clamp(0.0, 1.0);
      notifyListeners();
    };

    unityBridge.onSegmentationActiveChanged = (active) {
      _logger.i('[Bridge] 🤖 segmentation_active=$active');
      _segmentationActive = active;
      if (active) {
        _segMaskVisible = true;
      } else {
        _segObstacle = _segFloor = _segWall = _segBackground = 0;
      }
      notifyListeners();
      HapticFeedback.selectionClick();
      if (active) onShowSnackBar?.call('🤖 Segmentación ML activada');
    };

    final coordinatorVoiceStatus = unityBridge.onVoiceStatusReceived;
    unityBridge.onVoiceStatusReceived = (info) {
      coordinatorVoiceStatus?.call(info);
      final msg = info.isGuiding
          ? '📊 Guiando → ${info.destination} (${info.remainingSteps} pasos)'
          : info.isPreprocessing
          ? '📊 Calculando ruta...'
          : '📊 Sin navegación activa';
      onShowSnackBar?.call(msg);
    };

    unityBridge.onSessionLoaded = (SessionLoadedInfo info) {
      _logger.i('[Controller] 📦 session_loaded: $info');
      onSessionLoaded(info);
    };
  }

  // ─── Controles de voz ─────────────────────────────────────────────────────
  Future<void> toggleVoice() async {
    if (!_isInitialized) return;
    try {
      if (_isActive) {
        await coordinator.stop();
        _isActive = false;
        _statusMessage = 'Voz detenida';
      } else {
        await coordinator.start(mode: _currentMode);
        _isActive = true;
        _statusMessage = _wakeWordAvailable ? 'Esperando "oye Compas"...' : 'Escuchando...';
      }
      notifyListeners();
      HapticFeedback.mediumImpact();
    } catch (e) {
      onShowSnackBar?.call('Error: $e', isError: true);
    }
  }

  // ─── Lifecycle ────────────────────────────────────────────────────────────
  void handleAppLifecycle(flutter_widgets.AppLifecycleState state) {
    if (!_wakeWordAvailable || !_isInitialized) return;
    switch (state) {
      case flutter_widgets.AppLifecycleState.paused:
      case flutter_widgets.AppLifecycleState.inactive:
        coordinator.wakeWordService.pause();
        break;
      case flutter_widgets.AppLifecycleState.resumed:
        Future.delayed(const Duration(milliseconds: 800), () {
          if (_isActive && _wakeWordAvailable) coordinator.wakeWordService.resume();
        });
        break;
      default:
        break;
    }
  }

  // ─── Historial ────────────────────────────────────────────────────────────
  void addToHistory(NavigationIntent intent) {
    history.insert(0, CommandItem(intent: intent, time: DateTime.now()));
    if (history.length > _maxHistory) history.removeLast();
    notifyListeners();
  }

  // ─── Acciones del panel de testing ───────────────────────────────────────
  void fireTestIntent(NavigationIntent intent) {
    unityBridge.handleIntent(intent);
    addToHistory(intent);
    onShowSnackBar?.call('🧪 ${intent.suggestedResponse}');
    HapticFeedback.lightImpact();
    _currentIntent = intent;
    notifyListeners();
    Future.delayed(const Duration(seconds: 2), () {
      _currentIntent = null;
      notifyListeners();
    });
  }

  void testCreateWaypoint(String name) {
    if (name.isEmpty) {
      onShowSnackBar?.call('⚠️ Escribe un nombre', isError: true);
      return;
    }
    fireTestIntent(NavigationIntent(
      type: IntentType.navigate,
      target: '__unity:create_waypoint:$name',
      priority: 6,
      suggestedResponse: 'Creando baliza "$name"',
    ));
    Future.delayed(const Duration(milliseconds: 400), () {
      unityBridge.saveSession();
      _logger.i('[Test] Auto-guardado tras crear baliza "$name"');
    });
    _waypointCounter++;
    notifyListeners();
  }

  Future<void> testNavigateTo(String target) async {
    if (target.isEmpty) {
      onShowSnackBar?.call('⚠️ Escribe un destino', isError: true);
      return;
    }
    if (!unityBridge.isSceneReady) {
      onShowSnackBar?.call('⏳ Esperando que AR esté lista...');
      final ready = await _waitForBridgeReady();
      if (!ready) {
        onShowSnackBar?.call('⚠️ AR no disponible — intenta más tarde', isError: true);
        return;
      }
    }
    voiceNav.resetDeduplication();
    fireTestIntent(NavigationIntent(
      type: IntentType.navigate,
      target: target,
      priority: 8,
      suggestedResponse: 'Navegando a $target',
    ));
  }

  void testStop() {
    voiceNav.stop();
    coordinator.resetNavigation();
    fireTestIntent(NavigationIntent(
      type: IntentType.stop,
      target: '',
      priority: 10,
      suggestedResponse: 'Navegación detenida',
    ));
  }

  void testToggleSegMask() {
    if (!unityBridge.isReady) {
      onShowSnackBar?.call('⚠️ Unity no lista', isError: true);
      return;
    }
    if (!_segmentationActive) {
      onShowSnackBar?.call('ℹ️ La máscara solo está disponible durante navegación');
      return;
    }
    unityBridge.toggleSegMask();
    _segMaskVisible = !_segMaskVisible;
    notifyListeners();
    onShowSnackBar?.call(_segMaskVisible ? '🎭 Máscara activada' : '🎭 Máscara desactivada');
    HapticFeedback.lightImpact();
  }

  // ─── Dispose ──────────────────────────────────────────────────────────────
  @override
  void dispose() {
    _trackingWarningTimer?.cancel();
    _trackingDebounceTimer?.cancel();
    onReadyForTutorial = null;

    // Completar el Completer si aún está pendiente para no dejar Futures colgados
    if (!_tutorialCompleter.isCompleted) _tutorialCompleter.complete();

    coordinator.dispose();
    aiModeController.dispose();
    unityBridge.dispose();
    voiceNav.dispose();
    waypointContext.dispose();
    super.dispose();
  }
}