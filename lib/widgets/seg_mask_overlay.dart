// lib/widgets/seg_mask_overlay.dart
// ✅ v1.0 — Overlay de máscara de segmentación semántica
//
// Recibe el Uint8List de maskData (312×312 bytes, cada byte = clase 0-3)
// y lo dibuja sobre la vista de cámara usando CustomPainter con la misma
// paleta de colores que el modelo usa en Python (COLORMAP).
//
// La máscara se escala al tamaño del widget usando ImageShader con
// FilterQuality.none para mantener los bordes de píxel definidos,
// lo cual es correcto para segmentación semántica.
//
// Adaptación dinámica al aspect ratio real de la cámara:
//   El modelo trabaja en 312×312 (cuadrado). La cámara entrega
//   imágenes en landscape (p.ej. 720×480 → 3:2). Flutter rota la
//   vista en portrait, así que el usuario ve 480×720 (2:3).
//   La máscara cuadrada se estira para cubrir el RenderBox del widget.
//   Esto es intencional y consistente con el resize que hace
//   ObstacleDetectionService (copyResize directo a 312×312 sin crop).

import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

// ─── Paleta COLORMAP (misma que Python) ───────────────────────────────────────
// Clase 0 = fondo     → negro
// Clase 1 = piso      → verde oscuro
// Clase 2 = obstáculo → rojo
// Clase 3 = pared     → amarillo-oliva
const List<Color> _kClassColors = [
  Color(0x800000000),  // clase 0: negro transparente (fondo — no distraer)
  Color(0x9900A020),   // clase 1: verde oscuro semitransparente (piso)
  Color(0xBBE03020),   // clase 2: rojo semitransparente (obstáculo)
  Color(0xBBD4B800),   // clase 3: amarillo oscuro semitransparente (pared)
];

/// Muestra la máscara de segmentación como overlay sobre la vista AR.
///
/// [maskData]  → Uint8List(312×312) con la clase predicha por píxel.
/// [opacity]   → opacidad global del overlay (0.0–1.0, default 0.6).
/// [showLegend]→ si mostrar la leyenda de clases en la esquina.
class SegMaskOverlay extends StatefulWidget {
  final Uint8List? maskData;
  final double     opacity;
  final bool       showLegend;

  const SegMaskOverlay({
    super.key,
    required this.maskData,
    this.opacity   = 0.60,
    this.showLegend = true,
  });

  @override
  State<SegMaskOverlay> createState() => _SegMaskOverlayState();
}

class _SegMaskOverlayState extends State<SegMaskOverlay> {
  ui.Image? _image;
  Uint8List? _lastData;

  static const int _kSize = 312;

  @override
  void didUpdateWidget(SegMaskOverlay old) {
    super.didUpdateWidget(old);
    if (widget.maskData != null && widget.maskData != _lastData) {
      _lastData = widget.maskData;
      _buildImage(widget.maskData!);
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.maskData != null) {
      _lastData = widget.maskData;
      _buildImage(widget.maskData!);
    }
  }

  Future<void> _buildImage(Uint8List mask) async {
    // Convertir máscara de clases a RGBA (4 bytes por píxel)
    final rgba = Uint8List(_kSize * _kSize * 4);
    for (int i = 0; i < _kSize * _kSize; i++) {
      final cls   = mask[i].clamp(0, 3);
      final color = _kClassColors[cls];
      rgba[i * 4 + 0] = (color.value >> 16) & 0xFF; // R
      rgba[i * 4 + 1] = (color.value >> 8)  & 0xFF; // G
      rgba[i * 4 + 2] = (color.value)       & 0xFF; // B
      rgba[i * 4 + 3] = (color.value >> 24) & 0xFF; // A
    }

    final codec = await ui.ImageDescriptor.raw(
      await ui.ImmutableBuffer.fromUint8List(rgba),
      width:           _kSize,
      height:          _kSize,
      pixelFormat:     ui.PixelFormat.rgba8888,
    ).instantiateCodec();

    final frame = await codec.getNextFrame();
    if (mounted) {
      setState(() => _image = frame.image);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Máscara
        if (_image != null)
          Positioned.fill(
            child: Opacity(
              opacity: widget.opacity,
              child: CustomPaint(
                painter: _MaskPainter(_image!),
              ),
            ),
          ),

        // Leyenda de clases
        if (widget.showLegend)
          Positioned(
            top: 8,
            left: 8,
            child: _SegLegend(),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }
}

// ─── Painter ─────────────────────────────────────────────────────────────────

class _MaskPainter extends CustomPainter {
  final ui.Image image;
  _MaskPainter(this.image);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..filterQuality = FilterQuality.none; // píxel a píxel — no blur

    // Escalar la máscara cuadrada al tamaño completo del widget
    final src = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final dst = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(image, src, dst, paint);
  }

  @override
  bool shouldRepaint(_MaskPainter old) => old.image != image;
}

// ─── Leyenda ──────────────────────────────────────────────────────────────────

class _SegLegend extends StatelessWidget {
  static const _entries = [
    ('Fondo',      Color(0xFF000000)),
    ('Piso',       Color(0xFF00A020)),
    ('Obstáculo',  Color(0xFFE03020)),
    ('Pared',      Color(0xFFD4B800)),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: _entries.map((e) {
          final (label, color) = e;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 12, height: 12,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}