// lib/services/AI/conversation_service.dart
// ✅ CHATBOT CONVERSACIONAL CON DETECCIÓN DE INTENCIONES DE NAVEGACIÓN
// Prioridad: Conversación > Comandos

import 'dart:async';
import 'package:logger/logger.dart';

import '../../models/shared_models.dart';
import 'groq_service.dart';
import 'ai_mode_controller.dart';

/// Tipo de respuesta del chatbot
enum ResponseType {
  pureConversation,     // Solo chat, sin navegación
  conversationWithIntent, // Chat que incluye intención de navegar
  offlineCommand,       // Sin internet, solo comando básico
}

/// Respuesta completa del chatbot
class ChatbotResponse {
  final ResponseType type;
  final String message;              // Mensaje conversacional completo
  final NavigationIntent? intent;    // Intención de navegación (si existe)
  final double confidence;

  ChatbotResponse({
    required this.type,
    required this.message,
    this.intent,
    this.confidence = 1.0,
  });

  bool get shouldNavigate => intent != null;
  bool get isPureConversation => type == ResponseType.pureConversation;
}

/// Servicio de Chatbot Conversacional
class ConversationService {
  static final ConversationService _instance = ConversationService._internal();
  factory ConversationService() => _instance;
  ConversationService._internal();

  final Logger _logger = Logger();
  final GroqService _groqService = GroqService();
  final AIModeController _aiModeController = AIModeController();

  // Historial de conversación
  final List<ChatMessage> _conversationHistory = [];
  static const int _maxHistoryLength = 20; // Más largo para mejor contexto

  bool _isInitialized = false;

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      await _aiModeController.initialize();

      if (_aiModeController.canUseGroq()) {
        await _groqService.initialize();
        _logger.i('✅ Chatbot inicializado en modo online');
      } else {
        _logger.i('✅ Chatbot inicializado en modo offline');
      }

      _isInitialized = true;
    } catch (e) {
      _logger.e('Error inicializando Chatbot: $e');
      rethrow;
    }
  }

  /// ✅ PROCESAR MENSAJE DEL USUARIO (Chatbot primero)
  Future<ChatbotResponse> chat(String userMessage) async {
    if (!_isInitialized) {
      throw StateError('Chatbot no inicializado');
    }

    try {
      // Agregar mensaje del usuario al historial
      _addToHistory('user', userMessage);

      // Verificar conexión
      await _aiModeController.verifyInternetNow();

      final canUseGroq = _aiModeController.canUseGroq();

      if (canUseGroq) {
        return await _chatWithGroq(userMessage);
      } else {
        return await _chatOffline(userMessage);
      }

    } catch (e) {
      _logger.e('Error en chat: $e');

      // Fallback a offline si falla Groq
      if (_aiModeController.hasInternet) {
        _logger.w('Groq falló, usando modo offline...');
        return await _chatOffline(userMessage);
      }

      rethrow;
    }
  }

  /// ✅ CHAT CON GROQ (Modo Conversacional Inteligente)
  Future<ChatbotResponse> _chatWithGroq(String userMessage) async {
    try {
      // 1. PRIMERO: Dejar que Groq responda conversacionalmente
      //    con sistema especial que detecta intenciones de navegación

      final response = await _groqService.chat(
        userMessage,
        history: _conversationHistory.sublist(
          0,
          _conversationHistory.length > 1 ? _conversationHistory.length - 1 : 0,
        ),
        maxTokens: 400,
        systemPrompt: _buildChatbotSystemPrompt(),
      );

      _addToHistory('assistant', response.content);

      // 2. ANALIZAR la respuesta del chatbot para detectar si mencionó navegación
      final intent = _extractNavigationIntent(response.content, userMessage);

      if (intent != null) {
        _logger.i('💬🎯 Chat con navegación: "${response.content}"');
        _logger.i('   Intención: ${intent.target}');

        return ChatbotResponse(
          type: ResponseType.conversationWithIntent,
          message: response.content,
          intent: intent,
          confidence: 0.95,
        );
      }

      // 3. Solo conversación, sin navegación
      _logger.i('💬 Conversación pura: "${response.content}"');

      return ChatbotResponse(
        type: ResponseType.pureConversation,
        message: response.content,
        confidence: 0.95,
      );

    } catch (e) {
      _logger.e('Error en Groq chat: $e');
      Future.microtask(() => _aiModeController.verifyInternetNow());
      rethrow;
    }
  }

  /// ✅ PROMPT DEL CHATBOT (Conversacional con capacidad de navegación)
  String _buildChatbotSystemPrompt() {
    return '''Eres COMPAS, un robot asistente amigable, empático y conversacional.

PERSONALIDAD:
- Hablas español de forma natural, cálida y cercana
- Eres útil, paciente y educado
- Te gusta conversar y conocer a las personas
- Tienes sentido del humor sutil
- Respondes con empatía y comprensión

CAPACIDADES:
Puedes tanto conversar normalmente como ayudar con navegación física:
- Moverse adelante/atrás
- Girar a la izquierda/derecha
- Detenerte

INSTRUCCIONES DE RESPUESTA:

1. CONVERSACIÓN NORMAL (prioridad):
   - Responde naturalmente a saludos, preguntas, comentarios
   - Haz preguntas de seguimiento cuando sea apropiado
   - Muestra interés genuino en el usuario
   - Ejemplos:
     * Usuario: "Hola, ¿cómo estás?"
       Tú: "¡Hola! Estoy muy bien, gracias por preguntar. ¿Cómo estás tú? ¿En qué puedo ayudarte hoy?"
     * Usuario: "Cuéntame un chiste"
       Tú: "¿Por qué los robots nunca tienen hambre? ¡Porque ya vienen con batería incluida! 😄 ¿Quieres que te cuente otro?"
     * Usuario: "¿Qué puedes hacer?"
       Tú: "¡Me encanta esta pregunta! Puedo conversar contigo sobre lo que quieras, y también ayudarte a navegar. Puedo moverme, girar, explorar lugares. ¿Hay algo específico con lo que quieras que te ayude?"

2. CUANDO PIDEN NAVEGACIÓN:
   - Confirma naturalmente lo que vas a hacer
   - Usa lenguaje conversacional, no robótico
   - Ejemplos:
     * Usuario: "Podrías ir adelante por favor"
       Tú: "¡Claro que sí! Voy adelante ahora mismo. ¿Hay algo específico que quieras que vea?"
     * Usuario: "Gira a la izquierda"
       Tú: "Perfecto, girando a la izquierda. ¿Te ayudo a explorar algo en particular?"
     * Usuario: "Para ahí"
       Tú: "Listo, me detengo aquí. ¿Todo bien?"

3. PREGUNTAS SOBRE TI:
   - Usuario: "¿Quién eres?"
     Tú: "Soy COMPAS, tu robot asistente. Me diseñaron para ser tu compañero de navegación y conversación. ¡Me encanta ayudar y conocer gente nueva!"

IMPORTANTE:
- NO uses formato de lista con viñetas o números en conversaciones casuales
- NO seas excesivamente formal
- SÍ sé natural, cálido y humano
- SÍ adapta tu tono al del usuario
- Las respuestas conversacionales deben ser de 1-3 oraciones normalmente
- Solo respuestas más largas si el usuario hace una pregunta compleja

Contexto del historial: Tienes acceso al historial reciente de la conversación, úsalo para dar respuestas coherentes y con memoria de lo que se ha hablado.''';
  }

  /// ✅ EXTRAER INTENCIÓN DE NAVEGACIÓN de la respuesta del chatbot
  NavigationIntent? _extractNavigationIntent(String botResponse, String userMessage) {
    // Analizar tanto la respuesta del bot como el mensaje del usuario
    final combined = '${userMessage.toLowerCase()} ${botResponse.toLowerCase()}';

    // Patrones que indican CLARAMENTE navegación
    final navigationIndicators = {
      'forward': [
        'voy adelante', 'yendo adelante', 'me muevo adelante',
        'avanzando', 'caminando adelante', 'moviéndome adelante',
        'iré adelante', 'me moveré adelante',
      ],
      'stop': [
        'me detengo', 'deteniéndome', 'parando',
        'me paro', 'listo, me detengo', 'ok, me detengo',
        'me quedo aquí', 'alto',
      ],
      'left': [
        'girando a la izquierda', 'giro a la izquierda',
        'hacia la izquierda', 'volteo a la izquierda',
        'me voy a la izquierda', 'voy a la izquierda',
      ],
      'right': [
        'girando a la derecha', 'giro a la derecha',
        'hacia la derecha', 'volteo a la derecha',
        'me voy a la derecha', 'voy a la derecha',
      ],
    };

    // Detectar intención solo si el bot CONFIRMÓ que va a hacer algo
    for (var entry in navigationIndicators.entries) {
      final direction = entry.key;
      final indicators = entry.value;

      for (var indicator in indicators) {
        if (combined.contains(indicator)) {
          _logger.d('🎯 Navegación detectada: $direction (indicador: "$indicator")');
          return _createNavigationIntent(direction);
        }
      }
    }

    return null; // No hay intención de navegación
  }

  /// Crear intención de navegación
  NavigationIntent _createNavigationIntent(String direction) {
    switch (direction) {
      case 'forward':
        return NavigationIntent(
          type: IntentType.navigate,
          target: 'forward',
          priority: 8,
          suggestedResponse: '', // No usado, el chatbot ya respondió
        );

      case 'stop':
        return NavigationIntent(
          type: IntentType.stop,
          target: '',
          priority: 10,
          suggestedResponse: '',
        );

      case 'left':
        return NavigationIntent(
          type: IntentType.navigate,
          target: 'left',
          priority: 7,
          suggestedResponse: '',
        );

      case 'right':
        return NavigationIntent(
          type: IntentType.navigate,
          target: 'right',
          priority: 7,
          suggestedResponse: '',
        );

      default:
        return NavigationIntent.unknown();
    }
  }

  /// ✅ CHAT OFFLINE (Detección simple de comandos)
  Future<ChatbotResponse> _chatOffline(String userMessage) async {
    final normalized = userMessage.toLowerCase().trim();

    // Primero intentar detectar comandos directos
    final directCommands = {
      'forward': ['adelante', 'avanza', 'mueve', 'camina', 'anda', 'sigue'],
      'stop': ['para', 'pará', 'detente', 'alto', 'stop', 'frena'],
      'left': ['izquierda', 'izq', 'gira izquierda'],
      'right': ['derecha', 'der', 'gira derecha'],
    };

    for (var entry in directCommands.entries) {
      final direction = entry.key;
      final keywords = entry.value;

      for (var keyword in keywords) {
        if (normalized.contains(keyword)) {
          final response = _getOfflineNavigationResponse(direction);
          final intent = _createNavigationIntent(direction);

          return ChatbotResponse(
            type: ResponseType.offlineCommand,
            message: response,
            intent: intent,
            confidence: 0.85,
          );
        }
      }
    }

    // No es comando de navegación -> respuesta conversacional offline
    return ChatbotResponse(
      type: ResponseType.pureConversation,
      message: _getOfflineConversationalResponse(normalized),
      confidence: 0.7,
    );
  }

  String _getOfflineNavigationResponse(String direction) {
    switch (direction) {
      case 'forward': return 'De acuerdo, voy adelante';
      case 'stop': return 'Entendido, me detengo';
      case 'left': return 'Muy bien, girando a la izquierda';
      case 'right': return 'Perfecto, girando a la derecha';
      default: return 'Entendido';
    }
  }

  String _getOfflineConversationalResponse(String message) {
    // Respuestas simples offline
    if (message.contains('hola') || message.contains('hey')) {
      return '¡Hola! Estoy en modo offline, pero puedo ayudarte con navegación básica. ¿Quieres que me mueva?';
    }

    if (message.contains('cómo estás') || message.contains('como estas')) {
      return 'Estoy bien, gracias. Actualmente sin conexión a internet, pero listo para ayudarte a navegar.';
    }

    if (message.contains('qué puedes hacer') || message.contains('que puedes hacer')) {
      return 'Sin internet solo puedo ejecutar comandos básicos: avanzar, detenerme, girar a la izquierda o derecha.';
    }

    return 'Lo siento, estoy sin conexión a internet. Puedo ayudarte con comandos básicos: avanza, detente, gira izquierda, gira derecha.';
  }

  /// Agregar mensaje al historial
  void _addToHistory(String role, String content) {
    _conversationHistory.add(ChatMessage(
      role: role,
      content: content,
    ));

    // Limitar tamaño del historial
    if (_conversationHistory.length > _maxHistoryLength * 2) {
      _conversationHistory.removeRange(0, 2);
    }
  }

  /// Limpiar historial
  void clearHistory() {
    _conversationHistory.clear();
    _logger.d('Historial de conversación limpiado');
  }

  /// Obtener historial
  List<ChatMessage> get conversationHistory => List.unmodifiable(_conversationHistory);

  /// Verificar conexión
  Future<void> verifyConnection() async {
    await _aiModeController.verifyInternetNow();
  }

  /// Estadísticas
  Map<String, dynamic> getStatistics() {
    return {
      'is_initialized': _isInitialized,
      'conversation_length': _conversationHistory.length,
      'can_use_groq': _aiModeController.canUseGroq(),
      'has_internet': _aiModeController.hasInternet,
      'ai_mode': _aiModeController.currentMode.name,
    };
  }

  bool get isInitialized => _isInitialized;
  bool get canUseGroq => _aiModeController.canUseGroq();

  void dispose() {
    _conversationHistory.clear();
    _groqService.dispose();
    _logger.i('ConversationService disposed');
  }
}