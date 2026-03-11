// lib/services/voice_navigation_service.dart
// ✅ v5.5 — FIX: Cola se vaciaba tarde — mensajes low/medium descartados al llegar high/urgent
//           FIX: Tamaño máximo de cola reducido de 8 a 4
//           FIX: Dedup window reducida de 5s a 4s para giros consecutivos similares
//
// ============================================================================
//  CAMBIOS v5.0 → v5.5
// ============================================================================
//
//  PROBLEMA — Mensajes se acumulaban y el TTS no terminaba uno antes de
//             comenzar el siguiente, especialmente en tramos con recordatorios
//             de "sigue recto" + progreso + giros próximos:
//
//    CAUSA 1 — Cola de 8 slots demasiado grande:
//      Con 8 slots, los mensajes low (GoStraight, ProgressUpdate, WaitingForUser)
//      llenaban la cola y los giros llegaban a encontrar la cola llena o tenían
//      que esperar a que se vaciaran todos los low anteriores.
//
//    CAUSA 2 — Al llegar un giro (high), los low en cola NO se descartaban:
//      La lógica solo reemplazaba el elemento de menor prioridad si la cola
//      estaba LLENA. Si había 3 slots libres, el giro simplemente se encolaba
//      detrás de los 3 mensajes low que ya estaban esperando.
//
//  FIX v5.5:
//    1. _maxQueueSize reducida de 8 a 4.
//       Limita cuánto trabajo acumulado puede haber en cualquier momento.
//
//    2. _enqueue(): cuando llega una instrucción high o urgent, se descartan
//       TODOS los mensajes low y medium que estén en cola ANTES de insertar.
//       Un giro inminente hace completamente irrelevante cualquier recordatorio
//       de "sigue recto" o "vas bien" que estuviera esperando.
//
//    3. _deduplicationWindowMs reducida de 5000 a 4000ms.
//       Ventana más ajustada reduce falsos positivos en giros similares
//       consecutivos en tramos cortos.
//
//  TODOS LOS FIXES DE v5.0 SE CONSERVAN ÍNTEGRAMENTE.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_unity_widget/flutter_unity_widget.dart';
import 'package:logger/logger.dart';

import 'unity_bridge_service.dart';
import 'tts_service.dart';

// ─── Prioridad ────────────────────────────────────────────────────────────

enum _InstructionPriority { low, medium, high, urgent }

class _PendingInstruction {
  final String text;
  final _InstructionPriority priority;
  final String announcementType;
  final DateTime arrivedAt;

  const _PendingInstruction({
    required this.text,
    required this.priority,
    required this.announcementType,
    required this.arrivedAt,
  });

  @override
  String toString() =>
      '_PendingInstruction(${priority.name}, $announcementType, "$text")';
}

// ─── Servicio ─────────────────────────────────────────────────────────────

class VoiceNavigationService {
  static final VoiceNavigationService _instance =
  VoiceNavigationService._internal();
  factory VoiceNavigationService() => _instance;
  VoiceNavigationService._internal();

  final Logger _logger = Logger();

  TTSService? _ttsService;
  bool _ttsReady = false;

  // ✅ v5.5: Cola reducida de 8 a 4 — evita acumulación excesiva
  final List<_PendingInstruction> _queue = [];
  static const int _maxQueueSize = 4;

  _PendingInstruction? _currentInstruction;

  // Guard para evitar llamadas re-entrantes a _speakPending()
  bool _isDraining = false;

  // Deduplicación por texto + ventana de tiempo
  final Map<String, DateTime> _recentlySpoken = {};

  // ✅ v5.5: Reducida de 5000 a 4000ms — menos agresiva en giros consecutivos
  static const int _deduplicationWindowMs = 4000;

  UnityWidgetController? _unityController;
  StreamSubscription<UnityResponse>? _unitySubscription;
  StreamSubscription<void>? _ttsCompletionSubscription;

  final ValueNotifier<bool> isReadyNotifier = ValueNotifier(false);
  bool get isReady => _ttsReady;

  // ─── Inicialización ───────────────────────────────────────────────────────

  Future<void> initialize(TTSService ttsService) async {
    if (_ttsReady) {
      _logger.w('[VoiceNav] Ya inicializado — skip');
      return;
    }

    _ttsService = ttsService;

    if (!ttsService.isInitialized) {
      _logger.e('[VoiceNav] ❌ TTSService aún no inicializado.');
      throw StateError('TTSService debe estar inicializado primero.');
    }

    _ttsCompletionSubscription = ttsService.onComplete.listen((_) {
      _onTTSCompleted();
    });

    _ttsReady = true;
    isReadyNotifier.value = true;
    _logger.i('[VoiceNav] ✅ v5.5 listo — cola máx: $_maxQueueSize.');
  }

  // ─── Callback de completion del TTS ──────────────────────────────────────

  void _onTTSCompleted() {
    if (_currentInstruction != null) {
      _recentlySpoken[_currentInstruction!.text] = DateTime.now();
    }

    _notifyUnityTTSStatus(speaking: false);
    _currentInstruction = null;
    _isDraining = false;

    _speakPending();
  }

  // ─── Conexión con Unity ──────────────────────────────────────────────────

  void attachToUnityBridge(
      UnityBridgeService bridge, {
        UnityWidgetController? controller,
      }) {
    if (controller != null) {
      _unityController = controller;
      _logger.i('[VoiceNav] ✅ UnityWidgetController asignado.');
    }
    _unitySubscription?.cancel();
    _unitySubscription = bridge.responses.listen(_onUnityResponse);
    _logger.i('[VoiceNav] ✅ Suscrito al stream de Unity.');
  }

  void setUnityController(UnityWidgetController controller) {
    _unityController = controller;
    _logger.i('[VoiceNav] 🔄 UnityWidgetController actualizado.');
  }

  void handleUnityResponse(UnityResponse response) =>
      _onUnityResponse(response);

  // ─── Procesamiento de mensajes de Unity ─────────────────────────────────

  void _onUnityResponse(UnityResponse response) {
    if (response.action != 'guide_announcement') return;
    final text = response.message.trim();
    if (text.isEmpty) return;

    final type = response.raw['type'] as String? ?? '';
    final priority = _priorityForType(type);

    // Dedup por texto + ventana de tiempo SOLO para low/medium
    if (priority == _InstructionPriority.low ||
        priority == _InstructionPriority.medium) {
      final lastSpoken = _recentlySpoken[text];
      if (lastSpoken != null) {
        final elapsed = DateTime.now().difference(lastSpoken).inMilliseconds;
        if (elapsed < _deduplicationWindowMs) {
          _logger.d('[VoiceNav] 🔇 Dup [$type] (hace ${elapsed}ms): "$text"');
          return;
        }
      }
    }

    // Dedup en cola también solo para low/medium
    if (priority == _InstructionPriority.low ||
        priority == _InstructionPriority.medium) {
      final alreadyQueued = _queue.any((i) => i.text == text);
      if (alreadyQueued) {
        _logger.d('[VoiceNav] 🔇 Ya en cola [$type]: "$text"');
        return;
      }
    }

    _enqueue(_PendingInstruction(
      text:             text,
      priority:         priority,
      announcementType: type,
      arrivedAt:        DateTime.now(),
    ));
  }

  // ─── Cola de prioridad ────────────────────────────────────────────────────

  void _enqueue(_PendingInstruction instruction) {
    final isSpeaking = _ttsService?.isSpeaking ?? false;

    // ✅ v5.5: Si llega high o urgent, descartar todos los low/medium en cola.
    //
    // RAZONAMIENTO:
    //   Un giro inminente o una emergencia hace irrelevante cualquier
    //   recordatorio de "sigue recto", "vas bien" o "cuando estés listo"
    //   que estuviera esperando en cola. Es mejor silenciarlos que hacer
    //   esperar al usuario un giro crítico detrás de 3 mensajes informativos.
    //
    //   Ejemplo sin fix: cola = [GoStraight, ProgressUpdate, GoStraight] + llega TurnLeft
    //   → TurnLeft espera detrás de 3 mensajes low = ~12s de delay = giro pasado
    //
    //   Ejemplo con fix: cola = [] (vaciada) + TurnLeft al frente = instrucción inmediata
    if (instruction.priority == _InstructionPriority.high ||
        instruction.priority == _InstructionPriority.urgent) {
      final toRemove = _queue
          .where((i) =>
      i.priority == _InstructionPriority.low ||
          i.priority == _InstructionPriority.medium)
          .length;
      if (toRemove > 0) {
        _queue.removeWhere((i) =>
        i.priority == _InstructionPriority.low ||
            i.priority == _InstructionPriority.medium);
        _logger.i('[VoiceNav] 🗑️ Descartados $toRemove mensajes low/med '
            'por ${instruction.announcementType} (${instruction.priority.name})');
      }
    }

    // Si la cola sigue llena tras el vaciado, aplicar lógica de desplazamiento
    if (_queue.length >= _maxQueueSize) {
      int lowestIdx = 0;
      for (int i = 1; i < _queue.length; i++) {
        if (_queue[i].priority.index < _queue[lowestIdx].priority.index ||
            (_queue[i].priority == _queue[lowestIdx].priority &&
                _queue[i].arrivedAt.isBefore(_queue[lowestIdx].arrivedAt))) {
          lowestIdx = i;
        }
      }
      if (_queue[lowestIdx].priority.index <= instruction.priority.index) {
        _logger.w('[VoiceNav] ⚠️ Cola llena — descartando: '
            '[${_queue[lowestIdx].announcementType}] '
            '"${_queue[lowestIdx].text.substring(0, _queue[lowestIdx].text.length.clamp(0, 40))}..."');
        _queue.removeAt(lowestIdx);
      } else {
        _logger.w('[VoiceNav] ⚠️ Cola llena — descartando nuevo '
            '[${instruction.announcementType}] (prioridad más baja)');
        return;
      }
    }

    // Insertar en posición correcta según prioridad
    int insertIdx = _queue.length;
    for (int i = 0; i < _queue.length; i++) {
      if (instruction.priority.index > _queue[i].priority.index) {
        insertIdx = i;
        break;
      }
    }
    _queue.insert(insertIdx, instruction);

    _logger.d('[VoiceNav] 📥 Encolado [${instruction.announcementType}] '
        'p=${instruction.priority.name} — cola: ${_queue.length}');

    if (!isSpeaking && _currentInstruction == null && !_isDraining) {
      _speakPending();
    } else if (instruction.priority == _InstructionPriority.urgent) {
      _logger.i('[VoiceNav] ⚡ URGENTE — interrumpiendo TTS actual');
      _ttsService?.stop().then((_) {
        _notifyUnityTTSStatus(speaking: false);
        _currentInstruction = null;
        _isDraining = false;
        _speakPending();
      });
    }
  }

  void _speakPending() {
    if (_queue.isEmpty || !_ttsReady || _ttsService == null) return;

    if (_isDraining) {
      _logger.d('[VoiceNav] _speakPending() re-entrada evitada');
      return;
    }

    _isDraining = true;
    _currentInstruction = _queue.removeAt(0);

    _logger.d('[VoiceNav] ▶️ Reproduciendo [${_currentInstruction!.announcementType}] '
        '— cola restante: ${_queue.length}');

    _speak(_currentInstruction!);
  }

  Future<void> _speak(_PendingInstruction instruction) async {
    if (!_ttsReady || _ttsService == null) {
      _isDraining = false;
      return;
    }
    _logger.i('[VoiceNav] 🔊 [${instruction.announcementType}] "${instruction.text}"');

    _notifyUnityTTSStatus(speaking: true);

    final shouldInterrupt =
        instruction.priority == _InstructionPriority.urgent ||
            instruction.priority == _InstructionPriority.high;

    await _ttsService!.speak(instruction.text, interrupt: shouldInterrupt);
  }

  // ─── Notificación a Unity ────────────────────────────────────────────────

  void _notifyUnityTTSStatus({required bool speaking}) {
    if (_unityController == null) return;

    final int priorityIndex = (speaking && _currentInstruction != null)
        ? _currentInstruction!.priority.index
        : 0;

    final String payload = jsonEncode({
      'isSpeaking': speaking,
      'priority':   priorityIndex,
    });

    try {
      _unityController!.postMessage(
        'VoiceCommandAPI',
        'OnTTSStatus',
        payload,
      );
      _logger.d('[VoiceNav] 📡 →Unity: speaking=$speaking p=$priorityIndex');
    } catch (e) {
      _logger.w('[VoiceNav] ⚠️ postMessage error: $e');
    }
  }

  // ─── API pública ──────────────────────────────────────────────────────────

  /// Habla un texto directamente (fuera de cola), prioridad medium.
  Future<void> speak(String text) async {
    if (!_ttsReady || _ttsService == null) return;
    _currentInstruction = _PendingInstruction(
      text:             text,
      priority:         _InstructionPriority.medium,
      announcementType: 'manual',
      arrivedAt:        DateTime.now(),
    );
    _isDraining = true;
    _notifyUnityTTSStatus(speaking: true);
    await _ttsService!.speak(text, interrupt: false);
  }

  /// Detiene el TTS actual y limpia toda la cola.
  Future<void> stop() async {
    if (_ttsService == null) return;
    await _ttsService!.stop();
    _currentInstruction = null;
    _queue.clear();
    _isDraining = false;
    _notifyUnityTTSStatus(speaking: false);
    _logger.i('[VoiceNav] 🛑 Detenido — cola vaciada.');
  }

  /// Descarta toda la cola SIN detener el TTS actual.
  void flushQueue() {
    final discarded = _queue.length;
    _queue.clear();
    if (discarded > 0) {
      _logger.i('[VoiceNav] 🗑️ Cola vaciada ($discarded mensajes descartados).');
    }
  }

  /// Limpia la tabla de deduplicación y la cola pendiente.
  void resetDeduplication() {
    _recentlySpoken.clear();
    _queue.clear();
    _logger.d('[VoiceNav] 🔄 Deduplicación y cola reiniciadas.');
  }

  /// Devuelve el número de mensajes en cola.
  int get queueLength => _queue.length;

  /// Devuelve true si hay TTS activo o mensajes en cola.
  bool get isBusy =>
      (_ttsService?.isSpeaking ?? false) ||
          _currentInstruction != null ||
          _queue.isNotEmpty;

  Future<void> dispose() async {
    await _unitySubscription?.cancel();
    await _ttsCompletionSubscription?.cancel();
    _notifyUnityTTSStatus(speaking: false);
    _queue.clear();
    isReadyNotifier.dispose();
  }

  // ─── Helpers de prioridad ────────────────────────────────────────────────

  /// Mapa de prioridad por tipo de anuncio.
  /// Conservado íntegramente de v5.0 — todos los GuideAnnouncementType cubiertos.
  static _InstructionPriority _priorityForType(String type) {
    switch (type) {
    // ── URGENTE — interrumpen cualquier TTS en curso ────────────────────
      case 'ApproachingStairs':
      case 'StartingClimb':
      case 'StartingDescent':
      case 'ObstacleWarning':
      case 'UserDeviated':
        return _InstructionPriority.urgent;

    // ── ALTO — giros direccionales ──────────────────────────────────────
      case 'TurnLeft':
      case 'TurnRight':
      case 'SlightLeft':
      case 'SlightRight':
      case 'UTurn':
        return _InstructionPriority.high;

    // ── MEDIO — hitos de navegación ────────────────────────────────────
      case 'StartNavigation':
      case 'Arrived':
      case 'StairsComplete':
      case 'FloorReached':
      case 'ResumeAfterSeparation':
      case 'ResumeGuide':
        return _InstructionPriority.medium;

    // ── BAJO — información periódica ───────────────────────────────────
      case 'GoStraight':
      case 'ProgressUpdate':
      case 'WaitingForUser':
      case 'UserStopped':
        return _InstructionPriority.low;

      default:
        return _InstructionPriority.low;
    }
  }
}