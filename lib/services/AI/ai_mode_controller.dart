// lib/services/AI/ai_mode_controller.dart
// ✅ v2 — Fix latencia: caché de conectividad + verificación Groq lazy
//
//  PROBLEMA (v1):
//  ─────────────────────────────────────────────────────────────────────────
//  verifyInternetNow() se llamaba DOS VECES por cada comando de voz
//  (una en NavigationCoordinator._processUserInput y otra en
//  ConversationService.chat). Cada llamada hacía:
//    1. Socket TCP a 8.8.8.8 (~200ms)
//    2. HTTP GET a Groq /models (~800-1200ms)
//  Total: ~2-3 segundos EXTRA por comando, solo en verificaciones.
//
//  FIX:
//  ─────────────────────────────────────────────────────────────────────────
//  1. Cache de 60s para resultado de internet (TTL configurable).
//     Si el último check fue hace menos de 60s, devolver el resultado
//     cacheado sin hacer ninguna request de red.
//
//  2. Cache de 120s para disponibilidad de Groq.
//     Groq no cambia de estado cada 2 segundos — verificar cada 2 minutos
//     es más que suficiente.
//
//  3. verifyInternetNow() respeta el cache — solo hace la request real
//     si el cache está expirado o si la conectividad cambió.
//
//  4. _startPeriodicCheck sigue corriendo en background cada 30s,
//     pero solo actualiza el cache — NO bloquea el hilo principal.

import 'dart:convert';

import 'package:logger/logger.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'dart:async';
import 'dart:io';
import '../../config/api_config.dart';

enum AIMode {
  online,
  offline,
  auto,
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

  Timer? _connectivityCheckTimer;
  static const Duration _checkInterval   = Duration(seconds: 30);

  // ✅ FIX: Cache TTL para evitar verificaciones de red en cada comando
  static const Duration _internetCacheTTL = Duration(seconds: 60);
  static const Duration _groqCacheTTL     = Duration(seconds: 120);

  DateTime? _lastSuccessfulCheck;
  DateTime? _lastGroqCheck;

  Function(AIMode)? onModeChanged;
  Function(bool)? onConnectivityChanged;

  bool _isInitialized = false;

  Future<void> initialize() async {
    // ✅ Evita reinicializaciones
    if (_isInitialized) {
      _logger.i('⚡ AIModeController ya inicializado — skip');
      return;
    }

    _isInitialized = true;

    try {
      _logger.i('🚀 INICIALIZANDO AI MODE CONTROLLER v2');

      final hasValidKey = ApiConfig.groqApiKey.isNotEmpty &&
          !ApiConfig.groqApiKey.contains('....') &&
          ApiConfig.groqApiKey.length > 20;

      if (!hasValidKey) {
        _logger.w('⚠️ GROQ API KEY NO CONFIGURADA → Modo offline');
        _groqAvailable = false;
      } else {
        await _checkRealInternetConnectivity();
        if (_hasInternet) {
          await _verifyGroqAvailability();
        }
      }

      _connectivity.onConnectivityChanged.listen(
            (List<ConnectivityResult> results) {
          _handleConnectivityChange(
            results.isNotEmpty
                ? results.first
                : ConnectivityResult.none,
          );
        },
      );

      _startPeriodicCheck();

      _logger.i('✅ AI MODE CONTROLLER v2 listo');
      _logger.i(
        '   Internet: ${_hasInternet ? "✅" : "❌"} | Groq: ${_groqAvailable ? "✅" : "❌"}',
      );
      _logger.i('   Modo efectivo: ${getEffectiveMode().name}');
    } catch (e) {
      _logger.e('❌ Error inicializando: $e');
      _hasInternet = false;
      _groqAvailable = false;
    }
  }
  // ─── Verificación de Groq ─────────────────────────────────────────────────

  Future<void> _verifyGroqAvailability() async {
    try {
      _logger.d('🔍 Verificando Groq API...');
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
        _logger.i('✅ Groq API OK');
      } else if (response.statusCode == 401) {
        _groqAvailable = false;
        _logger.e('❌ Groq: Auth fallida (401)');
      } else {
        _groqAvailable = false;
        _logger.w('⚠️ Groq status: ${response.statusCode}');
      }
    } on TimeoutException {
      _groqAvailable = false;
      _logger.w('⏱️ Timeout Groq (>8s)');
    } on SocketException {
      _groqAvailable = false;
      _logger.w('🌐 Sin red para Groq');
    } catch (e) {
      _groqAvailable = false;
      _logger.w('⚠️ Error Groq: $e');
    }
  }

  // ─── Verificación de internet ─────────────────────────────────────────────

  Future<void> _checkRealInternetConnectivity() async {
    try {
      final canReachDNS = await _canReachHost('8.8.8.8', port: 53, timeout: 3);
      if (canReachDNS) {
        _hasInternet = true;
        _lastSuccessfulCheck = DateTime.now();
        _logger.d('✅ Internet OK (DNS)');
        return;
      }

      final canReachHTTP = await _canReachHTTP();
      if (canReachHTTP) {
        _hasInternet = true;
        _lastSuccessfulCheck = DateTime.now();
        _logger.d('✅ Internet OK (HTTP)');
        return;
      }

      _hasInternet = false;
      _logger.w('❌ Sin internet');
    } catch (e) {
      _logger.e('Error verificando conectividad: $e');
      _hasInternet = false;
    }
  }

  Future<bool> _canReachHost(String host, {int port = 53, int timeout = 3}) async {
    try {
      final socket = await Socket.connect(host, port, timeout: Duration(seconds: timeout));
      socket.destroy();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> _canReachHTTP() async {
    try {
      final response = await http.head(
        Uri.parse('https://www.google.com'),
      ).timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  // ─── Verificación periódica en background ────────────────────────────────

  void _startPeriodicCheck() {
    _connectivityCheckTimer?.cancel();
    _connectivityCheckTimer = Timer.periodic(_checkInterval, (_) async {
      final hadInternet = _hasInternet;
      final hadGroq = _groqAvailable;

      await _checkRealInternetConnectivity();

      if (_hasInternet) {
        final timeSinceGroq = _lastGroqCheck != null
            ? DateTime.now().difference(_lastGroqCheck!)
            : null;
        if (timeSinceGroq == null || timeSinceGroq >= _groqCacheTTL) {
          await _verifyGroqAvailability();
        }
      } else {
        _groqAvailable = false;
      }

      if (hadInternet != _hasInternet || hadGroq != _groqAvailable) {
        _logger.i('🔄 Conectividad cambió: internet=${_hasInternet} groq=${_groqAvailable}');
        onConnectivityChanged?.call(_hasInternet);
        if (_currentMode == AIMode.auto) _notifyModeChange();
      }
    });
  }

  void _handleConnectivityChange(ConnectivityResult result) {
    _logger.d('📡 Red cambió: ${result.name} — invalidando cache');
    // Invalidar cache al cambiar de red
    _lastSuccessfulCheck = null;
    _lastGroqCheck = null;

    Future.microtask(() async {
      await _checkRealInternetConnectivity();
      if (_hasInternet) await _verifyGroqAvailability();
      else _groqAvailable = false;

      onConnectivityChanged?.call(_hasInternet);
      if (_currentMode == AIMode.auto) _notifyModeChange();
    });
  }

  // ─── ✅ FIX PRINCIPAL: verifyInternetNow() con cache ────────────────────
  //
  // ANTES (v1): Hacía socket + HTTP request a Groq en CADA llamada.
  //   Tiempo: ~1.5-3s por llamada × 2 llamadas por comando = 3-6s de espera.
  //
  // AHORA (v2): Solo verifica si el cache expiró (>60s desde última check).
  //   Tiempo típico: <1ms (leer variable en memoria).
  //   Solo hace request real si pasaron más de 60s sin verificar.

  Future<bool> verifyInternetNow() async {
    final now = DateTime.now();

    // ✅ Cache de internet: si se verificó hace menos de 60s, usar resultado cacheado
    if (_lastSuccessfulCheck != null) {
      final age = now.difference(_lastSuccessfulCheck!);
      if (age < _internetCacheTTL && _hasInternet) {
        // ✅ Cache de Groq: solo re-verificar si expiró
        if (_lastGroqCheck != null) {
          final groqAge = now.difference(_lastGroqCheck!);
          if (groqAge < _groqCacheTTL) {
            _logger.d('⚡ Cache hit: internet=${_hasInternet} groq=${_groqAvailable} (internet:${age.inSeconds}s groq:${groqAge.inSeconds}s)');
            return _hasInternet;
          }
        }
        // Internet OK pero Groq cache expiró → solo re-verificar Groq
        _logger.d('⚡ Internet cacheado, re-verificando Groq...');
        await _verifyGroqAvailability();
        return _hasInternet;
      }
    }

    // Cache expirado o sin check previo → verificación completa
    _logger.d('🌐 Verificando conectividad (cache expirado)...');
    await _checkRealInternetConnectivity();
    if (_hasInternet) await _verifyGroqAvailability();
    else _groqAvailable = false;

    return _hasInternet;
  }

  // ─── API pública ──────────────────────────────────────────────────────────

  void setMode(AIMode mode) {
    if (_currentMode == mode) return;
    _currentMode = mode;
    _logger.i('🔄 Modo: ${mode.name} → efectivo: ${getEffectiveMode().name}');
    _notifyModeChange();
  }

  void _notifyModeChange() {
    onModeChanged?.call(getEffectiveMode());
  }

  AIMode getEffectiveMode() {
    if (_currentMode == AIMode.auto) {
      return (_hasInternet && _groqAvailable) ? AIMode.online : AIMode.offline;
    }
    if (_currentMode == AIMode.online && (!_hasInternet || !_groqAvailable)) {
      return AIMode.offline;
    }
    return _currentMode;
  }

  bool canUseGroq()        => getEffectiveMode() == AIMode.online;
  bool shouldUseLocalModel() => getEffectiveMode() == AIMode.offline;

  String getModeDescription() {
    final effective = getEffectiveMode();
    switch (_currentMode) {
      case AIMode.online:
        return effective == AIMode.online ? '🌐 Online (Groq)' : '📴 Offline (sin Groq)';
      case AIMode.offline:
        return '📴 Offline (Modelo Local)';
      case AIMode.auto:
        return effective == AIMode.online
            ? '🔄 Auto (usando Groq)'
            : '🔄 Auto (Modelo Local)';
    }
  }

  Map<String, dynamic> getStatistics() => {
    'current_mode':       _currentMode.name,
    'effective_mode':     getEffectiveMode().name,
    'has_internet':       _hasInternet,
    'groq_available':     _groqAvailable,
    'can_use_groq':       canUseGroq(),
    'internet_cache_age': _lastSuccessfulCheck != null
        ? DateTime.now().difference(_lastSuccessfulCheck!).inSeconds
        : null,
    'groq_cache_age': _lastGroqCheck != null
        ? DateTime.now().difference(_lastGroqCheck!).inSeconds
        : null,
    'internet_cache_ttl_s': _internetCacheTTL.inSeconds,
    'groq_cache_ttl_s':     _groqCacheTTL.inSeconds,
  };

  Future<Map<String, dynamic>> runDiagnostics() async {
    final diagnostics = <String, dynamic>{};
    diagnostics['groq_key_present']      = ApiConfig.groqApiKey.isNotEmpty;
    diagnostics['groq_key_length']       = ApiConfig.groqApiKey.length;
    diagnostics['groq_key_valid_format'] = ApiConfig.groqApiKey.length > 20 &&
        !ApiConfig.groqApiKey.contains('....');

    diagnostics['can_reach_dns']  = await _canReachHost('8.8.8.8', port: 53, timeout: 3);
    diagnostics['can_reach_http'] = await _canReachHTTP();
    diagnostics['current_mode']   = _currentMode.name;
    diagnostics['effective_mode'] = getEffectiveMode().name;
    diagnostics['has_internet']   = _hasInternet;
    diagnostics['groq_available'] = _groqAvailable;

    return diagnostics;
  }

  AIMode get currentMode   => _currentMode;
  AIMode get effectiveMode => getEffectiveMode();
  bool   get hasInternet   => _hasInternet;
  bool   get groqAvailable => _groqAvailable;

  void dispose() {
    _connectivityCheckTimer?.cancel();
    _logger.i('AIModeController disposed');
  }
}