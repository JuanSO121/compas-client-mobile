// lib/widgets/ar_calibration_overlay.dart
//
// ✅ v1.0 — Overlay de calibración AR para primer arranque
//
// Muestra una animación y texto guía para que el usuario mueva la cámara
// lentamente al iniciar la sesión AR, asegurando que el tracking se inicialice
// correctamente antes de pasar al estado ready.
//
// CUÁNDO SE MUESTRA:
//   - Durante AppReadyState.waitingSession (Unity cargado, sesión no confirmada).
//   - Se autocierra al recibir AppReadyState.ready.
//   - También puede cerrarse manualmente tras un timeout de 12 segundos.
//
// DISEÑO:
//   Semi-transparente para que el usuario vea la cámara detrás.
//   Animación de "scan" que indica movimiento circular suave.
//   Instrucciones de texto claras y accesibles.

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

class ArCalibrationOverlay extends StatefulWidget {
  /// Callback cuando el usuario toca "Listo" o pasa el timeout.
  final VoidCallback? onDismiss;

  /// Si true, muestra instrucciones de wake word adicionales.
  final bool showVoiceHint;

  const ArCalibrationOverlay({
    super.key,
    this.onDismiss,
    this.showVoiceHint = false,
  });

  @override
  State<ArCalibrationOverlay> createState() => _ArCalibrationOverlayState();
}

class _ArCalibrationOverlayState extends State<ArCalibrationOverlay>
    with TickerProviderStateMixin {
  // ── Animaciones ──────────────────────────────────────────────────────────
  late AnimationController _rotateCtrl;
  late AnimationController _pulseCtrl;
  late AnimationController _fadeCtrl;

  late Animation<double> _rotate;
  late Animation<double> _pulse;
  late Animation<double> _fade;

  // ── Pasos de instrucción ─────────────────────────────────────────────────
  int _currentStep = 0;

  static const List<_CalibrationStep> _steps = [
    _CalibrationStep(
      icon: Icons.rotate_90_degrees_ccw_rounded,
      title: 'Calibrando entorno AR',
      description: 'Mueve el dispositivo lentamente a los alrededores para que la cámara reconozca el espacio.',
    ),
    _CalibrationStep(
      icon: Icons.crop_free_rounded,
      title: 'Apunta a superficies',
      description: 'Enfoca el suelo y las paredes cercanas. Evita moverse demasiado rápido.',
    ),
    _CalibrationStep(
      icon: Icons.check_circle_outline_rounded,
      title: '¡Listo para navegar!',
      description: 'El entorno ha sido reconocido. Puedes comenzar a usar la navegación.',
    ),
  ];

  bool _canDismiss = false;

  @override
  void initState() {
    super.initState();

    // Animación de rotación del scanner (lenta, continua)
    _rotateCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
    _rotate = Tween(begin: 0.0, end: 2 * math.pi).animate(_rotateCtrl);

    // Pulso de los anillos
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _pulse = Tween(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    // Fade in inicial
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    )..forward();
    _fade = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeIn);

    SemanticsService.announce(
      'Calibrando entorno AR. Mueve el dispositivo lentamente.',
      TextDirection.ltr,
    );

    // Avanzar pasos automáticamente
    _scheduleStepAdvance();
  }

  void _scheduleStepAdvance() {
    Future.delayed(const Duration(seconds: 4), () {
      if (!mounted || _currentStep >= 1) return;
      setState(() => _currentStep = 1);
      _scheduleStepAdvance2();
    });
  }

  void _scheduleStepAdvance2() {
    Future.delayed(const Duration(seconds: 5), () {
      if (!mounted || _currentStep >= 2) return;
      setState(() {
        _currentStep = 2;
        _canDismiss = true;
        _rotateCtrl.stop();
      });
    });
  }

  @override
  void dispose() {
    _rotateCtrl.dispose();
    _pulseCtrl.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  void _dismiss() {
    if (!_canDismiss) return;
    _fadeCtrl.reverse().then((_) => widget.onDismiss?.call());
  }

  @override
  Widget build(BuildContext context) {
    final step = _steps[_currentStep];

    return FadeTransition(
      opacity: _fade,
      child: Container(
        color: Colors.black.withOpacity(0.72),
        child: SafeArea(
          child: Column(
            children: [
              const Spacer(),
              // ── Scanner animado ──────────────────────────────────────────
              SizedBox(
                width: 200,
                height: 200,
                child: AnimatedBuilder(
                  animation: Listenable.merge([_rotate, _pulse]),
                  builder: (_, __) => CustomPaint(
                    painter: _ScannerPainter(
                      angle: _rotate.value,
                      scale: _pulse.value,
                      finished: _currentStep == 2,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              // ── Texto principal ──────────────────────────────────────────
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 400),
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween(
                      begin: const Offset(0, 0.1),
                      end: Offset.zero,
                    ).animate(anim),
                    child: child,
                  ),
                ),
                child: Column(
                  key: ValueKey(_currentStep),
                  children: [
                    Icon(
                      step.icon,
                      color: _currentStep == 2
                          ? const Color(0xFF66BB6A)
                          : const Color(0xFF29B6F6),
                      size: 32,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      step.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 40),
                      child: Text(
                        step.description,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 15,
                          height: 1.5,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              // ── Indicadores de paso ──────────────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_steps.length, (i) {
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: _currentStep == i ? 20 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _currentStep == i
                          ? (_currentStep == 2
                          ? const Color(0xFF66BB6A)
                          : const Color(0xFF29B6F6))
                          : Colors.white30,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 24),
              // ── Botón "Continuar" (solo en paso final) ───────────────────
              AnimatedOpacity(
                opacity: _canDismiss ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 400),
                child: GestureDetector(
                  onTap: _dismiss,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 32, vertical: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF29B6F6).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                          color: const Color(0xFF29B6F6).withOpacity(0.5)),
                    ),
                    child: const Text(
                      'Comenzar navegación',
                      style: TextStyle(
                        color: Color(0xFF29B6F6),
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
              const Spacer(),
              // ── Hint de wake word (opcional) ─────────────────────────────
              if (widget.showVoiceHint)
                Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.06),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      children: const [
                        Icon(Icons.mic_rounded,
                            color: Color(0xFFFF6B00), size: 18),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Di "Oye COMPAS" seguido de tu destino para comenzar a navegar.',
                            style: TextStyle(
                                color: Colors.white60, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Modelo de paso ────────────────────────────────────────────────────────

class _CalibrationStep {
  final IconData icon;
  final String title;
  final String description;

  const _CalibrationStep({
    required this.icon,
    required this.title,
    required this.description,
  });
}

// ─── Painter del scanner ───────────────────────────────────────────────────

class _ScannerPainter extends CustomPainter {
  final double angle;
  final double scale;
  final bool finished;

  const _ScannerPainter({
    required this.angle,
    required this.scale,
    required this.finished,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 * 0.9 * scale;

    // ── Anillos exteriores ───────────────────────────────────────────────
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    for (int i = 3; i >= 1; i--) {
      ringPaint.color = finished
          ? const Color(0xFF66BB6A).withOpacity(0.15 * i)
          : const Color(0xFF29B6F6).withOpacity(0.12 * i);
      canvas.drawCircle(center, radius * (0.4 + 0.2 * i), ringPaint);
    }

    // ── Arco giratorio ───────────────────────────────────────────────────
    if (!finished) {
      final arcPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFF29B6F6).withOpacity(0.85);

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius * 0.85),
        angle,
        math.pi * 1.2,
        false,
        arcPaint,
      );

      // Punta brillante del arco
      final tipX =
          center.dx + radius * 0.85 * math.cos(angle + math.pi * 1.2);
      final tipY =
          center.dy + radius * 0.85 * math.sin(angle + math.pi * 1.2);
      final dotPaint = Paint()
        ..color = const Color(0xFF81D4FA)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
      canvas.drawCircle(Offset(tipX, tipY), 5, dotPaint);
    }

    // ── Cruz central ─────────────────────────────────────────────────────
    final crossPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = finished
          ? const Color(0xFF66BB6A).withOpacity(0.7)
          : const Color(0xFF29B6F6).withOpacity(0.5);

    const crossSize = 16.0;
    canvas.drawLine(
      center - const Offset(crossSize, 0),
      center + const Offset(crossSize, 0),
      crossPaint,
    );
    canvas.drawLine(
      center - const Offset(0, crossSize),
      center + const Offset(0, crossSize),
      crossPaint,
    );

    // ── Círculo central ──────────────────────────────────────────────────
    final dotPaint = Paint()
      ..color = finished
          ? const Color(0xFF66BB6A)
          : const Color(0xFF29B6F6);
    canvas.drawCircle(center, 5, dotPaint);

    // ── Check mark si terminó ────────────────────────────────────────────
    if (finished) {
      final checkPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0xFF66BB6A);

      final path = Path()
        ..moveTo(center.dx - 30, center.dy)
        ..lineTo(center.dx - 8, center.dy + 22)
        ..lineTo(center.dx + 32, center.dy - 24);

      canvas.drawPath(path, checkPaint);
    }
  }

  @override
  bool shouldRepaint(_ScannerPainter old) =>
      old.angle != angle ||
          old.scale != scale ||
          old.finished != finished;
}