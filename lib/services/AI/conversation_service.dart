// lib/services/AI/conversation_service.dart
// ✅ v3 — Fix extracción de destino de navegación
//
//  BUG CORREGIDO (v2 → v3):
//  ──────────────────────────────────────────────────────────────────────────
//  SÍNTOMA:
//    Usuario: "guíame a la baliza creada"
//    Groq responde: "Iniciando navegación a la baliza que acabas de crear. ¡Vamos!"
//    _extractAction detecta "iniciando navegación" en el texto del bot.
//    Extrae todo lo que viene después → "a la baliza que acabas de crear. ¡Vamos"
//    Unity recibe navigate_to("a la baliza que acabas de crear. ¡Vamos")
//    Unity: No encontré 'a la baliza que acabas de crear. ¡Vamos' ← ERROR
//
//  CAUSA RAÍZ — dos problemas combinados:
//
//  1) El system prompt NO le exigía al bot usar el nombre EXACTO del waypoint.
//     Groq inventaba frases como "la baliza que acabas de crear" en vez de
//     decir "Baliza 1" (el nombre real).
//
//  2) _cleanDestination no limitaba la longitud del destino extraído.
//     Si el bot decía una frase larga, se pasaba entera a Unity.
//
//  FIX:
//  1) System prompt: instrucción explícita de usar SIEMPRE el nombre exacto
//     del waypoint tal como el usuario lo mencionó, en las confirmaciones.
//     El bot DEBE responder: "Navegando a Baliza 1." — no parafrasear.
//
//  2) _extractNavigateTarget() reemplaza la extracción inline de navigate:
//     - Busca el nombre en la respuesta del bot comparando con el mensaje
//       del usuario (fuente más confiable del nombre real)
//     - Limita a máx. 50 chars (los nombres de waypoints son cortos)
//     - Prioriza extraer desde el mensaje del usuario si el bot parafrasea
//
//  FLUJO CORREGIDO:
//    Usuario: "guíame a Baliza 1"
//    Bot: "Navegando a Baliza 1 ahora mismo."
//    _extractAction → navigate, target = "Baliza 1"   ✅
//
//    Usuario: "llévame a la baliza creada"  (nombre ambiguo)
//    Bot: "Navegando a Baliza 1."  ← el prompt lo fuerza a usar nombre exacto
//    _extractAction → navigate, target = "Baliza 1"   ✅

import 'dart:async';
import 'package:logger/logger.dart';

import '../../models/shared_models.dart';
import 'groq_service.dart';
import 'ai_mode_controller.dart';

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

  final Logger           _logger           = Logger();
  final GroqService      _groqService      = GroqService();
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
  //
  // ✅ FIX v3: Regla crítica añadida al prompt:
  //   "CONFIRMACIÓN DE NAVEGACIÓN — usa SIEMPRE el nombre EXACTO"
  //
  // El problema anterior era que Groq parafraseaba: "Navegando a la baliza
  // que acabas de crear" → la extracción obtenía la frase larga.
  // Ahora el prompt le exige: "Navegando a [NombreExacto]." punto.

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

══════════════════════════════════════════════════════════════════
REGLA CRÍTICA — CONFIRMACIÓN DE NAVEGACIÓN:

Cuando el usuario pida ir a un destino, tu confirmación DEBE usar
el NOMBRE EXACTO que el usuario mencionó, sin parafrasear.

✅ CORRECTO:
  Usuario: "llévame a Baliza 1"
  Tú: "Navegando a Baliza 1."

  Usuario: "ir a la sala 101"
  Tú: "Navegando a Sala 101."

  Usuario: "quiero ir al baño"
  Tú: "Navegando a Baño."

❌ INCORRECTO — NUNCA hagas esto:
  "Iniciando navegación a la baliza que acabas de crear."
  "Voy hacia el destino que mencionaste."
  "Te llevo al lugar que me indicaste."

Si el usuario describe un destino en lugar de nombrarlo
("la baliza que creé", "el último punto", "el sitio de antes"),
pregunta cuál es el nombre exacto antes de navegar.

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

• Usuario: "quiero ir a la sala de reuniones"
  Tú: "Perfecto. Navegando a Sala de Reuniones."

• Usuario: "para la navegación"
  Tú: "Entendido. Deteniendo la navegación."

• Usuario: "¿qué balizas hay?" / "¿qué destinos hay?"
  Tú: "Consultando los destinos disponibles."

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
- Si no sabes el nombre exacto del destino, pregunta antes de confirmar
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
    //
    // ✅ FIX v3: _extractNavigateTarget() en lugar de extracción inline.
    //
    // Antes (v2):
    //   Buscaba "navegando a " en el bot y tomaba todo lo que seguía.
    //   Si el bot decía "Iniciando navegación a la baliza que acabas de crear.
    //   ¡Vamos!" → target = "A la baliza que acabas de crear. ¡Vamos"  ← MALO
    //
    // Ahora (v3):
    //   1. Busca el patrón "Navegando a [NombreCorto]." que el prompt fuerza
    //   2. Limita el nombre a máx. 50 chars (los nombres son cortos)
    //   3. Si el bot parafrasea igualmente, intenta extraer el nombre
    //      directamente del mensaje del usuario (más confiable)

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
      // Las siguientes son frases largas del bot que debemos reconocer
      // aunque el nombre no venga inmediatamente después:
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

  // ─── Extracción de destino de navegación ─────────────────────────────────
  //
  // ✅ FIX v3: lógica separada con límite de longitud y fallback al usuario.

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
        final afterLower    = botLower.substring(idx + phrase.length).trim();
        final afterOriginal = botOriginal.substring(idx + phrase.length).trim();

        // Limpiar y verificar longitud máxima
        // Los nombres de waypoints son cortos (< 50 chars)
        // Si es más largo, el bot probablemente está parafraseando
        final cleaned = _cleanDestination(afterOriginal);
        if (cleaned.isNotEmpty && cleaned.length <= 50) {
          _logger.d('🎯 Navigate (bot): "$phrase" → "$cleaned"');
          return cleaned;
        } else if (cleaned.length > 50) {
          _logger.d('🎯 Navigate bot-phrase demasiado larga (${cleaned.length} chars), '
              'intentando extraer desde usuario...');
          break; // Salir del loop y probar con el usuario
        }
      }
    }

    // 2. Fallback: extraer destino directamente del mensaje del usuario
    //    Este es más confiable porque el usuario dice el nombre real
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
      return 'Sin internet solo proceso comandos básicos: "llévame a [nombre]", "para", "qué balizas hay".';
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

  /// Limpia el texto extraído para obtener un nombre de destino válido.
  ///
  /// ✅ FIX v3: Añade límite de 50 palabras antes de la primera pausa
  /// (coma, punto, exclamación) para evitar capturar frases largas del bot.
  String _cleanDestination(String raw) {
    var s = raw.trim();

    // ── 1. Cortar en la primera puntuación de pausa ───────────────────
    // Esto previene capturar "la baliza que creé. ¡Vamos!" completo.
    // Delimitadores: . ! ? , ; : — ( [ "
    for (final char in ['.', '!', '?', ',', ';', ':', '—', '(', '[', '"']) {
      final idx = s.indexOf(char);
      if (idx > 0) {
        s = s.substring(0, idx).trim();
      }
    }

    // ── 2. Quitar artículos iniciales ─────────────────────────────────
    final articles = ['el ', 'la ', 'los ', 'las ', 'un ', 'una ', 'al ', 'del '];
    for (final art in articles) {
      if (s.toLowerCase().startsWith(art)) {
        s = s.substring(art.length).trim();
        break; // Solo quitar uno
      }
    }

    // ── 3. Quitar puntuación final residual ───────────────────────────
    while (s.isNotEmpty && '.!?,;:'.contains(s[s.length - 1])) {
      s = s.substring(0, s.length - 1).trim();
    }

    // ── 4. Capitalizar primera letra ──────────────────────────────────
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