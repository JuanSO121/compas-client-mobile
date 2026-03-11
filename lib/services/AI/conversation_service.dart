// lib/services/AI/conversation_service.dart
// ✅ v4 — Groq ahora conoce los waypoints reales de Unity
//
//  CAMBIOS v3 → v4:
//  ─────────────────────────────────────────────────────────────────────────
//  PROBLEMA CORREGIDO:
//    Usuario: "guíame a la habitación"
//    Groq respondía: "No sé a qué habitación te refieres" ← INCORRECTO
//    Pero el intent SÍ llegaba a Unity porque _extractAction lo detectaba
//    del texto del usuario → NPC navegaba pero el TTS decía que no sabía.
//
//  CAUSA RAÍZ:
//    El system prompt de Groq no incluía la lista de waypoints existentes.
//    Groq no podía confirmar, desambiguar ni rechazar destinos.
//
//  FIX v4:
//  1. WaypointContextService inyecta la lista real de waypoints en el prompt.
//     Groq ahora ve: "BALIZAS DISPONIBLES: Habitación 1, Habitación 2, Baño"
//     y puede responder correctamente:
//     → "Navegando a Habitación 1." (si hay una sola habitación)
//     → "Hay dos habitaciones: 1 y 2. ¿A cuál?" (si hay ambigüedad)
//     → "No tengo baliza 'cocina'. Destinos disponibles: [lista]" (si no existe)
//
//  2. _resolveTarget() resuelve el target extraído contra la lista real ANTES
//     de enviarlo a Unity — garantiza que Unity recibe el nombre exacto.
//     Ejemplo: usuario dice "habitación" → extracción da "habitación" →
//     resolveTarget("habitación") devuelve "Habitación 1" (de la lista real).
//
//  3. Si WaypointContextService no tiene datos aún (primer arranque),
//     el prompt instruye a Groq a pedir lista antes de navegar.
//
//  INTEGRACIÓN REQUERIDA en ar_navigation_screen.dart v7:
//    // En _setupUnityBridgeCallbacks():
//    _unityBridge.onWaypointsReceived = (waypoints) {
//      WaypointContextService().updateFromUnity(waypoints);  // ← AÑADIR
//      // ... resto del callback
//    };
//    // En _initializeServices(), al final:
//    if (_unityBridge.isReady) _unityBridge.listWaypoints();  // ← AÑADIR
//
//  TODO LO DEMÁS ES IDÉNTICO A v3.

import 'dart:async';
import 'package:logger/logger.dart';

import '../../models/shared_models.dart';
import 'groq_service.dart';
import 'ai_mode_controller.dart';
import 'waypoint_context_service.dart'; // ✅ v4

// ─── Tipos de respuesta ───────────────────────────────────────────────────────

enum ResponseType {
  pureConversation,
  conversationWithIntent,
  offlineCommand,
}

class ChatbotResponse {
  final ResponseType type;
  final String message;
  final NavigationIntent? intent;
  final double confidence;

  ChatbotResponse({
    required this.type,
    required this.message,
    this.intent,
    this.confidence = 1.0,
  });

  bool get shouldNavigate => intent != null;
}

enum _UnityAction { navigate, stop, list, create, remove, save, load, none }

// ─── Servicio principal ───────────────────────────────────────────────────────

class ConversationService {
  static final ConversationService _instance = ConversationService._internal();
  factory ConversationService() => _instance;
  ConversationService._internal();

  final Logger                _logger           = Logger();
  final GroqService           _groqService      = GroqService();
  final AIModeController      _aiModeController = AIModeController();
  // ✅ v4: contexto de waypoints reales
  final WaypointContextService _waypointContext = WaypointContextService();

  final List<ChatMessage> _conversationHistory = [];
  static const int _maxHistory = 20;
  bool _isInitialized = false;

  // ─── Inicialización ──────────────────────────────────────────────────────

  Future<void> initialize() async {
    if (_isInitialized) return;
    try {
      await _aiModeController.initialize();
      if (_aiModeController.canUseGroq()) {
        await _groqService.initialize();
        _logger.i('✅ ConversationService online (Groq)');
      } else {
        _logger.i('✅ ConversationService offline');
      }
      _isInitialized = true;
    } catch (e) {
      _logger.e('Error inicializando ConversationService: $e');
      rethrow;
    }
  }

  // ─── API pública ─────────────────────────────────────────────────────────

  Future<ChatbotResponse> chat(String userMessage) async {
    if (!_isInitialized) throw StateError('ConversationService no inicializado');

    _addToHistory('user', userMessage);

    await _aiModeController.verifyInternetNow();

    if (_aiModeController.canUseGroq()) {
      return await _chatWithGroq(userMessage);
    } else {
      return await _chatOffline(userMessage);
    }
  }

  // ─── Modo online (Groq) ──────────────────────────────────────────────────

  Future<ChatbotResponse> _chatWithGroq(String userMessage) async {
    try {
      final response = await _groqService.chat(
        userMessage,
        history: _conversationHistory.length > 1
            ? _conversationHistory.sublist(0, _conversationHistory.length - 1)
            : [],
        maxTokens: 350,
        systemPrompt: _buildSystemPrompt(), // ✅ v4: incluye waypoints
      );

      _addToHistory('assistant', response.content);

      final (action, rawTarget) = _extractAction(response.content, userMessage);

      if (action != _UnityAction.none) {
        // ✅ v4: Resolver el target contra la lista real de waypoints
        final resolvedTarget = action == _UnityAction.navigate
            ? _resolveTarget(rawTarget)
            : rawTarget;

        final intent = _buildIntent(action, resolvedTarget);
        if (intent != null) {
          _logger.i('💬🎯 Intent: $action → raw="$rawTarget" → resolved="$resolvedTarget"');
          return ChatbotResponse(
            type:       ResponseType.conversationWithIntent,
            message:    response.content,
            intent:     intent,
            confidence: 0.95,
          );
        }
      }

      return ChatbotResponse(
        type:       ResponseType.pureConversation,
        message:    response.content,
        confidence: 0.95,
      );

    } catch (e) {
      _logger.e('Error Groq: $e');
      return await _chatOffline(userMessage);
    }
  }

  // ─── Resolución de target ────────────────────────────────────────────────
  //
  // ✅ v4: Resuelve el nombre extraído al nombre exacto de la lista Unity.
  //
  // Ejemplos:
  //   "habitación"  → "Habitación 1"  (si es el único match)
  //   "Habitación 1" → "Habitación 1" (match exacto, sin cambio)
  //   "baño"        → "Baño"          (normaliza capitalización)
  //   "cocina"      → "cocina"        (no hay match → se manda tal cual,
  //                                    Unity responderá que no existe)

  String _resolveTarget(String rawTarget) {
    if (rawTarget.isEmpty) return rawTarget;

    // Si no tenemos contexto de waypoints, devolver tal cual
    if (!_waypointContext.hasWaypoints) {
      _logger.d('[Resolve] Sin contexto de waypoints, usando raw: "$rawTarget"');
      return rawTarget;
    }

    final resolved = _waypointContext.resolveTarget(rawTarget);
    if (resolved != null && resolved != rawTarget) {
      _logger.i('[Resolve] "$rawTarget" → "$resolved" (de lista Unity)');
      return resolved;
    }

    // Sin match claro: devolver raw capitalizado
    if (rawTarget.isNotEmpty) {
      final capitalized = rawTarget[0].toUpperCase() + rawTarget.substring(1);
      if (capitalized != rawTarget) {
        _logger.d('[Resolve] Capitalizado: "$rawTarget" → "$capitalized"');
        return capitalized;
      }
    }

    return rawTarget;
  }

  // ─── System prompt ───────────────────────────────────────────────────────
  //
  // ✅ v4: Ahora incluye la lista real de waypoints de Unity.
  //        WaypointContextService.getContextForPrompt() genera el bloque
  //        dinámicamente con las balizas actuales.

  String _buildSystemPrompt() {
    // ✅ v4: Inyectar contexto de waypoints reales
    final waypointContext = _waypointContext.getContextForPrompt();

    return '''Eres COMPAS, asistente de navegación indoor amigable y conversacional.

PERSONALIDAD:
- Hablas español natural, cálido y cercano
- Eres útil, paciente y empático
- Tienes humor sutil
- Respuestas cortas: 1-3 oraciones normalmente

CAPACIDADES DE NAVEGACIÓN INDOOR:
Ayudas al usuario a moverse dentro de un edificio usando balizas (waypoints).
Puedes: navegar a un destino, detener la navegación, listar destinos disponibles,
crear/eliminar balizas, guardar y cargar sesiones.

$waypointContext

══════════════════════════════════════════════════════════════════
REGLA CRÍTICA — CONFIRMACIÓN DE NAVEGACIÓN:

Cuando el usuario pida ir a un destino:
1. Verifica si existe en la lista de BALIZAS DISPONIBLES (arriba).
2. Si existe con ese nombre o uno similar → confirma usando el nombre EXACTO de la lista.
3. Si hay varios destinos similares → pregunta cuál antes de navegar.
4. Si NO existe → avisa y sugiere los disponibles.
5. NUNCA digas "no sé a qué destino te refieres" si la lista no está vacía —
   en su lugar, mapea la descripción al destino más probable o pregunta.

Tu confirmación DEBE usar el nombre EXACTO de la lista, sin parafrasear.

✅ CORRECTO:
  Lista tiene: "Habitación 1", "Baño", "Sala Principal"
  Usuario: "llévame a la habitación"
  Tú: "Navegando a Habitación 1."

  Usuario: "quiero ir al baño"
  Tú: "Navegando a Baño."

  Usuario: "habitaciones" (hay Habitación 1 y Habitación 2)
  Tú: "Hay dos habitaciones: Habitación 1 y Habitación 2. ¿A cuál quieres ir?"

  Usuario: "llévame a la cocina" (no existe en la lista)
  Tú: "No tengo una baliza llamada cocina. Los destinos disponibles son: Habitación 1, Baño, Sala Principal."

❌ INCORRECTO — NUNCA hagas esto:
  "No sé a qué habitación te refieres."  ← si solo hay una, ve ahí
  "Iniciando navegación a la baliza que acabas de crear."  ← parafraseo
  "Voy hacia el destino que mencionaste."  ← sin nombre concreto

══════════════════════════════════════════════════════════════════

PATRONES DE CONFIRMACIÓN (usa estos exactos):

• Navegar:  "Navegando a [NombreExacto]."
• Detener:  "Deteniendo la navegación."
• Listar:   "Consultando los destinos disponibles."
• Crear:    "Creando una baliza llamada [Nombre]."
• Eliminar: "Eliminando la baliza [Nombre]."
• Guardar:  "Guardando la sesión."
• Cargar:   "Cargando la sesión."

EJEMPLOS COMPLETOS:

• Usuario: "llévame al baño"
  Tú: "¡Claro! Navegando a Baño."

• Usuario: "para la navegación"
  Tú: "Entendido. Deteniendo la navegación."

• Usuario: "¿qué balizas hay?" / "¿qué destinos hay?"
  Tú: "Consultando los destinos disponibles."
  (NO listes los destinos tú mismo — deja que el sistema los muestre)

• Usuario: "guarda esto como sala principal"
  Tú: "Creando una baliza llamada Sala Principal."

• Usuario: "elimina la baliza entrada"
  Tú: "Eliminando la baliza Entrada."

• Usuario: "guarda la sesión"
  Tú: "Guardando la sesión."

• Usuario: "carga la sesión guardada"
  Tú: "Cargando la sesión."

CONVERSACIÓN GENERAL:

• Usuario: "hola"
  Tú: "¡Hola! ¿A dónde quieres ir?"

• Usuario: "¿qué puedes hacer?"
  Tú: "Puedo guiarte por el edificio. Dime el nombre de un destino y te llevo."

RECUERDA:
- Usa SIEMPRE los nombres de la lista para confirmar navegación
- Si no hay balizas, díselo al usuario amablemente
- NO uses listas con viñetas en respuestas conversacionales
- Respuestas breves y directas siempre''';
  }

  // ─── Extracción de acción ────────────────────────────────────────────────

  (_UnityAction, String) _extractAction(String botResponse, String userMessage) {
    final bot  = botResponse.toLowerCase();
    final user = userMessage.toLowerCase();

    // ── STOP ─────────────────────────────────────────────────────────────
    final stopBot  = ['deteniendo la navegación', 'cancelo la navegación',
      'navegación detenida', 'listo, me detengo'];
    final stopUser = ['para', 'detente', 'cancela', 'alto', 'stop', 'frena'];
    if (_matchesAny(bot, stopBot) || _matchesAny(user, stopUser)) {
      return (_UnityAction.stop, '');
    }

    // ── LIST ──────────────────────────────────────────────────────────────
    final listBot  = ['consultando los destinos', 'consulto los destinos',
      'destinos disponibles', 'listar balizas'];
    final listUser = ['qué balizas', 'cuáles balizas', 'qué destinos',
      'cuáles destinos', 'qué lugares', 'qué puntos',
      'muéstrame los destinos'];
    if (_matchesAny(bot, listBot) || _matchesAny(user, listUser)) {
      return (_UnityAction.list, '');
    }

    // ── SAVE ──────────────────────────────────────────────────────────────
    final savePhrases = ['guardando la sesión', 'guardo la sesión', 'sesión guardada'];
    final saveUser    = ['guarda la sesión', 'guardar sesión', 'guarda los cambios'];
    if (_matchesAny(bot, savePhrases) || _matchesAny(user, saveUser)) {
      return (_UnityAction.save, '');
    }

    // ── LOAD ──────────────────────────────────────────────────────────────
    final loadPhrases = ['cargando la sesión', 'cargo la sesión', 'sesión cargada'];
    final loadUser    = ['carga la sesión', 'cargar sesión', 'restaura la sesión'];
    if (_matchesAny(bot, loadPhrases) || _matchesAny(user, loadUser)) {
      return (_UnityAction.load, '');
    }

    // ── REMOVE ────────────────────────────────────────────────────────────
    final removeMatch = _extractAfterKeyword(bot, [
      'eliminando la baliza ', 'borrando la baliza ',
      'elimino la baliza ',    'borro la baliza ',
    ]);
    if (removeMatch != null) return (_UnityAction.remove, removeMatch);

    // ── CREATE ────────────────────────────────────────────────────────────
    final createMatch = _extractAfterKeyword(bot, [
      'llamada ', 'llamado ', 'con el nombre ', 'con nombre ',
    ]);
    if (createMatch != null &&
        _matchesAny(bot, ['creando', 'crear baliza', 'marcando', 'nuevo punto'])) {
      return (_UnityAction.create, createMatch);
    }

    // ── NAVIGATE ─────────────────────────────────────────────────────────
    final navPhrases = [
      'navegando a ',
      'voy a navegar hacia ',
      'voy hacia ',
      'te llevo a ',
      'te llevo hacia ',
      'me dirijo a ',
      'me dirijo hacia ',
      'iniciando ruta a ',
      'iniciando ruta hacia ',
      'iniciando navegación a ',
      'iniciando navegación hacia ',
      'navego a ',
      'navego hacia ',
      'navegar a ',
      'navegar hacia ',
    ];

    final dest = _extractNavigateTarget(bot, botResponse, user, userMessage, navPhrases);
    if (dest != null && dest.isNotEmpty) {
      return (_UnityAction.navigate, dest);
    }

    return (_UnityAction.none, '');
  }

  // ─── Extracción de destino de navegación (v3, sin cambios) ──────────────

  String? _extractNavigateTarget(
      String botLower,
      String botOriginal,
      String userLower,
      String userOriginal,
      List<String> phrases,
      ) {
    // 1. Buscar en el bot con límite de longitud
    for (final phrase in phrases) {
      final idx = botLower.indexOf(phrase);
      if (idx >= 0) {
        final afterOriginal = botOriginal.substring(idx + phrase.length).trim();
        final cleaned = _cleanDestination(afterOriginal);
        if (cleaned.isNotEmpty && cleaned.length <= 50) {
          _logger.d('🎯 Navigate (bot): "$phrase" → "$cleaned"');
          return cleaned;
        } else if (cleaned.length > 50) {
          _logger.d('🎯 Navigate bot-phrase demasiado larga (${cleaned.length} chars), '
              'intentando extraer desde usuario...');
          break;
        }
      }
    }

    // 2. Fallback: extraer del mensaje del usuario
    final userNavPhrases = [
      'llévame a ', 'llevame a ', 'llévame al ', 'llevame al ',
      'llévame a la ', 'llevame a la ',
      'ir a ', 'ir al ', 'ir a la ',
      'navega a ', 'navega al ', 'navega a la ',
      'navegar a ', 'navegar al ', 'navegar a la ',
      'quiero ir a ', 'quiero ir al ', 'quiero ir a la ',
      've a ', 've al ', 've a la ',
      'dónde queda ', 'donde queda ',
      'guíame a ', 'guiame a ', 'guíame al ', 'guiame al ',
      'guíame a la ', 'guiame a la ',
      'muéstrame ', 'mostrame ',
    ];

    for (final phrase in userNavPhrases) {
      final idx = userLower.indexOf(phrase);
      if (idx >= 0) {
        final afterOriginal = userOriginal.substring(idx + phrase.length).trim();
        final cleaned = _cleanDestination(afterOriginal);
        if (cleaned.isNotEmpty) {
          _logger.d('🎯 Navigate (usuario): "$phrase" → "$cleaned"');
          return cleaned;
        }
      }
    }

    return null;
  }

  // ─── Modo offline ─────────────────────────────────────────────────────────

  Future<ChatbotResponse> _chatOffline(String userMessage) async {
    final user = userMessage.toLowerCase().trim();

    if (_matchesAny(user, ['para', 'detente', 'alto', 'stop', 'cancela'])) {
      return ChatbotResponse(
        type: ResponseType.offlineCommand,
        message: 'Deteniendo la navegación.',
        intent: _buildIntent(_UnityAction.stop, ''),
        confidence: 0.9,
      );
    }

    final navPhrases = [
      'llévame a ', 'llevame a ', 'ir a ', 'navega a ',
      'guíame a ', 'guiame a ',
      'quiero ir a ', 'quiero ir al ', 'quiero ir a la ',
    ];
    for (final phrase in navPhrases) {
      final idx = user.indexOf(phrase);
      if (idx >= 0) {
        final rawDest = _cleanDestination(userMessage.substring(idx + phrase.length));
        if (rawDest.isNotEmpty) {
          // ✅ v4: también resolver en modo offline
          final dest = _resolveTarget(rawDest);
          return ChatbotResponse(
            type: ResponseType.offlineCommand,
            message: 'Navegando a $dest.',
            intent: _buildIntent(_UnityAction.navigate, dest),
            confidence: 0.85,
          );
        }
      }
    }

    if (_matchesAny(user, ['qué balizas', 'cuáles balizas', 'qué destinos', 'qué lugares'])) {
      return ChatbotResponse(
        type: ResponseType.offlineCommand,
        message: 'Consultando los destinos disponibles.',
        intent: _buildIntent(_UnityAction.list, ''),
        confidence: 0.85,
      );
    }

    if (user.contains('guarda la sesión') || user.contains('guardar sesión')) {
      return ChatbotResponse(
        type: ResponseType.offlineCommand,
        message: 'Guardando la sesión.',
        intent: _buildIntent(_UnityAction.save, ''),
        confidence: 0.85,
      );
    }
    if (user.contains('carga la sesión') || user.contains('cargar sesión')) {
      return ChatbotResponse(
        type: ResponseType.offlineCommand,
        message: 'Cargando la sesión guardada.',
        intent: _buildIntent(_UnityAction.load, ''),
        confidence: 0.85,
      );
    }

    return ChatbotResponse(
      type: ResponseType.pureConversation,
      message: _offlineFallback(user),
      confidence: 0.6,
    );
  }

  String _offlineFallback(String user) {
    if (user.contains('hola') || user.contains('hey')) {
      return '¡Hola! Estoy sin conexión, pero puedo llevarte a destinos si me dices el nombre exacto.';
    }
    if (user.contains('cómo estás') || user.contains('como estas')) {
      return 'Bien, aunque sin internet. Dime a dónde quieres ir.';
    }
    if (user.contains('qué puedes') || user.contains('que puedes')) {
      // ✅ v4: listar waypoints disponibles si los tenemos
      if (_waypointContext.hasWaypoints) {
        final names = _waypointContext.navigableWaypoints
            .map((w) => w.name)
            .join(', ');
        return 'Sin internet proceso comandos básicos. Destinos disponibles: $names.';
      }
      return 'Sin internet solo entiendo comandos básicos: "llévame a [nombre]", "para", "qué balizas hay".';
    }
    return 'Sin conexión solo entiendo comandos directos. Ejemplo: "llévame al baño".';
  }

  // ─── Construcción de intents ──────────────────────────────────────────────

  NavigationIntent? _buildIntent(_UnityAction action, String target) {
    switch (action) {
      case _UnityAction.navigate:
        if (target.isEmpty) return null;
        return NavigationIntent(
          type: IntentType.navigate,
          target: target,
          priority: 8,
          suggestedResponse: 'Navegando a $target',
        );

      case _UnityAction.stop:
        return NavigationIntent(
          type: IntentType.stop,
          target: '',
          priority: 10,
          suggestedResponse: 'Navegación detenida',
        );

      case _UnityAction.list:
        return NavigationIntent(
          type: IntentType.navigate,
          target: '__unity:list_waypoints',
          priority: 5,
          suggestedResponse: 'Consultando balizas disponibles',
        );

      case _UnityAction.create:
        if (target.isEmpty) return null;
        return NavigationIntent(
          type: IntentType.navigate,
          target: '__unity:create_waypoint:$target',
          priority: 6,
          suggestedResponse: 'Creando baliza "$target"',
        );

      case _UnityAction.remove:
        if (target.isEmpty) return null;
        return NavigationIntent(
          type: IntentType.navigate,
          target: '__unity:remove_waypoint:$target',
          priority: 6,
          suggestedResponse: 'Eliminando baliza "$target"',
        );

      case _UnityAction.save:
        return NavigationIntent(
          type: IntentType.navigate,
          target: '__unity:save_session',
          priority: 5,
          suggestedResponse: 'Guardando sesión',
        );

      case _UnityAction.load:
        return NavigationIntent(
          type: IntentType.navigate,
          target: '__unity:load_session',
          priority: 5,
          suggestedResponse: 'Cargando sesión',
        );

      case _UnityAction.none:
        return null;
    }
  }

  // ─── Utilidades ───────────────────────────────────────────────────────────

  bool _matchesAny(String text, List<String> patterns) =>
      patterns.any((p) => text.contains(p));

  String? _extractAfterKeyword(String text, List<String> keywords) {
    for (final kw in keywords) {
      final idx = text.indexOf(kw);
      if (idx >= 0) {
        final after   = text.substring(idx + kw.length).trim();
        final cleaned = _cleanDestination(after);
        if (cleaned.isNotEmpty) return cleaned;
      }
    }
    return null;
  }

  String _cleanDestination(String raw) {
    var s = raw.trim();

    for (final char in ['.', '!', '?', ',', ';', ':', '—', '(', '[', '"']) {
      final idx = s.indexOf(char);
      if (idx > 0) {
        s = s.substring(0, idx).trim();
      }
    }

    final articles = ['el ', 'la ', 'los ', 'las ', 'un ', 'una ', 'al ', 'del '];
    for (final art in articles) {
      if (s.toLowerCase().startsWith(art)) {
        s = s.substring(art.length).trim();
        break;
      }
    }

    while (s.isNotEmpty && '.!?,;:'.contains(s[s.length - 1])) {
      s = s.substring(0, s.length - 1).trim();
    }

    if (s.isNotEmpty) {
      s = s[0].toUpperCase() + s.substring(1);
    }

    return s;
  }

  void _addToHistory(String role, String content) {
    _conversationHistory.add(ChatMessage(role: role, content: content));
    if (_conversationHistory.length > _maxHistory * 2) {
      _conversationHistory.removeRange(0, 2);
    }
  }

  void clearHistory() {
    _conversationHistory.clear();
    _logger.d('Historial limpiado');
  }

  List<ChatMessage> get conversationHistory =>
      List.unmodifiable(_conversationHistory);

  Map<String, dynamic> getStatistics() => {
    'is_initialized':      _isInitialized,
    'conversation_length': _conversationHistory.length,
    'can_use_groq':        _aiModeController.canUseGroq(),
    'has_internet':        _aiModeController.hasInternet,
    'ai_mode':             _aiModeController.currentMode.name,
    'waypoints_in_context': _waypointContext.count,         // ✅ v4
    'waypoints_last_update': _waypointContext.lastUpdate?.toIso8601String(),
  };

  bool get isInitialized => _isInitialized;
  bool get canUseGroq    => _aiModeController.canUseGroq();

  void dispose() {
    _conversationHistory.clear();
    _groqService.dispose();
  }
}