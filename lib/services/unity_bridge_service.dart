// lib/services/unity_bridge_service.dart
// ✅ v3.4 — cachedWaypoints + logs limpios
//
// ============================================================================
//  CAMBIOS v3.3 → v3.4
// ============================================================================
//
//  1. _cachedWaypoints — lista interna que se actualiza cada vez que Unity
//     responde list_waypoints. Expuesta como cachedWaypoints (read-only).
//     NavigationCoordinator la usa para fuzzy matching antes de navegar,
//     evitando enviar nombres crudos del usuario directamente a Unity.
//
//  2. Logger reemplazado por wrapper de dos niveles:
//       _log()      → solo en debug builds (assert — eliminado en release)
//       _logError() → siempre (errores críticos reales)
//
//  TODO LO DEMÁS ES IDÉNTICO A v3.3.

import 'dart:async';
import 'dart:convert';
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
      action:  map['action']  as String? ?? '',
      ok:      map['ok']      as bool?   ?? false,
      message: map['message'] as String? ?? '',
      raw:     map,
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
    isGuiding:       map['isGuiding']       as bool?   ?? false,
    isPreprocessing: map['isPreprocessing'] as bool?   ?? false,
    ttsBusy:         map['ttsBusy']         as bool?   ?? false,
    destination:     map['destination']     as String? ?? '',
    remainingSteps:  map['remainingSteps']  as int?    ?? 0,
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
    id:        j['id']        as String? ?? '',
    name:      j['name']      as String? ?? '',
    type:      j['type']      as String? ?? '',
    navigable: j['navigable'] as bool?   ?? false,
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

  // ─── Logging ────────────────────────────────────────────────────────────
  static void _log(String msg) {
    assert(() {
      debugPrint('[UnityBridge] $msg');
      return true;
    }());
  }

  static void _logError(String msg) => debugPrint('[UnityBridge] ❌ $msg');

  // ─── Estado ─────────────────────────────────────────────────────────────

  UnityWidgetController? _controller;

  final ValueNotifier<bool> isReadyNotifier = ValueNotifier(false);
  bool get isReady => isReadyNotifier.value;

  static const String _gameObject = 'FlutterBridge';
  static const String _method     = 'OnFlutterCommand';

  final StreamController<UnityResponse> _responseStream =
      StreamController<UnityResponse>.broadcast();

  Stream<UnityResponse> get responses => _responseStream.stream;

  // ✅ v3.4 — Cache de waypoints actualizado en cada list_waypoints.
  // NavigationCoordinator lo lee para fuzzy matching sin necesidad de
  // solicitar la lista en cada navegación.
  final List<WaypointInfo> _cachedWaypoints = [];
  List<WaypointInfo> get cachedWaypoints => List.unmodifiable(_cachedWaypoints);

  // ─── Callbacks de alto nivel ─────────────────────────────────────────────

  Function(UnityResponse)?                              onResponse;
  Function(List<WaypointInfo>)?                         onWaypointsReceived;
  Function(bool isStable, String state, String reason)? onTrackingStateChanged;
  Function(UnityResponse)?                              onTTSRequest;
  Function(VoiceStatusInfo)?                            onVoiceStatusReceived;

  // ─── Setup ──────────────────────────────────────────────────────────────

  void setController(UnityWidgetController controller) {
    _controller = controller;
    isReadyNotifier.value = true;
    _log('Controller registrado — isReady=true');
  }

  void handleUnityMessage(dynamic message) {
    final raw = message?.toString() ?? '';
    if (raw.isEmpty) return;

    _log('← $raw');

    try {
      final response = UnityResponse.fromJson(raw);

      if (!_responseStream.isClosed) _responseStream.add(response);

      // tracking_state — callback propio, return temprano
      if (response.action == 'tracking_state') {
        final isStable = response.raw['stable'] as bool?   ?? true;
        final state    = response.raw['state']  as String? ?? '';
        final reason   = response.raw['reason'] as String? ?? '';
        onTrackingStateChanged?.call(isStable, state, reason);
        return;
      }

      // tts_request — callback propio, return temprano
      if (response.action == 'tts_request') {
        onTTSRequest?.call(response);
        return;
      }

      // voice_status — callback propio, return temprano
      if (response.action == 'voice_status') {
        final info = VoiceStatusInfo.fromMap(response.raw);
        onVoiceStatusReceived?.call(info);
        return;
      }

      // Callbacks generales
      onResponse?.call(response);

      if (response.action == 'list_waypoints' && response.ok) {
        // ✅ v3.4: actualizar cache interno
        _cachedWaypoints
          ..clear()
          ..addAll(response.waypoints);
        _log('Cache actualizado: ${_cachedWaypoints.length} waypoints');
        onWaypointsReceived?.call(response.waypoints);
      }

      if (!response.ok) {
        _logError('${response.action}: ${response.message}');
      }

    } catch (e) {
      _log('Mensaje no-JSON: $raw');
    }
  }

  // ─── handleIntent ────────────────────────────────────────────────────────

  void handleIntent(NavigationIntent intent) {
    switch (intent.type) {
      case IntentType.navigate:
        final target = intent.target;
        if (target.startsWith('__unity:')) {
          _handleUnityPrefix(target);
          return;
        }
        if (target.isNotEmpty) {
          navigateTo(target);
        }

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

    if (cmd == 'list_waypoints')     { listWaypoints();      return; }
    if (cmd == 'save_session')       { saveSession();        return; }
    if (cmd == 'load_session')       { loadSession();        return; }
    if (cmd == 'repeat_instruction') { repeatInstruction();  return; }
    if (cmd == 'stop_voice')         { stopVoice();          return; }
    if (cmd == 'voice_status')       { requestVoiceStatus(); return; }

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
      final rest     = cmd.substring('tts_speak:'.length);
      final colonIdx = rest.indexOf(':');
      if (colonIdx >= 0) {
        final priority = int.tryParse(rest.substring(0, colonIdx)) ?? 1;
        final text     = rest.substring(colonIdx + 1);
        if (text.isNotEmpty) speakArbitraryText(text, priority: priority);
      }
      return;
    }

    _logError('Prefijo __unity desconocido: $cmd');
  }

  // ─── Comandos de navegación ──────────────────────────────────────────────

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

  // ─── Comandos de waypoints ───────────────────────────────────────────────

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

  // ─── Comandos de sesión ──────────────────────────────────────────────────

  void saveSession() {
    _send({'action': 'save_session'});
    _log('→ save_session');
  }

  void loadSession() {
    _send({'action': 'load_session'});
    _log('→ load_session');
  }

  // ─── Comandos de guía de voz ─────────────────────────────────────────────

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
    int  priority  = 1,
    bool interrupt = false,
  }) {
    if (text.trim().isEmpty) return;
    _send({
      'action':    'tts_speak',
      'text':      text,
      'priority':  priority.clamp(0, 2),
      'interrupt': interrupt,
    });
    _log('→ tts_speak (p=$priority): "$text"');
  }

  // ─── Privado ─────────────────────────────────────────────────────────────

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

  void dispose() {
    _responseStream.close();
    _cachedWaypoints.clear();
    isReadyNotifier.dispose();
    _controller           = null;
    onTTSRequest          = null;
    onVoiceStatusReceived = null;
  }
}