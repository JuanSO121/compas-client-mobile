// lib/services/unity_bridge_service.dart
// ✅ v5.1 — Filtro de eco TTS para wake word + mejoras de robustez
//
// ============================================================================
// CAMBIOS v5.0 → v5.1
// ============================================================================
//
//  BUG CORREGIDO — Wake word captura el TTS del propio altavoz:
//
//    PROBLEMA (visible en logs):
//      [TTS] "Sistema conversacional activado"   ← altavoz reproduce
//      [WakeWord] STT: "sistema conversacional activado"  ← micrófono captura
//      [WakeWord] ❌ STT error: error_no_match (permanent: true)
//
//      El micrófono STT está abierto mientras el TTS habla.
//      El resultado del STT es el texto que acabamos de pronunciar,
//      que no coincide con ninguna keyword del wake word
//      ("oye compas", "hey compas", etc.) → error_no_match.
//
//    FIX:
//      1. Método registerTTSText(String text) — llamado desde NavigationCoordinator
//         (o desde quien gestione el TTS) ANTES de hablar. Registra el texto
//         y el timestamp de cuándo terminó el TTS.
//
//      2. shouldFilterAsEcho(String sttResult) — verifica si el resultado STT
//         es eco del TTS reciente (últimos 2.5s) comparando substrings normalizados.
//
//      3. Estos métodos son estáticos para que NavigationCoordinator pueda
//         llamarlos sin necesidad de tener una referencia al servicio.
//
//  CÓMO INTEGRAR EN NavigationCoordinator / WakeWordService:
//
//    // Antes de reproducir TTS:
//    UnityBridgeService.registerTTSText("Sistema conversacional activado");
//    await tts.speak("Sistema conversacional activado");
//
//    // En el handler de resultados STT del wake word:
//    void _onSpeechResult(String result) {
//      if (UnityBridgeService.shouldFilterAsEcho(result)) return;
//      _checkForWakeWord(result);
//    }
//
//  TODO LO DEMÁS DE v5.0 SE CONSERVA ÍNTEGRAMENTE.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_unity_widget/flutter_unity_widget.dart';

import '../models/shared_models.dart';

// ─── Modelos de respuesta ──────────────────────────────────────────────────

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

// ─── SessionLoadedInfo ────────────────────────────────────────────────────

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

// ─── VoiceStatusInfo ──────────────────────────────────────────────────────

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

  @override
  String toString() =>
      'VoiceStatusInfo(guiding=$isGuiding, dest="$destination", '
      'steps=$remainingSteps, ttsBusy=$ttsBusy)';
}

// ─── WaypointInfo ─────────────────────────────────────────────────────────

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

  @override
  String toString() => 'WaypointInfo($name, navigable=$navigable)';
}

// ─── Servicio principal ───────────────────────────────────────────────────

class UnityBridgeService {
  static final UnityBridgeService _instance = UnityBridgeService._internal();
  factory UnityBridgeService() => _instance;
  UnityBridgeService._internal();

  // ─── Logging ─────────────────────────────────────────────────────────────

  static void _log(String msg) {
    assert(() {
      debugPrint('[UnityBridge] $msg');
      return true;
    }());
  }

  static void _logError(String msg) => debugPrint('[UnityBridge] ❌ $msg');

  // ─── ✅ v5.1 NUEVO — Filtro de eco TTS ──────────────────────────────────
  //
  // El micrófono del wake word puede capturar el audio del propio altavoz.
  // Cuando el TTS dice "Sistema conversacional activado", el STT lo transcribe
  // y lanza error_no_match porque no coincide con ninguna keyword.
  //
  // Solución: registrar el texto del TTS antes de hablar, y filtrar en el STT.

  // Texto del TTS más reciente (normalizado a minúsculas sin acentos)
  static String? _lastTTSText;

  // Timestamp de cuándo se registró el último TTS
  static DateTime? _lastTTSRegisteredAt;

  // Tiempo máximo (ms) para considerar un resultado STT como eco del TTS.
  // 2500ms: cubre TTS de hasta ~3s de duración + latencia del STT.
  static const int _echoFilterWindowMs = 2500;

  /// ✅ v5.1 NUEVO — Registra el texto que el TTS está a punto de pronunciar.
  ///
  /// Llamar ANTES de iniciar el TTS en NavigationCoordinator o donde se gestione:
  ///
  /// ```dart
  /// UnityBridgeService.registerTTSText("Oye, el destino está al norte.");
  /// await tts.speak("Oye, el destino está al norte.");
  /// ```
  ///
  /// Esto permite que shouldFilterAsEcho() descarte el resultado STT
  /// si llega dentro de los próximos 2.5s y coincide con el texto hablado.
  static void registerTTSText(String text) {
    _lastTTSText = _normalizeSpeech(text);
    _lastTTSRegisteredAt = DateTime.now();
    assert(() {
      debugPrint(
        '[UnityBridge] 🔇 TTS registrado para filtro eco: "${_lastTTSText}"',
      );
      return true;
    }());
  }

  /// ✅ v5.1 NUEVO — Determina si un resultado STT es eco del TTS reciente.
  ///
  /// Usar en el handler de resultados STT del wake word:
  ///
  /// ```dart
  /// void _onSpeechResult(String result) {
  ///   if (UnityBridgeService.shouldFilterAsEcho(result)) return; // Ignorar eco
  ///   _checkForWakeWord(result);
  /// }
  /// ```
  ///
  /// Criterios para filtrar como eco:
  ///   1. Hay un TTS registrado (registerTTSText fue llamado)
  ///   2. El resultado llegó dentro de los últimos _echoFilterWindowMs
  ///   3. El resultado STT y el texto TTS tienen superposición significativa
  ///      (uno contiene al otro, o comparten 3+ palabras consecutivas)
  static bool shouldFilterAsEcho(String sttResult) {
    if (_lastTTSText == null || _lastTTSRegisteredAt == null) return false;

    final msSinceRegistered = DateTime.now()
        .difference(_lastTTSRegisteredAt!)
        .inMilliseconds;

    if (msSinceRegistered > _echoFilterWindowMs) {
      // Ventana expirada — limpiar para evitar falsos positivos futuros
      _lastTTSText = null;
      _lastTTSRegisteredAt = null;
      return false;
    }

    final normalizedSTT = _normalizeSpeech(sttResult);
    final normalizedTTS = _lastTTSText!;

    // Criterio 1: El STT está contenido en el TTS o viceversa
    if (normalizedTTS.contains(normalizedSTT) ||
        normalizedSTT.contains(normalizedTTS)) {
      assert(() {
        debugPrint(
          '[UnityBridge] 🔇 Eco TTS filtrado (substring): "$sttResult"',
        );
        return true;
      }());
      return true;
    }

    // Criterio 2: Comparten 3+ palabras consecutivas (subsecuencia de palabras)
    final ttsWords = normalizedTTS.split(' ');
    final sttWords = normalizedSTT.split(' ');

    if (sttWords.length >= 3) {
      for (int i = 0; i <= sttWords.length - 3; i++) {
        final trigram = '${sttWords[i]} ${sttWords[i + 1]} ${sttWords[i + 2]}';
        if (normalizedTTS.contains(trigram)) {
          assert(() {
            debugPrint(
              '[UnityBridge] 🔇 Eco TTS filtrado (trigram "$trigram"): "$sttResult"',
            );
            return true;
          }());
          return true;
        }
      }
    } else if (sttWords.length == 2 && ttsWords.length >= 2) {
      // Para resultados de 2 palabras, verificar si ambas están en el TTS
      final bothInTTS = sttWords.every((w) => normalizedTTS.contains(w));
      if (bothInTTS) {
        assert(() {
          debugPrint(
            '[UnityBridge] 🔇 Eco TTS filtrado (2-gram): "$sttResult"',
          );
          return true;
        }());
        return true;
      }
    }

    return false;
  }

  /// Normaliza texto para comparación: minúsculas, sin acentos, sin puntuación.
  static String _normalizeSpeech(String text) {
    return text
        .toLowerCase()
        .trim()
        // Quitar acentos comunes en español
        .replaceAll('á', 'a')
        .replaceAll('é', 'e')
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o')
        .replaceAll('ú', 'u')
        .replaceAll('ü', 'u')
        .replaceAll('ñ', 'n')
        // Quitar puntuación
        .replaceAll(RegExp(r'[^\w\s]'), '')
        // Normalizar espacios múltiples
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  // ─── Estado ──────────────────────────────────────────────────────────────

  UnityWidgetController? _controller;

  final ValueNotifier<bool> isReadyNotifier = ValueNotifier(false);
  bool get isReady => isReadyNotifier.value;

  static const String _gameObject = 'FlutterBridge';
  static const String _method = 'OnFlutterCommand';

  final StreamController<UnityResponse> _responseStream =
      StreamController<UnityResponse>.broadcast();

  Stream<UnityResponse> get responses => _responseStream.stream;

  final List<WaypointInfo> _cachedWaypoints = [];
  List<WaypointInfo> get cachedWaypoints => List.unmodifiable(_cachedWaypoints);

  // ─── Estado de sesión ─────────────────────────────────────────────────────

  bool sceneReadyHadSession = false;
  int sceneReadyWaypointCount = 0;

  // ─── Handshake scene_ready ────────────────────────────────────────────────

  Completer<void>? _sceneReadyCompleter;
  bool _sceneReady = false;
  bool get isSceneReady => _sceneReady;

  static const Duration _sceneReadyTimeout = Duration(seconds: 15);
  static const Duration _firstPingDelay = Duration(seconds: 5);

  Timer? _pingTimer;

  Future<void> waitForSceneReady() async {
    if (_sceneReady) {
      _log('waitForSceneReady: ya lista — retornando inmediatamente.');
      return;
    }

    _sceneReadyCompleter ??= Completer<void>();

    _pingTimer = Timer(_firstPingDelay, () {
      if (!_sceneReady) {
        _log(
          '⏳ Sin scene_ready en ${_firstPingDelay.inSeconds}s — enviando ping_scene...',
        );
        _send({'action': 'ping_scene'});
      }
    });

    try {
      await _sceneReadyCompleter!.future.timeout(
        _sceneReadyTimeout,
        onTimeout: () {
          _logError(
            'waitForSceneReady: timeout ${_sceneReadyTimeout.inSeconds}s — '
            'avanzando sin confirmación de Unity.',
          );
          _sceneReady = true;
        },
      );
    } finally {
      _pingTimer?.cancel();
      _pingTimer = null;
    }

    _log('waitForSceneReady: escena lista ✅');
  }

  // ─── Estado de segmentación ───────────────────────────────────────────────

  final ValueNotifier<bool> isSegmentationActiveNotifier = ValueNotifier(false);
  bool get isSegmentationActive => isSegmentationActiveNotifier.value;

  // ─── Callbacks ────────────────────────────────────────────────────────────

  Function(UnityResponse)? onResponse;
  Function(List<WaypointInfo>)? onWaypointsReceived;
  Function(bool isStable, String state, String reason)? onTrackingStateChanged;
  Function(UnityResponse)? onTTSRequest;
  Function(VoiceStatusInfo)? onVoiceStatusReceived;
  Function(Uint8List jpegBytes)? onFrameReceived;
  Function(double obstacle, double floor, double wall)?
  onSegmentationRatioReceived;
  Function(bool active)? onSegmentationActiveChanged;

  /// Llamado cuando Unity termina de cargar la sesión.
  /// Recibe los datos reales: waypoints, navmesh.
  Function(SessionLoadedInfo info)? onSessionLoaded;

  // ─── Setup ───────────────────────────────────────────────────────────────

  void setController(UnityWidgetController controller) {
    _controller = controller;
    isReadyNotifier.value = true;
    _log(
      'Controller registrado — isReady=true (escena AR aún puede estar cargando)',
    );
  }

  // ─── ✅ v5.1 — Notificación de TTS para sync de eco ──────────────────────

  /// Notifica al filtro de eco que el TTS comenzó a hablar.
  /// Llamar desde NavigationCoordinator/VoiceNav ANTES de speak().
  ///
  /// También envía el estado TTS a Unity si corresponde.
  void notifyTTSStarted(String text, {bool sendToUnity = true}) {
    registerTTSText(text); // Registrar para filtro de eco
    if (sendToUnity) sendTTSStatus(isSpeaking: true);
  }

  /// Notifica al filtro que el TTS terminó.
  /// Llamar desde NavigationCoordinator/VoiceNav DESPUÉS de que speak() completa.
  void notifyTTSEnded({bool sendToUnity = true}) {
    // Extender la ventana de filtrado hasta que expire sola (_echoFilterWindowMs)
    // No limpiamos _lastTTSText aquí — dejamos que expire naturalmente.
    if (sendToUnity) sendTTSStatus(isSpeaking: false);
  }

  // ─── Procesamiento de mensajes entrantes ──────────────────────────────────

  void handleUnityMessage(dynamic message) {
    final raw = message?.toString() ?? '';
    if (raw.isEmpty) return;

    if (raw.contains('"scene_ready"') || raw.contains('"scene_loading"')) {
      _handleHandshakeMessage(raw);
      return;
    }

    if (raw.contains('"session_loaded"')) {
      _handleSessionLoaded(raw);
      return;
    }

    if (raw.contains('"segmentation_active"')) {
      _handleSegmentationActive(raw);
      return;
    }

    if (raw.contains('"frame_data"')) {
      _handleFrameData(raw);
      return;
    }

    if (raw.contains('"segmentation_ratio"')) {
      _handleSegmentationRatio(raw);
      return;
    }

    if (raw.contains('"session_status"')) {
      _handleSessionStatus(raw);
    }

    _handleNormalMessage(raw);
  }

  // ─── Handlers privados ────────────────────────────────────────────────────

  void _handleHandshakeMessage(String raw) {
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final action = map['action'] as String? ?? '';

      if (action == 'scene_ready') {
        final detail = map['message'] as String? ?? '';
        _log('✅ scene_ready recibido: "$detail"');

        if (!_sceneReady) {
          _sceneReady = true;
          Future.microtask(() {
            _sceneReadyCompleter?.complete();
            _sceneReadyCompleter = null;
          });
        }
        return;
      }

      if (action == 'scene_loading') {
        _log('⏳ scene_loading: Unity aún inicializando — esperando...');
        return;
      }
    } catch (e) {
      _logError('Error procesando handshake: $e');
    }
  }

  void _handleSessionLoaded(String raw) {
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      if (map['action'] != 'session_loaded' || map['ok'] != true) return;

      final info = SessionLoadedInfo.fromMap(map);
      _log('📦 session_loaded: $info');

      sceneReadyHadSession = info.loaded;
      sceneReadyWaypointCount = info.waypointCount;

      onSessionLoaded?.call(info);
    } catch (e) {
      _logError('Error procesando session_loaded: $e');
    }
  }

  void _handleSegmentationActive(String raw) {
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      if (map['action'] != 'segmentation_active') return;
      final active = map['active'] as bool? ?? false;
      isSegmentationActiveNotifier.value = active;
      onSegmentationActiveChanged?.call(active);
      _log('📡 segmentation_active=$active');
    } catch (e) {
      _logError('Error procesando segmentation_active: $e');
    }
  }

  void _handleFrameData(String raw) {
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      if (map['action'] != 'frame_data') return;
      final b64 = map['data'] as String?;
      if (b64 != null && b64.isNotEmpty) {
        onFrameReceived?.call(base64Decode(b64));
      }
    } catch (e) {
      _log('Error decodificando frame_data: $e');
    }
  }

  void _handleSegmentationRatio(String raw) {
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      if (map['action'] != 'segmentation_ratio') return;
      final obstacle = (map['obstacle'] as num?)?.toDouble() ?? 0.0;
      final floor = (map['floor'] as num?)?.toDouble() ?? 0.0;
      final wall = (map['wall'] as num?)?.toDouble() ?? 0.0;
      onSegmentationRatioReceived?.call(obstacle, floor, wall);
    } catch (e) {
      _log('Error decodificando segmentation_ratio: $e');
    }
  }

  void _handleSessionStatus(String raw) {
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      if (map['action'] != 'session_status' || map['ok'] != true) return;

      if (sceneReadyHadSession) {
        _log('ℹ️ session_status ignorado — session_loaded ya procesado.');
        return;
      }

      final wps = UnityResponse.fromJson(raw).waypoints;
      if (wps.isNotEmpty) {
        _cachedWaypoints
          ..clear()
          ..addAll(wps);
        onWaypointsReceived?.call(wps);
        _log('📦 session_status (compat): ${wps.length} waypoints');
      }
    } catch (e) {
      _logError('Error procesando session_status: $e');
    }
  }

  void _handleNormalMessage(String raw) {
    _log('← $raw');
    try {
      final response = UnityResponse.fromJson(raw);

      if (!_responseStream.isClosed) {
        _responseStream.add(response);
      }

      switch (response.action) {
        case 'tracking_state':
          final isStable = response.raw['stable'] as bool? ?? true;
          final state = response.raw['state'] as String? ?? '';
          final reason = response.raw['reason'] as String? ?? '';
          onTrackingStateChanged?.call(isStable, state, reason);
          return;

        case 'tts_request':
          onTTSRequest?.call(response);
          return;

        case 'voice_status':
          onVoiceStatusReceived?.call(VoiceStatusInfo.fromMap(response.raw));
          return;

        case 'list_waypoints':
          if (response.ok) {
            _cachedWaypoints
              ..clear()
              ..addAll(response.waypoints);
            _log('Cache actualizado: ${_cachedWaypoints.length} waypoints');
            onWaypointsReceived?.call(response.waypoints);
          }
          break;
      }

      onResponse?.call(response);

      if (!response.ok) {
        _logError('${response.action}: ${response.message}');
      }
    } catch (e) {
      _log('Mensaje no-JSON: $raw');
    }
  }

  // ─── TTS ─────────────────────────────────────────────────────────────────

  void sendTTSStatus({required bool isSpeaking, int priority = 0}) {
    _send({
      'action': 'tts_status',
      'isSpeaking': isSpeaking,
      'priority': priority,
    });
  }

  // ─── handleIntent ─────────────────────────────────────────────────────────

  void handleIntent(NavigationIntent intent) {
    switch (intent.type) {
      case IntentType.navigate:
        final target = intent.target;
        if (target.startsWith('__unity:')) {
          _handleUnityPrefix(target);
          return;
        }
        if (target.isNotEmpty) navigateTo(target);

      case IntentType.stop:
        stopNavigation();

      case IntentType.describe:
      case IntentType.obstacle:
      case IntentType.help:
      case IntentType.unknown:
        break;
    }
  }

  void _handleUnityPrefix(String target) {
    const prefix = '__unity:';
    final cmd = target.substring(prefix.length);

    if (cmd == 'list_waypoints') {
      listWaypoints();
      return;
    }
    if (cmd == 'save_session') {
      saveSession();
      return;
    }
    if (cmd == 'load_session') {
      loadSession();
      return;
    }
    if (cmd == 'repeat_instruction') {
      repeatInstruction();
      return;
    }
    if (cmd == 'stop_voice') {
      stopVoice();
      return;
    }
    if (cmd == 'voice_status') {
      requestVoiceStatus();
      return;
    }
    if (cmd == 'toggle_seg_mask') {
      toggleSegMask();
      return;
    }
    if (cmd == 'session_status') {
      requestSessionStatus();
      return;
    }

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
      final colonIdx = rest.indexOf(':');
      if (colonIdx >= 0) {
        final priority = int.tryParse(rest.substring(0, colonIdx)) ?? 1;
        final text = rest.substring(colonIdx + 1);
        if (text.isNotEmpty) speakArbitraryText(text, priority: priority);
      }
      return;
    }

    _logError('Prefijo __unity desconocido: $cmd');
  }

  // ─── Comandos de navegación ───────────────────────────────────────────────

  void navigateTo(String waypointName) {
    _send({'action': 'navigate_to', 'name': waypointName});
    _log('→ navigate_to: $waypointName');
  }

  void stopNavigation() {
    _send({'action': 'stop_navigation'});
    _log('→ stop_navigation');
  }

  void requestNavStatus() {
    _send({'action': 'nav_status'});
  }

  // ─── Comandos de waypoints ────────────────────────────────────────────────

  void listWaypoints() {
    _send({'action': 'list_waypoints'});
    _log('→ list_waypoints');
  }

  void createWaypoint(String name) {
    _send({'action': 'create_waypoint', 'name': name});
    _log('→ create_waypoint: $name');
  }

  void removeWaypoint(String name) {
    _send({'action': 'remove_waypoint', 'name': name});
    _log('→ remove_waypoint: $name');
  }

  void clearWaypoints() {
    _send({'action': 'clear_waypoints'});
    _log('→ clear_waypoints');
  }

  // ─── Comandos de sesión ───────────────────────────────────────────────────

  void saveSession() {
    _send({'action': 'save_session'});
    _log('→ save_session');
  }

  void loadSession() {
    _send({'action': 'load_session'});
    _log('→ load_session');
  }

  void requestSessionStatus() {
    _send({'action': 'session_status'});
    _log('→ session_status');
  }

  // ─── Comandos de guía de voz ──────────────────────────────────────────────

  void repeatInstruction() {
    _send({'action': 'repeat_instruction'});
    _log('→ repeat_instruction');
  }

  void stopVoice() {
    _send({'action': 'stop_voice'});
    _log('→ stop_voice');
  }

  void requestVoiceStatus() {
    _send({'action': 'voice_status'});
    _log('→ voice_status');
  }

  void speakArbitraryText(
    String text, {
    int priority = 1,
    bool interrupt = false,
  }) {
    if (text.trim().isEmpty) return;
    _send({
      'action': 'tts_speak',
      'text': text,
      'priority': priority.clamp(0, 2),
      'interrupt': interrupt,
    });
    _log('→ tts_speak (p=$priority): "$text"');
  }

  // ─── Máscara de segmentación ──────────────────────────────────────────────

  void toggleSegMask() {
    _send({'action': 'toggle_seg_mask'});
    _log('→ toggle_seg_mask');
  }

  // ─── Privado ──────────────────────────────────────────────────────────────

  void _send(Map<String, dynamic> command) {
    if (!isReady) {
      _logError('No listo — comando ignorado: ${command['action']}');
      return;
    }
    try {
      _controller!.postMessage(_gameObject, _method, jsonEncode(command));
    } catch (e) {
      _logError('Error enviando: $e');
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
    isReadyNotifier.dispose();
    isSegmentationActiveNotifier.dispose();
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
    // Limpiar estado estático del filtro eco
    _lastTTSText = null;
    _lastTTSRegisteredAt = null;
  }
}
