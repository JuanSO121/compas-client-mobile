// lib/services/AI/groq_service.dart
// ✅ SERVICIO GROQ MEJORADO - CONEXIÓN ESTABLE Y ROBUSTA

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';

import '../../config/api_config.dart';
import '../../models/shared_models.dart';

enum GroqMode {
  command,      // Clasificación rápida de comandos
  conversation, // Conversación completa
}

class GroqService {
  static final GroqService _instance = GroqService._internal();
  factory GroqService() => _instance;
  GroqService._internal();

  final Logger _logger = Logger();

  bool _isInitialized = false;
  int _commandCalls = 0;
  int _conversationCalls = 0;
  int _errorCount = 0;
  int _consecutiveErrors = 0;

  // Cache para respuestas similares
  final Map<String, GroqCommandResponse> _responseCache = {};

  // ✅ Cliente HTTP reutilizable
  late http.Client _httpClient;

  Future<void> initialize() async {
    if (_isInitialized) {
      _logger.w('Groq Service ya inicializado');
      return;
    }

    if (ApiConfig.groqApiKey.isEmpty) {
      throw Exception('GROQ_API_KEY no configurado en .env');
    }

    // ✅ Crear cliente HTTP persistente
    _httpClient = http.Client();

    _isInitialized = true;
    _consecutiveErrors = 0;
    _logger.i('✅ Groq Service inicializado');
  }

  /// ✅ CLASIFICAR COMANDO (modo rápido)
  Future<GroqCommandResponse> classifyCommand(String text) async {
    if (!_isInitialized) {
      throw StateError('Groq Service no inicializado');
    }

    _commandCalls++;
    final stopwatch = Stopwatch()..start();

    try {
      // Verificar cache
      final normalizedText = text.toLowerCase().trim();
      if (_responseCache.containsKey(normalizedText)) {
        _logger.d('💾 Cache hit: "$text"');
        return _responseCache[normalizedText]!;
      }

      final response = await _makeGroqRequest(
        text: text,
        mode: GroqMode.command,
        maxTokens: 100,
        temperature: 0.1,
      );

      stopwatch.stop();

      // Guardar en cache
      _responseCache[normalizedText] = response;

      // Limpiar cache si crece mucho
      if (_responseCache.length > 50) {
        _responseCache.clear();
      }

      // ✅ Resetear contador de errores en éxito
      _consecutiveErrors = 0;

      _logger.i('[GROQ-CMD] "$text" → ${response.label} (${(response.confidence * 100).toStringAsFixed(1)}%) [${stopwatch.elapsedMilliseconds}ms]');

      return response;

    } on TimeoutException {
      _errorCount++;
      _consecutiveErrors++;
      _logger.e('⏱️ Groq timeout (error #$_consecutiveErrors)');
      throw Exception('Groq timeout');
    } catch (e) {
      _errorCount++;
      _consecutiveErrors++;
      _logger.e('❌ Error clasificando comando (error #$_consecutiveErrors): $e');
      rethrow;
    }
  }

  /// ✅ CONVERSACIÓN COMPLETA (modo conversacional)
  Future<GroqConversationResponse> chat(
      String message, {
        List<ChatMessage>? history,
        int maxTokens = 500,
        String? systemPrompt, // ✅ NUEVO: Prompt personalizable
      }) async {
    if (!_isInitialized) {
      throw StateError('Groq Service no inicializado');
    }

    _conversationCalls++;
    final stopwatch = Stopwatch()..start();

    try {
      final messages = _buildConversationMessages(
        message,
        history,
        systemPrompt: systemPrompt, // ✅ NUEVO
      );

      final response = await _httpClient.post(
        Uri.parse('${ApiConfig.groqBaseUrl}/chat/completions'),
        headers: ApiConfig.groqHeaders,
        body: jsonEncode({
          'model': ApiConfig.groqConversationModel,
          'messages': messages,
          'temperature': 0.7,
          'max_tokens': maxTokens,
          'stream': false,
          'top_p': 0.9,
        }),
      ).timeout(
        const Duration(seconds: 10),
      );

      if (response.statusCode != 200) {
        _logger.e('Groq API error: ${response.statusCode}');
        _logger.e('Response: ${response.body}');
        throw Exception('Groq API error: ${response.statusCode} - ${response.body}');
      }

      final data = jsonDecode(response.body);
      final content = data['choices'][0]['message']['content'] as String;
      final usage = data['usage'];

      stopwatch.stop();

      // ✅ Resetear contador de errores en éxito
      _consecutiveErrors = 0;

      _logger.i('[GROQ-CHAT] ${content.substring(0, content.length > 50 ? 50 : content.length)}... [${stopwatch.elapsedMilliseconds}ms]');

      return GroqConversationResponse(
        content: content,
        tokensUsed: usage['total_tokens'] as int,
        completionTokens: usage['completion_tokens'] as int,
        promptTokens: usage['prompt_tokens'] as int,
        responseTimeMs: stopwatch.elapsedMilliseconds,
      );

    } on TimeoutException {
      _errorCount++;
      _consecutiveErrors++;
      _logger.e('⏱️ Groq chat timeout (error #$_consecutiveErrors)');
      throw Exception('Groq timeout');
    } catch (e) {
      _errorCount++;
      _consecutiveErrors++;
      _logger.e('❌ Error en conversación (error #$_consecutiveErrors): $e');
      rethrow;
    }
  }

  /// ✅ CORE: Request a Groq API con manejo robusto
  Future<GroqCommandResponse> _makeGroqRequest({
    required String text,
    required GroqMode mode,
    int maxTokens = 100,
    double temperature = 0.1,
  }) async {

    final prompt = mode == GroqMode.command
        ? _buildCommandPrompt(text)
        : _buildConversationPrompt(text);

    try {
      final response = await _httpClient.post(
        Uri.parse('${ApiConfig.groqBaseUrl}/chat/completions'),
        headers: ApiConfig.groqHeaders,
        body: jsonEncode({
          'model': ApiConfig.groqCommandModel,
          'messages': [
            {'role': 'system', 'content': prompt},
            {'role': 'user', 'content': text},
          ],
          'temperature': temperature,
          'max_tokens': maxTokens,
          'stream': false,
          'top_p': 0.95,
        }),
      ).timeout(
        const Duration(seconds: 5), // ✅ 5 segundos para comandos
        onTimeout: () {
          throw TimeoutException('Groq timeout después de 5s');
        },
      );

      if (response.statusCode != 200) {
        _logger.e('Groq API error: ${response.statusCode}');
        _logger.e('Response body: ${response.body}');
        throw Exception('Groq API error: ${response.statusCode} - ${response.body}');
      }

      final data = jsonDecode(response.body);
      final content = data['choices'][0]['message']['content'] as String;

      return _parseCommandResponse(content);

    } on TimeoutException catch (e) {
      _logger.e('Timeout en Groq: $e');
      rethrow;
    } catch (e) {
      _logger.e('Error en request a Groq: $e');
      rethrow;
    }
  }

  /// ✅ Prompt optimizado para comandos (JSON puro)
  String _buildCommandPrompt(String text) {
    return '''Eres un clasificador de comandos de navegación para un robot asistente.

CATEGORÍAS EXACTAS (solo estas 6):
- MOVE: moverse adelante (avanza, muévete, camina, adelante, forward, anda, vamos)
- STOP: detenerse (para, detente, alto, stop, frena, quieto, espera)
- TURN_LEFT: girar izquierda (izquierda, gira a la izquierda, left, zurda, izq)
- TURN_RIGHT: girar derecha (derecha, gira a la derecha, right, diestra, der)
- HELP: ayuda (ayuda, help, auxilio, socorro)
- REPEAT: repetir (repite, otra vez, de nuevo, again)

INSTRUCCIONES:
1. Clasifica el comando en UNA categoría
2. Asigna confianza 0.0-1.0 basado en claridad
3. Responde SOLO con JSON, sin explicaciones
4. Si no encaja en ninguna, usa confianza < 0.5

FORMATO DE RESPUESTA (OBLIGATORIO):
{"label":"CATEGORIA","confidence":0.XX}

Ejemplos:
- "avanza" → {"label":"MOVE","confidence":0.95}
- "para ya" → {"label":"STOP","confidence":0.90}
- "no sé" → {"label":"MOVE","confidence":0.20}''';
  }

  /// ✅ Prompt para conversación natural
  String _buildConversationPrompt(String text) {
    return '''Eres COMPAS, un robot asistente amigable y útil.

Características:
- Hablas español de forma natural y concisa
- Eres útil y empático
- Respondes de forma breve pero completa
- Si te piden ejecutar una acción (mover, girar, etc), confirmas que la ejecutarás

Contexto: El usuario puede tanto conversar contigo como darte comandos de navegación.

Responde de forma natural al mensaje del usuario.''';
  }

  /// ✅ Parsear respuesta JSON de clasificación
  GroqCommandResponse _parseCommandResponse(String content) {
    try {
      // Limpiar respuesta (quitar markdown si existe)
      final jsonText = content
          .replaceAll('```json', '')
          .replaceAll('```', '')
          .trim();

      final json = jsonDecode(jsonText);
      final label = json['label'] as String;
      final confidence = (json['confidence'] as num).toDouble();

      // Thresholds por categoría
      const thresholds = {
        'MOVE': 0.65,
        'STOP': 0.65,
        'TURN_LEFT': 0.60,
        'TURN_RIGHT': 0.60,
        'REPEAT': 0.55,
        'HELP': 0.70,
      };

      final threshold = thresholds[label] ?? 0.50;
      final passesThreshold = confidence >= threshold;

      return GroqCommandResponse(
        label: label,
        confidence: confidence,
        passesThreshold: passesThreshold,
        threshold: threshold,
        rawResponse: content,
      );

    } catch (e) {
      _logger.e('Error parseando respuesta Groq: $e');
      _logger.e('Respuesta raw: $content');

      // Fallback: intentar detectar con keywords
      return _fallbackParsing(content);
    }
  }

  /// ✅ Fallback si JSON falla
  GroqCommandResponse _fallbackParsing(String content) {
    final lower = content.toLowerCase();

    if (lower.contains('move') || lower.contains('avanz')) {
      return GroqCommandResponse(
        label: 'MOVE',
        confidence: 0.70,
        passesThreshold: true,
        threshold: 0.65,
        rawResponse: content,
      );
    }

    if (lower.contains('stop') || lower.contains('para') || lower.contains('det')) {
      return GroqCommandResponse(
        label: 'STOP',
        confidence: 0.75,
        passesThreshold: true,
        threshold: 0.65,
        rawResponse: content,
      );
    }

    return GroqCommandResponse(
      label: 'UNKNOWN',
      confidence: 0.30,
      passesThreshold: false,
      threshold: 0.50,
      rawResponse: content,
    );
  }

  /// ✅ Construir mensajes para conversación con historial
  List<Map<String, String>> _buildConversationMessages(
      String message,
      List<ChatMessage>? history, {
        String? systemPrompt, // ✅ NUEVO
      }) {
    final messages = <Map<String, String>>[];

    // System prompt (personalizado o default)
    messages.add({
      'role': 'system',
      'content': systemPrompt ?? _buildConversationPrompt(message),
    });

    // Historial (limitar a últimos 10 mensajes)
    if (history != null && history.isNotEmpty) {
      final recentHistory = history.length > 10
          ? history.sublist(history.length - 10)
          : history;

      for (var msg in recentHistory) {
        messages.add({
          'role': msg.role,
          'content': msg.content,
        });
      }
    }

    // Mensaje actual
    messages.add({
      'role': 'user',
      'content': message,
    });

    return messages;
  }

  /// ✅ Verificar salud del servicio
  bool get isHealthy => _consecutiveErrors < 3;

  /// ✅ Resetear errores (útil después de reconectar)
  void resetErrors() {
    _consecutiveErrors = 0;
    _errorCount = 0;
    _logger.i('Contador de errores reseteado');
  }

  Map<String, dynamic> getStatistics() {
    return {
      'is_initialized': _isInitialized,
      'command_calls': _commandCalls,
      'conversation_calls': _conversationCalls,
      'error_count': _errorCount,
      'consecutive_errors': _consecutiveErrors,
      'cache_size': _responseCache.length,
      'total_calls': _commandCalls + _conversationCalls,
      'is_healthy': isHealthy,
    };
  }

  void clearCache() {
    _responseCache.clear();
    _logger.d('Cache limpiado');
  }

  void dispose() {
    _responseCache.clear();
    _httpClient.close(); // ✅ Cerrar cliente HTTP
    _isInitialized = false;
    _logger.i('GroqService disposed');
  }
}

// ========== MODELOS DE RESPUESTA ==========

class GroqCommandResponse {
  final String label;
  final double confidence;
  final bool passesThreshold;
  final double threshold;
  final String rawResponse;

  GroqCommandResponse({
    required this.label,
    required this.confidence,
    required this.passesThreshold,
    required this.threshold,
    required this.rawResponse,
  });

  VoiceCommandResult toVoiceCommandResult() {
    return VoiceCommandResult(
      label: label,
      confidence: confidence,
      passesThreshold: passesThreshold,
      threshold: threshold,
      inferenceTimeMs: 0,
      logits: [],
    );
  }
}

class GroqConversationResponse {
  final String content;
  final int tokensUsed;
  final int completionTokens;
  final int promptTokens;
  final int responseTimeMs;

  GroqConversationResponse({
    required this.content,
    required this.tokensUsed,
    required this.completionTokens,
    required this.promptTokens,
    required this.responseTimeMs,
  });
}

class ChatMessage {
  final String role; // 'user' o 'assistant'
  final String content;
  final DateTime timestamp;

  ChatMessage({
    required this.role,
    required this.content,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}