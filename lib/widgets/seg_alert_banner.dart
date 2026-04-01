// lib/widgets/seg_alert_banner.dart
// ✅ v1.0 — Banner de alerta crítica de segmentación semántica
//
// Se muestra cuando la condición de bloqueo total se cumple:
//   obs+wall ≥ 90% del frame  AND  floor < 5%
//
// El banner pulsa en rojo con un mensaje de voz (TTS ya gestionado
// por ObstacleDetectionService). Este widget solo maneja la UI.

import 'package:flutter/material.dart';

enum SegCriticalReason { wall, obstacle, both }

class SegCriticalAlert {
  final SegCriticalReason reason;
  final double            wallPct;
  final double            obsPct;
  final double            floorPct;
  final DateTime          timestamp;

  const SegCriticalAlert({
    required this.reason,
    required this.wallPct,
    required this.obsPct,
    required this.floorPct,
    required this.timestamp,
  });

  String get message {
    return switch (reason) {
      SegCriticalReason.wall     => '¡Pared bloqueando el paso!',
      SegCriticalReason.obstacle => '¡Obstáculo bloqueando el paso!',
      SegCriticalReason.both     => '¡Camino bloqueado — pared y obstáculo!',
    };
  }
}

class SegAlertBanner extends StatefulWidget {
  final SegCriticalAlert? alert;

  const SegAlertBanner({super.key, this.alert});

  @override
  State<SegAlertBanner> createState() => _SegAlertBannerState();
}

class _SegAlertBannerState extends State<SegAlertBanner>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulse;
  late Animation<double>   _anim;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.75, end: 1.0).animate(
      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final alert = widget.alert;
    if (alert == null) return const SizedBox.shrink();

    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Opacity(
        opacity: _anim.value,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(
            color: Color(0xCCCC1010),
          ),
          child: Row(
            children: [
              const Icon(Icons.warning_rounded, color: Colors.white, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      alert.message,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Pared ${(alert.wallPct * 100).toStringAsFixed(0)}%  '
                      'Obs ${(alert.obsPct * 100).toStringAsFixed(0)}%  '
                      'Piso ${(alert.floorPct * 100).toStringAsFixed(0)}%',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}