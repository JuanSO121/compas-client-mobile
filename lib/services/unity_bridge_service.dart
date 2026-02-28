// lib/services/unity_bridge_service.dart
// ✅ v2 — Sincronizado con FlutterUnityBridge.cs + VoiceCommandAPI.cs
//
//  ACCIONES QUE ENTIENDE Unity (FlutterUnityBridge.cs switch):
//    navigate_to       → VoiceCommandAPI.NavigateTo(name)
//    stop_navigation   → VoiceCommandAPI.StopNavigation()
//    nav_status        → VoiceCommandAPI.GetNavigationStatus()
//    list_waypoints    → VoiceCommandAPI.ListWaypoints()
//    create_waypoint   → VoiceCommandAPI.CreateWaypointAtAgent(name)
//    remove_waypoint   → VoiceCommandAPI.RemoveWaypoint(name)
//    clear_waypoints   → VoiceCommandAPI.ClearWaypoints()
//    save_session      → VoiceCommandAPI.SaveSession()
//    load_session      → VoiceCommandAPI.LoadSession()
//
//  RESPUESTAS QUE ENVÍA Unity (canal OnUnityResponse):
//    { "action": "...", "ok": true|false, "message": "...", ...extras }
//    list_waypoints incluye además: "count": N, "waypoints": [...]

import 'dart:async';
import 'dart:convert';
import 'package:flutter_unity_widget/flutter_unity_widget.dart';
import 'package:logger/logger.dart';
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

  /// Lista de waypoints (solo cuando action == 'list_waypoints')
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
    id:       j['id']       as String? ?? '',
    name:     j['name']     as String? ?? '',
    type:     j['type']     as String? ?? '',
    navigable: j['navigable'] as bool? ?? false,
    x: (j['pos']?['x'] as num?)?.toDouble() ?? 0,
    y: (j['pos']?['y'] as num?)?.toDouble() ?? 0,
    z: (j['pos']?['z'] as num?)?.toDouble() ?? 0,
  );

  @override
  String toString() => 'WaypointInfo($name, navigable=$navigable)';
}

// ─── Servicio principal ────────────────────────────────────────────────────

class UnityBridgeService {
  static final UnityBridgeService _instance = UnityBridgeService._internal();
  factory UnityBridgeService() => _instance;
  UnityBridgeService._internal();

  final Logger _logger = Logger();

  UnityWidgetController? _controller;
  bool _isReady = false;

  // GameObject y método en Unity (deben coincidir exactamente)
  static const String _gameObject = 'FlutterBridge';
  static const String _method     = 'OnFlutterCommand';

  // Stream de respuestas de Unity → suscriptores externos
  final StreamController<UnityResponse> _responseStream =
  StreamController<UnityResponse>.broadcast();

  Stream<UnityResponse> get responses => _responseStream.stream;

  // ─── Callbacks de alto nivel ─────────────────────────────────────────────

  /// Llamado cuando Unity confirma llegada a un waypoint o cambio de estado
  Function(UnityResponse)? onResponse;

  /// Llamado específicamente cuando llega la lista de waypoints
  Function(List<WaypointInfo>)? onWaypointsReceived;

  // ─── Setup ───────────────────────────────────────────────────────────────

  void setController(UnityWidgetController controller) {
    _controller = controller;
    _isReady = true;
    _logger.i('✅ [UnityBridge] Controller registrado');
  }

  /// Llamar desde ArNavigationScreen.onUnityMessage
  void handleUnityMessage(dynamic message) {
    final raw = message?.toString() ?? '';
    if (raw.isEmpty) return;

    _logger.d('[Unity→Flutter] $raw');

    try {
      final response = UnityResponse.fromJson(raw);

      // Notificar stream
      if (!_responseStream.isClosed) _responseStream.add(response);

      // Callbacks específicos
      onResponse?.call(response);

      if (response.action == 'list_waypoints' && response.ok) {
        onWaypointsReceived?.call(response.waypoints);
      }

      if (!response.ok) {
        _logger.w('[Unity→Flutter] ❌ ${response.action}: ${response.message}');
      }

    } catch (e) {
      // Unity puede enviar mensajes no-JSON (logs, eventos internos) — ignorar
      _logger.d('[Unity→Flutter] Mensaje no-JSON: $raw');
    }
  }

  bool get isReady => _isReady && _controller != null;

  // ─── handleIntent — punto de entrada desde NavigationCoordinator ─────────

  /// Traduce un NavigationIntent al comando Unity correspondiente.
  /// Cubrir todos los IntentType que puedan venir del coordinador.
  void handleIntent(NavigationIntent intent) {
    switch (intent.type) {
      case IntentType.navigate:
        if (intent.target.isNotEmpty) {
          navigateTo(intent.target);
        } else {
          _logger.w('[UnityBridge] navigate_to sin target — ignorado');
        }

      case IntentType.stop:
        stopNavigation();

    // Estos tipos no requieren acción directa en Unity AR
      case IntentType.describe:
      case IntentType.obstacle:
      case IntentType.help:
      case IntentType.unknown:
        _logger.d('[UnityBridge] Intent ${intent.type} no requiere acción Unity');
    }
  }

  // ─── Comandos de navegación ───────────────────────────────────────────────

  /// Navega al waypoint por nombre.
  void navigateTo(String waypointName) {
    _send({'action': 'navigate_to', 'name': waypointName});
    _logger.i('[UnityBridge] → navigate_to: $waypointName');
  }

  /// Detiene la navegación activa.
  void stopNavigation() {
    _send({'action': 'stop_navigation'});
    _logger.i('[UnityBridge] → stop_navigation');
  }

  /// Solicita el estado actual de navegación.
  /// La respuesta llega vía onResponse con action == 'nav_status'.
  void requestNavStatus() {
    _send({'action': 'nav_status'});
    _logger.d('[UnityBridge] → nav_status');
  }

  // ─── Comandos de waypoints ────────────────────────────────────────────────

  /// Solicita la lista completa de waypoints a Unity.
  /// La respuesta llega vía onWaypointsReceived.
  void listWaypoints() {
    _send({'action': 'list_waypoints'});
    _logger.i('[UnityBridge] → list_waypoints');
  }

  /// Crea un waypoint en la posición actual del agente con el nombre dado.
  void createWaypoint(String name) {
    _send({'action': 'create_waypoint', 'name': name});
    _logger.i('[UnityBridge] → create_waypoint: $name');
  }

  /// Elimina el waypoint con ese nombre exacto.
  void removeWaypoint(String name) {
    _send({'action': 'remove_waypoint', 'name': name});
    _logger.i('[UnityBridge] → remove_waypoint: $name');
  }

  /// Elimina todos los waypoints.
  void clearWaypoints() {
    _send({'action': 'clear_waypoints'});
    _logger.i('[UnityBridge] → clear_waypoints');
  }

  // ─── Comandos de sesión ───────────────────────────────────────────────────

  void saveSession() {
    _send({'action': 'save_session'});
    _logger.i('[UnityBridge] → save_session');
  }

  void loadSession() {
    _send({'action': 'load_session'});
    _logger.i('[UnityBridge] → load_session');
  }

  // ─── Privado ──────────────────────────────────────────────────────────────

  void _send(Map<String, dynamic> command) {
    if (!isReady) {
      _logger.w('[UnityBridge] No listo — comando ignorado: ${command['action']}');
      return;
    }
    try {
      _controller!.postMessage(_gameObject, _method, jsonEncode(command));
    } catch (e) {
      _logger.e('[UnityBridge] Error enviando: $e');
    }
  }

  void dispose() {
    _responseStream.close();
    _controller = null;
    _isReady = false;
  }
}