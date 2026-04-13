// lib/widgets/ar_test_panel.dart
// ✅ v1.0 — Panel de testing extraído de ArNavigationScreen
//
// Widget autocontenido que expone únicamente los callbacks necesarios.
// No conoce NavigationCoordinator ni UnityBridgeService directamente —
// recibe funciones y el estado que necesita como parámetros.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/shared_models.dart';
import '../services/unity_bridge_service.dart';
import '../services/AI/waypoint_context_service.dart';

// ─── Segmentation bar (standalone) ────────────────────────────────────────

class SegmentationBar extends StatelessWidget {
  const SegmentationBar({
    super.key,
    required this.label,
    required this.value,
    required this.color,
    this.alert = false,
  });

  final String label;
  final double value;
  final Color  color;
  final bool   alert;

  @override
  Widget build(BuildContext context) {
    final pct = (value * 100).toStringAsFixed(1);
    return Row(
      children: [
        SizedBox(
          width: 68,
          child: Row(children: [
            Container(
              width: 8, height: 8,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: alert ? Colors.red[200] : Colors.grey[500],
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ]),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: value.clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: Colors.white.withOpacity(0.08),
              valueColor: AlwaysStoppedAnimation<Color>(
                alert ? const Color(0xFFE24B4A) : color,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 40,
          child: Text(
            '$pct%',
            style: TextStyle(
              fontSize: 11,
              color: alert ? Colors.red[300] : Colors.grey[500],
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            textAlign: TextAlign.right,
          ),
        ),
        if (alert) ...[
          const SizedBox(width: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: const Color(0xFFB71C1C).withOpacity(0.6),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text(
              '⚠',
              style: TextStyle(fontSize: 9, color: Color(0xFFEF9A9A)),
            ),
          ),
        ],
      ],
    );
  }
}

// ─── ArTestPanel ───────────────────────────────────────────────────────────

class ArTestPanel extends StatefulWidget {
  const ArTestPanel({
    super.key,
    required this.unityBridge,
    required this.waypointContext,
    required this.onFireIntent,
    required this.onSnackBar,
    required this.segObstacle,
    required this.segFloor,
    required this.segWall,
    required this.segBackground,
    required this.segMaskVisible,
    required this.onToggleSegMask,
    required this.isSceneReady,
  });

  final UnityBridgeService     unityBridge;
  final WaypointContextService waypointContext;
  final Function(NavigationIntent) onFireIntent;
  final Function(String, {bool isError}) onSnackBar;

  final double segObstacle;
  final double segFloor;
  final double segWall;
  final double segBackground;
  final bool   segMaskVisible;
  final VoidCallback onToggleSegMask;
  final bool   isSceneReady;

  @override
  State<ArTestPanel> createState() => _ArTestPanelState();
}

class _ArTestPanelState extends State<ArTestPanel> {
  final _waypointNameController     = TextEditingController(text: 'Baliza 1');
  final _navigateTargetController   = TextEditingController(text: 'Entrada');
  final _ttsTestController          = TextEditingController(text: 'Claro, ¿en qué puedo ayudarte?');
  int _waypointCounter = 1;

  static const double _obstacleAlertThreshold = 0.12;

  @override
  void dispose() {
    _waypointNameController.dispose();
    _navigateTargetController.dispose();
    _ttsTestController.dispose();
    super.dispose();
  }

  bool get _unityReady => widget.unityBridge.isReady;

  void _testCreateWaypoint() {
    final name = _waypointNameController.text.trim();
    if (name.isEmpty) {
      widget.onSnackBar('⚠️ Escribe un nombre', isError: true);
      return;
    }
    _fire(NavigationIntent(
      type: IntentType.navigate,
      target: '__unity:create_waypoint:$name',
      priority: 6,
      suggestedResponse: 'Creando baliza "$name"',
    ));
    Future.delayed(const Duration(milliseconds: 400), () {
      widget.unityBridge.saveSession();
    });
    setState(() {
      _waypointCounter++;
      _waypointNameController.text = 'Baliza $_waypointCounter';
    });
  }

  void _testNavigateTo() {
    final target = _navigateTargetController.text.trim();
    if (target.isEmpty) {
      widget.onSnackBar('⚠️ Escribe un destino', isError: true);
      return;
    }
    _fire(NavigationIntent(
      type: IntentType.navigate,
      target: target,
      priority: 8,
      suggestedResponse: 'Navegando a $target',
    ));
  }

  void _testStop() {
    _fire(NavigationIntent(
      type: IntentType.stop,
      target: '',
      priority: 10,
      suggestedResponse: 'Navegación detenida',
    ));
  }

  void _testRepeatInstruction() {
    if (!_unityReady) { widget.onSnackBar('⚠️ Unity no lista', isError: true); return; }
    widget.unityBridge.repeatInstruction();
    widget.onSnackBar('🔁 Repetir instrucción enviado');
    HapticFeedback.lightImpact();
  }

  void _testStopVoice() {
    if (!_unityReady) { widget.onSnackBar('⚠️ Unity no lista', isError: true); return; }
    widget.unityBridge.stopVoice();
    widget.onSnackBar('🔇 Silenciar guía enviado');
    HapticFeedback.lightImpact();
  }

  void _testVoiceStatus() {
    if (!_unityReady) { widget.onSnackBar('⚠️ Unity no lista', isError: true); return; }
    widget.unityBridge.requestVoiceStatus();
    widget.onSnackBar('📊 voice_status solicitado');
    HapticFeedback.lightImpact();
  }

  void _testTTSSpeak() {
    if (!_unityReady) { widget.onSnackBar('⚠️ Unity no lista', isError: true); return; }
    final text = _ttsTestController.text.trim();
    if (text.isEmpty) { widget.onSnackBar('⚠️ Escribe un texto', isError: true); return; }
    widget.unityBridge.speakArbitraryText(text, priority: 1, interrupt: false);
    widget.onSnackBar('💬 tts_speak enviado');
    HapticFeedback.lightImpact();
  }

  void _fire(NavigationIntent intent) {
    widget.onFireIntent(intent);
    HapticFeedback.lightImpact();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.unityBridge.isReadyNotifier,
      builder: (context, isReady, _) {
        return Container(
          width: 290,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.70,
          ),
          decoration: BoxDecoration(
            color: const Color(0xFF0D0D1A).withOpacity(0.96),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: const Color(0xFF7B1FA2).withOpacity(0.6),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF7B1FA2).withOpacity(0.25),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildHeader(isReady),

                  // NAVEGACIÓN
                  const SizedBox(height: 14),
                  _sectionDivider('NAVEGACIÓN'),
                  const SizedBox(height: 10),
                  _inputRow(
                    controller: _navigateTargetController,
                    hint: 'Nombre del destino',
                    buttonLabel: 'Ir',
                    buttonIcon: Icons.navigation_rounded,
                    color: const Color(0xFF1565C0),
                    accentColor: const Color(0xFF64B5F6),
                    onPressed: isReady ? _testNavigateTo : null,
                  ),
                  const SizedBox(height: 8),
                  _actionButton(
                    label: 'Detener navegación',
                    icon: Icons.stop_circle_rounded,
                    color: const Color(0xFFB71C1C),
                    accentColor: const Color(0xFFEF9A9A),
                    onPressed: isReady ? _testStop : null,
                  ),

                  // BALIZAS
                  const SizedBox(height: 14),
                  _sectionDivider('BALIZAS'),
                  const SizedBox(height: 10),
                  _waypointStatus(),
                  _inputRow(
                    controller: _waypointNameController,
                    hint: 'Nombre de la baliza',
                    buttonLabel: 'Crear',
                    buttonIcon: Icons.add_location_alt_rounded,
                    color: const Color(0xFF1B5E20),
                    accentColor: const Color(0xFFA5D6A7),
                    onPressed: isReady ? _testCreateWaypoint : null,
                  ),

                  // GUÍA DE VOZ
                  const SizedBox(height: 14),
                  _sectionDivider('GUÍA DE VOZ'),
                  const SizedBox(height: 10),
                  _inputRow(
                    controller: _ttsTestController,
                    hint: 'Texto para COMPAS TTS',
                    buttonLabel: 'Hablar',
                    buttonIcon: Icons.record_voice_over_rounded,
                    color: const Color(0xFF4A148C),
                    accentColor: const Color(0xFFCE93D8),
                    onPressed: isReady ? _testTTSSpeak : null,
                  ),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(child: _actionButton(
                      label: 'Repetir',
                      icon: Icons.replay_rounded,
                      color: const Color(0xFF004D40),
                      accentColor: const Color(0xFF80CBC4),
                      onPressed: isReady ? _testRepeatInstruction : null,
                    )),
                    const SizedBox(width: 8),
                    Expanded(child: _actionButton(
                      label: 'Silenciar',
                      icon: Icons.voice_over_off_rounded,
                      color: const Color(0xFF37474F),
                      accentColor: const Color(0xFFB0BEC5),
                      onPressed: isReady ? _testStopVoice : null,
                    )),
                  ]),
                  const SizedBox(height: 8),
                  _actionButton(
                    label: 'Estado de guía',
                    icon: Icons.info_outline_rounded,
                    color: const Color(0xFF1A237E),
                    accentColor: const Color(0xFF90CAF9),
                    onPressed: isReady ? _testVoiceStatus : null,
                  ),

                  // SEGMENTACIÓN
                  const SizedBox(height: 14),
                  _sectionDivider('SEGMENTACIÓN'),
                  const SizedBox(height: 10),
                  _actionButton(
                    label: widget.segMaskVisible ? 'Ocultar máscara AR' : 'Mostrar máscara AR',
                    icon: widget.segMaskVisible ? Icons.layers_clear : Icons.layers,
                    color: widget.segMaskVisible ? const Color(0xFF4A148C) : const Color(0xFF1B5E20),
                    accentColor: widget.segMaskVisible ? const Color(0xFFCE93D8) : const Color(0xFFA5D6A7),
                    onPressed: isReady ? widget.onToggleSegMask : null,
                  ),
                  const SizedBox(height: 10),
                  _segBars(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(bool isReady) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: const Color(0xFF7B1FA2).withOpacity(0.3),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(Icons.bug_report_rounded, color: Color(0xFFCE93D8), size: 16),
        ),
        const SizedBox(width: 8),
        const Text(
          'Panel de testing',
          style: TextStyle(
            color: Color(0xFFCE93D8),
            fontSize: 14,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
        ),
        const Spacer(),
        _badge(label: isReady ? 'AR ✓' : 'AR ⏳', active: isReady),
        const SizedBox(width: 4),
        _badge(label: widget.isSceneReady ? 'SC ✓' : 'SC ⏳', active: widget.isSceneReady),
      ],
    );
  }

  Widget _waypointStatus() {
    return StreamBuilder<List<WaypointEntry>>(
      stream: widget.waypointContext.onWaypointsChanged,
      builder: (_, __) {
        if (!widget.waypointContext.hasWaypoints) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: Colors.blue.withOpacity(0.06),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.blue.withOpacity(0.2)),
            ),
            child: const Row(children: [
              Icon(Icons.info_outline, color: Colors.lightBlueAccent, size: 13),
              SizedBox(width: 6),
              Expanded(child: Text(
                'Sin balizas aún. Crea una para comenzar.',
                style: TextStyle(color: Colors.lightBlueAccent, fontSize: 11),
              )),
            ]),
          );
        }
        final names = widget.waypointContext.navigableWaypoints.map((w) => w.name).join(', ');
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: Colors.green.withOpacity(0.06),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.green.withOpacity(0.2)),
          ),
          child: Row(children: [
            const Icon(Icons.location_on, color: Colors.greenAccent, size: 13),
            const SizedBox(width: 6),
            Expanded(child: Text(
              names,
              style: const TextStyle(color: Colors.greenAccent, fontSize: 11),
              maxLines: 2, overflow: TextOverflow.ellipsis,
            )),
          ]),
        );
      },
    );
  }

  Widget _segBars() {
    final isAlert = widget.segObstacle >= _obstacleAlertThreshold;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isAlert ? Colors.red.withOpacity(0.4) : Colors.white.withOpacity(0.08),
        ),
      ),
      child: Column(
        children: [
          SegmentationBar(label: 'Background', value: widget.segBackground, color: const Color(0xFF888780)),
          const SizedBox(height: 6),
          SegmentationBar(label: 'Obstacle', value: widget.segObstacle, color: const Color(0xFFE24B4A), alert: isAlert),
          const SizedBox(height: 6),
          SegmentationBar(label: 'Floor', value: widget.segFloor, color: const Color(0xFF1D9E75)),
          const SizedBox(height: 6),
          SegmentationBar(label: 'Wall', value: widget.segWall, color: const Color(0xFF378ADD)),
        ],
      ),
    );
  }

  // ─── Widget helpers ───────────────────────────────────────────────────────

  static Widget _badge({required String label, required bool active}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: active ? Colors.green.withOpacity(0.2) : Colors.orange.withOpacity(0.2),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: active ? Colors.greenAccent : Colors.orange, width: 0.8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: active ? Colors.greenAccent : Colors.orange,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  static Widget _sectionDivider(String label) {
    return Row(children: [
      Text(label, style: const TextStyle(
        color: Color(0xFF9E9E9E), fontSize: 10,
        fontWeight: FontWeight.w700, letterSpacing: 1.2,
      )),
      const SizedBox(width: 8),
      Expanded(child: Container(height: 0.5, color: Colors.white12)),
    ]);
  }

  static Widget _inputRow({
    required TextEditingController controller,
    required String hint,
    required String buttonLabel,
    required IconData buttonIcon,
    required Color color,
    required Color accentColor,
    VoidCallback? onPressed,
  }) {
    final enabled = onPressed != null;
    return Row(children: [
      Expanded(
        child: Container(
          height: 38,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(enabled ? 0.07 : 0.03),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withOpacity(0.12)),
          ),
          child: TextField(
            controller: controller,
            enabled: enabled,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.35), fontSize: 12),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              isDense: true,
            ),
          ),
        ),
      ),
      const SizedBox(width: 8),
      GestureDetector(
        onTap: onPressed,
        child: AnimatedOpacity(
          opacity: enabled ? 1.0 : 0.35,
          duration: const Duration(milliseconds: 200),
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: color.withOpacity(0.85),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: accentColor.withOpacity(0.5)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(buttonIcon, color: accentColor, size: 15),
              const SizedBox(width: 5),
              Text(buttonLabel, style: TextStyle(color: accentColor, fontSize: 12, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      ),
    ]);
  }

  static Widget _actionButton({
    required String label,
    required IconData icon,
    required Color color,
    required Color accentColor,
    VoidCallback? onPressed,
  }) {
    final enabled = onPressed != null;
    return GestureDetector(
      onTap: onPressed,
      child: AnimatedOpacity(
        opacity: enabled ? 1.0 : 0.35,
        duration: const Duration(milliseconds: 200),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: color.withOpacity(0.75),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: accentColor.withOpacity(0.4)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: accentColor, size: 16),
            const SizedBox(width: 8),
            Flexible(child: Text(label,
              style: TextStyle(color: accentColor, fontSize: 12, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            )),
          ]),
        ),
      ),
    );
  }
}