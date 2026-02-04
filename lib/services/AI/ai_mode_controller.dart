// lib/services/AI/ai_mode_controller.dart
// ✅ CONTROLADOR CON VERIFICACIÓN REAL DE INTERNET

import 'package:logger/logger.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'dart:async';
import 'dart:io';
import '../../config/api_config.dart';

enum AIMode {
  online,   // Usa Gemini API
  offline,  // Usa modelo TFLite local
  auto,     // Decide automáticamente
}

class AIModeController {
  static final AIModeController _instance = AIModeController._internal();
  factory AIModeController() => _instance;
  AIModeController._internal();

  final Logger _logger = Logger();
  final Connectivity _connectivity = Connectivity();

  AIMode _currentMode = AIMode.auto;
  bool _hasInternet = false;
  bool _geminiAvailable = false;

  // ✅ Control de verificación periódica
  Timer? _connectivityCheckTimer;
  static const Duration _checkInterval = Duration(seconds: 30);

  // ✅ Cache de último estado
  DateTime? _lastSuccessfulCheck;

  Function(AIMode)? onModeChanged;
  Function(bool)? onConnectivityChanged;

  Future<void> initialize() async {
    try {
      // 1. Verificar API key de Gemini
      _geminiAvailable = ApiConfig.geminiApiKey.isNotEmpty &&
          !ApiConfig.geminiApiKey.contains('....');

      if (!_geminiAvailable) {
        _logger.w('⚠️ Gemini API Key no configurada');
        _logger.w('   Modo Online DESHABILITADO');
      }

      // 2. Verificación REAL de internet
      await _checkRealInternetConnectivity();

      // 3. Escuchar cambios de conectividad
      _connectivity.onConnectivityChanged.listen((List<ConnectivityResult> results) {
        _handleConnectivityChange(results.isNotEmpty ? results.first : ConnectivityResult.none);
      });

      // 4. ✅ Verificación periódica en background
      _startPeriodicCheck();

      _logger.i('✅ AI Mode Controller inicializado');
      _logger.i('   Modo actual: $_currentMode');
      _logger.i('   Internet: $_hasInternet');
      _logger.i('   Gemini disponible: $_geminiAvailable');

    } catch (e) {
      _logger.e('Error inicializando AI Mode Controller: $e');
      _hasInternet = false;
    }
  }

  /// ✅ VERIFICACIÓN REAL DE INTERNET (no solo WiFi activo)
  Future<void> _checkRealInternetConnectivity() async {
    try {
      _logger.d('🌐 Verificando conexión real a internet...');

      // Método 1: Ping a Google DNS (más rápido)
      final canReachDNS = await _canReachHost('8.8.8.8', port: 53, timeout: 3);

      if (canReachDNS) {
        _hasInternet = true;
        _lastSuccessfulCheck = DateTime.now();
        _logger.i('✅ Internet disponible (DNS alcanzable)');
        return;
      }

      // Método 2: HTTP request a endpoint confiable
      final canReachHTTP = await _canReachHTTP();

      if (canReachHTTP) {
        _hasInternet = true;
        _lastSuccessfulCheck = DateTime.now();
        _logger.i('✅ Internet disponible (HTTP OK)');
        return;
      }

      // Sin conexión real
      _hasInternet = false;
      _logger.w('❌ Sin conexión a internet');

    } catch (e) {
      _logger.e('Error verificando conectividad: $e');
      _hasInternet = false;
    }
  }

  /// ✅ Verificar si puede alcanzar un host (método rápido)
  Future<bool> _canReachHost(String host, {int port = 53, int timeout = 3}) async {
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: Duration(seconds: timeout),
      );
      socket.destroy();
      return true;
    } catch (e) {
      return false;
    }
  }

  /// ✅ Verificar conexión HTTP (método alternativo)
  Future<bool> _canReachHTTP() async {
    try {
      // Intenta conectarse a un endpoint ligero y confiable
      final response = await http.head(
        Uri.parse('https://www.google.com'),
      ).timeout(const Duration(seconds: 5));

      return response.statusCode == 200;
    } catch (e) {
      _logger.d('HTTP check falló: $e');
      return false;
    }
  }

  /// ✅ Iniciar verificación periódica
  void _startPeriodicCheck() {
    _connectivityCheckTimer?.cancel();

    _connectivityCheckTimer = Timer.periodic(_checkInterval, (_) async {
      final hadInternet = _hasInternet;
      await _checkRealInternetConnectivity();

      // Solo notificar si cambió el estado
      if (hadInternet != _hasInternet) {
        _logger.i('🔄 Estado de internet cambió: $_hasInternet');
        onConnectivityChanged?.call(_hasInternet);

        if (_currentMode == AIMode.auto) {
          _notifyModeChange();
        }
      }
    });
  }

  /// Manejar cambio de conectividad (WiFi/Datos)
  void _handleConnectivityChange(ConnectivityResult result) {
    _logger.d('📡 Conectividad cambió a: ${result.name}');

    // Cuando cambia la red, re-verificar internet REAL
    _checkRealInternetConnectivity().then((_) {
      onConnectivityChanged?.call(_hasInternet);

      if (_currentMode == AIMode.auto) {
        _notifyModeChange();
      }
    });
  }

  /// ✅ Verificación manual (para usar antes de operaciones críticas)
  Future<bool> verifyInternetNow() async {
    await _checkRealInternetConnectivity();
    return _hasInternet;
  }

  void setMode(AIMode mode) {
    if (_currentMode == mode) return;

    final oldMode = _currentMode;
    _currentMode = mode;

    _logger.i('🔄 Modo IA cambiado: ${oldMode.name} → ${mode.name}');
    _notifyModeChange();
  }

  void _notifyModeChange() {
    final effectiveMode = getEffectiveMode();
    onModeChanged?.call(effectiveMode);
  }

  AIMode getEffectiveMode() {
    if (_currentMode == AIMode.auto) {
      if (_hasInternet && _geminiAvailable) {
        return AIMode.online;
      } else {
        return AIMode.offline;
      }
    }

    if (_currentMode == AIMode.online && (!_hasInternet || !_geminiAvailable)) {
      _logger.w('⚠️ Modo online solicitado pero no disponible, usando offline');
      return AIMode.offline;
    }

    return _currentMode;
  }

  bool canUseGemini() {
    return getEffectiveMode() == AIMode.online;
  }

  bool shouldUseLocalModel() {
    return getEffectiveMode() == AIMode.offline;
  }

  String getModeDescription() {
    final effective = getEffectiveMode();

    switch (_currentMode) {
      case AIMode.online:
        return effective == AIMode.online
            ? '🌐 Online (Gemini)'
            : '📴 Offline (sin conexión)';

      case AIMode.offline:
        return '📴 Offline (Modelo Local)';

      case AIMode.auto:
        return effective == AIMode.online
            ? '🔄 Auto (usando Gemini)'
            : '🔄 Auto (usando Modelo Local)';
    }
  }

  Map<String, dynamic> getStatistics() {
    return {
      'current_mode': _currentMode.name,
      'effective_mode': getEffectiveMode().name,
      'has_internet': _hasInternet,
      'gemini_available': _geminiAvailable,
      'can_use_gemini': canUseGemini(),
      'last_successful_check': _lastSuccessfulCheck?.toIso8601String(),
      'time_since_last_check': _lastSuccessfulCheck != null
          ? DateTime.now().difference(_lastSuccessfulCheck!).inSeconds
          : null,
    };
  }

  AIMode get currentMode => _currentMode;
  AIMode get effectiveMode => getEffectiveMode();
  bool get hasInternet => _hasInternet;
  bool get geminiAvailable => _geminiAvailable;

  void dispose() {
    _connectivityCheckTimer?.cancel();
  }
}