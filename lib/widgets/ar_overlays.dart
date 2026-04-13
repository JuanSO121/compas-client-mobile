// lib/widgets/ar_overlays.dart
//
// ✅ v9.0 — Overlays de estado del sistema AR y barra de status.
// Contiene: _buildInitializingOverlay, _buildWaitingSessionOverlay,
//           _buildWaitingUserOverlay, _buildStatusBar, _buildTrackingBadge.

import 'package:flutter/material.dart';

import '../controllers/ar_navigation_controller.dart';
import '../services/voice_navigation_service.dart';
import '../services/unity_bridge_service.dart';

// ─── Overlay: inicializando (antes de scene_ready) ───────────────────────

class ArInitializingOverlay extends StatelessWidget {
  const ArInitializingOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withOpacity(0.82),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFFFF6B00)),
            SizedBox(height: 20),
            Text(
              'Conectando con AR...',
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w500,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Iniciando sistema de navegación',
              style: TextStyle(color: Color(0xFFAAAAAA), fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Overlay: cargando sesión (scene_ready llegó, esperando session_loaded)

class ArWaitingSessionOverlay extends StatelessWidget {
  const ArWaitingSessionOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withOpacity(0.60),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(
                color: Color(0xFFFF6B00),
                strokeWidth: 3,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Cargando sesión AR...',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Restaurando mapa y balizas',
              style: TextStyle(
                color: Colors.white.withOpacity(0.55),
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Overlay: sin sesión previa — confirmación del usuario ───────────────

class ArWaitingUserOverlay extends StatelessWidget {
  final bool wakeWordAvailable;
  final VoidCallback onReady;

  const ArWaitingUserOverlay({
    super.key,
    required this.wakeWordAvailable,
    required this.onReady,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withOpacity(0.78),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFFF6B00).withOpacity(0.15),
                    border: Border.all(
                      color: const Color(0xFFFF6B00).withOpacity(0.6),
                      width: 2,
                    ),
                  ),
                  child: const Icon(
                    Icons.navigation_rounded,
                    color: Color(0xFFFF6B00),
                    size: 40,
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'COMPAS listo',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Entorno AR preparado.\nNo hay sesión guardada — comenzarás de cero.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 15,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 36),
                GestureDetector(
                  onTap: onReady,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 32, vertical: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF6B00),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFFF6B00).withOpacity(0.4),
                          blurRadius: 20,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_circle_outline_rounded,
                            color: Colors.white, size: 22),
                        SizedBox(width: 10),
                        Text(
                          'Estoy listo',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (wakeWordAvailable)
                  Text(
                    'o di "Oye COMPAS: Estoy listo"',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.45),
                      fontSize: 13,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Badge de tracking inestable ─────────────────────────────────────────

class ArTrackingBadge extends StatelessWidget {
  final String reason;

  const ArTrackingBadge({super.key, required this.reason});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFE65100).withOpacity(0.92),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 8),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.sync_problem, color: Colors.white, size: 15),
          const SizedBox(width: 6),
          Text(
            reason.isNotEmpty ? 'Tracking: $reason' : 'Tracking inestable',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Barra de estado superior ────────────────────────────────────────────

class ArStatusBar extends StatelessWidget {
  final bool isActive;
  final String statusMessage;
  final bool segmentationActive;
  final UnityBridgeService unityBridge;
  final VoiceNavigationService voiceNav;

  const ArStatusBar({
    super.key,
    required this.isActive,
    required this.statusMessage,
    required this.segmentationActive,
    required this.unityBridge,
    required this.voiceNav,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          // Estado del sistema
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.65),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: isActive ? Colors.greenAccent : Colors.grey,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  statusMessage,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const Spacer(),
          // Badges de estado derecha
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // AR activo/cargando
              ValueListenableBuilder<bool>(
                valueListenable: unityBridge.isReadyNotifier,
                builder: (context, isConnected, _) => _StatusPill(
                  icon: Icons.view_in_ar,
                  label: isConnected ? 'AR Activo' : 'AR Cargando',
                  active: isConnected,
                ),
              ),
              const SizedBox(width: 6),
              // ML activo
              if (segmentationActive)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.65),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Icon(Icons.memory_rounded,
                      color: Colors.greenAccent, size: 14),
                ),
              const SizedBox(width: 6),
              // TTS listo
              ValueListenableBuilder<bool>(
                valueListenable: voiceNav.isReadyNotifier,
                builder: (_, ttsReady, __) => Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.65),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Icon(
                    ttsReady
                        ? Icons.record_voice_over_rounded
                        : Icons.voice_over_off_rounded,
                    color: ttsReady ? Colors.greenAccent : Colors.grey,
                    size: 14,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;

  const _StatusPill({
    required this.icon,
    required this.label,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.65),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon,
              color: active ? Colors.greenAccent : Colors.orange, size: 14),
          const SizedBox(width: 6),
          Text(label,
              style: const TextStyle(color: Colors.white, fontSize: 12)),
        ],
      ),
    );
  }
}