// lib/services/AI/voice_command_classifier.dart
// ✅ CLASIFICADOR CON GROQ + TFLITE FALLBACK

import 'dart:async';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:logger/logger.dart';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'dart:convert';

import '../../models/shared_models.dart';
import '../../config/api_config.dart';
import 'portable_tokenizer.dart';
import 'ai_mode_controller.dart';
import 'groq_service.dart'; // ✅ NUEVO

class VoiceCommandClassifier {
  static final VoiceCommandClassifier _instance = VoiceCommandClassifier._internal();
  factory VoiceCommandClassifier() => _instance;
  VoiceCommandClassifier._internal();

  final Logger _logger = Logger();
  final AIModeController _aiMode = AIModeController();
  final GroqService _groqService = GroqService(); // ✅ NUEVO

  // TFLite (offline)
  Interpreter? _interpreter;
  PortableTokenizer? _tokenizer;
  late int _maxLength;
  late int _numClasses;
  late Map<int, String> _labelMap;

  static const Map<String, double> _confidenceThresholds = {
    'MOVE': 0.65,
    'STOP': 0.65,
    'TURN_LEFT': 0.60,
    'TURN_RIGHT': 0.60,
    'REPEAT': 0.55,
    'HELP': 0.70,
    'UNKNOWN': 0.50,
  };

  bool _isInitialized = false;
  int _inferenceCount = 0;
  int _crashCount = 0;
  int _groqCalls = 0;
  int _tfliteCalls = 0;

  Future<void> initialize() async {
    if (_isInitialized) {
      _logger.w('Clasificador ya inicializado');
      return;
    }

    try {
      _logger.i('Inicializando Voice Command Classifier...');

      // 1. Inicializar AI Mode Controller
      await _aiMode.initialize();

      // 2. Inicializar Groq (si disponible)
      if (_aiMode.groqAvailable) { // Nota: reutilizamos la misma lógica
        try {
          await _groqService.initialize();
          _logger.i('✅ Groq inicializado');
        } catch (e) {
          _logger.w('⚠️ Groq no disponible: $e');
        }
      }

      // 3. Inicializar TFLite (siempre, como fallback)
      try {
        await _loadModelConfig();
        await _loadTFLiteModel();
        await _loadTokenizer();
        await _validateModel();
        _logger.i('✅ TFLite listo como fallback');
      } catch (e) {
        _logger.w('⚠️ TFLite no disponible: $e');
      }

      _isInitialized = true;
      _logger.i('✅ Voice Command Classifier listo');
      _logger.i('   Modo efectivo: ${_aiMode.getModeDescription()}');

    } catch (e) {
      _logger.e('❌ Error inicializando clasificador: $e');
      _isInitialized = false;
      rethrow;
    }
  }

  /// ✅ CLASIFICAR (decide entre Groq o TFLite)
  Future<VoiceCommandResult> classify(String text) async {
    if (!_isInitialized) {
      throw StateError('Clasificador no inicializado');
    }

    if (text.trim().isEmpty) {
      return VoiceCommandResult.empty();
    }

    if (text.length > 200) {
      _logger.w('Texto muy largo (${text.length} chars), truncando...');
      text = text.substring(0, 200);
    }

    final stopwatch = Stopwatch()..start();

    // ✅ Decidir qué método usar
    final shouldUseGroq = _aiMode.canUseGroq(); // Reutilizamos la lógica de Gemini

    if (shouldUseGroq) {
      try {
        final groqResponse = await _groqService.classifyCommand(text);
        final result = groqResponse.toVoiceCommandResult();

        _groqCalls++;
        stopwatch.stop();

        _logger.i('[GROQ] "$text" → ${result.label} (${(result.confidence * 100).toStringAsFixed(1)}%) [${stopwatch.elapsedMilliseconds}ms]');

        return result;

      } catch (e) {
        _logger.e('❌ Groq falló: $e, usando TFLite fallback');
        // Continuar con TFLite
      }
    }

    // Usar TFLite (offline o fallback)
    try {
      final result = await _classifyWithTFLite(text);
      _tfliteCalls++;
      stopwatch.stop();

      _logger.d('[TFLITE] "$text" → ${result.label} (${(result.confidence * 100).toStringAsFixed(1)}%) [${stopwatch.elapsedMilliseconds}ms]');

      return result;

    } catch (e) {
      _logger.e('Error en clasificación: $e');
      return VoiceCommandResult.error(e.toString());
    }
  }

  /// ✅ Clasificar con TFLite (tu código existente)
  Future<VoiceCommandResult> _classifyWithTFLite(String text) async {
    if (_interpreter == null || _tokenizer == null) {
      throw StateError('TFLite no inicializado');
    }

    // Tokenizar
    final inputIds = _tokenizer!.encode(
      text,
      maxLength: _maxLength,
      addSpecial: true,
    );

    if (inputIds.length != _maxLength) {
      throw StateError('Input IDs length inválido: ${inputIds.length} != $_maxLength');
    }

    // Inferencia
    List<double> logits;
    try {
      logits = _runInferenceSafe(inputIds);
    } catch (e) {
      _crashCount++;
      _logger.e('💥 CRASH en inferencia TFLite (#$_crashCount): $e');

      if (_crashCount >= 3) {
        _logger.e('⚠️ Demasiados crashes, deshabilitando TFLite');
        _isInitialized = false;
      }

      throw Exception('Crash en TFLite');
    }

    // Obtener predicción
    final predIdx = _argmax(logits);
    final confidence = logits[predIdx];
    final label = _labelMap[predIdx] ?? 'UNKNOWN';

    final threshold = _confidenceThresholds[label] ?? 0.50;
    final passesThreshold = confidence >= threshold;

    _inferenceCount++;

    return VoiceCommandResult(
      label: label,
      confidence: confidence,
      passesThreshold: passesThreshold,
      threshold: threshold,
      inferenceTimeMs: 0,
      logits: logits,
    );
  }

  // ... [resto del código TFLite sin cambios] ...

  List<double> _runInferenceSafe(List<int> inputIds) {
    if (_interpreter == null) {
      throw StateError('Modelo no cargado');
    }

    try {
      _interpreter!.getInputTensor(0);
    } catch (e) {
      throw StateError('Interpreter corrupto: $e');
    }

    final input = [inputIds];
    final output = List.generate(1, (_) => List.filled(_numClasses, 0.0));

    try {
      _interpreter!.run(input, output);
    } catch (e) {
      throw Exception('TFLite inference failed: $e');
    }

    final logits = output[0];

    if (logits.length != _numClasses) {
      throw StateError('Output length inválido: ${logits.length} != $_numClasses');
    }

    for (var i = 0; i < logits.length; i++) {
      if (logits[i].isNaN || logits[i].isInfinite) {
        throw StateError('Output contiene NaN o Infinity');
      }
    }

    return logits;
  }

  Future<void> _loadModelConfig() async {
    try {
      final configString = await rootBundle.loadString('assets/models/model_config.json');
      final config = jsonDecode(configString);

      _maxLength = config['max_length'] ?? 32;
      _numClasses = config['num_classes'] ?? 7;

      final labelMapRaw = config['reverse_label_map'] as Map<String, dynamic>;
      _labelMap = labelMapRaw.map((key, value) => MapEntry(int.parse(key), value as String));

      _logger.d('Configuración cargada: $_numClasses clases, maxLen=$_maxLength');

    } catch (e) {
      _logger.e('Error cargando configuración: $e');

      _maxLength = 32;
      _numClasses = 7;
      _labelMap = {
        0: 'MOVE',
        1: 'STOP',
        2: 'TURN_LEFT',
        3: 'TURN_RIGHT',
        4: 'REPEAT',
        5: 'HELP',
        6: 'UNKNOWN',
      };

      _logger.w('Usando configuración por defecto');
    }
  }

  Future<void> _loadTFLiteModel() async {
    try {
      _interpreter = await Interpreter.fromAsset(
        'assets/models/voice_command_model.tflite',
        options: InterpreterOptions()
          ..threads = 2
          ..useNnApiForAndroid = false,
      );

      // 🔥 OBTENER TENSORES
      final inputTensor = _interpreter!.getInputTensor(0);
      final outputTensor = _interpreter!.getOutputTensor(0);

      final inputShape = inputTensor.shape;
      final outputShape = outputTensor.shape;

      // 🔥 AGREGAR ESTOS LOGS
      _logger.i('Input shape: $inputShape');
      _logger.i('Input type: ${inputTensor.type}');
      _logger.i('Output shape: $outputShape');
      _logger.i('Output type: ${outputTensor.type}');

      if (inputShape[1] != _maxLength) {
        _logger.w('⚠️ Input shape mismatch: esperado $_maxLength, obtenido ${inputShape[1]}');
        _maxLength = inputShape[1];
      }

      if (outputShape[1] != _numClasses) {
        _logger.w('⚠️ Output shape mismatch: esperado $_numClasses, obtenido ${outputShape[1]}');
        _numClasses = outputShape[1];
      }

      _logger.i('Modelo TFLite cargado');

    } catch (e) {
      _logger.e('Error cargando modelo TFLite: $e');
      rethrow;
    }
  }

  Future<void> _loadTokenizer() async {
    try {
      _tokenizer = PortableTokenizer();
      await _tokenizer!.loadVocab('assets/models/vocab_portable.json');
      _logger.i('Tokenizador cargado: ${_tokenizer!.vocabSize} tokens');
    } catch (e) {
      _logger.e('Error cargando tokenizador: $e');
      rethrow;
    }
  }

  Future<void> _validateModel() async {
    if (_interpreter == null) {
      throw StateError('Intérprete no disponible');
    }

    try {
      final testIds = List.filled(_maxLength, 0);
      final input = [testIds];
      final output = List.generate(1, (_) => List.filled(_numClasses, 0.0));

      _interpreter!.run(input, output);
    } catch (e) {
      throw Exception('Modelo TFLite corrupto: $e');
    }
  }

  int _argmax(List<double> values) {
    double maxValue = values[0];
    int maxIndex = 0;

    for (int i = 1; i < values.length; i++) {
      if (values[i] > maxValue) {
        maxValue = values[i];
        maxIndex = i;
      }
    }

    return maxIndex;
  }

  Map<String, dynamic> getStatistics() {
    return {
      'is_initialized': _isInitialized,
      'inference_count': _inferenceCount,
      'crash_count': _crashCount,
      'groq_calls': _groqCalls,
      'tflite_calls': _tfliteCalls,
      'ai_mode': _aiMode.getStatistics(),
      'groq_stats': _groqService.getStatistics(),
    };
  }

  bool validateChunk(String text, String label) {
    const minChars = {
      'STOP': 3,
      'HELP': 3,
      'MOVE': 4,
      'TURN_LEFT': 3,
      'TURN_RIGHT': 3,
      'REPEAT': 4,
      'UNKNOWN': 0,
    };

    final cleanText = text.trim().toLowerCase();
    final minLength = minChars[label] ?? 0;

    return cleanText.length >= minLength;
  }

  List<ClassPrediction> getTopK(List<double> logits, {int k = 3}) {
    final predictions = <ClassPrediction>[];

    for (int i = 0; i < logits.length; i++) {
      predictions.add(ClassPrediction(
        label: _labelMap[i] ?? 'UNKNOWN',
        confidence: logits[i],
      ));
    }

    predictions.sort((a, b) => b.confidence.compareTo(a.confidence));
    return predictions.take(k).toList();
  }

  void resetCounter() {
    _inferenceCount = 0;
    _crashCount = 0;
    _groqCalls = 0;
    _tfliteCalls = 0;
  }

  bool get isInitialized => _isInitialized;
  int get inferenceCount => _inferenceCount;
  int get crashCount => _crashCount;

  void dispose() {
    try {
      _interpreter?.close();
    } catch (e) {
      _logger.e('Error cerrando interpreter: $e');
    }

    _interpreter = null;
    _tokenizer = null;
    _groqService.dispose();
    _aiMode.dispose();
    _isInitialized = false;
    _logger.i('VoiceCommandClassifier disposed');
  }
}