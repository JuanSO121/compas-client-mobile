// lib/services/voice_navigation_service.dart
// ============================================================================
//  SERVICIO DE INSTRUCCIONES DE VOZ — IndoorNavAR  v3.0
// ============================================================================
//
//  CAMBIOS v2.0 → v3.0:
//  ─────────────────────────────────────────────────────────────────────────
//  🐛 BUG CRÍTICO CORREGIDO: Dos instancias de FlutterTts compitiendo.
//
//  PROBLEMA (v2.0):
//    VoiceNavigationService creaba su propio FlutterTts interno.
//    TTSService (usado por NavigationCoordinator) también tiene FlutterTts.
//    Android solo permite UN engine TTS activo a la vez.
//    Resultado: el saludo post-wake-word ("Dime") se bloqueaba porque
//    VoiceNavigationService ya había tomado el engine. El coordinator
//    quedaba colgado en CoordinatorState.speaking → nunca arrancaba el STT.
//
//  FIX:
//    VoiceNavigationService ya NO crea FlutterTts propio.
//    Recibe el TTSService compartido vía attachToUnityBridge() o setTTSService().
//    Toda la reproducción de audio pasa por el mismo engine.
//
//  FLUJO COMPLETO (sin cambios funcionales):
//    1. Unity: GuideAnnouncementEvent → VoiceCommandAPI.OnGuideAnnouncement()
//       → Reply(json) → Flutter: VoiceNavigationService._onUnityResponse()
//    2. Flutter encola instrucción con prioridad.
//    3. Al reproducir: llama TTSService.speak() con interrupt según prioridad.
//    4. TTSService.setStartHandler → _notifyUnityTTSStatus(speaking: true)
//    5. TTSService.setCompletionHandler → _notifyUnityTTSStatus(speaking: false)
//       → ARGuideController reanuda NPC.
//
//  INTEGRACIÓN en ar_navigation_screen.dart (sin cambios necesarios):
//    void _onUnityCreated(UnityWidgetController controller) {
//      _unityBridge.setController(controller);
//      _voiceNav.setUnityController(controller);
//    }
//    // En _initializeServices():
//    await _voiceNav.initialize(_coordinator.ttsService);  // ← pasa TTSService
//    _voiceNav.attachToUnityBridge(_unityBridge);
//
//  PRIORIDADES enviadas a Unity:
//    0=low(GoStraight)  1=medium(Arrived)  2=high(giros)  3=urgent(escaleras)

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_unity_widget/flutter_unity_widget.dart';
import 'package:logger/logger.dart';

import 'unity_bridge_service.dart';
import 'tts_service.dart'; // ✅ v3.0: usa TTSService compartido

// ─── Prioridad ────────────────────────────────────────────────────────────

enum _InstructionPriority { low, medium, high, urgent }

class _PendingInstruction {
  final String text;
  final _InstructionPriority priority;
  final String announcementType;
  const _PendingInstruction({
    required this.text,
    required this.priority,
    required this.announcementType,
  });
}

// ─── Servicio ─────────────────────────────────────────────────────────────

class VoiceNavigationService {
  static final VoiceNavigationService _instance =
  VoiceNavigationService._internal();
  factory VoiceNavigationService() => _instance;
  VoiceNavigationService._internal();

  final Logger _logger = Logger();

  // ✅ v3.0: referencia al TTSService compartido (NO FlutterTts propio)
  TTSService? _ttsService;
  bool _ttsReady = false;

  _PendingInstruction? _currentInstruction;
  _PendingInstruction? _pendingInstruction;

  String _lastSpokenText       = '';
  String _lastAnnouncementType = '';

  UnityWidgetController? _unityController;
  StreamSubscription<UnityResponse>? _unitySubscription;

  // ✅ v3.0: escucha completions del TTSService para avanzar la cola
  StreamSubscription<void>? _ttsCompletionSubscription;

  final ValueNotifier<bool> isReadyNotifier = ValueNotifier(false);
  bool get isReady => _ttsReady;

  // ─── Inicialización ───────────────────────────────────────────────────────
  //
  // ✅ v3.0: recibe TTSService en lugar de crear FlutterTts propio.
  // TTSService ya debe estar inicializado antes de llamar a este método.
  // (NavigationCoordinator lo inicializa en su propio initialize())

  Future<void> initialize(TTSService ttsService) async {
    if (_ttsReady) {
      _logger.w('[VoiceNav] Ya inicializado — skip');
      return;
    }

    _ttsService = ttsService;

    if (!ttsService.isInitialized) {
      _logger.e('[VoiceNav] ❌ TTSService aún no inicializado. '
          'Llama a coordinator.initialize() antes de voiceNav.initialize().');
      throw StateError('TTSService debe estar inicializado primero.');
    }

    // Suscribirse a completions para avanzar la cola de instrucciones
    _ttsCompletionSubscription = ttsService.onComplete.listen((_) {
      _onTTSCompleted();
    });

    _ttsReady = true;
    isReadyNotifier.value = true;
    _logger.i('[VoiceNav] ✅ v3.0 listo. Usando TTSService compartido.');
  }

  // ─── Callback de completion del TTS ──────────────────────────────────────

  void _onTTSCompleted() {
    // Solo nos interesa si la instrucción actual era nuestra
    if (_currentInstruction == null) return;
    _notifyUnityTTSStatus(speaking: false);
    _currentInstruction = null;
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

    // Deduplicación: mismo tipo + mismo texto → ignorar
    if (type == _lastAnnouncementType && text == _lastSpokenText) {
      _logger.d('[VoiceNav] 🔇 Dup [$type]');
      return;
    }

    _enqueue(_PendingInstruction(
      text:             text,
      priority:         _priorityForType(type),
      announcementType: type,
    ));
  }

  // ─── Cola de prioridad ───────────────────────────────────────────────────

  void _enqueue(_PendingInstruction instruction) {
    // Reemplazar pendiente si la nueva es igual o más urgente
    if (_pendingInstruction == null ||
        instruction.priority.index >= _pendingInstruction!.priority.index) {
      _pendingInstruction = instruction;
    }

    final isSpeaking = _ttsService?.isSpeaking ?? false;

    if (!isSpeaking) {
      _speakPending();
    } else if (instruction.priority == _InstructionPriority.urgent) {
      // Urgente: interrumpir TTS actual inmediatamente
      _ttsService?.stop().then((_) {
        _notifyUnityTTSStatus(speaking: false);
        _currentInstruction = null;
        _speakPending();
      });
    }
    // Menor prioridad mientras TTS activo: esperar a _onTTSCompleted
  }

  void _speakPending() {
    if (_pendingInstruction == null || !_ttsReady || _ttsService == null) return;
    _currentInstruction   = _pendingInstruction;
    _pendingInstruction   = null;
    _lastSpokenText       = _currentInstruction!.text;
    _lastAnnouncementType = _currentInstruction!.announcementType;
    _speak(_currentInstruction!);
  }

  Future<void> _speak(_PendingInstruction instruction) async {
    if (!_ttsReady || _ttsService == null) return;
    _logger.i('[VoiceNav] 🔊 [${instruction.announcementType}] "${instruction.text}"');

    // Notificar a Unity ANTES de hablar
    _notifyUnityTTSStatus(speaking: true);

    // ✅ v3.0: interrupt=true solo para high/urgent para no cortar
    // instrucciones del coordinator (saludos, respuestas de Groq, etc.)
    final shouldInterrupt =
        instruction.priority == _InstructionPriority.urgent ||
            instruction.priority == _InstructionPriority.high;

    await _ttsService!.speak(instruction.text, interrupt: shouldInterrupt);
  }

  // ─── ✅ Notificación a Unity vía postMessage ─────────────────────────────

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

  // ─── API pública ─────────────────────────────────────────────────────────

  /// Habla un texto arbitrario (bypass de la cola, prioridad medium).
  Future<void> speak(String text) async {
    if (!_ttsReady || _ttsService == null) return;
    _currentInstruction = _PendingInstruction(
      text:             text,
      priority:         _InstructionPriority.medium,
      announcementType: 'manual',
    );
    _notifyUnityTTSStatus(speaking: true);
    await _ttsService!.speak(text, interrupt: false);
  }

  /// Detiene el TTS y notifica a Unity.
  Future<void> stop() async {
    if (_ttsService == null) return;
    await _ttsService!.stop();
    _currentInstruction = null;
    _pendingInstruction = null;
    _notifyUnityTTSStatus(speaking: false);
  }

  /// Limpia deduplicación al iniciar nueva navegación.
  void resetDeduplication() {
    _lastSpokenText       = '';
    _lastAnnouncementType = '';
    _pendingInstruction   = null;
  }

  Future<void> dispose() async {
    await _unitySubscription?.cancel();
    await _ttsCompletionSubscription?.cancel();
    _notifyUnityTTSStatus(speaking: false);
    isReadyNotifier.dispose();
  }

  // ─── Helpers de prioridad ────────────────────────────────────────────────

  static _InstructionPriority _priorityForType(String type) {
    switch (type) {
    // 3 = urgent → NPC pausa + interrumpe TTS anterior
      case 'ApproachingStairs':
      case 'StartingClimb':
      case 'StartingDescent':
      case 'ObstacleWarning':
        return _InstructionPriority.urgent;

    // 2 = high → NPC pausa hasta que TTS termina
      case 'TurnLeft':
      case 'TurnRight':
      case 'SlightLeft':
      case 'SlightRight':
      case 'UTurn':
        return _InstructionPriority.high;

    // 1 = medium → NPC NO pausa
      case 'StartNavigation':
      case 'Arrived':
      case 'StairsComplete':
      case 'ResumeGuide':
      case 'FloorReached':
      case 'ResumeAfterSeparation':
        return _InstructionPriority.medium;

    // 0 = low → NPC NO pausa
      case 'GoStraight':
      case 'WaitingForUser':
      case 'UserStopped':
      case 'UserDeviated':
      case 'ProgressUpdate':
      default:
        return _InstructionPriority.low;
    }
  }
}