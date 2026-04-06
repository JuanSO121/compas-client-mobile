// lib/controllers/ar_navigation_controller.dart
// ✅ v1.1 — Fix listWaypoints con reintentos cuando Unity aún no está lista
//
// ============================================================================
//  CAMBIOS v1.0 → v1.1
// ============================================================================
//
//  FIX — _onSessionLoadResponse ahora llama _requestWaypointsWithRetry()
//    en lugar de llamar directamente _unityBridge.listWaypoints().
//    Antes: si Unity no estaba lista al recibir session_loaded, el comando
//    se ignoraba silenciosamente y cachedWaypoints quedaba vacío para siempre.
//    Ahora: reintenta cada 500ms hasta que isReady sea true (máx 10 segundos).
//
//  TODO LO DEMÁS ES IDÉNTICO A v1.0.

import 'dart:async';
import 'package:flutter/foundation.dart';

import '../models/shared_models.dart';
import '../services/AI/navigation_coordinator.dart';
import '../services/AI/ai_mode_controller.dart';
import '../services/AI/waypoint_context_service.dart';
import '../services/unity_bridge_service.dart';
import '../services/voice_navigation_service.dart';
import 'package:flutter_unity_widget/flutter_unity_widget.dart';
import 'package:logger/logger.dart';

// ─── Estados de inicialización ────────────────────────────────────────────────

enum AppReadyState {
  initializing,
  waitingUser,
  loadingSession,
  ready,
}

// ─── Controller ──────────────────────────────────────────────────────────────

class ArNavigationController extends ChangeNotifier {
  ArNavigationController({
    required NavigationCoordinator  coordinator,
    required AIModeController       aiModeController,
    required UnityBridgeService     unityBridge,
    required VoiceNavigationService voiceNav,
    required WaypointContextService waypointContext,
  })  : _coordinator      = coordinator,
        _aiModeController = aiModeController,
        _unityBridge      = unityBridge,
        _voiceNav         = voiceNav,
        _waypointContext  = waypointContext;

  final NavigationCoordinator  _coordinator;
  final AIModeController       _aiModeController;
  final UnityBridgeService     _unityBridge;
  final VoiceNavigationService _voiceNav;
  final WaypointContextService _waypointContext;
  final Logger                 _logger = Logger();

  // ─── Estado expuesto a la UI ──────────────────────────────────────────────

  AppReadyState _appState             = AppReadyState.initializing;
  bool          _flutterServicesReady = false;
  bool          _unityReady           = false;

  bool              _isInitialized     = false;
  bool              _isActive          = false;
  String            _statusMessage     = 'Inicializando...';
  NavigationMode    _currentMode       = NavigationMode.eventBased;
  AIMode            _aiMode            = AIMode.auto;
  NavigationIntent? _currentIntent;
  bool              _wakeWordAvailable = false;

  bool _unityLoaded      = false;
  bool _showVoiceOverlay = true;

  bool   _arTrackingStable = true;
  String _arTrackingState  = '';
  String _arTrackingReason = '';

  double _segObstacle    = 0;
  double _segFloor       = 0;
  double _segWall        = 0;
  double _segBackground  = 0;
  bool   _segMaskVisible = true;

  Timer? _sessionLoadTimeout;
  Timer? _trackingWarningTimer;
  Timer? _waypointRetryTimer; // ✅ v1.1: timer para reintentos de listWaypoints

  // ─── Getters ──────────────────────────────────────────────────────────────

  AppReadyState     get appState          => _appState;
  bool              get isInitialized     => _isInitialized;
  bool              get isActive          => _isActive;
  String            get statusMessage     => _statusMessage;
  NavigationMode    get currentMode       => _currentMode;
  AIMode            get aiMode            => _aiMode;
  NavigationIntent? get currentIntent     => _currentIntent;
  bool              get wakeWordAvailable => _wakeWordAvailable;
  bool              get unityLoaded       => _unityLoaded;
  bool              get showVoiceOverlay  => _showVoiceOverlay;
  bool              get arTrackingStable  => _arTrackingStable;
  String            get arTrackingState   => _arTrackingState;
  String            get arTrackingReason  => _arTrackingReason;
  double            get segObstacle       => _segObstacle;
  double            get segFloor          => _segFloor;
  double            get segWall           => _segWall;
  double            get segBackground     => _segBackground;
  bool              get segMaskVisible    => _segMaskVisible;

  // ─── Callbacks hacia la UI ────────────────────────────────────────────────

  Function(String message, {bool isError})? onSnackBar;
  Function(String reason)?                  onTrackingSnackBar;
  VoidCallback?                             onHideSnackBar;

  // ─── Inicialización ───────────────────────────────────────────────────────

  Future<void> initializeServices() async {
    try {
      _setStatus('Inicializando servicios...');

      await _aiModeController.initialize();
      _aiMode = _aiModeController.currentMode;

      await _coordinator.initialize();
      _wakeWordAvailable = _coordinator.wakeWordAvailable;

      _coordinator.onStatusUpdate = (status) {
        _statusMessage = status;
        notifyListeners();
      };

      _coordinator.onIntentDetected = (intent) {
        _currentIntent = intent;
        notifyListeners();
        Future.delayed(const Duration(seconds: 3), () {
          _currentIntent = null;
          notifyListeners();
        });
      };

      _coordinator.onCommandExecuted = (intent) {
        _unityBridge.handleIntent(intent);
        onSnackBar?.call('✅ ${intent.suggestedResponse}');

        if (intent.type == IntentType.navigate &&
            !intent.target.startsWith('__unity:')) {
          _voiceNav.resetDeduplication();
        }
        if (intent.type == IntentType.stop) {
          _voiceNav.stop();
          _coordinator.resetNavigation();
        }

        if (intent.target == '__app:user_ready' &&
            _appState == AppReadyState.waitingUser) {
          onUserReady();
        }
      };

      _coordinator.onCommandRejected = (reason) {
        onSnackBar?.call('⛔ $reason', isError: true);
      };

      _aiModeController.onModeChanged = (mode) {
        _aiMode = mode;
        notifyListeners();
      };

      await _voiceNav.initialize(_coordinator.ttsService);
      _voiceNav.attachToUnityBridge(_unityBridge);

      if (_coordinator.wakeWordAvailable) {
        _voiceNav.attachWakeWordService(_coordinator.wakeWordService);
      }

      _logger.i('[Controller] ✅ Servicios inicializados');

      _isInitialized = true;
      _setStatus('Cargando escena AR...');

      _flutterServicesReady = true;
      _tryAdvanceToWaitingUser();

    } catch (e) {
      _logger.e('[Controller] Error: $e');
      _setStatus('Error: $e');
      _isInitialized = false;
      notifyListeners();
    }
  }

  // ─── Unity ────────────────────────────────────────────────────────────────

  void onUnityCreated(UnityWidgetController controller) {
    _unityBridge.setController(controller);
    _voiceNav.setUnityController(controller);
    _coordinator.attachUnityBridge(_unityBridge);

    // Preservar callback de voice_status del coordinator
    final coordCallback = _unityBridge.onVoiceStatusReceived;
    _unityBridge.onVoiceStatusReceived = (info) {
      coordCallback?.call(info);
      final msg = info.isGuiding
          ? '📊 Guiando → ${info.destination} (${info.remainingSteps} pasos)'
          : info.isPreprocessing
              ? '📊 Calculando ruta...'
              : '📊 Sin navegación activa';
      onSnackBar?.call(msg);
    };

    _unityBridge.onResponse = (response) {
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
        onSnackBar?.call('⚠️ ${response.message}', isError: true);
        return;
      }
      if (response.action == 'navigation_arrived') {
        if (_voiceNav.isReady) {
          _voiceNav.speak(response.message);
        } else {
          _coordinator.speak(response.message);
        }
        _coordinator.resetNavigation();
        onSnackBar?.call('📍 ${response.message}');
      }
    };

    _unityBridge.onWaypointsReceived = (waypoints) {
      _logger.i('[Controller] 📍 ${waypoints.length} waypoints recibidos');
      _waypointContext.updateFromUnity(waypoints);
    };

    _unityBridge.onTrackingStateChanged = _onTrackingStateChanged;

    _unityBridge.onSegmentationRatioReceived = (obs, floor, wall) {
      _segObstacle   = obs;
      _segFloor      = floor;
      _segWall       = wall;
      _segBackground = (1.0 - obs - floor - wall).clamp(0.0, 1.0);
      notifyListeners();
    };

    _unityLoaded = true;
    notifyListeners();

    _logger.i('[Controller] UnityWidget creado — esperando scene_ready...');

    _unityBridge.waitForSceneReady().then((_) {
      _logger.i('[Controller] ✅ scene_ready confirmado');
      _unityReady = true;
      _tryAdvanceToWaitingUser();
    });
  }

  void onUnityMessage(dynamic message) {
    _unityBridge.handleUnityMessage(message);
  }

  // ─── Máquina de estados ───────────────────────────────────────────────────

  void _tryAdvanceToWaitingUser() {
    if (_appState != AppReadyState.initializing) return;
    if (!_flutterServicesReady || !_unityReady) return;

    _logger.i('[Controller] initializing → waitingUser');
    _appState      = AppReadyState.waitingUser;
    _statusMessage = '¿Listo para navegar?';
    notifyListeners();
    _coordinator.speak('Bienvenido. Di "Estoy listo" cuando quieras comenzar.');
  }

  void onUserReady() {
    if (_appState != AppReadyState.waitingUser) return;
    _logger.i('[Controller] waitingUser → loadingSession');
    _appState      = AppReadyState.loadingSession;
    _statusMessage = 'Cargando sesión...';
    notifyListeners();

    _unityBridge.loadSession();

    _sessionLoadTimeout = Timer(const Duration(seconds: 8), () {
      _logger.w('[Controller] Timeout session_loaded — avanzando a ready');
      _onSessionLoadResponse(
        success: false,
        message: 'No se encontró sesión guardada.',
      );
    });
  }

  void _onSessionLoadResponse({required bool success, required String message}) {
    if (_appState != AppReadyState.loadingSession) return;
    _logger.i('[Controller] loadingSession → ready (success: $success)');

    _appState = AppReadyState.ready;

    // ✅ v1.1: solicitar waypoints con reintentos en lugar de llamada directa
    _requestWaypointsWithRetry();

    final msg = success
        ? 'Sesión cargada. Listo para navegar.'
        : 'No hay sesión guardada. Puedes crear balizas.';

    _voiceNav.isReady ? _voiceNav.speak(msg) : _coordinator.speak(msg);

    _statusMessage = _wakeWordAvailable
        ? 'Di "Oye COMPAS" para navegar'
        : 'Presiona el micrófono para hablar';
    notifyListeners();
  }

  // ✅ v1.1: solicita waypoints reintentando cada 500ms hasta que Unity
  // confirme isReady. Máximo 20 intentos (10 segundos).
  void _requestWaypointsWithRetry() {
    _waypointRetryTimer?.cancel();

    if (_unityBridge.isReady) {
      _unityBridge.listWaypoints();
      _logger.i('[Controller] listWaypoints() enviado (Unity lista)');
      return;
    }

    _logger.w('[Controller] Unity no lista al solicitar waypoints — reintentando cada 500ms...');

    int attempts = 0;
    _waypointRetryTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (timer) {
        attempts++;
        if (_unityBridge.isReady) {
          timer.cancel();
          _waypointRetryTimer = null;
          _unityBridge.listWaypoints();
          _logger.i('[Controller] listWaypoints() enviado tras $attempts intentos');
        } else if (attempts >= 20) {
          timer.cancel();
          _waypointRetryTimer = null;
          _logger.e('[Controller] Unity no respondió para listWaypoints tras 10s');
        }
      },
    );
  }

  // ─── Tracking ─────────────────────────────────────────────────────────────

  void _onTrackingStateChanged(bool isStable, String state, String reason) {
    _arTrackingStable = isStable;
    _arTrackingState  = state;
    _arTrackingReason = reason;
    notifyListeners();

    if (!isStable) {
      onTrackingSnackBar?.call(reason.isNotEmpty ? reason : state);
      _trackingWarningTimer?.cancel();
      _trackingWarningTimer = Timer(const Duration(seconds: 6), () {
        if (!_arTrackingStable) {
          onTrackingSnackBar?.call(
            _arTrackingReason.isNotEmpty ? _arTrackingReason : _arTrackingState,
          );
        }
      });
    } else {
      _trackingWarningTimer?.cancel();
      onHideSnackBar?.call();
    }
  }

  // ─── Acciones de UI ───────────────────────────────────────────────────────

  Future<void> toggleVoice() async {
    if (!_isInitialized) return;
    if (_isActive) {
      await _coordinator.stop();
      _isActive      = false;
      _statusMessage = 'Voz detenida';
    } else {
      await _coordinator.start(mode: _currentMode);
      _isActive      = true;
      _statusMessage = _wakeWordAvailable
          ? 'Esperando "Oye COMPAS"...'
          : 'Escuchando...';
    }
    notifyListeners();
  }

  void toggleVoiceOverlay() {
    _showVoiceOverlay = !_showVoiceOverlay;
    notifyListeners();
  }

  void toggleSegMask() {
    if (!_unityBridge.isReady) {
      onSnackBar?.call('⚠️ Unity no lista', isError: true);
      return;
    }
    _unityBridge.toggleSegMask();
    _segMaskVisible = !_segMaskVisible;
    notifyListeners();
    onSnackBar?.call(_segMaskVisible ? '🎭 Máscara activada' : '🎭 Máscara desactivada');
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  void _setStatus(String msg) {
    _statusMessage = msg;
    notifyListeners();
  }

  // ─── Dispose ──────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _sessionLoadTimeout?.cancel();
    _trackingWarningTimer?.cancel();
    _waypointRetryTimer?.cancel(); // ✅ v1.1: limpiar timer de reintentos
    super.dispose();
  }
}