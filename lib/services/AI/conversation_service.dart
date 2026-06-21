// lib/services/AI/conversation_service.dart
// ✅ v7.2 — Fix sintaxis · "Destinos" · Frases empáticas · Sin tecnicismos
//
// ============================================================================
//  CAMBIOS v7.1 → v7.2
// ============================================================================
//
//  BUG CRÍTICO corregido:
//    Línea ~919: faltaba ';' al final del return del case _UnityAction.save.
//    El compilador lanzaba: Expected ';' after this.
//
//  Sin otros cambios funcionales.

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
  clear,
  save,
  load,
  introduce,
  none,
}

const _waypointMutationActions = {
  _UnityAction.create,
  _UnityAction.remove,
  _UnityAction.clear,
};

// ─── Servicio principal ───────────────────────────────────────────────────────

class ConversationService {
  static final ConversationService _instance = ConversationService._internal();
  factory ConversationService() => _instance;
  ConversationService._internal();

  final Logger                 _logger           = Logger();
  final GroqService            _groqService      = GroqService();
  final AIModeController       _aiModeController = AIModeController();
  final WaypointContextService _waypointContext  = WaypointContextService();

  final List<ChatMessage> _conversationHistory = [];
  static const int _maxHistory = 20;
  bool _isInitialized = false;

  String? _pendingSuggestion;

  Function()? onWaypointMutation;

  // ─── Inicialización ──────────────────────────────────────────────────────

  Future<void> initialize() async {
    if (_isInitialized) return;
    try {
      await _aiModeController.initialize();
      if (_aiModeController.canUseGroq()) {
        await _groqService.initialize();
        _logger.i('✅ ConversationService v7.2 online (Groq)');
      } else {
        _logger.i('✅ ConversationService v7.2 offline');
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

          if (_waypointMutationActions.contains(action)) {
            _logger.d('[Mutation] Recargando destinos por: $action');
            onWaypointMutation?.call();
          }

          return ChatbotResponse(
            type:       ResponseType.conversationWithIntent,
            message:    response.content,
            intent:     intent,
            confidence: 0.95,
          );
        }
      }

      if (action == _UnityAction.none) {
        final suggestion = _extractSuggestion(response.content);
        if (suggestion != null && suggestion.isNotEmpty) {
          _pendingSuggestion = _resolveTarget(suggestion);
          _logger.d('[Suggest] Destino sugerido: "$_pendingSuggestion"');
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
      _logger.d('[Resolve] Sin destinos, usando raw: "$rawTarget"');
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

    return '''Eres COMPAS, asistente de navegación en la Biblioteca de la Universidad de San Buenaventura Cali. Guías al usuario de forma amable, breve y directa. El usuario te habla por voz. Muchos usuarios tienen discapacidad visual, así que cada palabra cuenta.

PERSONALIDAD:
- Español natural y cercano, como el asistente de Google
- Máximo 1-2 oraciones por respuesta
- Nunca uses viñetas en respuestas que se escuchan
- Llama a los lugares guardados "destinos", nunca "balizas" ni "waypoints"
- Nunca dejes al usuario sin respuesta ni en silencio sin explicación

CAPACIDADES:
Puedes llevar al usuario a cualquier destino disponible, detener la navegación, repetir la última indicación, informar el estado de la ruta, silenciar la guía de voz, mostrar los destinos disponibles, guardar o cargar una sesión, guardar un nuevo destino en la posición actual del usuario, eliminar destinos guardados y explicarle al usuario cómo funciona la aplicación cuando lo pida.

══════════════════════════════════════════════════════════════════

PRESENTACIÓN DEL ASISTENTE:

Si el usuario dice:
- "preséntate"
- "presentate"
- "cuéntame de ti"
- "cuentame de ti"
- "qué puedes hacer"
- "que puedes hacer"
- "cómo funcionas"
- "como funcionas"

Responde EXACTAMENTE:

"Claro. Déjame presentarme."

NO expliques todo en un solo mensaje.
La aplicación reproducirá la presentación por partes.

══════════════════════════════════════════════════════════════════

$waypointContext

══════════════════════════════════════════════════════════════════
REGLA IMPORTANTE — CONFIRMAR DESTINO:

Cuando el usuario pida ir a algún lugar:
1. Verifica si existe en DESTINOS DISPONIBLES.
2. Si existe → confirma con el nombre EXACTO de la lista.
3. Si hay varios similares → pregunta cuál antes de ir.
4. Si no existe → díselo y menciona los disponibles.

Tu confirmación debe usar el nombre EXACTO de la lista.

✅ CORRECTO:
  Lista: "Habitación 1", "Baño", "Sala Principal"
  Usuario: "llévame a la habitación"
  Tú: "Navegando a Habitación 1."

  Usuario: "quiero ir al baño"
  Tú: "Navegando a Baño."

  Usuario: "habitaciones" (hay Habitación 1 y Habitación 2)
  Tú: "Hay dos opciones: Habitación 1 y Habitación 2. ¿A cuál vamos?"

  Usuario: "llévame a la cocina" (no existe)
  Tú: "Ese lugar no lo tengo guardado. Los que tengo son: Habitación 1, Baño, Sala Principal."

❌ NUNCA:
  "No sé a qué habitación te refieres." ← si solo hay una, ve ahí
  "Voy hacia el destino que mencionaste." ← sin nombre concreto
  "baliza", "waypoint" ← el usuario no entiende esos términos
  "No puedo ayudarte con eso." ← siempre ofrece una alternativa

══════════════════════════════════════════════════════════════════
REGLA CRÍTICA — UN SOLO CANDIDATO:

Si hay EXACTAMENTE UN destino que coincide con lo pedido,
ve directo sin preguntar.

❌ MAL: "¿Quieres ir a la Habitación 2° Piso?"
✅ BIEN: "Navegando a Habitación 2° Piso."

Solo pregunta si hay DOS O MÁS candidatos igualmente válidos.

══════════════════════════════════════════════════════════════════

FRASES DE CONFIRMACIÓN (usa estas exactas — el sistema las detecta):

• Ir a un destino:            "Navegando a [NombreExacto]."
• Detener navegación:         "Deteniendo la navegación."
• Silenciar voz:              "Silenciando la guía de voz."
• Repetir indicación:         "Repitiendo la última indicación."
• Estado de ruta:             "Consultando el estado de la navegación."
• Ver destinos disponibles:   "Consultando los destinos disponibles."
• Guardar sesión:             "Guardando la sesión."
• Cargar sesión:              "Cargando la sesión."
• Guardar destino:            "Guardando el lugar como [Nombre]."
• Eliminar destino:           "Eliminando el lugar [Nombre]."
• Eliminar todos:             "Eliminando todos los destinos."
• Presentación:               "Claro. Déjame presentarme."

EJEMPLOS:

• "llévame al baño"            → "Claro. Navegando a Baño."
• "para"                       → "Listo. Deteniendo la navegación."
• "silencia la guía"           → "Silenciando la guía de voz."
• "repite eso"                 → "Repitiendo la última indicación."
• "¿cuánto falta?"             → "Consultando el estado de la navegación."
• "¿qué destinos hay?"         → "Consultando los destinos disponibles."
• "guarda aquí como Recepción" → "Guardando el lugar como Recepción."
• "borra el destino Baño"      → "Eliminando el lugar Baño."
• "elimina todos"              → "Eliminando todos los destinos."
• "preséntate"                 → "Claro. Déjame presentarme."
• "hola"                       → "¡Hola! ¿A dónde quieres ir?"

RECUERDA:
- Si solo hay un destino que coincide, ve directo sin preguntar
- Respuestas cortas y claras siempre
- Si no hay destinos registrados, díselo con amabilidad y ofrece ayuda
- Nunca dejes al usuario sin una respuesta útil''';
  }

  // ─── Extracción de acción ────────────────────────────────────────────────

  (_UnityAction, String) _extractAction(String botResponse, String userMessage) {
    final bot  = botResponse.toLowerCase();
    final user = userMessage.toLowerCase();

    // Confirmación de sugerencia pendiente
    final confirmPhrases = [
      'sí', 'si', 'claro', 'ok', 'dale', 'bueno', 'perfecto',
      'adelante', 'vamos', 'de acuerdo', 'está bien', 'esta bien',
      'correcto', 'exacto', 'eso', 'ese', 'esa',
    ];
    if (_pendingSuggestion != null && _pendingSuggestion!.isNotEmpty) {
      if (_matchesAny(user, confirmPhrases)) {
        final dest = _pendingSuggestion!;
        _pendingSuggestion = null;
        _logger.i('[Suggest] ✅ Confirmado → navegando a "$dest"');
        return (_UnityAction.navigate, dest);
      }
      _logger.d('[Suggest] Sugerencia descartada');
      _pendingSuggestion = null;
    }

    // ── STOP_VOICE ──────────────────────────────────────────────────────────
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

    // ── STOP ────────────────────────────────────────────────────────────────
    final stopBot  = [
      'deteniendo la navegación', 'cancelo la navegación',
      'navegación detenida', 'listo, me detengo',
    ];
    final stopUser = [
      'para', 'detente', 'cancela', 'alto', 'stop', 'frena',
      'detener navegación', 'cancelar ruta',
    ];
    if (_matchesAny(bot, stopBot) || _matchesAny(user, stopUser)) {
      return (_UnityAction.stop, '');
    }

    // ── REPEAT ──────────────────────────────────────────────────────────────
    final repeatBot  = [
      'repitiendo la última indicación',
      'repitiendo la última instrucción',
      'repito la instrucción',
      'repito la indicación',
    ];
    final repeatUser = [
      'repite', 'repítelo', 'repetir', 'otra vez', 'de nuevo',
      'qué dijiste', 'qué me dijiste', 'no escuché', 'no oí',
      'no entendí', 'más despacio',
    ];
    if (_matchesAny(bot, repeatBot) || _matchesAny(user, repeatUser)) {
      return (_UnityAction.repeat, '');
    }

    // ── STATUS ──────────────────────────────────────────────────────────────
    final statusBot  = [
      'consultando el estado de la navegación',
      'consulto el estado',
    ];
    final statusUser = [
      'cuánto falta', 'cuanto falta', 'qué tan lejos', 'a dónde voy',
      'cuántos pasos', 'cuantos pasos', 'estado de la navegación',
      'cómo voy', 'como voy', 'qué está pasando',
      'próxima indicación', 'proxima indicacion',
      'próxima instrucción', 'proxima instruccion',
    ];
    if (_matchesAny(bot, statusBot) || _matchesAny(user, statusUser)) {
      return (_UnityAction.status, '');
    }

    // ── LIST ────────────────────────────────────────────────────────────────
    final listBot  = [
      'consultando los destinos disponibles',
      'consulto los destinos disponibles',
    ];
    final listUser = [
      'qué destinos', 'cuáles destinos', 'qué lugares', 'qué hay',
      'qué puntos', 'muéstrame los destinos', 'qué lugares hay',
      'cuáles lugares hay', 'destinos disponibles',
      // legacy por si el usuario dice "balizas"
      'qué balizas', 'cuáles balizas',
    ];
    if (_matchesAny(bot, listBot) || _matchesAny(user, listUser)) {
      return (_UnityAction.list, '');
    }

    // ── SAVE ────────────────────────────────────────────────────────────────
    final savePhrases = ['guardando la sesión', 'guardo la sesión'];
    final saveUser    = ['guarda la sesión', 'guardar sesión', 'guarda los cambios'];
    if (_matchesAny(bot, savePhrases) || _matchesAny(user, saveUser)) {
      return (_UnityAction.save, '');
    }

    // ── LOAD ────────────────────────────────────────────────────────────────
    final loadPhrases = ['cargando la sesión', 'cargo la sesión'];
    final loadUser    = ['carga la sesión', 'cargar sesión', 'restaura la sesión'];
    if (_matchesAny(bot, loadPhrases) || _matchesAny(user, loadUser)) {
      return (_UnityAction.load, '');
    }

    // ── CLEAR ───────────────────────────────────────────────────────────────
    final clearBot = [
      'eliminando todos los destinos',
      'eliminando todas las balizas',
      'borrando todos los destinos',
      'elimino todos los destinos',
    ];
    final clearUser = [
      'borra todo', 'borrar todo', 'elimina todo', 'eliminar todo',
      'limpiar destinos', 'borrar todos', 'eliminar todos',
      'borra todos los destinos', 'elimina todos los destinos',
      'limpiar balizas', 'borrar todas las balizas', 'limpiar waypoints',
    ];
    if (_matchesAny(bot, clearBot) || _matchesAny(user, clearUser)) {
      return (_UnityAction.clear, '');
    }

    // ── REMOVE ──────────────────────────────────────────────────────────────
    final removeMatch = _extractAfterKeyword(bot, [
      'eliminando el lugar ',
      'eliminando la baliza ',
      'borrando el lugar ',
      'elimino el lugar ',
    ]);
    if (removeMatch != null) return (_UnityAction.remove, removeMatch);

    // ── CREATE ──────────────────────────────────────────────────────────────
    final createMatch = _extractAfterKeyword(bot, [
      'guardando el lugar como ',
      'guardo el lugar como ',
      'guardando la baliza como ',
    ]);
    if (createMatch != null && createMatch.isNotEmpty) {
      return (_UnityAction.create, createMatch);
    }

    final createUserMatch = _extractAfterKeyword(user, [
      'marca aquí como ', 'marca esto como ', 'marca aqui como ',
      'guarda aquí como ', 'guarda aqui como ', 'guarda esto como ',
      'crear destino ', 'nuevo destino ',
      'crear baliza ', 'crear waypoint ', 'nuevo punto ',
      'añade baliza ', 'nueva baliza ',
    ]);
    if (createUserMatch != null && createUserMatch.isNotEmpty) {
      return (_UnityAction.create, createUserMatch);
    }

    // ── NAVIGATE ────────────────────────────────────────────────────────────
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

    // ── INTRODUCE ───────────────────────────────────────────────────────────
    final introduceUser = [
      'preséntate',
      'presentate',
      'cuéntame de ti',
      'cuentame de ti',
      'qué puedes hacer',
      'que puedes hacer',
      'cómo funcionas',
      'como funcionas',
    ];

    if (_matchesAny(user, introduceUser)) {
      return (_UnityAction.introduce, '');
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
          _logger.d('[Suggest] Detectado: "$cleaned"');
          return cleaned;
        }
      }
    }
    return null;
  }

  // ─── Modo offline ─────────────────────────────────────────────────────────

  Future<ChatbotResponse> _chatOffline(String userMessage) async {
    final user = userMessage.toLowerCase().trim();

    // Confirmación de sugerencia pendiente
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

    // Silenciar voz
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
        message: 'Repitiendo la última indicación.',
        intent: _buildIntent(_UnityAction.repeat, ''),
        confidence: 0.9,
      );
    }

    if (_matchesAny(user, ['cuánto falta', 'cuanto falta', 'qué tan lejos',
      'a dónde voy', 'cuántos pasos', 'cómo voy', 'como voy',
      'estado de la navegación', 'próxima indicación'])) {
      return ChatbotResponse(
        type: ResponseType.offlineCommand,
        message: 'Consultando el estado de la navegación.',
        intent: _buildIntent(_UnityAction.status, ''),
        confidence: 0.85,
      );
    }

    // Clear
    if (_matchesAny(user, ['borra todo', 'borrar todo', 'elimina todo',
      'eliminar todo', 'limpiar destinos', 'borrar todos',
      'eliminar todos', 'limpiar balizas', 'borrar waypoints'])) {
      _notifyMutationIfNeeded(_UnityAction.clear);
      return ChatbotResponse(
        type: ResponseType.offlineCommand,
        message: 'Eliminando todos los destinos.',
        intent: _buildIntent(_UnityAction.clear, ''),
        confidence: 0.9,
      );
    }

    // Remove
    final removeOfflinePhrases = [
      'borra el destino ', 'elimina el destino ',
      'borra la baliza ', 'elimina la baliza ',
      'elimina el lugar ', 'borra el lugar ',
    ];
    for (final phrase in removeOfflinePhrases) {
      final idx = user.indexOf(phrase);
      if (idx >= 0) {
        final name = _cleanDestination(userMessage.substring(idx + phrase.length));
        if (name.isNotEmpty) {
          _notifyMutationIfNeeded(_UnityAction.remove);
          return ChatbotResponse(
            type: ResponseType.offlineCommand,
            message: 'Eliminando el lugar $name.',
            intent: _buildIntent(_UnityAction.remove, name),
            confidence: 0.85,
          );
        }
      }
    }

    // Create
    final createOfflinePhrases = [
      'marca aquí como ', 'marca esto como ', 'marca aqui como ',
      'guarda aquí como ', 'guarda aqui como ', 'guarda esto como ',
      'crear destino ', 'nuevo destino ',
      'crear baliza ', 'nueva baliza ',
    ];
    for (final phrase in createOfflinePhrases) {
      final idx = user.indexOf(phrase);
      if (idx >= 0) {
        final name = _cleanDestination(userMessage.substring(idx + phrase.length));
        if (name.isNotEmpty) {
          _notifyMutationIfNeeded(_UnityAction.create);
          return ChatbotResponse(
            type: ResponseType.offlineCommand,
            message: 'Guardando el lugar como $name.',
            intent: _buildIntent(_UnityAction.create, name),
            confidence: 0.85,
          );
        }
      }
    }

    // Navigate
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

    if (_matchesAny(user, ['qué destinos', 'qué lugares', 'qué hay',
      'destinos disponibles', 'qué balizas'])) {
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

  // Fallback offline empático
  String _offlineFallback(String user) {
    if (user.contains('hola') || user.contains('hey') || user.contains('buenas')) {
      return 'Hola, estoy con señal limitada. Pero puedo llevarte a un lugar si me dices el nombre.';
    }
    if (user.contains('cómo estás') || user.contains('como estas')) {
      return 'Aquí estoy, aunque sin internet hoy. ¿A dónde quieres ir?';
    }
    if (user.contains('qué puedes') || user.contains('que puedes')) {
      if (_waypointContext.hasWaypoints) {
        final names = _waypointContext.navigableWaypoints
            .map((w) => w.name)
            .join(', ');
        return 'Sin internet puedo guiarte a estos lugares: $names.';
      }
      return 'Sin internet puedo llevarte a cualquier lugar guardado y repetir indicaciones. ¿A dónde vamos?';
    }
    if (user.contains('biblioteca') || user.contains('pisos') || user.contains('qué hay')) {
      return 'La biblioteca tiene 3 pisos con cubículos, sala de computadores y coworking. ¿A dónde quieres ir?';
    }
    if (user.contains('universidad') || user.contains('san buen') || user.contains('usb')) {
      return 'Estás en la Universidad de San Buenaventura Cali, al sur de la ciudad. ¿Te llevo a algún lugar?';
    }
    return 'Estoy con señal limitada, pero puedo guiarte. Dime a dónde quieres ir.';
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
          suggestedResponse: 'Repitiendo indicación',
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

      case _UnityAction.clear:
        return NavigationIntent(
          type: IntentType.navigate,
          target: '__unity:clear_waypoints',
          priority: 6,
          suggestedResponse: 'Eliminando todos los lugares',
        );

    // ─── FIX: punto y coma que faltaba ───────────────────────────────────
      case _UnityAction.save:
        return NavigationIntent(
          type: IntentType.navigate,
          target: '__unity:save_session',
          priority: 5,
          suggestedResponse: 'Guardando sesión',
        );  // ← ';' que faltaba en v7.1

      case _UnityAction.introduce:
        return NavigationIntent(
          type: IntentType.navigate,
          target: '__unity:introduce_compas',
          priority: 4,
          suggestedResponse: 'Presentando COMPAS',
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

  // ─── Helper mutación ─────────────────────────────────────────────────────

  void _notifyMutationIfNeeded(_UnityAction action) {
    if (_waypointMutationActions.contains(action)) {
      _logger.d('[Mutation] Recargando destinos por: $action (offline)');
      onWaypointMutation?.call();
    }
  }

  // ─── Utilidades ──────────────────────────────────────────────────────────

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
    _pendingSuggestion = null;
    _logger.d('Historial limpiado');
  }

  List<ChatMessage> get conversationHistory =>
      List.unmodifiable(_conversationHistory);

  Map<String, dynamic> getStatistics() => {
    'is_initialized':           _isInitialized,
    'conversation_length':      _conversationHistory.length,
    'can_use_groq':             _aiModeController.canUseGroq(),
    'has_internet':             _aiModeController.hasInternet,
    'ai_mode':                  _aiModeController.currentMode.name,
    'destinations_in_context':  _waypointContext.count,
    'destinations_last_update': _waypointContext.lastUpdate?.toIso8601String(),
    'pending_suggestion':       _pendingSuggestion,
    'has_mutation_callback':    onWaypointMutation != null,
  };

  bool get isInitialized => _isInitialized;
  bool get canUseGroq    => _aiModeController.canUseGroq();

  void dispose() {
    _conversationHistory.clear();
    _pendingSuggestion = null;
    onWaypointMutation = null;
    _groqService.dispose();
  }
}