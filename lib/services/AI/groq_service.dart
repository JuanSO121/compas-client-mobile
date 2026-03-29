// lib/services/AI/groq_service.dart
// ✅ v2 — Integrado con ConversationService v5 + NavigationContext para TTS
//
// ============================================================================
//  CAMBIOS v1 → v2
// ============================================================================
//
//  CAMBIO 1 — NavigationContext: nuevo parámetro opcional en chat()
//    ConversationService puede pasar el estado de navegación para que
//    el LLM responda "¿cuánto falta?" con datos reales de Unity.
//
//  CAMBIO 2 — maxTokens: 500 → 120 por defecto
//    Respuestas TTS: máximo 2 oraciones. 120 tokens es suficiente y reduce
//    latencia (~300ms menos por llamada).
//
//  CAMBIO 3 — temperature: 0.7 → 0.6
//    Más consistente para asistente de navegación, sin perder naturalidad.
//
//  CAMBIO 4 — Historial: 10 → 6 mensajes
//    Para navegación indoor el contexto relevante es reciente.
//    Reduce tokens y latencia sin perder coherencia.
//
//  CAMBIO 5 — Prompt conversacional reescrito para biblioteca universitaria
//    Personalidad cálida, empática, con reglas explícitas de formato TTS.
//    Sin markdown, sin listas, máximo 2 oraciones.
//
//  CAMBIO 6 — Labels del clasificador alineados con ConversationService v5
//    START_NAVIGATION, STOP, REPEAT, STATUS, HELP
//    (se mantienen legacy MOVE/TURN en thresholds por retrocompatibilidad)
//
//  COMPATIBILIDAD TOTAL con ConversationService v5:
//    - chat() acepta systemPrompt (ConversationService v5 lo pasa siempre)
//    - Cuando systemPrompt viene de ConversationService, navigationContext
//      es ignorado (ConversationService ya incluye el contexto en su prompt)
//    - NavigationContext solo aplica cuando GroqService genera su propio prompt

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';

import '../../config/api_config.dart';
import '../../models/shared_models.dart';

enum GroqMode {
  command,
  conversation,
}

/// Estado de navegación para enriquecer el prompt conversacional.
/// ConversationService lo construye con datos de VoiceStatusInfo de Unity.
class NavigationContext {
  final bool   isNavigating;
  final String destination;
  final double remainingMeters;
  final int    remainingSteps;
  final String nextInstruction;

  const NavigationContext({
    this.isNavigating    = false,
    this.destination     = '',
    this.remainingMeters = 0,
    this.remainingSteps  = 0,
    this.nextInstruction = '',
  });

  String toPromptString() {
    if (!isNavigating) return 'Sin navegación activa.';
    final sb = StringBuffer();
    if (destination.isNotEmpty)     sb.write('Destino: "$destination". ');
    if (remainingSteps > 0)         sb.write('Pasos restantes: $remainingSteps. ');
    if (nextInstruction.isNotEmpty) sb.write('Próxima indicación: $nextInstruction.');
    final result = sb.toString().trim();
    return result.isEmpty ? 'Navegación en curso.' : result;
  }
}

class GroqService {
  static final GroqService _instance = GroqService._internal();
  factory GroqService() => _instance;
  GroqService._internal();

  final Logger _logger = Logger();

  bool _isInitialized     = false;
  int  _commandCalls      = 0;
  int  _conversationCalls = 0;
  int  _errorCount        = 0;
  int  _consecutiveErrors = 0;

  final Map<String, GroqCommandResponse> _responseCache = {};
  late http.Client _httpClient;

  Future<void> initialize() async {
    if (_isInitialized) { _logger.w('Groq Service ya inicializado'); return; }
    if (ApiConfig.groqApiKey.isEmpty) throw Exception('GROQ_API_KEY no configurado');

    _httpClient        = http.Client();
    _isInitialized     = true;
    _consecutiveErrors = 0;
    _logger.i('✅ Groq Service v2 inicializado');
  }

  // ─── Clasificador ─────────────────────────────────────────────────────────

  Future<GroqCommandResponse> classifyCommand(String text) async {
    if (!_isInitialized) throw StateError('Groq Service no inicializado');

    _commandCalls++;
    final sw = Stopwatch()..start();

    try {
      final key = text.toLowerCase().trim();
      if (_responseCache.containsKey(key)) {
        _logger.d('💾 Cache hit: "$text"');
        return _responseCache[key]!;
      }

      final response = await _makeGroqRequest(
        text: text, mode: GroqMode.command,
        maxTokens: 80, temperature: 0.1,
      );

      sw.stop();
      _responseCache[key] = response;
      if (_responseCache.length > 50) _responseCache.clear();
      _consecutiveErrors = 0;

      _logger.i('[GROQ-CMD] "$text" → ${response.label} '
          '(${(response.confidence * 100).toStringAsFixed(1)}%) [${sw.elapsedMilliseconds}ms]');

      return response;

    } on TimeoutException {
      _errorCount++; _consecutiveErrors++;
      _logger.e('⏱️ Groq timeout (#$_consecutiveErrors)');
      throw Exception('Groq timeout');
    } catch (e) {
      _errorCount++; _consecutiveErrors++;
      _logger.e('❌ Error clasificando (#$_consecutiveErrors): $e');
      rethrow;
    }
  }

  // ─── Conversación ─────────────────────────────────────────────────────────

  /// [systemPrompt] — ConversationService v5 siempre lo pasa con su propio
  /// prompt que incluye waypoints disponibles. Se respeta sin modificaciones.
  ///
  /// [navigationContext] — solo aplica cuando NO se pasa systemPrompt.
  /// Permite responder "¿cuánto falta?" con datos reales de Unity.
  ///
  /// [maxTokens] — 120 por defecto (respuestas TTS cortas).
  Future<GroqConversationResponse> chat(
    String message, {
    List<ChatMessage>?  history,
    int                 maxTokens         = 120,
    String?             systemPrompt,
    NavigationContext?  navigationContext,
  }) async {
    if (!_isInitialized) throw StateError('Groq Service no inicializado');

    _conversationCalls++;
    final sw = Stopwatch()..start();

    try {
      final messages = _buildMessages(
        message, history,
        systemPrompt: systemPrompt,
        navigationContext: navigationContext,
      );

      final response = await _httpClient.post(
        Uri.parse('${ApiConfig.groqBaseUrl}/chat/completions'),
        headers: ApiConfig.groqHeaders,
        body: jsonEncode({
          'model':       ApiConfig.groqConversationModel,
          'messages':    messages,
          'temperature': 0.6,
          'max_tokens':  maxTokens,
          'stream':      false,
          'top_p':       0.9,
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw Exception('Groq API error: ${response.statusCode} - ${response.body}');
      }

      final data    = jsonDecode(response.body);
      final content = data['choices'][0]['message']['content'] as String;
      final usage   = data['usage'];

      sw.stop();
      _consecutiveErrors = 0;

      final preview = content.length > 60 ? '${content.substring(0, 60)}...' : content;
      _logger.i('[GROQ-CHAT] $preview [${sw.elapsedMilliseconds}ms]');

      return GroqConversationResponse(
        content:          content.trim(),
        tokensUsed:       usage['total_tokens']      as int,
        completionTokens: usage['completion_tokens'] as int,
        promptTokens:     usage['prompt_tokens']     as int,
        responseTimeMs:   sw.elapsedMilliseconds,
      );

    } on TimeoutException {
      _errorCount++; _consecutiveErrors++;
      _logger.e('⏱️ Groq chat timeout (#$_consecutiveErrors)');
      throw Exception('Groq timeout');
    } catch (e) {
      _errorCount++; _consecutiveErrors++;
      _logger.e('❌ Error conversación (#$_consecutiveErrors): $e');
      rethrow;
    }
  }

  // ─── Internals ────────────────────────────────────────────────────────────

  Future<GroqCommandResponse> _makeGroqRequest({
    required String text, required GroqMode mode,
    int maxTokens = 80, double temperature = 0.1,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('${ApiConfig.groqBaseUrl}/chat/completions'),
      headers: ApiConfig.groqHeaders,
      body: jsonEncode({
        'model':       ApiConfig.groqCommandModel,
        'messages': [
          {'role': 'system', 'content': _commandPrompt()},
          {'role': 'user',   'content': text},
        ],
        'temperature': temperature,
        'max_tokens':  maxTokens,
        'stream':      false,
        'top_p':       0.95,
      }),
    ).timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException('Groq timeout 5s'),
    );

    if (response.statusCode != 200) {
      throw Exception('Groq API error: ${response.statusCode}');
    }

    final content = jsonDecode(response.body)['choices'][0]['message']['content'] as String;
    return _parse(content);
  }

  List<Map<String, String>> _buildMessages(
    String message, List<ChatMessage>? history, {
    String? systemPrompt, NavigationContext? navigationContext,
  }) {
    final msgs = <Map<String, String>>[];

    msgs.add({
      'role':    'system',
      'content': systemPrompt ?? _conversationPrompt(ctx: navigationContext),
    });

    // ✅ v2: máximo 6 mensajes de historial (era 10)
    if (history != null && history.isNotEmpty) {
      final recent = history.length > 6
          ? history.sublist(history.length - 6)
          : history;
      for (final m in recent) {
        msgs.add({'role': m.role, 'content': m.content});
      }
    }

    msgs.add({'role': 'user', 'content': message});
    return msgs;
  }

  // ─── Prompts ──────────────────────────────────────────────────────────────

  String _commandPrompt() => '''Eres el clasificador de intenciones de COMPAS, asistente de navegación en una biblioteca universitaria.

LABELS (solo estos 5):
- START_NAVIGATION: el usuario quiere ir a un lugar o preguntar dónde está algo
  Ej: "llévame a la sala de estudio", "¿dónde están los baños?", "quiero ir a recepción"
- STOP: detener la navegación actual
  Ej: "para", "detente", "cancela", "alto", "no quiero ir"
- REPEAT: volver a escuchar la última instrucción
  Ej: "repite", "¿qué dijiste?", "no escuché", "otra vez"
- STATUS: preguntar por el progreso de la navegación
  Ej: "¿cuánto falta?", "¿ya casi llegamos?", "¿dónde estoy?", "¿cuántos pasos?"
- HELP: ayuda general, saludos, preguntas generales, o comando no reconocido
  Ej: "hola", "ayuda", "¿qué puedes hacer?", cualquier pregunta general

REGLAS:
1. Si menciona un lugar o destino → START_NAVIGATION siempre
2. Si pregunta por progreso durante navegación → STATUS
3. Todo lo que no sea claramente STOP o REPEAT → HELP
4. Responde SOLO con JSON

FORMATO: {"label":"LABEL","confidence":0.XX}''';

  /// Prompt por defecto de COMPAS — solo se usa cuando ConversationService
  /// NO pasa su propio systemPrompt (caso poco frecuente en producción).
  String _conversationPrompt({NavigationContext? ctx}) {
    final navInfo = ctx?.toPromptString() ?? 'Sin navegación activa.';

    return '''Eres COMPAS, asistente de navegación de la biblioteca universitaria. Ayudas a estudiantes, visitantes y personas con discapacidad visual a moverse por el edificio.

PERSONALIDAD:
- Cálido, paciente y empático
- Claro y directo — el usuario escucha tus respuestas en voz alta
- Máximo 2 oraciones cortas por respuesta
- Si no entiendes algo, lo dices con amabilidad y ofreces una alternativa

ESTADO ACTUAL:
$navInfo

CAPACIDADES:
Guiar a cualquier lugar, repetir la última instrucción, informar cuánto falta, detener la navegación.

REGLAS DE FORMATO (obligatorias):
- Sin listas, sin guiones, sin asteriscos, sin emojis
- Español natural y conversacional
- Máximo 2 oraciones

EJEMPLOS:
"hola" → "Hola, soy COMPAS. ¿A dónde quieres ir?"
"¿qué puedes hacer?" → "Puedo guiarte a cualquier lugar de la biblioteca. Solo dime a dónde quieres ir."
"no escuché" → "No hay problema, di 'repite' y te vuelvo a dar la indicación."
"me perdí" → "Tranquilo, estoy aquí. Dime a dónde querías ir y te guío desde donde estás."''';
  }

  // ─── Parsing ──────────────────────────────────────────────────────────────

  GroqCommandResponse _parse(String content) {
    try {
      final clean = content.replaceAll('```json', '').replaceAll('```', '').trim();
      final json  = jsonDecode(clean);
      final label = json['label'] as String;
      final conf  = (json['confidence'] as num).toDouble();

      const thresholds = {
        'START_NAVIGATION': 0.70,
        'STOP':             0.65,
        'REPEAT':           0.60,
        'STATUS':           0.65,
        'HELP':             0.50,
        'MOVE':             0.65,
        'TURN_LEFT':        0.60,
        'TURN_RIGHT':       0.60,
      };

      final threshold = thresholds[label] ?? 0.50;
      return GroqCommandResponse(
        label: label, confidence: conf,
        passesThreshold: conf >= threshold,
        threshold: threshold, rawResponse: content,
      );

    } catch (e) {
      _logger.e('Error parseando Groq: $e — raw: $content');
      return _fallback(content);
    }
  }

  GroqCommandResponse _fallback(String content) {
    final l = content.toLowerCase();
    if (l.contains('start_navigation') || l.contains('navigation')) {
      return GroqCommandResponse(label: 'START_NAVIGATION', confidence: 0.70,
          passesThreshold: true, threshold: 0.70, rawResponse: content);
    }
    if (l.contains('stop') || l.contains('para')) {
      return GroqCommandResponse(label: 'STOP', confidence: 0.70,
          passesThreshold: true, threshold: 0.65, rawResponse: content);
    }
    if (l.contains('repeat') || l.contains('repite')) {
      return GroqCommandResponse(label: 'REPEAT', confidence: 0.70,
          passesThreshold: true, threshold: 0.60, rawResponse: content);
    }
    if (l.contains('status') || l.contains('falta')) {
      return GroqCommandResponse(label: 'STATUS', confidence: 0.70,
          passesThreshold: true, threshold: 0.65, rawResponse: content);
    }
    return GroqCommandResponse(label: 'HELP', confidence: 0.60,
        passesThreshold: true, threshold: 0.50, rawResponse: content);
  }

  // ─── Utils ────────────────────────────────────────────────────────────────

  bool get isHealthy => _consecutiveErrors < 3;

  void resetErrors() {
    _consecutiveErrors = 0; _errorCount = 0;
    _logger.i('Errores reseteados');
  }

  void clearCache() { _responseCache.clear(); _logger.d('Cache limpiado'); }

  Map<String, dynamic> getStatistics() => {
    'is_initialized':     _isInitialized,
    'command_calls':      _commandCalls,
    'conversation_calls': _conversationCalls,
    'error_count':        _errorCount,
    'consecutive_errors': _consecutiveErrors,
    'cache_size':         _responseCache.length,
    'total_calls':        _commandCalls + _conversationCalls,
    'is_healthy':         isHealthy,
  };

  void dispose() {
    _responseCache.clear();
    _httpClient.close();
    _isInitialized = false;
    _logger.i('GroqService disposed');
  }
}

// ─── Modelos ──────────────────────────────────────────────────────────────

class GroqCommandResponse {
  final String label;
  final double confidence;
  final bool   passesThreshold;
  final double threshold;
  final String rawResponse;

  const GroqCommandResponse({
    required this.label,
    required this.confidence,
    required this.passesThreshold,
    required this.threshold,
    required this.rawResponse,
  });

  VoiceCommandResult toVoiceCommandResult() => VoiceCommandResult(
    label: label, confidence: confidence,
    passesThreshold: passesThreshold,
    threshold: threshold, inferenceTimeMs: 0, logits: [],
  );
}

class GroqConversationResponse {
  final String content;
  final int    tokensUsed;
  final int    completionTokens;
  final int    promptTokens;
  final int    responseTimeMs;

  const GroqConversationResponse({
    required this.content,
    required this.tokensUsed,
    required this.completionTokens,
    required this.promptTokens,
    required this.responseTimeMs,
  });
}

class ChatMessage {
  final String   role;
  final String   content;
  final DateTime timestamp;

  ChatMessage({
    required this.role,
    required this.content,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}