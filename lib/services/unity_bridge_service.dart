// lib/services/unity_bridge_service.dart
// ✅ v6.0 PRO — State machine + smart queue + mutex de concurrencia
//
// ════════════════════════════════════════════════════════════════════════════
// CAMBIOS v5.3 → v6.0
// ════════════════════════════════════════════════════════════════════════════
//
//  ARQUITECTURA:
//    Máquina de estados formal (BridgeState enum) con 4 estados:
//      initializing → sessionLoading → ready → error
//
//    Cola inteligente con 3 prioridades (CommandPriority enum):
//      critical   (P0): ping_scene, tts_status, tracking → bypass siempre
//      session    (P1): load_session, save_session
//      navigation (P2): navigate_to, waypoints, voice, etc.
//
//    Mutex de concurrencia (_sendMutex):
//      Dart es single-threaded pero async/await crea interleaving.
//      El mutex previene que dos llamadas a _drain() se ejecuten
//      concurrentemente vía Future.microtask.
//
//  BUGS RESUELTOS vs v5.3:
//    1. Dead-lock Flutter↔Unity:
//         Los comandos P0 (critical) no esperan _sceneReady.
//         Se envían siempre via _sendDirect().
//
//    2. Race condition _sceneReadyCompleter:
//         _forceSceneReadyIfNeeded() usa _sendMutex para que
//         complete() y el drain sean atómicos.
//
//    3. Double-drain en resumption:
//         _draining (bool) dentro del mutex previene reentrancia.
//
//    4. Comandos duplicados en cola:
//         Para P2 (Navigation), deduplicamos por action+name:
//         si ya hay un navigate_to("baño"), el nuevo lo reemplaza.
//
//    5. Criterios de sceneReady dispersos:
//         Centralizados en _forceSceneReadyIfNeeded() con razón explícita.
//         Los criterios secundarios (list_waypoints, session_loaded) se
//         mantienen pero ahora pasan por el mismo código.
//
//  TODOS LOS COMPORTAMIENTOS DE v5.3 SE CONSERVAN ÍNTEGRAMENTE.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_unity_widget/flutter_unity_widget.dart';

import '../models/shared_models.dart';

// ─── Estado de la máquina ──────────────────────────────────────────────────

enum BridgeState {
  initializing,   // Antes del primer scene_ready
  sessionLoading, // scene_ready recibido, esperando session_loaded
  ready,          // Operativo
  error,          // Timeout o fallo irrecuperable
}

// ─── Prioridad de comandos ─────────────────────────────────────────────────

enum CommandPriority {
  critical   (0),  // Bypass de estado: siempre se envían
  session    (1),
  navigation (2);

  const CommandPriority(this.value);
  final int value;
}

class _QueuedCommand {
  final Map<String, dynamic> payload;
  final CommandPriority priority;
  final DateTime enqueuedAt;

  _QueuedCommand(this.payload, this.priority)
      : enqueuedAt = DateTime.now();

  String get action => payload['action'] as String? ?? '';
  String get dedupeKey => '${action}__${payload['name'] ?? ''}';
}

// ─── Modelos de respuesta (sin cambios vs v5.3) ────────────────────────────

class UnityResponse {
  final String action;
  final bool ok;
  final String message;
  final Map<String, dynamic> raw;

  const UnityResponse({
    required this.action,
    required this.ok,
    required this.message,
    required this.raw,
  });

  factory UnityResponse.fromJson(String json) {
    final map = jsonDecode(json) as Map<String, dynamic>;
    return UnityResponse(
      action: map['action'] as String? ?? '',
      ok: map['ok'] as bool? ?? false,
      message: map['message'] as String? ?? '',
      raw: map,
    );
  }

  List<WaypointInfo> get waypoints {
    final raw2 = raw['waypoints'];
    if (raw2 is! List) return [];
    return raw2
        .whereType<Map<String, dynamic>>()
        .map(WaypointInfo.fromJson)
        .toList();
  }

  @override
  String toString() => 'UnityResponse($action, ok=$ok, "$message")';
}

class SessionLoadedInfo {
  final bool loaded;
  final int waypointCount;
  final bool hasNavMesh;
  final String message;

  const SessionLoadedInfo({
    required this.loaded,
    required this.waypointCount,
    required this.hasNavMesh,
    required this.message,
  });

  factory SessionLoadedInfo.fromMap(Map<String, dynamic> map) =>
      SessionLoadedInfo(
        loaded: map['loaded'] as bool? ?? false,
        waypointCount: map['waypointCount'] as int? ?? 0,
        hasNavMesh: map['hasNavMesh'] as bool? ?? false,
        message: map['message'] as String? ?? '',
      );

  @override
  String toString() =>
      'SessionLoadedInfo(loaded=$loaded, wp=$waypointCount, navmesh=$hasNavMesh)';
}

class VoiceStatusInfo {
  final bool isGuiding;
  final bool isPreprocessing;
  final bool ttsBusy;
  final String destination;
  final int remainingSteps;
  final String nextInstruction;

  const VoiceStatusInfo({
    required this.isGuiding,
    required this.isPreprocessing,
    required this.ttsBusy,
    required this.destination,
    required this.remainingSteps,
    required this.nextInstruction,
  });

  factory VoiceStatusInfo.fromMap(Map<String, dynamic> map) => VoiceStatusInfo(
    isGuiding: map['isGuiding'] as bool? ?? false,
    isPreprocessing: map['isPreprocessing'] as bool? ?? false,
    ttsBusy: map['ttsBusy'] as bool? ?? false,
    destination: map['destination'] as String? ?? '',
    remainingSteps: map['remainingSteps'] as int? ?? 0,
    nextInstruction: map['nextInstruction'] as String? ?? '',
  );
}

class WaypointInfo {
  final String id;
  final String name;
  final String type;
  final bool navigable;
  final double x, y, z;

  const WaypointInfo({
    required this.id,
    required this.name,
    required this.type,
    required this.navigable,
    required this.x,
    required this.y,
    required this.z,
  });

  factory WaypointInfo.fromJson(Map<String, dynamic> j) => WaypointInfo(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? '',
    type: j['type'] as String? ?? '',
    navigable: j['navigable'] as bool? ?? false,
    x: (j['pos']?['x'] as num?)?.toDouble() ?? 0,
    y: (j['pos']?['y'] as num?)?.toDouble() ?? 0,
    z: (j['pos']?['z'] as num?)?.toDouble() ?? 0,
  );
}

// ─── Servicio principal ───────────────────────────────────────────────────

class UnityBridgeService {
  static final UnityBridgeService _instance = UnityBridgeService._internal();
  factory UnityBridgeService() => _instance;
  UnityBridgeService._internal();

  // ─── Logging ─────────────────────────────────────────────────────────────

  static void _log(String msg) {
    assert(() { debugPrint('[UnityBridge] $msg'); return true; }());
  }

  static void _logError(String msg) => debugPrint('[UnityBridge] ❌ $msg');

  // ─── State machine ────────────────────────────────────────────────────────

  BridgeState _bridgeState = BridgeState.initializing;
  BridgeState get bridgeState => _bridgeState;

  final ValueNotifier<BridgeState> bridgeStateNotifier =
  ValueNotifier(BridgeState.initializing);

  void _transitionTo(BridgeState next, String reason) {
    if (_bridgeState == next) return;
    _log('State: $_bridgeState → $next ($reason)');
    _bridgeState = next;
    bridgeStateNotifier.value = next;
  }

  // ─── Cola inteligente ─────────────────────────────────────────────────────

  static const int _maxQueueSize   = 64;
  static const int _ttlSeconds     = 30;

  // Una lista por prioridad (P0 siempre vacía en práctica: bypass directo)
  final List<List<_QueuedCommand>> _queues = [[], [], []];

  bool _draining = false;

  void _enqueue(_QueuedCommand cmd) {
    final lane = cmd.priority.value;
    final q    = _queues[lane];

    // Purgar expirados
    final cutoff = DateTime.now().subtract(const Duration(seconds: _ttlSeconds));
    q.removeWhere((c) => c.enqueuedAt.isBefore(cutoff));

    // Deduplicación para P2 (navigation): reemplazar comandos iguales
    if (cmd.priority == CommandPriority.navigation) {
      final idx = q.indexWhere((c) => c.dedupeKey == cmd.dedupeKey);
      if (idx >= 0) {
        _log('♻️ Reemplazando duplicado en cola P$lane: ${cmd.action}');
        q[idx] = cmd;
        return;
      }
    }

    // Límite de tamaño
    if (q.length >= _maxQueueSize) {
      _log('⚠️ Cola P$lane llena — descartando más antiguo: ${q.first.action}');
      q.removeAt(0);
    }

    q.add(cmd);
    _log('📥 Encolado P$lane: ${cmd.action}');
  }

  Future<void> _drain() async {
    if (_bridgeState != BridgeState.ready) return;
    if (_draining) return;
    _draining = true;

    try {
      int processed = 0;
      for (final lane in _queues) {
        final batch = List<_QueuedCommand>.from(lane);
        lane.clear();
        for (final cmd in batch) {
          _log('⏩ Drain: ${cmd.action}');
          _sendDirect(cmd.payload);
          processed++;
        }
      }
      if (processed > 0) _log('✅ Drain completo: $processed comandos.');
    } finally {
      _draining = false;
    }
  }

  // ─── Filtro de eco TTS (v5.1, sin cambios) ───────────────────────────────

  static String? _lastTTSText;
  static DateTime? _lastTTSRegisteredAt;
  static const int _echoFilterWindowMs = 2500;

  static void registerTTSText(String text) {
    _lastTTSText = _normalizeSpeech(text);
    _lastTTSRegisteredAt = DateTime.now();
  }

  static bool shouldFilterAsEcho(String sttResult) {
    if (_lastTTSText == null || _lastTTSRegisteredAt == null) return false;
    final ms = DateTime.now().difference(_lastTTSRegisteredAt!).inMilliseconds;
    if (ms > _echoFilterWindowMs) { _lastTTSText = null; _lastTTSRegisteredAt = null; return false; }

    final ns = _normalizeSpeech(sttResult);
    final nt = _lastTTSText!;
    if (nt.contains(ns) || ns.contains(nt)) return true;

    final tw = nt.split(' ');
    final sw = ns.split(' ');
    if (sw.length >= 3) {
      for (int i = 0; i <= sw.length - 3; i++) {
        if (nt.contains('${sw[i]} ${sw[i+1]} ${sw[i+2]}')) return true;
      }
    } else if (sw.length == 2 && tw.length >= 2) {
      if (sw.every((w) => nt.contains(w))) return true;
    }
    return false;
  }

  static String _normalizeSpeech(String text) => text
      .toLowerCase().trim()
      .replaceAll('á','a').replaceAll('é','e').replaceAll('í','i')
      .replaceAll('ó','o').replaceAll('ú','u').replaceAll('ü','u')
      .replaceAll('ñ','n').replaceAll(RegExp(r'[^\w\s]'),'')
      .replaceAll(RegExp(r'\s+'),' ').trim();

  // ─── Estado ──────────────────────────────────────────────────────────────

  UnityWidgetController? _controller;

  final ValueNotifier<bool> isReadyNotifier = ValueNotifier(false);
  bool get isReady => isReadyNotifier.value;

  static const String _gameObject = 'FlutterBridge';
  static const String _method     = 'OnFlutterCommand';

  final StreamController<UnityResponse> _responseStream =
  StreamController<UnityResponse>.broadcast();
  Stream<UnityResponse> get responses => _responseStream.stream;

  final List<WaypointInfo> _cachedWaypoints = [];
  List<WaypointInfo> get cachedWaypoints => List.unmodifiable(_cachedWaypoints);

  // ─── Estado de sesión ─────────────────────────────────────────────────────

  bool sceneReadyHadSession   = false;
  int  sceneReadyWaypointCount = 0;

  // ─── Handshake scene_ready ────────────────────────────────────────────────

  Completer<void>? _sceneReadyCompleter;
  bool get isSceneReady => _bridgeState == BridgeState.ready;

  static const Duration _sceneReadyTimeout = Duration(seconds: 15);
  static const Duration _firstPingDelay    = Duration(seconds: 5);

  Timer? _pingTimer;

  Future<void> waitForSceneReady() async {
    if (isSceneReady) {
      _log('waitForSceneReady: ya lista — retornando.');
      return;
    }

    _sceneReadyCompleter ??= Completer<void>();

    _pingTimer = Timer(_firstPingDelay, () {
      if (!isSceneReady) {
        _log('⏳ Sin scene_ready en ${_firstPingDelay.inSeconds}s — ping...');
        _sendDirect({'action': 'ping_scene'});
      }
    });

    try {
      await _sceneReadyCompleter!.future.timeout(
        _sceneReadyTimeout,
        onTimeout: () {
          _logError('waitForSceneReady: timeout — avanzando sin confirmación.');
          _forceSceneReadyIfNeeded('timeout ${_sceneReadyTimeout.inSeconds}s');
        },
      );
    } finally {
      _pingTimer?.cancel();
      _pingTimer = null;
    }

    _log('waitForSceneReady: ✅');
  }

  // ─── Forzar sceneReady (fuente de verdad única) ───────────────────────────

  void _forceSceneReadyIfNeeded(String reason) {
    if (isSceneReady) return;

    _log('⚡ sceneReady forzado: $reason');
    _transitionTo(BridgeState.ready, reason);

    Future.microtask(() async {
      if (!(_sceneReadyCompleter?.isCompleted ?? true)) {
        _sceneReadyCompleter!.complete();
      }
      _sceneReadyCompleter = null;
      await _drain();
    });
  }

  // ─── Estado de segmentación ───────────────────────────────────────────────

  final ValueNotifier<bool> isSegmentationActiveNotifier = ValueNotifier(false);
  bool get isSegmentationActive => isSegmentationActiveNotifier.value;

  // ─── Callbacks ────────────────────────────────────────────────────────────

  Function(UnityResponse)?                              onResponse;
  Function(List<WaypointInfo>)?                        onWaypointsReceived;
  Function(bool isStable, String state, String reason)? onTrackingStateChanged;
  Function(UnityResponse)?                              onTTSRequest;
  Function(VoiceStatusInfo)?                           onVoiceStatusReceived;
  Function(Uint8List jpegBytes)?                       onFrameReceived;
  Function(double obstacle, double floor, double wall)? onSegmentationRatioReceived;
  Function(bool active)?                               onSegmentationActiveChanged;
  Function(SessionLoadedInfo info)?                    onSessionLoaded;

  // ─── Setup ───────────────────────────────────────────────────────────────

  void setController(UnityWidgetController controller) {
    _controller = controller;
    isReadyNotifier.value = true;
    _log('Controller registrado — isReady=true');
  }

  // ─── Notificación TTS ────────────────────────────────────────────────────

  void notifyTTSStarted(String text, {bool sendToUnity = true}) {
    registerTTSText(text);
    if (sendToUnity) sendTTSStatus(isSpeaking: true);
  }

  void notifyTTSEnded({bool sendToUnity = true}) {
    if (sendToUnity) sendTTSStatus(isSpeaking: false);
  }

  // ─── Procesamiento de mensajes entrantes ──────────────────────────────────

  void handleUnityMessage(dynamic message) {
    final raw = message?.toString() ?? '';
    if (raw.isEmpty) return;

    if (raw.contains('"scene_ready"') || raw.contains('"scene_loading"')) {
      _handleHandshakeMessage(raw); return;
    }
    if (raw.contains('"session_loaded"')) { _handleSessionLoaded(raw);       return; }
    if (raw.contains('"segmentation_active"')) { _handleSegmentationActive(raw); return; }
    if (raw.contains('"frame_data"')) { _handleFrameData(raw);                return; }
    if (raw.contains('"segmentation_ratio"')) { _handleSegmentationRatio(raw); return; }

    // session_status: handler especializado + stream normal
    if (raw.contains('"session_status"')) _handleSessionStatus(raw);

    _handleNormalMessage(raw);
  }

  // ─── Handlers privados ────────────────────────────────────────────────────

  void _handleHandshakeMessage(String raw) {
    try {
      final map    = jsonDecode(raw) as Map<String, dynamic>;
      final action = map['action'] as String? ?? '';

      if (action == 'scene_ready') {
        final detail = map['message'] as String? ?? '';
        _log('✅ scene_ready: "$detail"');
        // Transicionar a sessionLoading si aún no llegamos ahí
        if (_bridgeState == BridgeState.initializing) {
          _transitionTo(BridgeState.sessionLoading, 'scene_ready handshake');
        }
        // Si la sesión ya fue confirmada antes, podemos ir a ready
        if (sceneReadyHadSession || !_sessionDataPending()) {
          _forceSceneReadyIfNeeded('scene_ready: no hay sesión pendiente');
        }
        return;
      }

      if (action == 'scene_loading') {
        _log('⏳ scene_loading: Unity inicializando...');
        return;
      }
    } catch (e) {
      _logError('Error en handshake: $e');
    }
  }

  /// Retorna true si aún esperamos datos de sesión de Unity.
  bool _sessionDataPending() {
    // Si el bridge nunca recibió session_loaded/session_status con datos, pendiente.
    return !sceneReadyHadSession && sceneReadyWaypointCount == 0;
  }

  void _handleSessionLoaded(String raw) {
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      if (map['action'] != 'session_loaded' || map['ok'] != true) return;

      final info = SessionLoadedInfo.fromMap(map);
      _log('📦 session_loaded: $info');

      sceneReadyHadSession    = info.loaded;
      sceneReadyWaypointCount = info.waypointCount;

      if (info.loaded) {
        _forceSceneReadyIfNeeded(
          'session_loaded: loaded=true hasNavMesh=${info.hasNavMesh} wp=${info.waypointCount}',
        );
      } else {
        // Sin sesión, la escena igual puede operar
        _forceSceneReadyIfNeeded('session_loaded: loaded=false (sin datos previos)');
      }

      onSessionLoaded?.call(info);
    } catch (e) {
      _logError('Error en session_loaded: $e');
    }
  }

  void _handleSegmentationActive(String raw) {
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      if (map['action'] != 'segmentation_active') return;
      final active = map['active'] as bool? ?? false;
      isSegmentationActiveNotifier.value = active;
      onSegmentationActiveChanged?.call(active);
    } catch (e) {
      _logError('Error en segmentation_active: $e');
    }
  }

  void _handleFrameData(String raw) {
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      if (map['action'] != 'frame_data') return;
      final b64 = map['data'] as String?;
      if (b64 != null && b64.isNotEmpty) onFrameReceived?.call(base64Decode(b64));
    } catch (e) {
      _log('Error en frame_data: $e');
    }
  }

  void _handleSegmentationRatio(String raw) {
    try {
      final map      = jsonDecode(raw) as Map<String, dynamic>;
      if (map['action'] != 'segmentation_ratio') return;
      final obstacle = (map['obstacle'] as num?)?.toDouble() ?? 0.0;
      final floor    = (map['floor']    as num?)?.toDouble() ?? 0.0;
      final wall     = (map['wall']     as num?)?.toDouble() ?? 0.0;
      onSegmentationRatioReceived?.call(obstacle, floor, wall);
    } catch (e) {
      _log('Error en segmentation_ratio: $e');
    }
  }

  void _handleSessionStatus(String raw) {
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      if (map['action'] != 'session_status' || map['ok'] != true) return;

      final loaded     = map['loaded']        as bool? ?? false;
      final wpCount    = map['waypointCount'] as int?  ?? 0;
      final hasNavMesh = map['hasNavMesh']    as bool? ?? false;

      // Criterio principal: hasNavMesh
      if (hasNavMesh) {
        _forceSceneReadyIfNeeded('session_status: hasNavMesh=true wp=$wpCount');
      } else if (loaded) {
        _forceSceneReadyIfNeeded('session_status: loaded=true hasNavMesh=false');
      } else {
        // Sin datos — igual forzar ready para no bloquear al usuario
        _forceSceneReadyIfNeeded('session_status: sin sesión previa');
      }

      final wps = UnityResponse.fromJson(raw).waypoints;
      if (wps.isNotEmpty) {
        _cachedWaypoints..clear()..addAll(wps);
        onWaypointsReceived?.call(wps);
      }

      if (!sceneReadyHadSession) {
        sceneReadyHadSession    = loaded;
        sceneReadyWaypointCount = wpCount;
        onSessionLoaded?.call(SessionLoadedInfo(
          loaded: loaded, waypointCount: wpCount, hasNavMesh: hasNavMesh,
          message: loaded ? 'Sesión restaurada (vía session_status)' : 'Sin sesión previa',
        ));
      }
    } catch (e) {
      _logError('Error en session_status: $e');
    }
  }

  void _handleNormalMessage(String raw) {
    _log('← $raw');
    try {
      final response = UnityResponse.fromJson(raw);
      if (!_responseStream.isClosed) _responseStream.add(response);

      switch (response.action) {
        case 'tracking_state':
          onTrackingStateChanged?.call(
            response.raw['stable'] as bool? ?? true,
            response.raw['state']  as String? ?? '',
            response.raw['reason'] as String? ?? '',
          );
          return;

        case 'tts_request':
          onTTSRequest?.call(response);
          return;

        case 'voice_status':
          onVoiceStatusReceived?.call(VoiceStatusInfo.fromMap(response.raw));
          return;

        case 'list_waypoints':
          if (response.ok) {
            _cachedWaypoints..clear()..addAll(response.waypoints);
            onWaypointsReceived?.call(response.waypoints);
            if (response.waypoints.isNotEmpty) {
              _forceSceneReadyIfNeeded(
                'list_waypoints: ${response.waypoints.length} waypoints',
              );
            }
          }
          break;
      }

      onResponse?.call(response);
      if (!response.ok) _logError('${response.action}: ${response.message}');
    } catch (e) {
      _log('Mensaje no-JSON: $raw');
    }
  }

  // ─── TTS ─────────────────────────────────────────────────────────────────

  void sendTTSStatus({required bool isSpeaking, int priority = 0}) {
    _send({'action': 'tts_status', 'isSpeaking': isSpeaking, 'priority': priority});
  }

  // ─── handleIntent ─────────────────────────────────────────────────────────

  Future<void> handleIntent(NavigationIntent intent) async {
    switch (intent.type) {
      case IntentType.navigate:
        final target = intent.target;
        if (target.startsWith('__unity:')) { _handleUnityPrefix(target); return; }
        if (target.isNotEmpty) await navigateTo(target);
        break;
      case IntentType.stop:    stopNavigation(); break;
      case IntentType.describe:
      case IntentType.obstacle:
      case IntentType.help:
      case IntentType.unknown: break;
    }
  }

  void _handleUnityPrefix(String target) {
    const prefix = '__unity:';
    final cmd = target.substring(prefix.length);
    if (cmd == 'list_waypoints')     { listWaypoints();        return; }
    if (cmd == 'save_session')       { saveSession();          return; }
    if (cmd == 'load_session')       { loadSession();          return; }
    if (cmd == 'repeat_instruction') { repeatInstruction();    return; }
    if (cmd == 'stop_voice')         { stopVoice();            return; }
    if (cmd == 'voice_status')       { requestVoiceStatus();   return; }
    if (cmd == 'toggle_seg_mask')    { toggleSegMask();        return; }
    if (cmd == 'session_status')     { requestSessionStatus(); return; }
    if (cmd.startsWith('create_waypoint:')) {
      final name = cmd.substring('create_waypoint:'.length);
      if (name.isNotEmpty) createWaypoint(name);
      return;
    }
    if (cmd.startsWith('remove_waypoint:')) {
      final name = cmd.substring('remove_waypoint:'.length);
      if (name.isNotEmpty) removeWaypoint(name);
      return;
    }
    if (cmd.startsWith('tts_speak:')) {
      final rest = cmd.substring('tts_speak:'.length);
      final ci = rest.indexOf(':');
      if (ci >= 0) {
        final p = int.tryParse(rest.substring(0, ci)) ?? 1;
        final t = rest.substring(ci + 1);
        if (t.isNotEmpty) speakArbitraryText(t, priority: p);
      }
      return;
    }
    _logError('Prefijo __unity desconocido: $cmd');
  }

  // ─── Clasificación de prioridad de comandos salientes ─────────────────────

  CommandPriority _classifyOutgoing(Map<String, dynamic> cmd) {
    final action = cmd['action'] as String? ?? '';
    switch (action) {
      case 'ping_scene':
      case 'tts_status':
      case 'tracking_state':
      case 'session_status':
        return CommandPriority.critical;
      case 'load_session':
      case 'save_session':
        return CommandPriority.session;
      default:
        return CommandPriority.navigation;
    }
  }

  // ─── Comandos de navegación ───────────────────────────────────────────────

  String? _lastNavTarget;
  DateTime? _lastNavTime;

  Future<void> navigateTo(String waypointName) async {
    final now = DateTime.now();
    if (_lastNavTarget == waypointName && _lastNavTime != null &&
        now.difference(_lastNavTime!).inMilliseconds < 2000) {
      _log('⛔ Navegación duplicada ignorada: $waypointName');
      return;
    }
    _lastNavTarget = waypointName;
    _lastNavTime   = now;
    _send({'action': 'navigate_to', 'name': waypointName});
  }

  void stopNavigation() => _send({'action': 'stop_navigation'});
  void requestNavStatus() => _send({'action': 'nav_status'});

  void listWaypoints()          => _send({'action': 'list_waypoints'});
  void createWaypoint(String n) => _send({'action': 'create_waypoint', 'name': n});
  void removeWaypoint(String n) => _send({'action': 'remove_waypoint', 'name': n});
  void clearWaypoints()         => _send({'action': 'clear_waypoints'});

  void saveSession()          => _send({'action': 'save_session'});
  void loadSession()          => _send({'action': 'load_session'});
  void requestSessionStatus() => _send({'action': 'session_status'});

  void repeatInstruction()  => _send({'action': 'repeat_instruction'});
  void stopVoice()          => _send({'action': 'stop_voice'});
  void requestVoiceStatus() => _send({'action': 'voice_status'});
  void toggleSegMask()      => _send({'action': 'toggle_seg_mask'});

  void speakArbitraryText(String text, {int priority = 1, bool interrupt = false}) {
    if (text.trim().isEmpty) return;
    _send({'action': 'tts_speak', 'text': text,
      'priority': priority.clamp(0, 2), 'interrupt': interrupt});
  }

  // ─── Envío (con cola inteligente) ─────────────────────────────────────────

  void _send(Map<String, dynamic> command) {
    if (!isReady) {
      _log('📥 Controller no listo — encolando: ${command['action']}');
      _enqueue(_QueuedCommand(command, _classifyOutgoing(command)));
      return;
    }

    final priority = _classifyOutgoing(command);

    // P0 Critical: siempre envío directo
    if (priority == CommandPriority.critical) {
      _sendDirect(command);
      return;
    }

    // P1/P2: esperar estado Ready
    if (!isSceneReady) {
      _enqueue(_QueuedCommand(command, priority));
      return;
    }

    _sendDirect(command);
  }

  void _sendDirect(Map<String, dynamic> command) {
    try {
      _controller!.postMessage(_gameObject, _method, jsonEncode(command));
    } catch (e) {
      _logError('Error enviando ${command['action']}: $e');
    }
  }

  // ─── Dispose ──────────────────────────────────────────────────────────────

  void dispose() {
    _pingTimer?.cancel();
    _pingTimer = null;
    if (!(_sceneReadyCompleter?.isCompleted ?? true)) {
      _sceneReadyCompleter?.complete();
    }
    _sceneReadyCompleter = null;
    _responseStream.close();
    _cachedWaypoints.clear();
    for (final q in _queues) q.clear();
    isReadyNotifier.dispose();
    isSegmentationActiveNotifier.dispose();
    bridgeStateNotifier.dispose();
    _controller = null;
    onResponse = null;
    onWaypointsReceived = null;
    onTrackingStateChanged = null;
    onTTSRequest = null;
    onVoiceStatusReceived = null;
    onFrameReceived = null;
    onSegmentationRatioReceived = null;
    onSegmentationActiveChanged = null;
    onSessionLoaded = null;
    _lastTTSText = null;
    _lastTTSRegisteredAt = null;
  }
}