// lib/services/AI/conversation_service.dart
// ✅ v6 — Fix navegación: falso match LIST, sugerencias pendientes, prompt reforzado
//
// ============================================================================
//  CAMBIOS v5 → v6
// ============================================================================
//
//  BUG CORREGIDO — Falso match _UnityAction.list sobre respuestas informativas:
//
//    PROBLEMA (v5):
//      _extractAction() tenía 'destinos disponibles' en listBot.
//      Cuando GROQ respondía "Los destinos disponibles son: ..."
//      (sin confirmar navegación), se disparaba _UnityAction.list
//      en lugar de _UnityAction.none → Unity recibía list_waypoints
//      en vez de ejecutar la navegación solicitada.
//
//    FIX 1 — listBot depurado:
//      Se eliminó 'destinos disponibles' de listBot. Ahora solo coincide
//      con la frase de acción exacta del system prompt:
//      "consultando los destinos disponibles."
//
//  NUEVO — Manejo de sugerencias pendientes (_pendingSuggestion):
//
//    PROBLEMA (v5):
//      Cuando GROQ no encontraba el destino exacto y respondía con una
//      sugerencia ("¿Quieres ir a Habitación 2° Piso?"), el sistema
//      descartaba la sugerencia. Si el usuario decía "sí", no había
//      contexto para saber a dónde navegar.
//
//    FIX 2 — _extractSuggestion() + _pendingSuggestion:
//      Si GROQ sugiere un destino sin confirmarlo, se guarda en
//      _pendingSuggestion. Si el usuario responde afirmativamente
//      ("sí", "dale", "ok", etc.) en el turno siguiente, se dispara
//      _UnityAction.navigate con ese destino automáticamente.
//
//  NUEVO — System prompt reforzado con regla "un solo candidato":
//
//    FIX 3 — GROQ debe confirmar directamente si hay un único candidato:
//      Si el usuario pide un lugar y hay exactamente un destino similar,
//      GROQ ya no debe preguntar — debe responder "Navegando a [Nombre]."
//      directamente para que _extractAction() detecte la acción.
//
//  TODO LO DEMÁS ES IDÉNTICO A v5.

import 'dart:async';
import 'package:logger/logger.dart';

import '../../models/shared_models.dart';
import 'groq_service.dart';
import 'ai_mode_controller.dart';
import 'waypoint_context_service.dart';

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

enum _UnityAction {
  navigate,
  stop,
  stopVoice,
  repeat,
  status,
  list,
  create,
  remove,
  save,
  load,
  none,
}

// ─── Servicio principal ───────────────────────────────────────────────────────

class ConversationService {
  static final ConversationService _instance = ConversationService._internal();
  factory ConversationService() => _instance;
  ConversationService._internal();

  final Logger                _logger           = Logger();
  final GroqService           _groqService      = GroqService();
  final AIModeController      _aiModeController = AIModeController();
  final WaypointContextService _waypointContext = WaypointContextService();

  final List<ChatMessage> _conversationHistory = [];
  static const int _maxHistory = 20;
  bool _isInitialized = false;

  // ✅ v6 FIX 2 — Destino sugerido pendiente de confirmación del usuario
  String? _pendingSuggestion;

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
        systemPrompt: _buildSystemPrompt(),
      );

      _addToHistory('assistant', response.content);

      final (action, rawTarget) = _extractAction(response.content, userMessage);

      if (action != _UnityAction.none) {
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

      // ✅ v6 FIX 2 — Si GROQ no confirmó acción, buscar sugerencia implícita
      if (action == _UnityAction.none) {
        final suggestion = _extractSuggestion(response.content);
        if (suggestion != null && suggestion.isNotEmpty) {
          _pendingSuggestion = _resolveTarget(suggestion);
          _logger.d('[Suggest] Destino sugerido guardado: "$_pendingSuggestion"');
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

  // ─── Resolución de destino ───────────────────────────────────────────────

  String _resolveTarget(String rawTarget) {
    if (rawTarget.isEmpty) return rawTarget;

    if (!_waypointContext.hasWaypoints) {
      _logger.d('[Resolve] Sin destinos registrados, usando raw: "$rawTarget"');
      return rawTarget;
    }

    final resolved = _waypointContext.resolveTarget(rawTarget);
    if (resolved != null && resolved != rawTarget) {
      _logger.i('[Resolve] "$rawTarget" → "$resolved"');
      return resolved;
    }

    if (rawTarget.isNotEmpty) {
      final capitalized = rawTarget[0].toUpperCase() + rawTarget.substring(1);
      if (capitalized != rawTarget) return capitalized;
    }

    return rawTarget;
  }

  // ─── System prompt ───────────────────────────────────────────────────────

  String _buildSystemPrompt() {
    final waypointContext = _waypointContext.getContextForPrompt();

    return '''Eres COMPAS, asistente de navegación para interiores. Guías al usuario dentro del edificio de forma amable y directa.

PERSONALIDAD:
- Español natural y cercano
- Respuestas breves: 1-2 oraciones
- Sin listas con viñetas en respuestas habladas

CAPACIDADES:
Puedes llevar al usuario a un lugar, detener la navegación, repetir la última instrucción, informar el estado de la navegación, silenciar la guía de voz, mostrar los lugares disponibles, guardar o cargar una sesión.

$waypointContext

══════════════════════════════════════════════════════════════════
REGLA IMPORTANTE — CONFIRMAR DESTINO:

Cuando el usuario pida ir a algún lugar:
1. Verifica si existe en LUGARES DISPONIBLES.
2. Si existe → confirma con el nombre EXACTO de la lista.
3. Si hay varios similares → pregunta cuál antes de ir.
4. Si no existe → díselo y menciona los disponibles.

Tu confirmación debe usar el nombre EXACTO de la lista, sin parafrasear.

✅ CORRECTO:
  Lista: "Habitación 1", "Baño", "Sala Principal"
  Usuario: "llévame a la habitación"
  Tú: "Navegando a Habitación 1."

  Usuario: "quiero ir al baño"
  Tú: "Navegando a Baño."

  Usuario: "habitaciones" (hay Habitación 1 y Habitación 2)
  Tú: "Hay dos habitaciones disponibles: Habitación 1 y Habitación 2. ¿A cuál vamos?"

  Usuario: "llévame a la cocina" (no existe)
  Tú: "No tengo registrado ese lugar. Los disponibles son: Habitación 1, Baño, Sala Principal."

❌ NUNCA hagas esto:
  "No sé a qué habitación te refieres." ← si solo hay una, ve ahí
  "Voy hacia el destino que mencionaste." ← sin nombre concreto

══════════════════════════════════════════════════════════════════
REGLA CRÍTICA — UN SOLO CANDIDATO:

Si el usuario pide un lugar y existe EXACTAMENTE UN destino similar
o que corresponda aproximadamente a lo pedido, NO preguntes —
confirma DIRECTAMENTE con la frase de navegación.

❌ MAL (genera ambigüedad y rompe la detección de acciones):
  "¿Quieres ir a la Habitación 2° Piso?"

✅ BIEN (acción directa, detectable por el sistema):
  "Navegando a Habitación 2° Piso."

Solo pregunta si hay DOS O MÁS candidatos igualmente válidos.

══════════════════════════════════════════════════════════════════

FRASES DE CONFIRMACIÓN (usa estas exactas):

• Ir a un lugar:        "Navegando a [NombreExacto]."
• Detener navegación:   "Deteniendo la navegación."
• Silenciar voz:        "Silenciando la guía de voz."
• Repetir instrucción:  "Repitiendo la última instrucción."
• Estado navegación:    "Consultando el estado de la navegación."
• Ver lugares:          "Consultando los destinos disponibles."
• Guardar sesión:       "Guardando la sesión."
• Cargar sesión:        "Cargando la sesión."
• Crear lugar:          "Guardando el lugar como [Nombre]."
• Eliminar lugar:       "Eliminando el lugar [Nombre]."

EJEMPLOS:

• "llévame al baño"            → "¡Claro! Navegando a Baño."
• "para la navegación"         → "Entendido. Deteniendo la navegación."
• "silencia la guía"           → "Silenciando la guía de voz."
• "repite eso"                 → "Repitiendo la última instrucción."
• "¿qué me dijiste?"           → "Repitiendo la última instrucción."
• "¿cuánto falta?"             → "Consultando el estado de la navegación."
• "¿a dónde voy?"              → "Consultando el estado de la navegación."
• "¿qué lugares hay?"          → "Consultando los destinos disponibles."
• "guarda esto como recepción" → "Guardando el lugar como Recepción."
• "hola"                       → "¡Hola! ¿A dónde quieres ir?"
• "¿qué puedes hacer?"         → "Puedo llevarte a cualquier lugar del edificio, repetir instrucciones y más. ¿A dónde vamos?"

RECUERDA:
- Usa siempre los nombres exactos de la lista para confirmar
- Si no hay lugares registrados, díselo al usuario
- Respuestas cortas y directas siempre
- Si solo hay un lugar que coincide con lo pedido, ve directamente sin preguntar''';
  }

  // ─── Extracción de acción ────────────────────────────────────────────────

  (_UnityAction, String) _extractAction(String botResponse, String userMessage) {
    final bot  = botResponse.toLowerCase();
    final user = userMessage.toLowerCase();

    // ✅ v6 FIX 2 — Verificar confirmación de sugerencia pendiente PRIMERO
    // Si el usuario confirma ("sí", "dale", etc.) y hay una sugerencia guardada,
    // navegamos directamente sin necesidad de que GROQ repita el destino.
    final confirmPhrases = [
      'sí', 'si', 'claro', 'ok', 'dale', 'bueno', 'perfecto',
      'adelante', 'vamos', 'de acuerdo', 'está bien', 'esta bien',
      'correcto', 'exacto', 'eso', 'ese', 'esa',
    ];
    if (_pendingSuggestion != null && _pendingSuggestion!.isNotEmpty) {
      if (_matchesAny(user, confirmPhrases)) {
        final dest = _pendingSuggestion!;
        _pendingSuggestion = null;
        _logger.i('[Suggest] ✅ Confirmación recibida → navegando a "$dest"');
        return (_UnityAction.navigate, dest);
      }
      // Si el usuario no confirmó, limpiar sugerencia (cambió de tema)
      if (!_matchesAny(user, confirmPhrases)) {
        _logger.d('[Suggest] Sugerencia descartada — usuario cambió de tema');
        _pendingSuggestion = null;
      }
    }

    // ── STOP_VOICE (antes que STOP para evitar captura prematura) ────────
    final stopVoiceBot = [
      'silenciando la guía de voz',
      'silencio la guía',
      'apago la guía de voz',
    ];
    final stopVoiceUser = [
      'silencia', 'silencio', 'cállate', 'callate',
      'para de hablar', 'deja de hablar', 'sin voz', 'modo mudo',
      'apaga la voz', 'apaga el audio',
    ];
    if (_matchesAny(bot, stopVoiceBot) || _matchesAny(user, stopVoiceUser)) {
      return (_UnityAction.stopVoice, '');
    }

    // ── STOP (detener navegación completa) ────────────────────────────────
    final stopBot  = ['deteniendo la navegación', 'cancelo la navegación',
      'navegación detenida', 'listo, me detengo'];
    final stopUser = ['para', 'detente', 'cancela', 'alto', 'stop', 'frena',
      'detener navegación', 'cancelar ruta'];
    if (_matchesAny(bot, stopBot) || _matchesAny(user, stopUser)) {
      return (_UnityAction.stop, '');
    }

    // ── REPEAT ────────────────────────────────────────────────────────────
    final repeatBot  = ['repitiendo la última instrucción', 'repito la instrucción'];
    final repeatUser = [
      'repite', 'repítelo', 'repetir', 'otra vez', 'de nuevo',
      'qué dijiste', 'qué me dijiste', 'no escuché', 'no oí',
      'no entendí', 'más despacio',
    ];
    if (_matchesAny(bot, repeatBot) || _matchesAny(user, repeatUser)) {
      return (_UnityAction.repeat, '');
    }

    // ── STATUS ────────────────────────────────────────────────────────────
    final statusBot  = [
      'consultando el estado de la navegación',
      'consulto el estado',
    ];
    final statusUser = [
      'cuánto falta', 'cuanto falta', 'qué tan lejos', 'a dónde voy',
      'cuántos pasos', 'cuantos pasos', 'estado de la navegación',
      'cómo voy', 'como voy', 'qué está pasando',
      'próxima instrucción', 'proxima instruccion',
    ];
    if (_matchesAny(bot, statusBot) || _matchesAny(user, statusUser)) {
      return (_UnityAction.status, '');
    }

    // ── LIST ──────────────────────────────────────────────────────────────
    // ✅ v6 FIX 1 — Se eliminó 'destinos disponibles' de listBot.
    // Esa cadena aparece en respuestas INFORMATIVAS de GROQ ("Los destinos
    // disponibles son: ...") y causaba un falso positivo que disparaba
    // list_waypoints en Unity en lugar de procesar la navegación.
    // Solo se mantienen frases de ACCIÓN explícita del system prompt.
    final listBot  = [
      'consultando los destinos disponibles',   // frase exacta de confirmación
      'consulto los destinos disponibles',
    ];
    final listUser = ['qué lugares', 'cuáles lugares', 'qué destinos',
      'cuáles destinos', 'qué hay', 'qué puntos',
      'muéstrame los destinos', 'qué balizas', 'cuáles balizas'];
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
      'eliminando el lugar ', 'eliminando la baliza ',
      'borrando el lugar ',   'elimino el lugar ',
    ]);
    if (removeMatch != null) return (_UnityAction.remove, removeMatch);

    // ── CREATE ────────────────────────────────────────────────────────────
    final createMatch = _extractAfterKeyword(bot, [
      'guardando el lugar como ', 'llamada ', 'llamado ',
      'con el nombre ', 'con nombre ',
    ]);
    if (createMatch != null &&
        _matchesAny(bot, ['guardando el lugar', 'creando', 'marcando', 'nuevo punto'])) {
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

  // ─── Extracción de destino de navegación ────────────────────────────────

  String? _extractNavigateTarget(
      String botLower,
      String botOriginal,
      String userLower,
      String userOriginal,
      List<String> phrases,
      ) {
    for (final phrase in phrases) {
      final idx = botLower.indexOf(phrase);
      if (idx >= 0) {
        final afterOriginal = botOriginal.substring(idx + phrase.length).trim();
        final cleaned = _cleanDestination(afterOriginal);
        if (cleaned.isNotEmpty && cleaned.length <= 50) {
          _logger.d('🎯 Navigate (bot): "$phrase" → "$cleaned"');
          return cleaned;
        } else if (cleaned.length > 50) {
          break;
        }
      }
    }

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

  // ─── Extracción de sugerencia implícita ──────────────────────────────────

  /// ✅ v6 FIX 2 — Detecta cuando GROQ sugiere un destino sin confirmarlo.
  /// Busca patrones de pregunta con un destino concreto en la respuesta.
  /// Retorna el nombre del destino sugerido o null si no hay sugerencia.
  String? _extractSuggestion(String botResponse) {
    final bot = botResponse.toLowerCase();
    final suggestionPhrases = [
      '¿quieres ir a ',
      '¿te llevo a ',
      '¿vamos a ',
      '¿deseas ir a ',
      '¿vamos hacia ',
      '¿quieres que te lleve a ',
      '¿te guío a ',
      '¿te guío hacia ',
      'quieres ir a ',
      'te llevo a ',
    ];

    for (final phrase in suggestionPhrases) {
      final idx = bot.indexOf(phrase);
      if (idx >= 0) {
        final afterOriginal = botResponse.substring(idx + phrase.length).trim();
        final cleaned = _cleanDestination(afterOriginal);
        if (cleaned.isNotEmpty && cleaned.length <= 60) {
          _logger.d('[Suggest] Sugerencia detectada: "$cleaned"');
          return cleaned;
        }
      }
    }
    return null;
  }

  // ─── Modo offline ─────────────────────────────────────────────────────────

  Future<ChatbotResponse> _chatOffline(String userMessage) async {
    final user = userMessage.toLowerCase().trim();

    // ✅ v6 FIX 2 — Verificar confirmación de sugerencia pendiente también offline
    final confirmPhrases = [
      'sí', 'si', 'claro', 'ok', 'dale', 'bueno', 'perfecto',
      'adelante', 'vamos', 'de acuerdo', 'está bien', 'esta bien',
      'correcto', 'exacto', 'eso', 'ese', 'esa',
    ];
    if (_pendingSuggestion != null && _pendingSuggestion!.isNotEmpty) {
      if (_matchesAny(user, confirmPhrases)) {
        final dest = _pendingSuggestion!;
        _pendingSuggestion = null;
        return ChatbotResponse(
          type: ResponseType.offlineCommand,
          message: 'Navegando a $dest.',
          intent: _buildIntent(_UnityAction.navigate, dest),
          confidence: 0.9,
        );
      }
      _pendingSuggestion = null;
    }

    // silenciar voz (antes de stop)
    if (_matchesAny(user, ['silencia', 'cállate', 'callate', 'para de hablar',
      'deja de hablar', 'sin voz', 'modo mudo'])) {
      return ChatbotResponse(
        type: ResponseType.offlineCommand,
        message: 'Silenciando la guía de voz.',
        intent: _buildIntent(_UnityAction.stopVoice, ''),
        confidence: 0.9,
      );
    }

    if (_matchesAny(user, ['para', 'detente', 'alto', 'stop', 'cancela',
      'detener navegación', 'cancelar ruta'])) {
      return ChatbotResponse(
        type: ResponseType.offlineCommand,
        message: 'Deteniendo la navegación.',
        intent: _buildIntent(_UnityAction.stop, ''),
        confidence: 0.9,
      );
    }

    if (_matchesAny(user, ['repite', 'repítelo', 'repetir', 'otra vez',
      'de nuevo', 'qué dijiste', 'no escuché', 'no oí'])) {
      return ChatbotResponse(
        type: ResponseType.offlineCommand,
        message: 'Repitiendo la última instrucción.',
        intent: _buildIntent(_UnityAction.repeat, ''),
        confidence: 0.9,
      );
    }

    if (_matchesAny(user, ['cuánto falta', 'cuanto falta', 'qué tan lejos',
      'a dónde voy', 'cuántos pasos', 'cómo voy', 'como voy',
      'estado de la navegación', 'próxima instrucción'])) {
      return ChatbotResponse(
        type: ResponseType.offlineCommand,
        message: 'Consultando el estado de la navegación.',
        intent: _buildIntent(_UnityAction.status, ''),
        confidence: 0.85,
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

    if (_matchesAny(user, ['qué lugares', 'qué destinos', 'qué hay', 'qué balizas'])) {
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
        message: 'Cargando la sesión.',
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
      return 'Hola. Estoy sin conexión, pero puedo llevarte a un lugar si me dices el nombre exacto.';
    }
    if (user.contains('cómo estás') || user.contains('como estas')) {
      return 'Bien, aunque sin internet. Dime a dónde quieres ir.';
    }
    if (user.contains('qué puedes') || user.contains('que puedes')) {
      if (_waypointContext.hasWaypoints) {
        final names = _waypointContext.navigableWaypoints
            .map((w) => w.name)
            .join(', ');
        return 'Sin internet proceso comandos básicos. Lugares disponibles: $names.';
      }
      return 'Sin internet puedo: llevar a un lugar, repetir instrucción, '
          'consultar estado o silenciar la voz. Dime lo que necesitas.';
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

      case _UnityAction.stopVoice:
        return NavigationIntent(
          type: IntentType.navigate,
          target: '__unity:stop_voice',
          priority: 9,
          suggestedResponse: 'Guía de voz silenciada',
        );

      case _UnityAction.repeat:
        return NavigationIntent(
          type: IntentType.navigate,
          target: '__unity:repeat_instruction',
          priority: 7,
          suggestedResponse: 'Repitiendo instrucción',
        );

      case _UnityAction.status:
        return NavigationIntent(
          type: IntentType.navigate,
          target: '__unity:voice_status',
          priority: 6,
          suggestedResponse: 'Consultando estado',
        );

      case _UnityAction.list:
        return NavigationIntent(
          type: IntentType.navigate,
          target: '__unity:list_waypoints',
          priority: 5,
          suggestedResponse: 'Consultando destinos disponibles',
        );

      case _UnityAction.create:
        if (target.isEmpty) return null;
        return NavigationIntent(
          type: IntentType.navigate,
          target: '__unity:create_waypoint:$target',
          priority: 6,
          suggestedResponse: 'Guardando lugar "$target"',
        );

      case _UnityAction.remove:
        if (target.isEmpty) return null;
        return NavigationIntent(
          type: IntentType.navigate,
          target: '__unity:remove_waypoint:$target',
          priority: 6,
          suggestedResponse: 'Eliminando lugar "$target"',
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
    _pendingSuggestion = null;  // ✅ v6: limpiar sugerencia al resetear historial
    _logger.d('Historial limpiado');
  }

  List<ChatMessage> get conversationHistory =>
      List.unmodifiable(_conversationHistory);

  Map<String, dynamic> getStatistics() => {
    'is_initialized':            _isInitialized,
    'conversation_length':       _conversationHistory.length,
    'can_use_groq':              _aiModeController.canUseGroq(),
    'has_internet':              _aiModeController.hasInternet,
    'ai_mode':                   _aiModeController.currentMode.name,
    'destinations_in_context':   _waypointContext.count,
    'destinations_last_update':  _waypointContext.lastUpdate?.toIso8601String(),
    'pending_suggestion':        _pendingSuggestion,  // ✅ v6: nuevo campo de diagnóstico
  };

  bool get isInitialized => _isInitialized;
  bool get canUseGroq    => _aiModeController.canUseGroq();

  void dispose() {
    _conversationHistory.clear();
    _pendingSuggestion = null;
    _groqService.dispose();
  }
}