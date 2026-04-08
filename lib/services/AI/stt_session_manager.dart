// lib/services/AI/stt_session_manager.dart
// ✅ v2.0 — Reescritura: FSM limpia, sin Timers internos, sin cooldown propio.
//
// ============================================================================
// POR QUÉ SE REESCRIBIÓ (bugs v1.x)
// ============================================================================
//
//  BUG 1 — _minTimeBetweenSessions (500ms) bloqueaba reinicios legítimos.
//    Medía desde markIdle(), no desde el listen() previo. Cuando
//    WakeWordService.resume() intentaba reabrir el STT tras un comando,
//    canStart() devolvía false porque 500ms no habían pasado desde el
//    cierre, aunque el listen() nuevo era completamente independiente.
//
//  BUG 2 — El Timer de transición (2s) nunca se cancelaba en el happy-path.
//    Si el STT pasaba starting → active → done correctamente, el timer
//    expiraba igualmente y forzaba un markIdle() espurio, haciendo que
//    el coordinator viera un idle cuando el STT aún estaba activo.
//
//  BUG 3 — _isTransitioning era un bool sin scope de reset garantizado.
//    Una excepción entre markStarting() y markActive() lo dejaba en true
//    para siempre, bloqueando silenciosamente todos los canStart() futuros.
//
//  BUG 4 — waitUntilIdle() usaba polling cada 100ms: ineficiente y propenso
//    a dejar el loop corriendo si el caller no esperaba correctamente.
//
// ============================================================================
// DISEÑO v2.0
// ============================================================================
//
//  FSM de 3 estados: idle → starting → active → idle.
//  No hay estado 'stopping': markIdle() es el único retorno a idle.
//
//  canStart() solo verifica el estado actual — sin cooldowns de tiempo.
//  El control de cooldown entre sesiones es responsabilidad del caller.
//
//  waitUntilIdle() usa ValueNotifier listener — cero polling.

import 'dart:async';
import 'package:flutter/foundation.dart';

// ─── Estados ─────────────────────────────────────────────────────────────────

enum SessionState {
  /// Sin sesión STT activa. Lista para iniciar.
  idle,

  /// Entre markStarting() y markActive(). Aún no confirmado por la plataforma.
  starting,

  /// Sesión STT activa, recibiendo audio.
  active,
}

// ─── Manager ──────────────────────────────────────────────────────────────────

/// Rastreador de estado de sesión STT.
///
/// Fuente de verdad única del estado del STT para evitar race conditions
/// entre WakeWordService, NavigationCoordinator e IntegratedVoiceCommandService.
///
/// Responsabilidades:
///   ✅ Rastrear estado (idle / starting / active).
///   ✅ Exponer estado de forma reactiva (ValueListenable).
///   ✅ Proveer espera reactiva sin polling (waitUntilIdle).
///
/// NO es responsable de:
///   ❌ Controlar el STT directamente.
///   ❌ Gestionar timers de retry.
///   ❌ Imponer cooldowns entre sesiones (eso va en el caller).
class STTSessionManager {
  // ─── Estado ────────────────────────────────────────────────────────────────

  final ValueNotifier<SessionState> _state = ValueNotifier(SessionState.idle);

  ValueListenable<SessionState> get stateListenable => _state;

  SessionState get state => _state.value;

  bool get isIdle => _state.value == SessionState.idle;
  bool get isActive => _state.value == SessionState.active;
  bool get isStarting => _state.value == SessionState.starting;

  // ─── canStart ──────────────────────────────────────────────────────────────

  /// Devuelve true si se puede abrir una nueva sesión STT.
  ///
  /// Solo verifica el estado FSM. No impone cooldowns temporales.
  bool canStart() {
    if (_state.value != SessionState.idle) {
      _log('canStart=false — estado: ${_state.value.name}');
      return false;
    }
    return true;
  }

  // ─── Transiciones ──────────────────────────────────────────────────────────

  /// Registra el intento de abrir una sesión.
  /// Retorna false si el estado actual no lo permite (ya activa / starting).
  bool markStarting() {
    if (!canStart()) return false;
    _to(SessionState.starting);
    return true;
  }

  /// Confirma que el STT está escuchando activamente.
  /// Solo válido si el estado es 'starting'. Ignorado en cualquier otro estado.
  void markActive() {
    if (_state.value == SessionState.starting) {
      _to(SessionState.active);
    } else {
      _log('markActive() ignorado — estado: ${_state.value.name}');
    }
  }

  /// Cierra la sesión STT, volviendo al estado idle.
  ///
  /// Llamar aquí tanto para cierre normal como para cleanup de error.
  /// Es el único punto de retorno a idle — no hay markStopping() separado.
  void markIdle() {
    if (_state.value != SessionState.idle) {
      _to(SessionState.idle);
    }
  }

  /// Reset de emergencia para recuperación de errores críticos.
  /// No loguea la transición para no contaminar el log en recuperaciones.
  void forceReset() {
    _log('⚠️ forceReset() desde ${_state.value.name}');
    _state.value = SessionState.idle;
  }

  // ─── Espera reactiva ───────────────────────────────────────────────────────

  /// Espera sin polling hasta que el estado sea idle.
  ///
  /// Usa ValueNotifier listener para eficiencia O(1).
  /// El [timeout] previene bloqueos si el STT nunca notifica su cierre.
  Future<void> waitUntilIdle({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    if (isIdle) return;

    final completer = Completer<void>();

    void onStateChange() {
      if (_state.value == SessionState.idle && !completer.isCompleted) {
        completer.complete();
      }
    }

    _state.addListener(onStateChange);

    try {
      await completer.future.timeout(
        timeout,
        onTimeout: () {
          _log('⏱️ waitUntilIdle timeout (${timeout.inSeconds}s) — forceReset');
          forceReset();
        },
      );
    } finally {
      _state.removeListener(onStateChange);
    }
  }

  // ─── Internos ──────────────────────────────────────────────────────────────

  void _to(SessionState next) {
    _log('${_state.value.name} → ${next.name}');
    _state.value = next;
  }

  static void _log(String msg) {
    assert(() {
      debugPrint('[STTSession] $msg');
      return true;
    }());
  }

  void dispose() {
    _state.dispose();
  }
}
