// lib/services/AI/stt_session_manager.dart
// ✅ GESTOR DE SESIONES STT - EVITA CONFLICTOS

import 'dart:async';
import 'package:logger/logger.dart';

/// Gestor de sesiones STT para evitar conflictos y race conditions
///
/// PROBLEMA RESUELTO:
/// - Múltiples intentos de start() simultáneos
/// - error_busy por sesiones superpuestas
/// - Loops infinitos de reinicio
class STTSessionManager {
  final Logger _logger = Logger();

  // Estado de sesión
  SessionState _state = SessionState.idle;
  DateTime? _lastStateChange;
  Timer? _transitionTimer;

  // Lock para operaciones
  bool _isTransitioning = false;

  // Configuración
  static const Duration _transitionTimeout = Duration(seconds: 2);
  static const Duration _minTimeBetweenSessions = Duration(milliseconds: 500);

  /// Verificar si puede iniciar sesión
  bool canStart() {
    if (_isTransitioning) {
      _logger.w('⚠️ En transición, no puede iniciar');
      return false;
    }

    if (_state == SessionState.active) {
      _logger.w('⚠️ Sesión ya activa');
      return false;
    }

    // Verificar tiempo mínimo entre sesiones
    if (_lastStateChange != null) {
      final elapsed = DateTime.now().difference(_lastStateChange!);
      if (elapsed < _minTimeBetweenSessions) {
        _logger.w('⚠️ Muy pronto para nueva sesión (${elapsed.inMilliseconds}ms)');
        return false;
      }
    }

    return true;
  }

  /// Marcar inicio de sesión
  Future<bool> markStarting() async {
    if (!canStart()) return false;

    _isTransitioning = true;
    _changeState(SessionState.starting);

    // Timeout de transición
    _transitionTimer = Timer(_transitionTimeout, () {
      if (_state == SessionState.starting) {
        _logger.e('⏱️ Timeout en transición a active');
        _changeState(SessionState.idle);
        _isTransitioning = false;
      }
    });

    return true;
  }

  /// Confirmar sesión activa
  void markActive() {
    _transitionTimer?.cancel();
    _isTransitioning = false;
    _changeState(SessionState.active);
    _logger.d('✅ Sesión STT activa');
  }

  /// Marcar fin de sesión
  void markStopping() {
    _transitionTimer?.cancel();
    _isTransitioning = false;
    _changeState(SessionState.stopping);
  }

  /// Confirmar sesión cerrada
  void markIdle() {
    _transitionTimer?.cancel();
    _isTransitioning = false;
    _changeState(SessionState.idle);
    _logger.d('⏹️ Sesión STT cerrada');
  }

  /// Forzar reset (en caso de error)
  void forceReset() {
    _logger.w('🔄 Force reset de session manager');
    _transitionTimer?.cancel();
    _isTransitioning = false;
    _changeState(SessionState.idle);
  }

  /// Cambiar estado con logging
  void _changeState(SessionState newState) {
    if (_state != newState) {
      _logger.d('State: ${_state.name} → ${newState.name}');
      _state = newState;
      _lastStateChange = DateTime.now();
    }
  }

  /// Esperar hasta que esté idle
  Future<void> waitUntilIdle({Duration timeout = const Duration(seconds: 3)}) async {
    final startTime = DateTime.now();

    while (_state != SessionState.idle) {
      if (DateTime.now().difference(startTime) > timeout) {
        _logger.e('⏱️ Timeout esperando idle state');
        forceReset();
        break;
      }

      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  // Getters
  SessionState get state => _state;
  bool get isIdle => _state == SessionState.idle;
  bool get isActive => _state == SessionState.active;
  bool get isTransitioning => _isTransitioning;
  Duration? get timeSinceLastChange => _lastStateChange != null
      ? DateTime.now().difference(_lastStateChange!)
      : null;

  void dispose() {
    _transitionTimer?.cancel();
  }
}

/// Estados posibles de la sesión STT
enum SessionState {
  idle,      // Sin sesión
  starting,  // Iniciando sesión
  active,    // Sesión activa
  stopping,  // Cerrando sesión
}