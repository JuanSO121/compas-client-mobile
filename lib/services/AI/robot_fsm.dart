// lib/services/AI/robot_fsm.dart
// ✅ FINITE STATE MACHINE + VALIDADORES
// Garantiza transiciones válidas y seguridad en comandos críticos

import 'package:logger/logger.dart';

/// Estados del robot virtual
enum RobotState {
  idle,      // Esperando
  moving,    // En movimiento
  turning,   // Girando
  stopped,   // Detenido explícitamente
  helpMode,  // Modo ayuda activado
}

/// Acciones posibles
enum Action {
  move,
  stop,
  turnLeft,
  turnRight,
  repeat,
  help,
  unknown,
}

/// Validador de chunks (longitud mínima por comando)
class ChunkValidator {
  static const Map<Action, int> minChars = {
    Action.stop: 3,
    Action.help: 3,
    Action.move: 4,
    Action.turnLeft: 3,
    Action.turnRight: 3,
    Action.repeat: 4,
    Action.unknown: 0,
  };

  static bool validate(String text, Action action) {
    final cleanText = text.trim().toLowerCase();
    final minLength = minChars[action] ?? 0;
    return cleanText.length >= minLength;
  }
}

/// FSM (Finite State Machine) para navegación AR
///
/// REGLAS DE TRANSICIÓN:
/// - STOP y HELP tienen prioridad absoluta (siempre se ejecutan)
/// - MOVE solo en idle/stopped
/// - TURN solo en moving
/// - REPEAT solo si hay acción previa
class RobotFSM {
  final Logger _logger = Logger();

  // Estado actual
  RobotState state = RobotState.idle;
  Action? lastAction;

  // Historial
  final List<CommandRecord> commandHistory = [];

  // Thresholds de confianza (IDÉNTICOS a Python)
  static const Map<Action, double> confidenceThresholds = {
    Action.stop: 0.65,
    Action.help: 0.70,
    Action.move: 0.65,
    Action.turnLeft: 0.60,
    Action.turnRight: 0.60,
    Action.repeat: 0.55,
    Action.unknown: 0.50,
  };

  /// Verificar si la acción puede ejecutarse
  ///
  /// Returns:
  ///   (canExecute, reason) - tupla con permiso y razón
  (bool, String) canExecute(Action action, double confidence) {
    // 1. COMANDOS CRÍTICOS: STOP y HELP tienen prioridad absoluta
    if (action == Action.stop || action == Action.help) {
      final threshold = confidenceThresholds[action]!;
      if (confidence >= threshold) {
        return (true, 'Critical action');
      }
      return (false, 'Low confidence: ${(confidence * 100).toStringAsFixed(1)}%');
    }

    // 2. Verificar threshold de confianza
    final threshold = confidenceThresholds[action] ?? 0.50;
    if (confidence < threshold) {
      return (false, 'Low confidence: ${(confidence * 100).toStringAsFixed(1)}%');
    }

    // 3. Validar transiciones según estado actual
    switch (action) {
      case Action.move:
        if (state == RobotState.idle || state == RobotState.stopped) {
          return (true, 'MOVE allowed from $state');
        }
        return (false, 'Cannot MOVE: already moving or turning');

      case Action.turnLeft:
      case Action.turnRight:
        if (state == RobotState.moving) {
          return (true, 'TURN allowed while moving');
        }
        return (false, 'Cannot TURN: not moving (state: $state)');

      case Action.repeat:
        if (lastAction != null && lastAction != Action.unknown) {
          return (true, 'Repeat ${lastAction.toString()}');
        }
        return (false, 'No action to repeat');

      case Action.unknown:
        return (false, 'Unknown command');

      default:
        return (false, 'Invalid action');
    }
  }

  /// Ejecutar acción si es válida
  ///
  /// Returns:
  ///   true si se ejecutó, false si se rechazó
  bool execute(Action action, double confidence, String text) {
    // COMANDOS CRÍTICOS: STOP y HELP siempre se ejecutan
    if (action == Action.stop) {
      state = RobotState.stopped;
      lastAction = action;
      _recordCommand(action, confidence, text, true);
      _logger.i('  🔴 STOP (conf: ${(confidence * 100).toStringAsFixed(1)}%)');
      return true;
    }

    if (action == Action.help) {
      state = RobotState.helpMode;
      lastAction = action;
      _recordCommand(action, confidence, text, true);
      _logger.i('  🆘 HELP (conf: ${(confidence * 100).toStringAsFixed(1)}%)');
      return true;
    }

    // Validar con FSM
    final (canExec, reason) = canExecute(action, confidence);
    if (!canExec) {
      _logger.w('  ⛔ FSM REJECT: $reason');
      _recordCommand(action, confidence, text, false);
      return false;
    }

    // Actualizar estado según acción
    switch (action) {
      case Action.move:
        state = RobotState.moving;
        break;

      case Action.turnLeft:
      case Action.turnRight:
        state = RobotState.turning;
        break;

      case Action.repeat:
      // Ejecutar última acción
        if (lastAction != null) {
          action = lastAction!;
        }
        break;

      default:
        break;
    }

    lastAction = action;
    _recordCommand(action, confidence, text, true);

    _logger.i('  ✅ ${action.name} (conf: ${(confidence * 100).toStringAsFixed(1)}%, state: ${state.name})');

    return true;
  }

  /// Registrar comando en historial
  void _recordCommand(Action action, double confidence, String text, bool executed) {
    commandHistory.add(CommandRecord(
      action: action,
      confidence: confidence,
      text: text,
      executed: executed,
      timestamp: DateTime.now(),
      state: state,
    ));

    // Limitar historial a 100 comandos
    if (commandHistory.length > 100) {
      commandHistory.removeAt(0);
    }
  }

  /// Obtener últimos N comandos
  List<CommandRecord> getRecentCommands(int n) {
    if (commandHistory.length <= n) {
      return commandHistory;
    }
    return commandHistory.sublist(commandHistory.length - n);
  }

  /// Obtener estadísticas
  Map<String, dynamic> getStatistics() {
    final total = commandHistory.length;
    final executed = commandHistory.where((c) => c.executed).length;
    final rejected = total - executed;

    return {
      'total_commands': total,
      'executed': executed,
      'rejected': rejected,
      'current_state': state.toString(),
      'last_action': lastAction?.toString() ?? 'none',
      'acceptance_rate': total > 0 ? (executed / total * 100).toStringAsFixed(1) : '0.0',
    };
  }

  /// Resetear FSM al estado inicial
  void reset() {
    state = RobotState.idle;
    lastAction = null;
    _logger.d('FSM reseted to idle');
  }
}

/// Registro de comando ejecutado
class CommandRecord {
  final Action action;
  final double confidence;
  final String text;
  final bool executed;
  final DateTime timestamp;
  final RobotState state;

  CommandRecord({
    required this.action,
    required this.confidence,
    required this.text,
    required this.executed,
    required this.timestamp,
    required this.state,
  });

  Map<String, dynamic> toJson() => {
    'action': action.toString(),
    'confidence': confidence,
    'text': text,
    'executed': executed,
    'timestamp': timestamp.toIso8601String(),
    'state': state.toString(),
  };

  @override
  String toString() =>
      'CommandRecord(${action.name}, ${(confidence * 100).toStringAsFixed(1)}%, ${executed ? "✅" : "❌"})';
}