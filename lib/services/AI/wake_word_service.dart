// lib/services/AI/wake_word_service.dart
// ✅ WAKE WORD SERVICE - API PORCUPINE ACTUALIZADA
// Soporta palabras clave built-in y personalizadas

import 'package:porcupine_flutter/porcupine.dart';
import 'package:porcupine_flutter/porcupine_manager.dart';
import 'package:porcupine_flutter/porcupine_error.dart';
import 'package:logger/logger.dart';

/// Servicio de detección de wake word con Porcupine
///
/// PALABRAS CLAVE DISPONIBLES (built-in):
/// - 'alexa', 'americano', 'blueberry', 'bumblebee',
/// - 'computer', 'grapefruit', 'grasshopper', 'hey google',
/// - 'hey siri', 'jarvis', 'ok google', 'picovoice', 'porcupine'
///
/// Para "Oye COMPAS" personalizado, necesitas:
/// 1. Crear modelo en Picovoice Console (https://console.picovoice.ai/)
/// 2. Descargar archivo .ppn
/// 3. Colocarlo en assets/wake_words/
/// 4. Usar WakeWordConfig.custom()
class WakeWordService {
  static final WakeWordService _instance = WakeWordService._internal();
  factory WakeWordService() => _instance;
  WakeWordService._internal();

  final Logger _logger = Logger();

  PorcupineManager? _porcupineManager;
  bool _isInitialized = false;
  bool _isListening = false;
  bool _isPaused = false;

  // Configuración actual
  String? _currentKeyword;
  double _currentSensitivity = 0.7;

  // Estadísticas
  int _detectionCount = 0;
  DateTime? _lastDetection;

  // Callbacks
  Function()? onWakeWordDetected;
  Function(String)? onError;

  /// Inicializar con configuración
  Future<void> initialize({
    required String accessKey,
    WakeWordConfig config = const WakeWordConfig.builtIn('hey google'),
    double sensitivity = 0.7,
  }) async {
    if (_isInitialized) {
      _logger.w('Wake word service ya inicializado');
      return;
    }

    try {
      _logger.i('Inicializando Porcupine wake word...');
      _logger.i('Palabra clave: ${config.keyword}');

      _currentKeyword = config.keyword;
      _currentSensitivity = sensitivity;

      if (config.isBuiltIn) {
        await _initializeBuiltIn(accessKey, config.keyword, sensitivity);
      } else {
        await _initializeCustom(accessKey, config.modelPath!, sensitivity);
      }

      _isInitialized = true;
      _logger.i('✅ Porcupine wake word inicializado');
      _logger.i('   Keyword: $_currentKeyword');
      _logger.i('   Sensibilidad: ${(sensitivity * 100).toInt()}%');

    } on PorcupineActivationException catch (e) {
      _logger.e('Error de activación Porcupine: ${e.message}');
      throw Exception('Access Key inválido o expirado: ${e.message}');

    } on PorcupineException catch (e) {
      _logger.e('Error Porcupine: ${e.message}');
      throw Exception('Error inicializando wake word: ${e.message}');

    } catch (e) {
      _logger.e('Error desconocido: $e');
      throw Exception('Error inicializando wake word: $e');
    }
  }

  /// Inicializar con palabra clave built-in
  Future<void> _initializeBuiltIn(
      String accessKey,
      String keyword,
      double sensitivity,
      ) async {
    try {
      _porcupineManager = await PorcupineManager.fromBuiltInKeywords(
        accessKey,
        [_stringToBuiltInKeyword(keyword)],
        _wakeWordCallback,
        errorCallback: _errorCallback,
      );

      _logger.d('Manager creado con built-in keyword: $keyword');

    } catch (e) {
      _logger.e('Error creando manager built-in: $e');
      rethrow;
    }
  }

  /// Inicializar con modelo personalizado (.ppn file)
  Future<void> _initializeCustom(
      String accessKey,
      String keywordPath,
      double sensitivity,
      ) async {
    try {
      _porcupineManager = await PorcupineManager.fromKeywordPaths(
        accessKey,
        [keywordPath],
        _wakeWordCallback,
        modelPath: 'assets/wake_words/porcupine_params_es.pv', // 🔥 AQUÍ
        sensitivities: [sensitivity],
        errorCallback: _errorCallback,
      );

      _logger.d('Manager creado con modelo personalizado: $keywordPath');

    } catch (e) {
      _logger.e('Error creando manager custom: $e');
      rethrow;
    }
  }


  /// Convertir string a BuiltInKeyword enum
  BuiltInKeyword _stringToBuiltInKeyword(String keyword) {
    final keywordMap = {
      'alexa': BuiltInKeyword.ALEXA,
      'americano': BuiltInKeyword.AMERICANO,
      'blueberry': BuiltInKeyword.BLUEBERRY,
      'bumblebee': BuiltInKeyword.BUMBLEBEE,
      'computer': BuiltInKeyword.COMPUTER,
      'grapefruit': BuiltInKeyword.GRAPEFRUIT,
      'grasshopper': BuiltInKeyword.GRASSHOPPER,
      'hey google': BuiltInKeyword.HEY_GOOGLE,
      'hey siri': BuiltInKeyword.HEY_SIRI,
      'jarvis': BuiltInKeyword.JARVIS,
      'ok google': BuiltInKeyword.OK_GOOGLE,
      'picovoice': BuiltInKeyword.PICOVOICE,
      'porcupine': BuiltInKeyword.PORCUPINE,
    };

    final normalized = keyword.toLowerCase().trim();

    if (!keywordMap.containsKey(normalized)) {
      _logger.w('Keyword "$keyword" no reconocida, usando "hey google"');
      return BuiltInKeyword.HEY_GOOGLE;
    }

    return keywordMap[normalized]!;
  }

  /// Iniciar detección
  Future<void> start() async {
    if (!_isInitialized) {
      throw StateError('Wake word service no inicializado');
    }

    if (_isListening && !_isPaused) {
      _logger.w('Ya está escuchando');
      return;
    }

    try {
      if (_isPaused) {
        // Reanudar desde pausa
        await resume();
      } else {
        // Iniciar por primera vez
        await _porcupineManager?.start();
        _isListening = true;
        _isPaused = false;
        _logger.i('🎤 Wake word detection iniciado');
      }

    } catch (e) {
      _logger.e('Error iniciando wake word: $e');
      onError?.call('Error iniciando detección: $e');
      rethrow;
    }
  }

  /// Pausar detección (libera micrófono)
  Future<void> pause() async {
    if (!_isListening || _isPaused) {
      _logger.d('No está escuchando o ya pausado');
      return;
    }

    try {
      await _porcupineManager?.stop();
      _isPaused = true;
      _logger.d('⏸️ Wake word pausado');

    } catch (e) {
      _logger.e('Error pausando wake word: $e');
    }
  }

  /// Reanudar detección
  Future<void> resume() async {
    if (!_isPaused) {
      _logger.d('No está pausado');
      return;
    }

    try {
      await _porcupineManager?.start();
      _isPaused = false;
      _logger.d('▶️ Wake word reanudado');

    } catch (e) {
      _logger.e('Error reanudando wake word: $e');
      onError?.call('Error reanudando detección: $e');
    }
  }

  /// Detener completamente
  Future<void> stop() async {
    if (!_isListening) {
      _logger.d('No está escuchando');
      return;
    }

    try {
      await _porcupineManager?.stop();
      _isListening = false;
      _isPaused = false;
      _logger.i('⏹️ Wake word detenido');

    } catch (e) {
      _logger.e('Error deteniendo wake word: $e');
    }
  }

  /// Callback de detección
  void _wakeWordCallback(int keywordIndex) async {
    if (_isPaused) return; // protección extra

    _detectionCount++;
    _lastDetection = DateTime.now();

    _logger.i('🎯 Wake word detectado! (${_detectionCount}x)');

    onWakeWordDetected?.call();
  }


  /// Callback de error
  void _errorCallback(PorcupineException error) {
    _logger.e('Porcupine error: ${error.message}');
    onError?.call(error.message ?? 'Error desconocido');
  }

  /// Cambiar sensibilidad (requiere reinicio)
  Future<void> setSensitivity(double sensitivity, String accessKey) async {
    if (!_isInitialized) {
      _logger.w('Servicio no inicializado');
      return;
    }

    try {
      final wasListening = _isListening;
      final currentConfig = WakeWordConfig.builtIn(_currentKeyword ?? 'hey google');

      // Detener y liberar recursos
      await stop();
      await _porcupineManager?.delete();
      _porcupineManager = null;
      _isInitialized = false;

      // Reinicializar con nueva sensibilidad
      await initialize(
        accessKey: accessKey,
        config: currentConfig,
        sensitivity: sensitivity,
      );

      // Restaurar estado
      if (wasListening) {
        await start();
      }

      _logger.i('Sensibilidad actualizada: ${(sensitivity * 100).toInt()}%');

    } catch (e) {
      _logger.e('Error cambiando sensibilidad: $e');
      rethrow;
    }
  }

  /// Obtener estadísticas
  Map<String, dynamic> getStatistics() {
    return {
      'is_initialized': _isInitialized,
      'is_listening': _isListening,
      'is_paused': _isPaused,
      'keyword': _currentKeyword,
      'sensitivity': _currentSensitivity,
      'detection_count': _detectionCount,
      'last_detection': _lastDetection?.toIso8601String(),
      'time_since_last': _lastDetection != null
          ? DateTime.now().difference(_lastDetection!).inSeconds
          : null,
    };
  }

  /// Resetear estadísticas
  void resetStatistics() {
    _detectionCount = 0;
    _lastDetection = null;
  }

  // Getters
  bool get isInitialized => _isInitialized;
  bool get isListening => _isListening;
  bool get isPaused => _isPaused;
  int get detectionCount => _detectionCount;
  String? get currentKeyword => _currentKeyword;

  /// Liberar recursos
  Future<void> dispose() async {
    await stop();
    await _porcupineManager?.delete();
    _porcupineManager = null;
    _isInitialized = false;
    _logger.i('WakeWordService disposed');
  }
}

/// Configuración de wake word
class WakeWordConfig {
  final String keyword;
  final String? modelPath;
  final bool isBuiltIn;

  const WakeWordConfig.builtIn(this.keyword)
      : modelPath = null,
        isBuiltIn = true;

  const WakeWordConfig.custom({
    required this.keyword,
    required this.modelPath,
  }) : isBuiltIn = false;

  /// Palabras clave built-in disponibles
  static const List<String> availableBuiltIn = [
    'alexa',
    'americano',
    'blueberry',
    'bumblebee',
    'computer',
    'grapefruit',
    'grasshopper',
    'hey google',
    'hey siri',
    'jarvis',
    'ok google',
    'picovoice',
    'porcupine',
  ];
}