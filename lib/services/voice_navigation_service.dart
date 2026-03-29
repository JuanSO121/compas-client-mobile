// lib/services/voice_navigation_service.dart
// ✅ v6.6 — Logs limpios
//
// ============================================================================
//  CAMBIOS v6.5 → v6.6
// ============================================================================
//
//  Logger reemplazado por wrapper de dos niveles:
//    _log()      → solo en debug builds (assert — eliminado en release)
//    _logError() → siempre (errores críticos reales)
//
//  TODO LO DEMÁS ES IDÉNTICO A v6.5 (token de generación para race condition).

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_unity_widget/flutter_unity_widget.dart';

import 'unity_bridge_service.dart';
import 'tts_service.dart';
import 'AI/wake_word_service.dart';

enum _InstructionPriority { low, medium, high, urgent }

class _PendingInstruction {
  final String               text;
  final _InstructionPriority priority;
  final String               announcementType;
  final DateTime             arrivedAt;

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

class VoiceNavigationService {
  static final VoiceNavigationService _instance =
      VoiceNavigationService._internal();
  factory VoiceNavigationService() => _instance;
  VoiceNavigationService._internal();

  // ─── Logging ────────────────────────────────────────────────────────────
  static void _log(String msg) {
    assert(() {
      debugPrint('[VoiceNav] $msg');
      return true;
    }());
  }

  static void _logError(String msg) => debugPrint('[VoiceNav] ❌ $msg');

  // ─── Estado ─────────────────────────────────────────────────────────────

  TTSService?      _ttsService;
  WakeWordService? _wakeWordService;
  bool _ttsReady = false;

  final List<_PendingInstruction> _queue    = [];
  static const int                _maxQueueSize = 6;

  _PendingInstruction? _currentInstruction;
  bool                 _isDraining = false;

  final Map<String, DateTime> _recentlySpoken = {};
  static const int _deduplicationWindowMs = 4000;

  UnityWidgetController?             _unityController;
  StreamSubscription<UnityResponse>? _unitySubscription;
  StreamSubscription<void>?          _ttsCompletionSubscription;

  // v6.5: token de generación para cancelar resume() obsoletos
  int _resumeGeneration = 0;

  final ValueNotifier<bool> isReadyNotifier = ValueNotifier(false);
  bool get isReady => _ttsReady;

  // ─── Inicialización ──────────────────────────────────────────────────────

  Future<void> initialize(TTSService ttsService) async {
    if (_ttsReady) return;

    _ttsService = ttsService;

    if (!ttsService.isInitialized) {
      throw StateError('TTSService debe estar inicializado primero.');
    }

    _ttsCompletionSubscription = ttsService.onComplete.listen((_) {
      _onTTSCompleted();
    });

    _ttsReady = true;
    isReadyNotifier.value = true;
    _log('v6.6 listo — cola máx: $_maxQueueSize');
  }

  void attachWakeWordService(WakeWordService wakeWordService) {
    _wakeWordService = wakeWordService;
    _log('WakeWordService conectado');
  }

  // ─── TTS completed ───────────────────────────────────────────────────────

  void _onTTSCompleted() {}

  // ─── Wake word helpers ───────────────────────────────────────────────────

  Future<void> _pauseWakeWord() async {
    if (_wakeWordService == null) return;
    if (!_wakeWordService!.isListening) return;

    // v6.5: incrementar generación ANTES de pausar
    _resumeGeneration++;

    try {
      await _wakeWordService!.pause();
      _log('Wake word pausado para TTS');
    } catch (e) {
      _logError('Error pausando wake word: $e');
    }
  }

  void _resumeWakeWord() {
    if (_wakeWordService == null) return;
    if (!_wakeWordService!.isInitialized) return;

    final ttsStillActive = _ttsService?.isSpeaking ?? false;
    if (_queue.isNotEmpty || _currentInstruction != null || ttsStillActive) return;

    final generation = ++_resumeGeneration;

    Future.delayed(const Duration(milliseconds: 350), () {
      if (generation != _resumeGeneration) {
        _log('Resume cancelado — nueva actividad TTS durante delay');
        return;
      }

      final stillActive = _ttsService?.isSpeaking ?? false;
      if (_queue.isEmpty && _currentInstruction == null && !stillActive) {
        _wakeWordService!.resume().catchError((e) {
          _logError('Error reanudando wake word: $e');
        });
        _log('Wake word reanudado (350ms)');
      }
    });
  }

  // ─── Conexión con Unity ──────────────────────────────────────────────────

  void attachToUnityBridge(
    UnityBridgeService bridge, {
    UnityWidgetController? controller,
  }) {
    if (controller != null) {
      _unityController = controller;
    }

    _unitySubscription?.cancel();
    _unitySubscription = bridge.responses.listen(_onUnityResponse);
    bridge.onTTSRequest = _onTTSRequest;

    _log('Suscrito a stream Unity + onTTSRequest');
  }

  void setUnityController(UnityWidgetController controller) {
    _unityController = controller;
  }

  void handleUnityResponse(UnityResponse response) =>
      _onUnityResponse(response);

  // ─── Handler tts_request ─────────────────────────────────────────────────

  void _onTTSRequest(UnityResponse response) {
    final text      = response.raw['text']      as String? ?? '';
    final priority  = response.raw['priority']  as int?    ?? 0;
    final interrupt = response.raw['interrupt'] as bool?   ?? false;

    if (text.trim().isEmpty) return;

    _log('tts_request p=$priority interrupt=$interrupt "$text"');

    final instrPriority = _priorityFromInt(priority);

    if (instrPriority == _InstructionPriority.low ||
        instrPriority == _InstructionPriority.medium) {
      if (_currentInstruction?.text == text) return;

      final lastSpoken = _recentlySpoken[text];
      if (lastSpoken != null) {
        final elapsed = DateTime.now().difference(lastSpoken).inMilliseconds;
        if (elapsed < _deduplicationWindowMs) return;
      }

      if (_queue.any((i) => i.text == text)) return;
    }

    final instruction = _PendingInstruction(
      text:             text,
      priority:         instrPriority,
      announcementType: 'tts_req_p$priority',
      arrivedAt:        DateTime.now(),
    );

    if (interrupt) {
      _queue.insert(0, instruction);
      _isDraining = false;
      _ttsService?.stop();

      Future.microtask(() {
        final stillSpeaking = _ttsService?.isSpeaking ?? false;
        if (!stillSpeaking && !_isDraining && _queue.isNotEmpty) {
          _speakPending();
        }
      });
      return;
    }

    _enqueue(instruction);
  }

  static _InstructionPriority _priorityFromInt(int p) {
    switch (p) {
      case 3:  return _InstructionPriority.urgent;
      case 2:  return _InstructionPriority.high;
      case 1:  return _InstructionPriority.medium;
      default: return _InstructionPriority.low;
    }
  }

  // ─── Canal legacy guide_announcement ─────────────────────────────────────

  void _onUnityResponse(UnityResponse response) {
    if (response.action != 'guide_announcement') return;
    final text = response.message.trim();
    if (text.isEmpty) return;

    final type     = response.raw['type'] as String? ?? '';
    final priority = _priorityForType(type);

    if (priority == _InstructionPriority.low ||
        priority == _InstructionPriority.medium) {
      final lastSpoken = _recentlySpoken[text];
      if (lastSpoken != null) {
        final elapsed = DateTime.now().difference(lastSpoken).inMilliseconds;
        if (elapsed < _deduplicationWindowMs) return;
      }
      if (_queue.any((i) => i.text == text)) return;
    }

    _enqueue(_PendingInstruction(
      text:             text,
      priority:         priority,
      announcementType: type,
      arrivedAt:        DateTime.now(),
    ));
  }

  // ─── Cola ────────────────────────────────────────────────────────────────

  void _enqueue(_PendingInstruction instruction) {
    final isSpeaking = _ttsService?.isSpeaking ?? false;

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
        _log('Descartados $toRemove low/med por ${instruction.priority.name}');
      }
    }

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
        _queue.removeAt(lowestIdx);
      } else {
        return;
      }
    }

    int insertIdx = _queue.length;
    for (int i = 0; i < _queue.length; i++) {
      if (instruction.priority.index > _queue[i].priority.index) {
        insertIdx = i;
        break;
      }
    }
    _queue.insert(insertIdx, instruction);

    if (!isSpeaking && _currentInstruction == null && !_isDraining) {
      _speakPending();
    } else if (instruction.priority == _InstructionPriority.urgent) {
      _isDraining = false;
      _ttsService?.stop();
    }
  }

  void _speakPending() {
    if (_queue.isEmpty || !_ttsReady || _ttsService == null) return;
    if (_isDraining) return;

    _isDraining = true;
    _currentInstruction = _queue.removeAt(0);

    _speak(_currentInstruction!);
  }

  Future<void> _speak(_PendingInstruction instruction) async {
    if (!_ttsReady || _ttsService == null) {
      _isDraining = false;
      return;
    }

    _log('▶ [${instruction.announcementType}] "${instruction.text}"');

    await _pauseWakeWord();
    _notifyUnityTTSStatus(speaking: true);

    final shouldInterrupt =
        instruction.priority == _InstructionPriority.urgent ||
        instruction.priority == _InstructionPriority.high;

    try {
      await _ttsService!.speak(instruction.text, interrupt: shouldInterrupt);
    } catch (e) {
      _logError('Error en speak(): $e');
    } finally {
      _recentlySpoken[instruction.text] = DateTime.now();
      _currentInstruction = null;
      _isDraining         = false;

      _notifyUnityTTSStatus(speaking: false);
      _resumeWakeWord();
      _speakPending();
    }
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
      _unityController!.postMessage('VoiceCommandAPI', 'OnTTSStatus', payload);
    } catch (e) {
      _logError('postMessage error: $e');
    }
  }

  // ─── API pública ─────────────────────────────────────────────────────────

  Future<void> speak(String text) async {
    if (!_ttsReady || _ttsService == null) return;
    final instruction = _PendingInstruction(
      text:             text,
      priority:         _InstructionPriority.medium,
      announcementType: 'manual',
      arrivedAt:        DateTime.now(),
    );
    _currentInstruction = instruction;
    _isDraining = true;
    await _speak(instruction);
  }

  Future<void> stop() async {
    if (_ttsService == null) return;
    await _ttsService!.stop();
    _currentInstruction = null;
    _queue.clear();
    _isDraining = false;
    _notifyUnityTTSStatus(speaking: false);
    _resumeWakeWord();
    _log('Detenido — cola vaciada');
  }

  void flushQueue() {
    final discarded = _queue.length;
    _queue.clear();
    if (discarded > 0) _log('Cola vaciada ($discarded descartados)');
  }

  void resetDeduplication() {
    _recentlySpoken.clear();
    _queue.clear();
    _log('Deduplicación y cola reiniciadas');
  }

  int  get queueLength => _queue.length;
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

  // ─── Helpers de prioridad (canal legacy) ─────────────────────────────────

  static _InstructionPriority _priorityForType(String type) {
    switch (type) {
      case 'ApproachingStairs':
      case 'StartingClimb':
      case 'StartingDescent':
      case 'ObstacleWarning':
      case 'UserDeviated':
        return _InstructionPriority.urgent;
      case 'TurnLeft':
      case 'TurnRight':
      case 'SlightLeft':
      case 'SlightRight':
      case 'UTurn':
        return _InstructionPriority.high;
      case 'StartNavigation':
      case 'Arrived':
      case 'StairsComplete':
      case 'FloorReached':
      case 'ResumeAfterSeparation':
      case 'ResumeGuide':
        return _InstructionPriority.medium;
      default:
        return _InstructionPriority.low;
    }
  }
}