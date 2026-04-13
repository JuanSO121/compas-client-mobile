// lib/widgets/ar_voice_overlay.dart
//
// ✅ v9.0 — Overlay de voz + panel de testing simplificado.
//
// Panel de testing reducido a lo esencial:
//   - NAVEGACIÓN: ir a destino + detener
//   - BALIZAS: crear baliza
//   - SEGMENTACIÓN: stats + toggle máscara
//
// Se eliminó: TTS speak, repetir/silenciar/estado guía (callbacks de debug).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/ar_navigation_controller.dart';
import '../models/shared_models.dart';
import '../services/unity_bridge_service.dart';
import '../services/voice_navigation_service.dart';
import 'ar_overlays.dart';

// ─── Voice overlay completo ───────────────────────────────────────────────

class ArVoiceOverlay extends StatefulWidget {
  final ArNavigationController controller;
  final AnimationController pulseController;
  final AnimationController waveController;
  final Animation<double> pulseAnimation;
  final Animation<double> waveAnimation;

  const ArVoiceOverlay({
    super.key,
    required this.controller,
    required this.pulseController,
    required this.waveController,
    required this.pulseAnimation,
    required this.waveAnimation,
  });

  @override
  State<ArVoiceOverlay> createState() => _ArVoiceOverlayState();
}

class _ArVoiceOverlayState extends State<ArVoiceOverlay> {
  ArNavigationController get ctrl => widget.controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) => SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 48),
            ArStatusBar(
              isActive: ctrl.isActive,
              statusMessage: ctrl.statusMessage,
              segmentationActive: ctrl.segmentationActive,
              unityBridge: ctrl.unityBridge,
              voiceNav: ctrl.voiceNav,
            ),
            const Spacer(),
            if (ctrl.currentIntent != null) ...[
              _CurrentCommandBanner(intent: ctrl.currentIntent!),
              const SizedBox(height: 12),
            ],
            if (ctrl.history.isNotEmpty)
              _CompactHistory(history: ctrl.history),
            const SizedBox(height: 16),
            _MainVoiceButton(
              isInitialized: ctrl.isInitialized,
              isActive: ctrl.isActive,
              pulseAnimation: widget.pulseAnimation,
              waveAnimation: widget.waveAnimation,
              onTap: () {
                ctrl.toggleVoice();
                if (ctrl.isActive) {
                  widget.pulseController.repeat(reverse: true);
                  widget.waveController.repeat();
                } else {
                  widget.pulseController.stop();
                  widget.waveController.stop();
                }
              },
            ),
            const SizedBox(height: 44),
          ],
        ),
      ),
    );
  }
}

// ─── Banner de comando actual ─────────────────────────────────────────────

class _CurrentCommandBanner extends StatelessWidget {
  final NavigationIntent intent;
  const _CurrentCommandBanner({required this.intent});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFFF6B00).withOpacity(0.85),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Icon(_intentIcon(intent.type), color: Colors.white, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                intent.suggestedResponse,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Historial compacto ───────────────────────────────────────────────────

class _CompactHistory extends StatelessWidget {
  final List<CommandItem> history;
  const _CompactHistory({required this.history});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.6),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: history.take(3).map((item) {
            final diff = DateTime.now().difference(item.time);
            final timeStr = diff.inSeconds < 60
                ? 'hace ${diff.inSeconds}s'
                : 'hace ${diff.inMinutes}m';
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Icon(_intentIcon(item.intent.type),
                      color: Colors.white70, size: 14),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      item.intent.suggestedResponse,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(timeStr,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 11)),
                ],
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

// ─── Botón principal de voz ───────────────────────────────────────────────

class _MainVoiceButton extends StatelessWidget {
  final bool isInitialized;
  final bool isActive;
  final Animation<double> pulseAnimation;
  final Animation<double> waveAnimation;
  final VoidCallback onTap;

  const _MainVoiceButton({
    required this.isInitialized,
    required this.isActive,
    required this.pulseAnimation,
    required this.waveAnimation,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isInitialized ? onTap : null,
      child: AnimatedBuilder(
        animation: pulseAnimation,
        builder: (context, child) => Transform.scale(
          scale: isActive ? pulseAnimation.value : 1.0,
          child: Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: !isInitialized
                  ? Colors.grey.withOpacity(0.7)
                  : (isActive
                  ? const Color(0xFFE53935).withOpacity(0.9)
                  : const Color(0xFFFF6B00).withOpacity(0.9)),
              boxShadow: [
                BoxShadow(
                  color: (isActive
                      ? const Color(0xFFE53935)
                      : const Color(0xFFFF6B00))
                      .withOpacity(0.4),
                  blurRadius: 24,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (isActive)
                  AnimatedBuilder(
                    animation: waveAnimation,
                    builder: (context, _) => Container(
                      width: 100 + (30 * waveAnimation.value),
                      height: 100 + (30 * waveAnimation.value),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withOpacity(
                              0.3 * (1 - waveAnimation.value)),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                Icon(
                  isActive ? Icons.stop_rounded : Icons.mic_rounded,
                  color: Colors.white,
                  size: 46,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Panel de testing (simplificado) ─────────────────────────────────────

class ArTestPanel extends StatefulWidget {
  final ArNavigationController controller;

  const ArTestPanel({super.key, required this.controller});

  @override
  State<ArTestPanel> createState() => _ArTestPanelState();
}

class _ArTestPanelState extends State<ArTestPanel> {
  final TextEditingController _navigateCtrl =
  TextEditingController(text: 'Entrada');
  final TextEditingController _waypointCtrl =
  TextEditingController(text: 'Baliza 1');

  ArNavigationController get ctrl => widget.controller;

  @override
  void dispose() {
    _navigateCtrl.dispose();
    _waypointCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final isReady = ctrl.unityBridge.isReady;
        return ValueListenableBuilder<bool>(
          valueListenable: ctrl.unityBridge.isReadyNotifier,
          builder: (context, _, __) => Container(
            width: 272,
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.65,
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
                    // Header
                    _PanelHeader(
                      unityBridge: ctrl.unityBridge,
                      voiceNav: ctrl.voiceNav,
                      sessionLoaded: ctrl.sessionLoaded,
                    ),

                    // Sesión restaurada
                    if (ctrl.sessionLoaded) ...[
                      const SizedBox(height: 10),
                      _SessionBadge(
                        waypointCount: ctrl.sessionWaypointCount,
                        hasNavMesh: ctrl.sessionHasNavMesh,
                      ),
                    ],

                    // ── NAVEGACIÓN ────────────────────────────────────────
                    const SizedBox(height: 14),
                    _SectionDivider(label: 'NAVEGACIÓN'),
                    const SizedBox(height: 10),
                    _InputRow(
                      controller: _navigateCtrl,
                      hint: 'Destino',
                      buttonLabel: 'Ir',
                      buttonIcon: Icons.navigation_rounded,
                      color: const Color(0xFF1565C0),
                      accentColor: const Color(0xFF64B5F6),
                      onPressed: isReady
                          ? () => ctrl.testNavigateTo(_navigateCtrl.text.trim())
                          : null,
                    ),
                    const SizedBox(height: 8),
                    _ActionButton(
                      label: 'Detener navegación',
                      icon: Icons.stop_circle_rounded,
                      color: const Color(0xFFB71C1C),
                      accentColor: const Color(0xFFEF9A9A),
                      onPressed: isReady ? ctrl.testStop : null,
                    ),

                    // ── BALIZAS ───────────────────────────────────────────
                    const SizedBox(height: 14),
                    _SectionDivider(label: 'BALIZAS'),
                    const SizedBox(height: 10),
                    _WaypointsList(waypointContext: ctrl.waypointContext),
                    _InputRow(
                      controller: _waypointCtrl,
                      hint: 'Nombre de la baliza',
                      buttonLabel: 'Crear',
                      buttonIcon: Icons.add_location_alt_rounded,
                      color: const Color(0xFF1B5E20),
                      accentColor: const Color(0xFFA5D6A7),
                      onPressed: isReady
                          ? () {
                        ctrl.testCreateWaypoint(
                            _waypointCtrl.text.trim());
                        _waypointCtrl.text =
                        'Baliza ${ctrl.waypointCounter}';
                      }
                          : null,
                    ),

                    // ── SEGMENTACIÓN ──────────────────────────────────────
                    const SizedBox(height: 14),
                    _SectionDivider(label: 'SEGMENTACIÓN'),
                    const SizedBox(height: 10),
                    _SegmentationPanel(controller: ctrl),
                    const SizedBox(height: 4),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─── Sub-widgets del panel ────────────────────────────────────────────────

class _PanelHeader extends StatelessWidget {
  final UnityBridgeService unityBridge;
  final VoiceNavigationService voiceNav;
  final bool sessionLoaded;

  const _PanelHeader({
    required this.unityBridge,
    required this.voiceNav,
    required this.sessionLoaded,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: const Color(0xFF7B1FA2).withOpacity(0.3),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(Icons.bug_report_rounded,
              color: Color(0xFFCE93D8), size: 16),
        ),
        const SizedBox(width: 8),
        const Text(
          'Panel de testing',
          style: TextStyle(
            color: Color(0xFFCE93D8),
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        const Spacer(),
        // Badges AR / SC / SES / TTS
        ValueListenableBuilder<bool>(
          valueListenable: unityBridge.isReadyNotifier,
          builder: (_, arReady, __) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Badge(label: arReady ? 'AR ✓' : 'AR ⏳', active: arReady),
              const SizedBox(width: 4),
              _Badge(
                label: unityBridge.isSceneReady ? 'SC ✓' : 'SC ⏳',
                active: unityBridge.isSceneReady,
              ),
              const SizedBox(width: 4),
              _Badge(label: sessionLoaded ? 'SES ✓' : 'SES ⏳', active: sessionLoaded),
              const SizedBox(width: 4),
              ValueListenableBuilder<bool>(
                valueListenable: voiceNav.isReadyNotifier,
                builder: (_, ttsReady, __) => _Badge(
                  label: ttsReady ? 'TTS ✓' : 'TTS ⏳',
                  active: ttsReady,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final bool active;
  const _Badge({required this.label, required this.active});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: active
            ? Colors.green.withOpacity(0.2)
            : Colors.orange.withOpacity(0.2),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: active ? Colors.greenAccent : Colors.orange,
          width: 0.8,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: active ? Colors.greenAccent : Colors.orange,
          fontSize: 9,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SessionBadge extends StatelessWidget {
  final int waypointCount;
  final bool hasNavMesh;
  const _SessionBadge({required this.waypointCount, required this.hasNavMesh});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.green.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.green.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          const Icon(Icons.restore_rounded,
              color: Colors.greenAccent, size: 13),
          const SizedBox(width: 6),
          Text(
            'Sesión restaurada · $waypointCount baliza(s)'
                '${hasNavMesh ? " · NavMesh ✓" : ""}',
            style: const TextStyle(color: Colors.greenAccent, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _WaypointsList extends StatelessWidget {
  final dynamic waypointContext; // WaypointContextService
  const _WaypointsList({required this.waypointContext});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: waypointContext.onWaypointsChanged,
      builder: (_, __) {
        final hasWaypoints = waypointContext.hasWaypoints as bool;
        if (!hasWaypoints) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: Colors.blue.withOpacity(0.06),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.blue.withOpacity(0.2)),
            ),
            child: const Row(children: [
              Icon(Icons.info_outline,
                  color: Colors.lightBlueAccent, size: 13),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Sin balizas aún. Crea una para comenzar.',
                  style: TextStyle(
                      color: Colors.lightBlueAccent, fontSize: 11),
                ),
              ),
            ]),
          );
        }
        final names = (waypointContext.navigableWaypoints as List)
            .map((w) => w.name as String)
            .join(', ');
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: Colors.green.withOpacity(0.06),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.green.withOpacity(0.2)),
          ),
          child: Row(children: [
            const Icon(Icons.location_on,
                color: Colors.greenAccent, size: 13),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                names,
                style: const TextStyle(
                    color: Colors.greenAccent, fontSize: 11),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ]),
        );
      },
    );
  }
}

class _SegmentationPanel extends StatelessWidget {
  final ArNavigationController controller;
  const _SegmentationPanel({required this.controller});

  @override
  Widget build(BuildContext context) {
    final active = controller.segmentationActive;
    return Column(
      children: [
        // Estado del modelo
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: active
                ? Colors.green.withOpacity(0.10)
                : Colors.grey.withOpacity(0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active
                  ? Colors.greenAccent.withOpacity(0.35)
                  : Colors.white12,
            ),
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active ? Colors.greenAccent : Colors.grey[600],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  active ? 'Modelo ML activo' : 'Se activa al navegar',
                  style: TextStyle(
                    color: active ? Colors.greenAccent : Colors.grey[500],
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(
                active ? Icons.memory_rounded : Icons.memory_outlined,
                color: active
                    ? Colors.greenAccent.withOpacity(0.7)
                    : Colors.grey[700],
                size: 16,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Toggle máscara
        _ActionButton(
          label: controller.segMaskVisible
              ? 'Ocultar máscara AR'
              : 'Mostrar máscara AR',
          icon: controller.segMaskVisible
              ? Icons.layers_clear
              : Icons.layers,
          color: controller.segMaskVisible
              ? const Color(0xFF4A148C)
              : const Color(0xFF1B5E20),
          accentColor: controller.segMaskVisible
              ? const Color(0xFFCE93D8)
              : const Color(0xFFA5D6A7),
          onPressed: (controller.unityBridge.isReady && active)
              ? controller.testToggleSegMask
              : null,
          tooltip: active ? null : 'Solo disponible durante navegación',
        ),
        // Barras de segmentación
        if (active) ...[
          const SizedBox(height: 10),
          _SegmentationBars(
            obstacle: controller.segObstacle,
            floor: controller.segFloor,
            wall: controller.segWall,
            background: controller.segBackground,
          ),
        ],
      ],
    );
  }
}

class _SegmentationBars extends StatelessWidget {
  final double obstacle, floor, wall, background;
  static const double _alertThreshold =
      ArNavigationController.obstacleAlertThreshold;

  const _SegmentationBars({
    required this.obstacle,
    required this.floor,
    required this.wall,
    required this.background,
  });

  @override
  Widget build(BuildContext context) {
    final isAlert = obstacle >= _alertThreshold;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isAlert
              ? Colors.red.withOpacity(0.4)
              : Colors.white.withOpacity(0.08),
        ),
      ),
      child: Column(children: [
        _SegBar(label: 'BG',       value: background, color: const Color(0xFF888780)),
        const SizedBox(height: 6),
        _SegBar(label: 'Obstacle', value: obstacle,   color: const Color(0xFFE24B4A), alert: isAlert),
        const SizedBox(height: 6),
        _SegBar(label: 'Floor',    value: floor,      color: const Color(0xFF1D9E75)),
        const SizedBox(height: 6),
        _SegBar(label: 'Wall',     value: wall,       color: const Color(0xFF378ADD)),
      ]),
    );
  }
}

class _SegBar extends StatelessWidget {
  final String label;
  final double value;
  final Color color;
  final bool alert;

  const _SegBar({
    required this.label,
    required this.value,
    required this.color,
    this.alert = false,
  });

  @override
  Widget build(BuildContext context) {
    final pct = (value * 100).toStringAsFixed(1);
    return Row(
      children: [
        SizedBox(
          width: 58,
          child: Row(children: [
            Container(
              width: 8,
              height: 8,
              decoration:
              BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
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
                  alert ? const Color(0xFFE24B4A) : color),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 36,
          child: Text(
            '$pct%',
            style: TextStyle(
              fontSize: 11,
              color: alert ? Colors.red[300] : Colors.grey[500],
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
            child: const Text('⚠',
                style: TextStyle(fontSize: 9, color: Color(0xFFEF9A9A))),
          ),
        ],
      ],
    );
  }
}

// ─── Helpers compartidos (input row, action button, section divider) ──────

class _SectionDivider extends StatelessWidget {
  final String label;
  const _SectionDivider({required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Text(
        label,
        style: const TextStyle(
          color: Color(0xFF9E9E9E),
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
      const SizedBox(width: 8),
      Expanded(child: Container(height: 0.5, color: Colors.white12)),
    ]);
  }
}

class _InputRow extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final String buttonLabel;
  final IconData buttonIcon;
  final Color color;
  final Color accentColor;
  final VoidCallback? onPressed;

  const _InputRow({
    required this.controller,
    required this.hint,
    required this.buttonLabel,
    required this.buttonIcon,
    required this.color,
    required this.accentColor,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
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
              hintStyle: TextStyle(
                  color: Colors.white.withOpacity(0.35), fontSize: 12),
              border: InputBorder.none,
              contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
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
              Text(
                buttonLabel,
                style: TextStyle(
                  color: accentColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ]),
          ),
        ),
      ),
    ]);
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final Color accentColor;
  final VoidCallback? onPressed;
  final String? tooltip;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.accentColor,
    this.onPressed,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final button = GestureDetector(
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
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  color: accentColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ]),
        ),
      ),
    );
    if (tooltip != null && !enabled) {
      return Tooltip(
          message: tooltip!,
          triggerMode: TooltipTriggerMode.tap,
          child: button);
    }
    return button;
  }
}

// ─── Helper global de iconos por intent ──────────────────────────────────

IconData _intentIcon(IntentType type) => switch (type) {
  IntentType.navigate => Icons.navigation_rounded,
  IntentType.stop     => Icons.stop_circle_rounded,
  IntentType.describe => Icons.description_rounded,
  IntentType.help     => Icons.help_rounded,
  _                   => Icons.question_mark_rounded,
};