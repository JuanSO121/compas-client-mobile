// lib/services/AI/conversation_service.dart
// ✅ v2 — Chatbot conversacional para navegación INDOOR por waypoints con nombre.
//
//  CAMBIO PRINCIPAL respecto a v1:
//    v1 mapeaba a direcciones físicas (forward/left/right) → inútil para Unity AR.
//    v2 extrae NOMBRES DE DESTINO ("Sala 101", "Baño", "Salida") y los pasa
//    como intent.target para que VoiceCommandAPI.NavigateTo(name) los busque
//    en WaypointManager.SearchWaypointsByName().
//
//  FLUJO:
//    Usuario dice  → "llévame al baño"
//    Groq responde → "¡Claro! Iniciando navegación al Baño."
//    _extractIntent → NavigationIntent(type=navigate, target="Baño")
//    NavigationCoordinator.onCommandExecuted → UnityBridge.handleIntent(intent)
//    Unity → VoiceCommandAPI.NavigateTo("Baño") → WaypointManager.SearchWaypointsByName
//
//  COMANDOS DETECTADOS:
//    navigate  → "llévame a X", "ir a X", "navegar a X", "dónde queda X"
//    stop      → "para", "detente", "cancela la navegación"
//    list      → "qué balizas hay", "cuáles son los destinos", "qué lugares conoces"
//    create    → "crea una baliza aquí llamada X", "marca este punto como X"
//    remove    → "elimina la baliza X", "borra el punto X"
//    save      → "guarda la sesión", "guarda los cambios"
//    load      → "carga la sesión", "restaura la sesión"

import 'dart:async';
import 'package:logger/logger.dart';

import '../../models/shared_models.dart';
import 'groq_service.dart';
import 'ai_mode_controller.dart';

// ─── Tipos de respuesta ───────────────────────────────────────────────────────

enum ResponseType {
  pureConversation,       // Solo chat, sin acción Unity
  conversationWithIntent, // Chat + acción Unity
  offlineCommand,         // Sin internet, comando básico detectado localmente
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

// ─── Intent types extendidos ──────────────────────────────────────────────────
// Los IntentType básicos de shared_models cubren navigate y stop.
// Para list/create/remove/save/load usamos una extensión interna
// que se mapea a UnityBridgeService directamente.

enum _UnityAction { navigate, stop, list, create, remove, save, load, none }

// ─── Servicio principal ───────────────────────────────────────────────────────

class ConversationService {
  static final ConversationService _instance = ConversationService._internal();
  factory ConversationService() => _instance;
  ConversationService._internal();

  final Logger          _logger         = Logger();
  final GroqService     _groqService    = GroqService();
  final AIModeController _aiModeController = AIModeController();

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
        systemPrompt: _buildSystemPrompt(),
      );

      _addToHistory('assistant', response.content);

      final (action, target) = _extractAction(response.content, userMessage);

      if (action != _UnityAction.none) {
        final intent = _buildIntent(action, target);
        if (intent != null) {
          _logger.i('💬🎯 Intent: $action → "$target"');
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

  // ─── System prompt ───────────────────────────────────────────────────────

  String _buildSystemPrompt() {
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

EJEMPLOS DE RESPUESTA CON NAVEGACIÓN:

• Usuario: "llévame al baño"
  Tú: "¡Claro! Iniciando navegación al Baño ahora."

• Usuario: "quiero ir a la sala de reuniones"
  Tú: "Perfecto, voy a navegar hacia la Sala de Reuniones."

• Usuario: "para la navegación"
  Tú: "Entendido, deteniendo la navegación."

• Usuario: "¿qué lugares conoces?" / "¿cuáles son las balizas?"
  Tú: "Voy a consultar los destinos disponibles para ti."

• Usuario: "guarda esto como punto de partida"
  Tú: "Creando una baliza en esta posición llamada Punto de Partida."

• Usuario: "elimina la baliza entrada"
  Tú: "Eliminando la baliza Entrada."

• Usuario: "guarda la sesión"
  Tú: "Guardando la sesión actual con todas las balizas."

• Usuario: "carga la sesión guardada"
  Tú: "Cargando la sesión guardada."

EJEMPLOS SIN NAVEGACIÓN:

• Usuario: "hola, ¿cómo estás?"
  Tú: "¡Hola! Estoy listo para ayudarte a moverte. ¿A dónde quieres ir?"

• Usuario: "¿qué puedes hacer?"
  Tú: "Puedo guiarte por el edificio a cualquier destino que tengas marcado, y también conversar. ¿A dónde quieres ir primero?"

REGLAS IMPORTANTES:
- Si el usuario pide ir a algún lugar, SIEMPRE confirma con frases como "navegando a X", "voy hacia X", "iniciando ruta a X"
- NO inventes nombres de balizas — usa el nombre exacto que mencione el usuario
- NO uses listas con viñetas en respuestas conversacionales
- Adapta el tono al usuario''';
  }

  // ─── Extracción de acción ────────────────────────────────────────────────

  /// Analiza la respuesta del bot + el mensaje del usuario para detectar qué
  /// acción ejecutar en Unity y con qué parámetro.
  ///
  /// Retorna (_UnityAction, target_string).
  (_UnityAction, String) _extractAction(String botResponse, String userMessage) {
    final bot  = botResponse.toLowerCase();
    final user = userMessage.toLowerCase();

    // ── STOP ─────────────────────────────────────────────────────────────
    final stopPhrases = [
      'deteniendo la navegación', 'cancelo la navegación', 'me detengo',
      'listo, me detengo', 'para aquí', 'navegación detenida',
    ];
    final stopUser = ['para', 'detente', 'cancela', 'alto', 'stop', 'frena'];
    if (_matchesAny(bot, stopPhrases) || _matchesAny(user, stopUser)) {
      return (_UnityAction.stop, '');
    }

    // ── LIST ──────────────────────────────────────────────────────────────
    final listPhrases = [
      'consultar los destinos', 'consulto los destinos',
      'voy a mostrarte los destinos', 'destinos disponibles',
      'ver las balizas', 'listar balizas',
    ];
    final listUser = [
      'qué balizas', 'cuáles balizas', 'qué destinos', 'cuáles destinos',
      'qué lugares', 'cuáles lugares', 'muéstrame los destinos',
      'qué puntos', 'cuáles puntos',
    ];
    if (_matchesAny(bot, listPhrases) || _matchesAny(user, listUser)) {
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
    // "Eliminando la baliza Entrada." → target = "Entrada"
    final removeMatch = _extractAfterKeyword(bot, [
      'eliminando la baliza', 'borrando la baliza',
      'elimino la baliza',    'borro la baliza',
    ]);
    if (removeMatch != null) return (_UnityAction.remove, removeMatch);

    // ── CREATE ────────────────────────────────────────────────────────────
    // "Creando una baliza ... llamada Sala 101." → target = "Sala 101"
    final createMatch = _extractAfterKeyword(bot, [
      'llamada ', 'llamado ', 'con el nombre ', 'con nombre ',
    ]);
    if (createMatch != null && _matchesAny(bot, [
      'creando', 'crear baliza', 'marcando', 'nuevo punto',
    ])) {
      return (_UnityAction.create, createMatch);
    }

    // ── NAVIGATE ─────────────────────────────────────────────────────────
    // Indicadores que el bot confirmó que va a navegar
    final navPhrases = [
      'navegando a ', 'navegando hacia ', 'navego a ', 'navego hacia ',
      'voy a navegar', 'iniciando navegación', 'iniciando ruta',
      'iniciando la ruta', 'voy hacia ', 'te llevo a ',
      'te llevo hacia ', 'me dirijo a ', 'me dirijo hacia ',
    ];

    for (final phrase in navPhrases) {
      final idx = bot.indexOf(phrase);
      if (idx >= 0) {
        final after = botResponse.substring(idx + phrase.length).trim();
        final dest  = _cleanDestination(after);
        if (dest.isNotEmpty) {
          _logger.d('🎯 Navigate detectado: "$phrase" → "$dest"');
          return (_UnityAction.navigate, dest);
        }
      }
    }

    // Fallback: el usuario claramente pidió ir a algún lugar
    // aunque el bot no use las frases exactas
    final navigateUserPhrases = [
      'llévame a ', 'llevame a ', 'ir a ', 'navega a ', 'navegar a ',
      'quiero ir a ', 'quiero ir al ', 'quiero ir a la ',
      'dónde queda ', 'donde queda ', 'muéstrame ', 'mostrame ',
    ];
    for (final phrase in navigateUserPhrases) {
      final idx = user.indexOf(phrase);
      if (idx >= 0) {
        final after = userMessage.substring(idx + phrase.length).trim();
        final dest  = _cleanDestination(after);
        if (dest.isNotEmpty) {
          _logger.d('🎯 Navigate (user fallback): "$phrase" → "$dest"');
          return (_UnityAction.navigate, dest);
        }
      }
    }

    return (_UnityAction.none, '');
  }

  // ─── Modo offline ────────────────────────────────────────────────────────

  Future<ChatbotResponse> _chatOffline(String userMessage) async {
    final user = userMessage.toLowerCase().trim();

    // STOP
    if (_matchesAny(user, ['para', 'detente', 'alto', 'stop', 'cancela'])) {
      return ChatbotResponse(
        type: ResponseType.offlineCommand,
        message: 'Entendido, deteniendo la navegación.',
        intent: _buildIntent(_UnityAction.stop, ''),
        confidence: 0.9,
      );
    }

    // NAVIGATE — extraer destino directo del usuario
    final navPhrases = [
      'llévame a ', 'llevame a ', 'ir a ', 'navega a ',
      'quiero ir a ', 'quiero ir al ', 'quiero ir a la ',
    ];
    for (final phrase in navPhrases) {
      final idx = user.indexOf(phrase);
      if (idx >= 0) {
        final dest = _cleanDestination(userMessage.substring(idx + phrase.length));
        if (dest.isNotEmpty) {
          return ChatbotResponse(
            type: ResponseType.offlineCommand,
            message: 'Navegando a $dest.',
            intent: _buildIntent(_UnityAction.navigate, dest),
            confidence: 0.85,
          );
        }
      }
    }

    // LIST
    if (_matchesAny(user, ['qué balizas', 'cuáles balizas', 'qué destinos', 'qué lugares'])) {
      return ChatbotResponse(
        type: ResponseType.offlineCommand,
        message: 'Consultando destinos disponibles.',
        intent: _buildIntent(_UnityAction.list, ''),
        confidence: 0.85,
      );
    }

    // SAVE / LOAD
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

    // Conversación offline genérica
    return ChatbotResponse(
      type: ResponseType.pureConversation,
      message: _offlineFallback(user),
      confidence: 0.6,
    );
  }

  String _offlineFallback(String user) {
    if (user.contains('hola') || user.contains('hey')) {
      return '¡Hola! Estoy sin conexión, pero puedo llevarte a destinos si me dices el nombre.';
    }
    if (user.contains('cómo estás') || user.contains('como estas')) {
      return 'Estoy bien, aunque sin internet. Dime a dónde quieres ir y lo intento.';
    }
    if (user.contains('qué puedes') || user.contains('que puedes')) {
      return 'Sin internet solo proceso comandos básicos: llévame a [nombre], para, lista de balizas.';
    }
    return 'Sin conexión solo entiendo comandos directos. Ejemplo: "llévame al baño".';
  }

  // ─── Construcción de intents ──────────────────────────────────────────────

  /// Convierte _UnityAction + target → NavigationIntent que el coordinador
  /// pasará a UnityBridgeService.handleIntent().
  ///
  /// Para acciones que no son navigate/stop se usa IntentType.navigate con
  /// un target especial prefijado que UnityBridgeService reconoce directamente.
  /// Esto evita tener que modificar shared_models.dart.
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

    // Para list/create/remove/save/load usamos IntentType.navigate con
    // target prefijado "__unity:action:param" que UnityBridgeService
    // intercepta antes de llamar navigateTo().
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

  // ─── Utilidades ──────────────────────────────────────────────────────────

  bool _matchesAny(String text, List<String> patterns) =>
      patterns.any((p) => text.contains(p));

  /// Extrae el texto que viene después de la primera coincidencia de las keywords.
  String? _extractAfterKeyword(String text, List<String> keywords) {
    for (final kw in keywords) {
      final idx = text.indexOf(kw);
      if (idx >= 0) {
        final after = text.substring(idx + kw.length).trim();
        final cleaned = _cleanDestination(after);
        if (cleaned.isNotEmpty) return cleaned;
      }
    }
    return null;
  }

  /// Limpia el destino extraído: quita puntuación final, artículos iniciales,
  /// espacios extra y capitaliza correctamente.
  String _cleanDestination(String raw) {
    var s = raw.trim();

    // Quitar puntuación final
    while (s.isNotEmpty && '.!?,;:'.contains(s[s.length - 1])) {
      s = s.substring(0, s.length - 1).trim();
    }

    // Quitar artículos iniciales comunes
    final articles = ['el ', 'la ', 'los ', 'las ', 'un ', 'una ', 'al ', 'del '];
    for (final art in articles) {
      if (s.toLowerCase().startsWith(art)) {
        s = s.substring(art.length).trim();
        break;
      }
    }

    // Quitar todo lo que venga después de una coma o punto (aclaraciones del bot)
    final commaIdx = s.indexOf(',');
    if (commaIdx > 0) s = s.substring(0, commaIdx).trim();

    // Capitalizar primera letra
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
  };

  bool get isInitialized => _isInitialized;
  bool get canUseGroq    => _aiModeController.canUseGroq();

  void dispose() {
    _conversationHistory.clear();
    _groqService.dispose();
  }
}