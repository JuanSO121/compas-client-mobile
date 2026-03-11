// lib/services/AI/waypoint_context_service.dart
// ✅ v1.0 — Puente Unity ↔ ConversationService
//
//  PROBLEMA QUE RESUELVE:
//  ─────────────────────────────────────────────────────────────────────────
//  Groq no sabe qué waypoints existen en Unity. Cuando el usuario dice
//  "guíame a la habitación", Groq responde "no sé a qué habitación te
//  refieres" — aunque el intent SÍ llega a Unity (porque _extractAction
//  lo detecta del texto del usuario). El resultado es incohererente:
//  el NPC empieza a navegar PERO el TTS dice que no sabe el destino.
//
//  SOLUCIÓN:
//  1. WaypointContextService mantiene en memoria la lista de waypoints
//     que Unity reporta via OnUnityResponse (list_waypoints).
//  2. ConversationService llama a getContextForPrompt() antes de cada
//     llamada a Groq, inyectando los waypoints en el system prompt.
//  3. Groq ahora puede:
//     a) Confirmar el nombre exacto del waypoint
//     b) Desambiguar si hay varios ("¿te refieres a Habitación 1 o 2?")
//     c) Avisar si el destino no existe ("No tengo baliza 'cocina'")
//
//  FLUJO COMPLETO:
//    Inicio → _screen.initState() llama listWaypoints() desde Unity
//    Unity → list_waypoints response → UnityBridgeService.onWaypointsReceived
//    → WaypointContextService.updateFromUnity(waypoints)
//    → Cache local actualizada
//
//    Usuario: "guíame a la habitación"
//    ConversationService._buildSystemPrompt()
//    → incluye: "DESTINOS DISPONIBLES:\n- Habitación 1\n- Habitación 2"
//    Groq: "Hay dos habitaciones: Habitación 1 y Habitación 2. ¿A cuál?"
//    Usuario: "la primera"
//    Groq: "Navegando a Habitación 1."  ← extracción limpia ✅
//
//  INTEGRACIÓN (ver ar_navigation_screen.dart + conversation_service.dart):
//    1. En _initializeServices():
//         _unityBridge.onWaypointsReceived = (waypoints) {
//           _waypointContext.updateFromUnity(waypoints);
//         };
//    2. En ConversationService._buildSystemPrompt():
//         final ctx = WaypointContextService().getContextForPrompt();
//         // Insertar ctx en el prompt
//    3. Solicitar lista al inicio y cada vez que cambie:
//         _unityBridge.listWaypoints(); // en _initializeServices()

import 'dart:async';
import 'package:logger/logger.dart';
import '../unity_bridge_service.dart'; // WaypointInfo

// ─── Modelo de waypoint simplificado ────────────────────────────────────────

class WaypointEntry {
  final String id;
  final String name;
  final String type;
  final bool navigable;

  const WaypointEntry({
    required this.id,
    required this.name,
    required this.type,
    required this.navigable,
  });

  factory WaypointEntry.fromUnity(WaypointInfo info) => WaypointEntry(
    id:        info.id,
    name:      info.name,
    type:      info.type,
    navigable: info.navigable,
  );

  @override
  String toString() => name;
}

// ─── Servicio ────────────────────────────────────────────────────────────────

class WaypointContextService {
  static final WaypointContextService _instance =
  WaypointContextService._internal();
  factory WaypointContextService() => _instance;
  WaypointContextService._internal();

  final Logger _logger = Logger();

  List<WaypointEntry> _waypoints        = [];
  DateTime?           _lastUpdate;
  bool                _hasEverReceived  = false;

  // Notificador para que la UI o servicios sepan que cambió la lista
  final StreamController<List<WaypointEntry>> _changeController =
  StreamController<List<WaypointEntry>>.broadcast();

  Stream<List<WaypointEntry>> get onWaypointsChanged => _changeController.stream;

  // ─── Actualización desde Unity ──────────────────────────────────────────

  /// Llamar desde UnityBridgeService.onWaypointsReceived
  void updateFromUnity(List<WaypointInfo> unityWaypoints) {
    _waypoints = unityWaypoints
        .map(WaypointEntry.fromUnity)
        .where((w) => w.name.isNotEmpty)
        .toList();

    _lastUpdate          = DateTime.now();
    _hasEverReceived     = true;

    _logger.i('[WaypointCtx] ✅ ${_waypoints.length} waypoint(s) actualizados: '
        '${_waypoints.map((w) => w.name).join(', ')}');

    if (!_changeController.isClosed) {
      _changeController.add(List.unmodifiable(_waypoints));
    }
  }

  /// Actualización manual (para testing o modo offline)
  void updateManual(List<String> names) {
    _waypoints = names
        .where((n) => n.isNotEmpty)
        .map((n) => WaypointEntry(id: n, name: n, type: 'manual', navigable: true))
        .toList();
    _lastUpdate      = DateTime.now();
    _hasEverReceived = true;
    _logger.i('[WaypointCtx] 📝 Manual: ${_waypoints.length} waypoints');
  }

  // ─── Contexto para Groq ──────────────────────────────────────────────────

  /// Bloque de texto para insertar en el system prompt de Groq.
  ///
  /// Si no hay waypoints conocidos, devuelve instrucción para preguntar.
  /// Si hay waypoints, los lista con los navegables marcados.
  String getContextForPrompt() {
    if (!_hasEverReceived || _waypoints.isEmpty) {
      return '''
══════════════════════════════════════════════════════════════════
BALIZAS DISPONIBLES: (aún no recibidas de Unity)

No tienes información sobre los destinos disponibles todavía.
Si el usuario pide navegar a algún sitio, PRIMERO pregunta:
"¿A qué baliza quieres ir? Aún no tengo la lista cargada."
NO confirmes navegación sin conocer el destino exacto.
══════════════════════════════════════════════════════════════════''';
    }

    final navigable = _waypoints.where((w) => w.navigable).toList();
    final nonNavigable = _waypoints.where((w) => !w.navigable).toList();

    final buf = StringBuffer();
    buf.writeln('══════════════════════════════════════════════════════════════════');
    buf.writeln('BALIZAS DISPONIBLES EN EL EDIFICIO (${navigable.length} navegables):');
    buf.writeln();

    if (navigable.isEmpty) {
      buf.writeln('  (No hay balizas navegables actualmente)');
    } else {
      for (final w in navigable) {
        buf.writeln('  • ${w.name}');
      }
    }

    if (nonNavigable.isNotEmpty) {
      buf.writeln();
      buf.writeln('  No navegables (referencia): ${nonNavigable.map((w) => w.name).join(', ')}');
    }

    buf.writeln();
    buf.writeln('REGLAS DE USO DE LA LISTA:');
    buf.writeln('• Cuando el usuario pida navegar, VERIFICA que el destino existe en la lista.');
    buf.writeln('• Si el destino existe con ese nombre exacto → confirma: "Navegando a [Nombre]."');
    buf.writeln('• Si el destino existe con nombre similar → usa el nombre EXACTO de la lista.');
    buf.writeln('  Ejemplo: usuario dice "habitación" → lista tiene "Habitación 1" → di "Navegando a Habitación 1."');
    buf.writeln('• Si hay VARIOS destinos similares → pregunta cuál antes de navegar.');
    buf.writeln('  Ejemplo: "Hay dos habitaciones: Habitación 1 y Habitación 2. ¿A cuál vas?"');
    buf.writeln('• Si el destino NO existe en la lista → avisa y sugiere alternativas.');
    buf.writeln('  Ejemplo: "No tengo una baliza llamada cocina. Los destinos disponibles son: [lista]"');
    buf.writeln('• NUNCA digas que no sabes los destinos si la lista no está vacía.');
    buf.writeln('══════════════════════════════════════════════════════════════════');

    return buf.toString();
  }

  /// Busca waypoints cuyo nombre coincida (fuzzy) con el texto dado.
  /// Útil para validar el target antes de enviarlo a Unity.
  List<WaypointEntry> findMatches(String query) {
    if (query.isEmpty || _waypoints.isEmpty) return [];

    final q = query.toLowerCase().trim();

    // 1. Coincidencia exacta (case-insensitive)
    final exact = _waypoints
        .where((w) => w.name.toLowerCase() == q)
        .toList();
    if (exact.isNotEmpty) return exact;

    // 2. El nombre contiene el query
    final contains = _waypoints
        .where((w) => w.name.toLowerCase().contains(q))
        .toList();
    if (contains.isNotEmpty) return contains;

    // 3. El query contiene el nombre (el usuario usó el nombre completo)
    final reverse = _waypoints
        .where((w) => q.contains(w.name.toLowerCase()))
        .toList();
    if (reverse.isNotEmpty) return reverse;

    // 4. Palabras en común
    final queryWords = q.split(' ').where((w) => w.length > 2).toSet();
    final wordMatch = _waypoints.where((wp) {
      final wpWords = wp.name.toLowerCase().split(' ').toSet();
      return queryWords.intersection(wpWords).isNotEmpty;
    }).toList();

    return wordMatch;
  }

  /// Resuelve un destino ambiguo al nombre exacto del waypoint más probable.
  /// Devuelve null si no hay coincidencia confiable.
  String? resolveTarget(String query) {
    final matches = findMatches(query);
    if (matches.isEmpty) return null;
    if (matches.length == 1) return matches.first.name;

    // Múltiples matches: devolver el más corto (más específico) o el exacto
    final exact = matches.firstWhere(
          (w) => w.name.toLowerCase() == query.toLowerCase(),
      orElse: () => matches.first,
    );
    return exact.name;
  }

  // ─── Getters ────────────────────────────────────────────────────────────

  List<WaypointEntry> get waypoints         => List.unmodifiable(_waypoints);
  List<WaypointEntry> get navigableWaypoints =>
      _waypoints.where((w) => w.navigable).toList();
  bool get hasWaypoints    => _waypoints.isNotEmpty;
  bool get hasEverReceived => _hasEverReceived;
  int  get count           => _waypoints.length;
  DateTime? get lastUpdate => _lastUpdate;

  void clear() {
    _waypoints = [];
    _logger.d('[WaypointCtx] Lista limpiada');
  }

  void dispose() {
    _changeController.close();
  }
}