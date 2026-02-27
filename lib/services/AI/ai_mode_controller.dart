// lib/services/AI/ai_mode_controller.dart
// ✅ CONTROLADOR CON VERIFICACIÓN REAL DE INTERNET - VERSIÓN MEJORADA

import 'dart:convert';

import 'package:logger/logger.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'dart:async';
import 'dart:io';
import '../../config/api_config.dart';

enum AIMode {
  online,   // Usa Groq API
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
  bool _groqAvailable = false;

  // ✅ Control de verificación periódica
  Timer? _connectivityCheckTimer;
  static const Duration _checkInterval = Duration(seconds: 30);

  // ✅ Cache de último estado
  DateTime? _lastSuccessfulCheck;
  DateTime? _lastGroqCheck;

  Function(AIMode)? onModeChanged;
  Function(bool)? onConnectivityChanged;

  Future<void> initialize() async {
    try {
      _logger.i('═══════════════════════════════════════');
      _logger.i('🚀 INICIALIZANDO AI MODE CONTROLLER');
      _logger.i('═══════════════════════════════════════');

      // 1. Verificar API key de Groq
      final hasValidKey = ApiConfig.groqApiKey.isNotEmpty &&
          !ApiConfig.groqApiKey.contains('....') &&
          ApiConfig.groqApiKey.length > 20;

      if (!hasValidKey) {
        _logger.w('═══════════════════════════════════════');
        _logger.w('⚠️  GROQ API KEY NO CONFIGURADA');
        _logger.w('═══════════════════════════════════════');
        _logger.w('   Key length: ${ApiConfig.groqApiKey.length}');
        _logger.w('   Modo Online: ❌ DESHABILITADO');
        _logger.w('   Modo Offline: ✅ ACTIVO (TFLite)');
        _logger.w('═══════════════════════════════════════');
        _groqAvailable = false;
      } else {
        _logger.i('✅ Groq API Key detectada');
        _logger.i('   Key length: ${ApiConfig.groqApiKey.length} caracteres');
        _logger.i('   Key preview: ${ApiConfig.groqApiKey.substring(0, 10)}...');

        // 2. Verificar internet primero
        await _checkRealInternetConnectivity();

        // 3. Solo verificar Groq si hay internet
        if (_hasInternet) {
          await _verifyGroqAvailability();
        } else {
          _logger.w('⚠️ Sin internet, no se puede verificar Groq');
          _groqAvailable = false;
        }
      }

      // 4. Escuchar cambios de conectividad
      _connectivity.onConnectivityChanged.listen((List<ConnectivityResult> results) {
        _handleConnectivityChange(results.isNotEmpty ? results.first : ConnectivityResult.none);
      });

      // 5. ✅ Verificación periódica en background
      _startPeriodicCheck();

      _logger.i('═══════════════════════════════════════');
      _logger.i('✅ AI MODE CONTROLLER INICIALIZADO');
      _logger.i('═══════════════════════════════════════');
      _logger.i('   Modo actual: ${_currentMode.name}');
      _logger.i('   Internet: ${_hasInternet ? "✅ DISPONIBLE" : "❌ NO DISPONIBLE"}');
      _logger.i('   Groq disponible: ${_groqAvailable ? "✅ SI" : "❌ NO"}');
      _logger.i('   Modo efectivo: ${getEffectiveMode().name}');
      _logger.i('═══════════════════════════════════════');

    } catch (e) {
      _logger.e('❌ Error inicializando AI Mode Controller: $e');
      _hasInternet = false;
      _groqAvailable = false;
    }
  }

  /// ✅ VERIFICAR QUE GROQ API ESTÉ ACCESIBLE
  Future<void> _verifyGroqAvailability() async {
    try {
      _logger.d('🔍 Verificando accesibilidad de Groq API...');
      _lastGroqCheck = DateTime.now();

      final response = await http.get(
        Uri.parse('${ApiConfig.groqBaseUrl}/models'),
        headers: {
          'Authorization': 'Bearer ${ApiConfig.groqApiKey}',
          'Content-Type': 'application/json',
        },
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        _groqAvailable = true;
        _logger.i('✅ Groq API accesible y autenticado');

        // Verificar que el modelo esté disponible
        try {
          final data = jsonDecode(response.body);
          final models = data['data'] as List;
          final hasModel = models.any((m) =>
          m['id'] == ApiConfig.groqCommandModel
          );

          if (hasModel) {
            _logger.i('✅ Modelo ${ApiConfig.groqCommandModel} disponible');
          } else {
            _logger.w('⚠️ Modelo ${ApiConfig.groqCommandModel} no encontrado');
            _logger.w('   Modelos disponibles: ${models.map((m) => m['id']).take(3).join(", ")}...');
          }
        } catch (e) {
          _logger.d('No se pudo verificar modelo específico: $e');
        }

      } else if (response.statusCode == 401) {
        _groqAvailable = false;
        _logger.e('❌ Groq API: Autenticación fallida (401)');
        _logger.e('   Verifica tu GROQ_API_KEY en .env');
      } else {
        _groqAvailable = false;
        _logger.w('⚠️ Groq API no accesible (status: ${response.statusCode})');
        _logger.w('   Body: ${response.body.substring(0, response.body.length > 100 ? 100 : response.body.length)}');
      }

    } on TimeoutException {
      _groqAvailable = false;
      _logger.w('⏱️ Timeout verificando Groq API (>8s)');
    } on SocketException {
      _groqAvailable = false;
      _logger.w('🌐 No se pudo conectar a Groq (red)');
    } catch (e) {
      _groqAvailable = false;
      _logger.w('⚠️ Error verificando Groq API: $e');
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
      final hadGroq = _groqAvailable;

      await _checkRealInternetConnectivity();

      // Solo verificar Groq si hay internet y no se verificó recientemente
      if (_hasInternet) {
        final timeSinceLastGroqCheck = _lastGroqCheck != null
            ? DateTime.now().difference(_lastGroqCheck!)
            : null;

        // Verificar Groq cada 2 minutos si hay internet
        if (timeSinceLastGroqCheck == null ||
            timeSinceLastGroqCheck.inMinutes >= 2) {
          await _verifyGroqAvailability();
        }
      } else {
        _groqAvailable = false;
      }

      // Solo notificar si cambió algún estado
      if (hadInternet != _hasInternet || hadGroq != _groqAvailable) {
        _logger.i('═══════════════════════════════════════');
        _logger.i('🔄 ESTADO CAMBIÓ');
        _logger.i('═══════════════════════════════════════');
        _logger.i('   Internet: ${hadInternet ? "✅" : "❌"} → ${_hasInternet ? "✅" : "❌"}');
        _logger.i('   Groq: ${hadGroq ? "✅" : "❌"} → ${_groqAvailable ? "✅" : "❌"}');
        _logger.i('   Modo efectivo: ${getEffectiveMode().name}');
        _logger.i('═══════════════════════════════════════');

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

    // Cuando cambia la red, re-verificar todo
    Future.microtask(() async {
      await _checkRealInternetConnectivity();

      if (_hasInternet) {
        await _verifyGroqAvailability();
      } else {
        _groqAvailable = false;
      }

      onConnectivityChanged?.call(_hasInternet);

      if (_currentMode == AIMode.auto) {
        _notifyModeChange();
      }
    });
  }

  /// ✅ Verificación manual (para usar antes de operaciones críticas)
  Future<bool> verifyInternetNow() async {
    await _checkRealInternetConnectivity();

    if (_hasInternet) {
      await _verifyGroqAvailability();
    }

    return _hasInternet;
  }

  void setMode(AIMode mode) {
    if (_currentMode == mode) return;

    final oldMode = _currentMode;
    _currentMode = mode;

    _logger.i('═══════════════════════════════════════');
    _logger.i('🔄 MODO IA CAMBIADO');
    _logger.i('═══════════════════════════════════════');
    _logger.i('   Anterior: ${oldMode.name}');
    _logger.i('   Nuevo: ${mode.name}');
    _logger.i('   Efectivo: ${getEffectiveMode().name}');
    _logger.i('═══════════════════════════════════════');

    _notifyModeChange();
  }

  void _notifyModeChange() {
    final effectiveMode = getEffectiveMode();
    onModeChanged?.call(effectiveMode);
  }

  AIMode getEffectiveMode() {
    if (_currentMode == AIMode.auto) {
      if (_hasInternet && _groqAvailable) {
        return AIMode.online;
      } else {
        return AIMode.offline;
      }
    }

    if (_currentMode == AIMode.online && (!_hasInternet || !_groqAvailable)) {
      // Log más discreto
      _logger.d('Modo online solicitado pero no disponible');
      _logger.d('   Internet: ${_hasInternet ? "✅" : "❌"}');
      _logger.d('   Groq: ${_groqAvailable ? "✅" : "❌"}');
      _logger.d('   Usando modo offline (TFLite)');
      return AIMode.offline;
    }

    return _currentMode;
  }

  bool canUseGroq() {
    return getEffectiveMode() == AIMode.online;
  }

  bool shouldUseLocalModel() {
    return getEffectiveMode() == AIMode.offline;
  }

  String getModeDescription() {
    final effective = getEffectiveMode();

    switch (_currentMode) {
      case AIMode.online:
        if (effective == AIMode.online) {
          return '🌐 Online (Groq)';
        } else if (!_hasInternet) {
          return '📴 Offline (sin conexión)';
        } else {
          return '📴 Offline (Groq no disponible)';
        }

      case AIMode.offline:
        return '📴 Offline (Modelo Local)';

      case AIMode.auto:
        return effective == AIMode.online
            ? '🔄 Auto (usando Groq)'
            : '🔄 Auto (usando Modelo Local)';
    }
  }

  String getDetailedStatus() {
    final buffer = StringBuffer();

    buffer.writeln('═══════════════════════════════════════');
    buffer.writeln('📊 ESTADO DEL SISTEMA AI');
    buffer.writeln('═══════════════════════════════════════');
    buffer.writeln('Modo configurado: ${_currentMode.name}');
    buffer.writeln('Modo efectivo: ${getEffectiveMode().name}');
    buffer.writeln('───────────────────────────────────────');
    buffer.writeln('Internet: ${_hasInternet ? "✅ DISPONIBLE" : "❌ NO DISPONIBLE"}');
    buffer.writeln('Groq API: ${_groqAvailable ? "✅ DISPONIBLE" : "❌ NO DISPONIBLE"}');
    buffer.writeln('TFLite: ✅ SIEMPRE DISPONIBLE');
    buffer.writeln('───────────────────────────────────────');

    if (_lastSuccessfulCheck != null) {
      final timeSince = DateTime.now().difference(_lastSuccessfulCheck!);
      buffer.writeln('Última verificación de internet: hace ${timeSince.inSeconds}s');
    }

    if (_lastGroqCheck != null) {
      final timeSince = DateTime.now().difference(_lastGroqCheck!);
      buffer.writeln('Última verificación de Groq: hace ${timeSince.inSeconds}s');
    }

    buffer.writeln('═══════════════════════════════════════');

    return buffer.toString();
  }

  Map<String, dynamic> getStatistics() {
    return {
      'current_mode': _currentMode.name,
      'effective_mode': getEffectiveMode().name,
      'has_internet': _hasInternet,
      'groq_available': _groqAvailable,
      'can_use_groq': canUseGroq(),
      'should_use_local': shouldUseLocalModel(),
      'last_successful_check': _lastSuccessfulCheck?.toIso8601String(),
      'last_groq_check': _lastGroqCheck?.toIso8601String(),
      'time_since_last_check': _lastSuccessfulCheck != null
          ? DateTime.now().difference(_lastSuccessfulCheck!).inSeconds
          : null,
      'time_since_groq_check': _lastGroqCheck != null
          ? DateTime.now().difference(_lastGroqCheck!).inSeconds
          : null,
      'groq_key_configured': ApiConfig.groqApiKey.isNotEmpty,
      'groq_key_length': ApiConfig.groqApiKey.length,
    };
  }

  /// ✅ Diagnóstico completo
  Future<Map<String, dynamic>> runDiagnostics() async {
    _logger.i('═══════════════════════════════════════');
    _logger.i('🔧 EJECUTANDO DIAGNÓSTICO COMPLETO');
    _logger.i('═══════════════════════════════════════');

    final diagnostics = <String, dynamic>{};

    // 1. Verificar API Key
    diagnostics['groq_key_present'] = ApiConfig.groqApiKey.isNotEmpty;
    diagnostics['groq_key_length'] = ApiConfig.groqApiKey.length;
    diagnostics['groq_key_valid_format'] = ApiConfig.groqApiKey.length > 20 &&
        !ApiConfig.groqApiKey.contains('....');

    // 2. Verificar conectividad
    _logger.d('   Verificando DNS...');
    final canReachDNS = await _canReachHost('8.8.8.8', port: 53, timeout: 3);
    diagnostics['can_reach_dns'] = canReachDNS;

    _logger.d('   Verificando HTTP...');
    final canReachHTTP = await _canReachHTTP();
    diagnostics['can_reach_http'] = canReachHTTP;

    // 3. Verificar Groq API
    if (diagnostics['groq_key_valid_format'] == true && (canReachDNS || canReachHTTP)) {
      _logger.d('   Verificando Groq API...');
      try {
        final response = await http.get(
          Uri.parse('${ApiConfig.groqBaseUrl}/models'),
          headers: {
            'Authorization': 'Bearer ${ApiConfig.groqApiKey}',
            'Content-Type': 'application/json',
          },
        ).timeout(const Duration(seconds: 8));

        diagnostics['groq_api_reachable'] = true;
        diagnostics['groq_api_status_code'] = response.statusCode;
        diagnostics['groq_api_authenticated'] = response.statusCode == 200;

        if (response.statusCode == 200) {
          try {
            final data = jsonDecode(response.body);
            final models = data['data'] as List;
            diagnostics['groq_models_count'] = models.length;
            diagnostics['groq_has_target_model'] = models.any((m) =>
            m['id'] == ApiConfig.groqCommandModel
            );
          } catch (e) {
            diagnostics['groq_model_check_error'] = e.toString();
          }
        }

      } catch (e) {
        diagnostics['groq_api_reachable'] = false;
        diagnostics['groq_api_error'] = e.toString();
      }
    } else {
      diagnostics['groq_api_reachable'] = false;
      if (diagnostics['groq_key_valid_format'] != true) {
        diagnostics['groq_api_error'] = 'API key no configurada o inválida';
      } else {
        diagnostics['groq_api_error'] = 'Sin conexión a internet';
      }
    }

    // 4. Estado general
    diagnostics['current_mode'] = _currentMode.name;
    diagnostics['effective_mode'] = getEffectiveMode().name;
    diagnostics['has_internet'] = _hasInternet;
    diagnostics['groq_available'] = _groqAvailable;

    // 5. Recomendaciones
    final recommendations = <String>[];

    if (!diagnostics['groq_key_valid_format']) {
      recommendations.add('⚠️ Configura GROQ_API_KEY en el archivo .env');
      recommendations.add('   Obtén tu key en: https://console.groq.com/keys');
    }

    if (!diagnostics['can_reach_dns'] && !diagnostics['can_reach_http']) {
      recommendations.add('⚠️ Sin conexión a internet. Verifica WiFi/Datos móviles');
    }

    if (diagnostics['groq_key_valid_format'] == true &&
        diagnostics['groq_api_reachable'] == true &&
        diagnostics['groq_api_authenticated'] == false) {
      recommendations.add('⚠️ API key de Groq inválida o expirada');
      recommendations.add('   Verifica tu key en: https://console.groq.com/keys');
    }

    if (diagnostics['groq_api_authenticated'] == true &&
        diagnostics['groq_has_target_model'] == false) {
      recommendations.add('⚠️ Modelo ${ApiConfig.groqCommandModel} no disponible');
      recommendations.add('   Verifica modelos disponibles en consola Groq');
    }

    if (recommendations.isEmpty) {
      recommendations.add('✅ Sistema funcionando correctamente');
    }

    diagnostics['recommendations'] = recommendations;

    _logger.i('═══════════════════════════════════════');
    _logger.i('📋 RESULTADOS DEL DIAGNÓSTICO:');
    _logger.i('═══════════════════════════════════════');
    for (var rec in recommendations) {
      _logger.i('   $rec');
    }
    _logger.i('═══════════════════════════════════════');

    return diagnostics;
  }

  AIMode get currentMode => _currentMode;
  AIMode get effectiveMode => getEffectiveMode();
  bool get hasInternet => _hasInternet;
  bool get groqAvailable => _groqAvailable;

  void dispose() {
    _connectivityCheckTimer?.cancel();
    _logger.i('AIModeController disposed');
  }
}