// lib/screens/environment_recognition_screen.dart
// ✅ v2.1 — Overlay de máscara de segmentación para verificación visual
//
// NUEVO en v2.1:
//   - Botón "Máscara" en la barra superior que alterna el overlay.
//   - Cuando está activo, se dibuja sobre la cámara un CustomPainter
//     que colorea cada píxel según su clase (igual que el video de Colab):
//       Negro      → background (clase 0)
//       Azul       → floor      (clase 1)
//       Rojo       → obstacle   (clase 2)
//       Amarillo   → wall       (clase 3)
//   - Alpha del overlay: 60% para ver la cámara debajo.
//   - El overlay se actualiza con cada resultado de segmentación.
//   - ObstacleDetectionService expone ahora maskData (List<List<int>>)
//     con el argmax por píxel de la última inferencia.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';

import '../services/obstacle_detection_service.dart';
import '../widgets/accessible_camera_button.dart';

// ─── Colores del overlay (mismo que COLORMAP del Colab) ──────────────────────
// clase 0 = background → negro   transparente (no pintar)
// clase 1 = floor      → azul
// clase 2 = obstacle   → rojo
// clase 3 = wall       → amarillo
const List<Color> _kClassColors = [
  Color(0x00000000), // background → transparente
  Color(0xFF2196F3), // floor      → azul
  Color(0xFFF44336), // obstacle   → rojo
  Color(0xFFFFEB3B), // wall       → amarillo
];

// ─── CustomPainter para la máscara ───────────────────────────────────────────

class _MaskPainter extends CustomPainter {
  final ui.Image? maskImage;

  _MaskPainter(this.maskImage);

  @override
  void paint(Canvas canvas, Size size) {
    if (maskImage == null) return;
    final paint = Paint()..filterQuality = FilterQuality.medium;

    final imgW = maskImage!.width.toDouble();
    final imgH = maskImage!.height.toDouble();
    final src  = Rect.fromLTWH(0, 0, imgW, imgH);

    // La cámara usa BoxFit.cover: escala la imagen para que cubra todo
    // el SizedBox manteniendo aspecto, y recorta los bordes.
    // La máscara debe seguir exactamente la misma transformación.
    final scaleX = size.width  / imgW;
    final scaleY = size.height / imgH;
    final scale  = scaleX > scaleY ? scaleX : scaleY; // cover = max scale

    final scaledW = imgW * scale;
    final scaledH = imgH * scale;
    final offsetX = (size.width  - scaledW) / 2;
    final offsetY = (size.height - scaledH) / 2;

    final dst = Rect.fromLTWH(offsetX, offsetY, scaledW, scaledH);
    canvas.drawImageRect(maskImage!, src, dst, paint);
  }

  @override
  bool shouldRepaint(_MaskPainter old) => old.maskImage != maskImage;
}

// ─── Screen ───────────────────────────────────────────────────────────────────

class EnvironmentRecognitionScreen extends StatefulWidget {
  const EnvironmentRecognitionScreen({super.key});

  @override
  State<EnvironmentRecognitionScreen> createState() =>
      _EnvironmentRecognitionScreenState();
}

class _EnvironmentRecognitionScreenState
    extends State<EnvironmentRecognitionScreen>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {

  // ─── Cámara ────────────────────────────────────────────────────────────────
  CameraController?       _cameraController;
  List<CameraDescription>? _cameras;
  bool _isCameraInitialized = false;
  bool _isStreaming          = false;

  // ─── Servicio ──────────────────────────────────────────────────────────────
  final ObstacleDetectionService _obstacleService = ObstacleDetectionService();
  bool _serviceReady = false;

  // ─── Estado de UI ──────────────────────────────────────────────────────────
  SegmentationResult? _lastResult;
  SegObstacleAlert?   _currentAlert;
  final List<SegObstacleAlert> _alertHistory = [];
  static const int _maxAlertHistory = 3;

  StreamSubscription<SegmentationResult>? _resultSub;
  StreamSubscription<SegObstacleAlert>?   _alertSub;
  Timer? _alertClearTimer;

  // ─── Overlay de máscara ────────────────────────────────────────────────────
  bool      _showMask  = false;
  ui.Image? _maskImage;

  @override
  bool get wantKeepAlive => true;

  // ─── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initServiceAndCamera();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SemanticsService.announce(
        'Pantalla de reconocimiento de entorno. Detección de obstáculos activa.',
        TextDirection.ltr,
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final ctrl = _cameraController;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _stopStream();
      ctrl.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initServiceAndCamera();
    }
  }

  Future<void> _initServiceAndCamera() async {
    try {
      await _obstacleService.initialize();
      if (mounted) setState(() => _serviceReady = true);

      _resultSub = _obstacleService.onSegmentationResult.listen((result) {
        if (!mounted) return;
        setState(() => _lastResult = result);
        // Reconstruir la imagen de máscara si el overlay está activo
        if (_showMask) _buildMaskImage(result);
      });

      _alertSub = _obstacleService.onObstacleAlert.listen((alert) {
        if (!mounted) return;
        setState(() {
          _currentAlert = alert;
          _alertHistory.insert(0, alert);
          if (_alertHistory.length > _maxAlertHistory) _alertHistory.removeLast();
        });
        SemanticsService.announce(alert.message, TextDirection.ltr);
        if (alert.level == SegAlertLevel.danger) {
          HapticFeedback.heavyImpact();
        } else {
          HapticFeedback.mediumImpact();
        }
        _alertClearTimer?.cancel();
        _alertClearTimer = Timer(const Duration(milliseconds: 2500), () {
          if (mounted) setState(() => _currentAlert = null);
        });
      });
    } catch (e) {
      _showSnackBar('Modelo de detección no disponible', isError: true);
    }
    await _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) {
        _showSnackBar('No se encontró cámara', isError: true);
        return;
      }
      final camera = _cameras!.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras!.first,
      );
      _cameraController = CameraController(
        camera, ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await _cameraController!.initialize();
      if (mounted) setState(() => _isCameraInitialized = true);
    } catch (e) {
      _showSnackBar('Error al iniciar cámara', isError: true);
    }
  }

  // ─── Máscara ───────────────────────────────────────────────────────────────

  /// Convierte el SegmentationResult en una ui.Image de 312×312 con los
  /// colores de clase, usando el maskData del servicio.
  void _buildMaskImage(SegmentationResult result) {
    final maskData = _obstacleService.lastMaskData;
    if (maskData == null) return;

    const size = 312;
    final pixels = Uint32List(size * size);

    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        final cls = maskData[y * size + x];
        final color = _kClassColors[cls.clamp(0, 3)];
        // ui.Image usa ARGB en little-endian → almacenar como ABGR
        final a = (color.a * 255).toInt() & 0xFF;
        final r = (color.r * 255).toInt() & 0xFF;
        final g = (color.g * 255).toInt() & 0xFF;
        final b = (color.b * 255).toInt() & 0xFF;
        // Flutter ui.Image pixel order: RGBA
        pixels[y * size + x] = (a << 24) | (b << 16) | (g << 8) | r;
      }
    }

    ui.decodeImageFromPixels(
      pixels.buffer.asUint8List(),
      size, size,
      ui.PixelFormat.rgba8888,
      (img) {
        if (mounted) setState(() => _maskImage = img);
      },
    );
  }

  // ─── Control de streaming ──────────────────────────────────────────────────

  Future<void> _startStream() async {
    if (!_isCameraInitialized || _cameraController == null || _isStreaming) return;
    try {
      _obstacleService.startDetection();
      await _cameraController!.startImageStream((CameraImage image) {
        _obstacleService.processCameraImage(image);
      });
      setState(() => _isStreaming = true);
      HapticFeedback.mediumImpact();
      _showSnackBar('Detección iniciada');
    } catch (e) {
      _showSnackBar('Error iniciando detección', isError: true);
    }
  }

  Future<void> _stopStream() async {
    if (!_isStreaming) return;
    try {
      _obstacleService.stopDetection();
      if (_cameraController?.value.isStreamingImages == true) {
        await _cameraController!.stopImageStream();
      }
    } catch (_) {}
    setState(() {
      _isStreaming  = false;
      _currentAlert = null;
      _maskImage    = null;
    });
    HapticFeedback.lightImpact();
  }

  void _switchCamera() async {
    if (_cameras == null || _cameras!.length < 2) {
      _showSnackBar('Solo una cámara disponible');
      return;
    }
    if (_isStreaming) await _stopStream();
    final currentLens = _cameraController?.description.lensDirection;
    await _cameraController?.dispose();
    final newCamera = currentLens == CameraLensDirection.back
        ? _cameras!.firstWhere(
            (c) => c.lensDirection == CameraLensDirection.front,
            orElse: () => _cameras!.first)
        : _cameras!.firstWhere(
            (c) => c.lensDirection == CameraLensDirection.back,
            orElse: () => _cameras!.first);
    _cameraController = CameraController(
      newCamera, ResolutionPreset.medium,
      enableAudio: false, imageFormatGroup: ImageFormatGroup.yuv420,
    );
    try {
      await _cameraController!.initialize();
      if (mounted) setState(() {});
    } catch (e) {
      _showSnackBar('Error al cambiar cámara', isError: true);
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      backgroundColor: isError
          ? Theme.of(context).colorScheme.error
          : Theme.of(context).colorScheme.secondary,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(16),
      duration: Duration(seconds: isError ? 3 : 2),
    ));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _alertClearTimer?.cancel();
    _resultSub?.cancel();
    _alertSub?.cancel();
    _stopStream();
    _cameraController?.dispose();
    super.dispose();
  }

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);

    return Stack(
      children: [
        // Cámara
        if (_isCameraInitialized && _cameraController != null)
          Positioned.fill(child: _buildCameraPreview())
        else
          Positioned.fill(child: _buildLoadingView(theme)),

        // Overlay de máscara — ahora renderizado dentro de _buildCameraPreview()

        // Leyenda de colores (visible cuando máscara activa)
        if (_showMask && _isStreaming)
          Positioned(
            bottom: 200, right: 16,
            child: _buildColorLegend(),
          ),

        // Barra superior
        Positioned(
          top: 16, left: 16, right: 16,
          child: _buildTopBar(theme),
        ),

        // Badge de alerta
        if (_currentAlert != null)
          Positioned(
            top: 90, left: 16, right: 16,
            child: _buildAlertBadge(_currentAlert!),
          ),

        // Stats de segmentación
        if (_isStreaming && _lastResult != null && !_showMask)
          Positioned(
            top: _currentAlert != null ? 160 : 90,
            left: 16, right: 16,
            child: _buildSegmentationStats(_lastResult!),
          ),

        // Controles inferiores
        Positioned(
          bottom: 32, left: 0, right: 0,
          child: _buildBottomControls(theme),
        ),

        // Historial
        if (_alertHistory.isNotEmpty && !_isStreaming)
          Positioned(
            bottom: 180, left: 16, right: 16,
            child: _buildAlertHistory(theme),
          ),
      ],
    );
  }

  // ─── Widgets ───────────────────────────────────────────────────────────────

  Widget _buildCameraPreview() {
    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width:  _cameraController!.value.previewSize!.height,
            height: _cameraController!.value.previewSize!.width,
            child: Stack(
              children: [
                CameraPreview(_cameraController!),
                // Máscara superpuesta con el MISMO tamaño que la cámara
                // → misma escala, sin distorsión
                if (_showMask && _maskImage != null)
                  Opacity(
                    opacity: 0.60,
                    child: SizedBox.expand(
                      child: CustomPaint(
                        painter: _MaskPainter(_maskImage),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingView(ThemeData theme) {
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation(theme.colorScheme.primary)),
            const SizedBox(height: 24),
            const Text('Iniciando cámara...',
                style: TextStyle(color: Colors.white, fontSize: 18,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(ThemeData theme) {
    // Fila 1: estado cámara + botón máscara
    // Fila 2: estado IA + botón cambiar cámara
    // Dividir en dos filas evita el overflow en pantallas estrechas
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.6),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.2)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Fila 1 ──────────────────────────────────────────────────────
          Row(
            children: [
              // Estado cámara
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: (_isCameraInitialized
                      ? theme.colorScheme.secondary
                      : theme.colorScheme.error).withOpacity(0.3),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(_isCameraInitialized ? Icons.videocam : Icons.videocam_off,
                      size: 13, color: Colors.white),
                  const SizedBox(width: 4),
                  Text(
                    _isStreaming ? 'DETECTANDO' : (_isCameraInitialized ? 'Lista' : 'Sin cámara'),
                    style: const TextStyle(color: Colors.white, fontSize: 11,
                        fontWeight: FontWeight.w600),
                  ),
                ]),
              ),

              const Spacer(),

              // Botón máscara
              GestureDetector(
                onTap: () {
                  setState(() {
                    _showMask = !_showMask;
                    if (!_showMask) _maskImage = null;
                  });
                  HapticFeedback.selectionClick();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _showMask
                        ? Colors.purple.withOpacity(0.5)
                        : Colors.white.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: _showMask ? Colors.purpleAccent : Colors.white30,
                    ),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.layers_rounded,
                        size: 13,
                        color: _showMask ? Colors.purpleAccent : Colors.white70),
                    const SizedBox(width: 4),
                    Text(
                      _showMask ? 'Máscara ON' : 'Máscara',
                      style: TextStyle(
                        color: _showMask ? Colors.purpleAccent : Colors.white70,
                        fontSize: 11, fontWeight: FontWeight.w600,
                      ),
                    ),
                  ]),
                ),
              ),
            ],
          ),

          const SizedBox(height: 6),

          // ── Fila 2 ──────────────────────────────────────────────────────
          Row(
            children: [
              // Estado IA
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: (_serviceReady ? Colors.green : Colors.orange).withOpacity(0.25),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: (_serviceReady ? Colors.greenAccent : Colors.orange).withOpacity(0.5),
                  ),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                    _serviceReady ? Icons.memory_rounded : Icons.hourglass_empty_rounded,
                    size: 12,
                    color: _serviceReady ? Colors.greenAccent : Colors.orange,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _serviceReady ? 'IA lista' : 'Cargando IA',
                    style: TextStyle(
                      color: _serviceReady ? Colors.greenAccent : Colors.orange,
                      fontSize: 11, fontWeight: FontWeight.w600,
                    ),
                  ),
                ]),
              ),

              const Spacer(),

              // Cambiar cámara
              Material(
                color: Colors.white.withOpacity(0.2),
                shape: const CircleBorder(),
                child: InkWell(
                  onTap: _isStreaming ? null : _switchCamera,
                  customBorder: const CircleBorder(),
                  child: const Padding(
                    padding: EdgeInsets.all(7),
                    child: Icon(Icons.flip_camera_ios_rounded,
                        color: Colors.white, size: 18),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Leyenda de colores que aparece cuando el overlay está activo
  Widget _buildColorLegend() {
    final items = [
      (_kClassColors[1], 'Piso'),
      (_kClassColors[2], 'Obstáculo'),
      (_kClassColors[3], 'Pared'),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.75),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: items.map((item) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 12, height: 12,
                decoration: BoxDecoration(
                  color: item.$1,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 6),
              Text(item.$2,
                  style: const TextStyle(color: Colors.white70, fontSize: 11)),
            ]),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildAlertBadge(SegObstacleAlert alert) {
    final isDanger = alert.level == SegAlertLevel.danger;
    final color    = isDanger ? const Color(0xFFD32F2F) : const Color(0xFFE65100);
    return Semantics(
      liveRegion: true,
      label: alert.message,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: color.withOpacity(0.93),
          borderRadius: BorderRadius.circular(18),
          boxShadow: [BoxShadow(color: color.withOpacity(0.5),
              blurRadius: 20, spreadRadius: 2)],
        ),
        child: Row(children: [
          Icon(isDanger ? Icons.warning_rounded : Icons.warning_amber_rounded,
              color: Colors.white, size: 26),
          const SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(alert.message, style: const TextStyle(
                  color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text('${(alert.proportion * 100).toStringAsFixed(0)}% del campo visual',
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ],
          )),
          Icon(alert.type == SegObstacleType.wall
              ? Icons.warehouse_rounded : Icons.block_rounded,
              color: Colors.white70, size: 20),
        ]),
      ),
    );
  }

  Widget _buildSegmentationStats(SegmentationResult result) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.72),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.bar_chart_rounded, color: Colors.white54, size: 14),
            const SizedBox(width: 6),
            const Text('Segmentación en vivo',
                style: TextStyle(color: Colors.white54, fontSize: 11,
                    fontWeight: FontWeight.w600, letterSpacing: 0.8)),
            const Spacer(),
            Text('${result.inferenceMs}ms',
                style: const TextStyle(color: Colors.white38, fontSize: 11)),
          ]),
          const SizedBox(height: 8),
          _buildClassBar('Piso',      result.floorRatio,      Colors.lightBlueAccent),
          _buildClassBar('Pared',     result.wallRatio,       Colors.amber),
          _buildClassBar('Obstáculo', result.obstacleRatio,   Colors.redAccent),
          _buildClassBar('Fondo',     result.backgroundRatio, Colors.white30),
        ],
      ),
    );
  }

  Widget _buildClassBar(String label, double ratio, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        SizedBox(
          width: 68,
          child: Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 11)),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: ratio.clamp(0.0, 1.0),
              backgroundColor: Colors.white12,
              valueColor: AlwaysStoppedAnimation(color),
              minHeight: 8,
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 36,
          child: Text('${(ratio * 100).toStringAsFixed(0)}%',
              textAlign: TextAlign.right,
              style: TextStyle(color: color, fontSize: 11,
                  fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }

  Widget _buildBottomControls(ThemeData theme) {
    return Column(children: [
      AccessibleCameraButton(
        isStreaming:   _isStreaming,
        isProcessing:  false,
        isConnected:   _isCameraInitialized && _serviceReady,
        onStartStream: _startStream,
        onStopStream:  _stopStream,
      ),
      const SizedBox(height: 20),
      if (!_isStreaming && _isCameraInitialized)
        Material(
          color: Colors.white.withOpacity(0.2),
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            onTap: null, // captura single frame — misma lógica que antes
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.camera_alt_rounded, color: Colors.white, size: 22),
                SizedBox(width: 10),
                Text('Analizar imagen',
                    style: TextStyle(fontSize: 16,
                        fontWeight: FontWeight.bold, color: Colors.white)),
              ]),
            ),
          ),
        ),
    ]);
  }

  Widget _buildAlertHistory(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.82),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(children: [
            Icon(Icons.history_rounded, color: Colors.white54, size: 14),
            SizedBox(width: 6),
            Text('Últimas alertas',
                style: TextStyle(color: Colors.white54, fontSize: 11,
                    fontWeight: FontWeight.w700, letterSpacing: 0.8)),
          ]),
          const SizedBox(height: 8),
          ..._alertHistory.map((alert) {
            final isDanger = alert.level == SegAlertLevel.danger;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Icon(isDanger ? Icons.warning_rounded : Icons.warning_amber_rounded,
                    color: isDanger ? Colors.redAccent : Colors.orangeAccent,
                    size: 14),
                const SizedBox(width: 8),
                Expanded(child: Text(alert.message,
                    style: const TextStyle(color: Colors.white70, fontSize: 13))),
                Text('${(alert.proportion * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(color: Colors.white38, fontSize: 11)),
              ]),
            );
          }),
        ],
      ),
    );
  }
}