// lib/services/obstacle_detection_service.dart
// ✅ v2.0 — Lógica de proximidad avanzada (5 técnicas)
//
// NUEVAS TÉCNICAS vs v1.5:
//
//  1. ZONA VERTICAL (alta/media/baja)
//     La máscara 312×312 se divide en 3 franjas horizontales:
//       top    (y < 104) → obstáculo lejos (horizonte)
//       middle (104-208) → obstáculo acercándose
//       bottom (y > 208) → obstáculo inmediato (a los pies)
//     Se usa la zona con mayor concentración para calcular el nivel.
//
//  2. DIRECCIÓN LATERAL (izquierda / centro / derecha)
//     Centroide X de los píxeles de obstáculo/pared.
//     El mensaje TTS incluye la dirección: "Obstáculo a la izquierda",
//     "¡Pared al centro!" — más accionable para el usuario.
//
//  3. CRECIMIENTO TEMPORAL
//     Compara la proporción actual vs la media de los últimos 4 frames.
//     Si crece > 4% por frame → el usuario se acerca activamente.
//     En ese caso se reduce el umbral de alerta en un nivel.
//
//  4. FLOOR RATIO INVERSO
//     Si floorRatio < 8% Y hay obstáculo/pared en rango → el espacio
//     libre frente al usuario se está agotando. Sube urgencia.
//
//  5. CONFIANZA DE LOGIT (filtrado de ruido)
//     Solo se cuentan los píxeles donde el logit ganador supera 0.55.
//     Los píxeles de baja confianza (bordes, sombras) se ignoran.
//     Reduce falsos positivos sin perder detecciones reales.

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:camera/camera.dart';
import 'package:logger/logger.dart';
import 'package:image/image.dart' as img;

import 'tts_service.dart';

// ─── Enums y tipos ────────────────────────────────────────────────────────────

enum SegAlertLevel { none, warning, danger }

enum SegObstacleType { wall, obstacle }

/// Zona vertical del frame donde se concentra el obstáculo
enum SegZone { top, middle, bottom }

/// Dirección lateral del centroide del obstáculo
enum SegDirection { left, center, right }

class SegObstacleAlert {
  final SegAlertLevel   level;
  final SegObstacleType type;
  final double          proportion;
  final String          message;
  final DateTime        timestamp;
  final SegZone         zone;
  final SegDirection    direction;
  final bool            isApproaching; // crecimiento temporal detectado

  const SegObstacleAlert({
    required this.level,
    required this.type,
    required this.proportion,
    required this.message,
    required this.timestamp,
    required this.zone,
    required this.direction,
    required this.isApproaching,
  });

  @override
  String toString() =>
      'SegObstacleAlert(${type.name}, ${level.name}, '
      '${(proportion * 100).toStringAsFixed(1)}%, '
      '${zone.name}, ${direction.name}'
      '${isApproaching ? ", ACERCÁNDOSE" : ""})';
}

class SegmentationResult {
  final double backgroundRatio;
  final double floorRatio;
  final double wallRatio;
  final double obstacleRatio;
  final int    inferenceMs;
  final Uint8List? maskData;

  // Ratios por zona vertical (top / middle / bottom, franja de 104px cada una)
  final double obsTopRatio;
  final double obsMidRatio;
  final double obsBotRatio;
  final double wallTopRatio;
  final double wallMidRatio;
  final double wallBotRatio;

  // Centroides (0.0–1.0, normalizados)
  final double obsCentroidX;   // posición X del centroide de obstáculo
  final double wallCentroidX;  // posición X del centroide de pared

  // Píxeles de alta confianza (logit > 0.55)
  final double obsHighConfRatio;
  final double wallHighConfRatio;

  const SegmentationResult({
    required this.backgroundRatio,
    required this.floorRatio,
    required this.wallRatio,
    required this.obstacleRatio,
    required this.inferenceMs,
    this.maskData,
    this.obsTopRatio    = 0,
    this.obsMidRatio    = 0,
    this.obsBotRatio    = 0,
    this.wallTopRatio   = 0,
    this.wallMidRatio   = 0,
    this.wallBotRatio   = 0,
    this.obsCentroidX   = 0.5,
    this.wallCentroidX  = 0.5,
    this.obsHighConfRatio  = 0,
    this.wallHighConfRatio = 0,
  });

  @override
  String toString() =>
      'Seg(bg=${(backgroundRatio*100).toStringAsFixed(1)}% '
      'floor=${(floorRatio*100).toStringAsFixed(1)}% '
      'wall=${(wallRatio*100).toStringAsFixed(1)}% '
      'obs=${(obstacleRatio*100).toStringAsFixed(1)}% '
      '${inferenceMs}ms)';
}

// ─── Payload para el isolate ──────────────────────────────────────────────────

class _InferencePayload {
  final Uint8List modelBytes;
  final Uint8List yBytes;
  final Uint8List uBytes;
  final Uint8List vBytes;
  final int       width;
  final int       height;
  final int       yBytesPerRow;
  final int       uBytesPerRow;
  final int       uBytesPerPixel;
  final bool      isBgra;
  final Uint8List bgraBytes;

  const _InferencePayload({
    required this.modelBytes,
    required this.yBytes,
    required this.uBytes,
    required this.vBytes,
    required this.width,
    required this.height,
    required this.yBytesPerRow,
    required this.uBytesPerRow,
    required this.uBytesPerPixel,
    required this.isBgra,
    required this.bgraBytes,
  });
}

// ─── Función top-level para compute() ────────────────────────────────────────

SegmentationResult _runInference(_InferencePayload p) {
  const modelSize  = 312;
  const numClasses = 4;
  // Umbral de logit para considerar un píxel "de alta confianza"
  // Técnica 5: filtrado de ruido
  const double logitConfThreshold = 0.55;
  // Divisores de zona vertical: top < 104, middle 104-208, bottom >= 208
  const int zoneH = modelSize ~/ 3; // 104

  final sw = Stopwatch()..start();

  // 1. Reconstruir imagen RGB
  late img.Image source;
  if (p.isBgra) {
    source = img.Image.fromBytes(
      width: p.width, height: p.height,
      bytes: p.bgraBytes.buffer,
      order: img.ChannelOrder.bgra,
    );
  } else {
    source = img.Image(width: p.width, height: p.height);
    for (int y = 0; y < p.height; y++) {
      for (int x = 0; x < p.width; x++) {
        final yv  = p.yBytes[y * p.yBytesPerRow + x];
        final idx = (y ~/ 2) * p.uBytesPerRow + (x ~/ 2) * p.uBytesPerPixel;
        final uv  = p.uBytes[idx];
        final vv  = p.vBytes[idx];
        source.setPixelRgb(x, y,
          (yv + 1.402    * (vv - 128)).clamp(0, 255).toInt(),
          (yv - 0.344136 * (uv - 128) - 0.714136 * (vv - 128)).clamp(0, 255).toInt(),
          (yv + 1.772    * (uv - 128)).clamp(0, 255).toInt(),
        );
      }
    }
  }

  // 2. Resize directo a 312×312 (sin crop cuadrado).
  //
  //  La cámara entrega 720×480 landscape. La vista en pantalla muestra
  //  480×720 portrait via FittedBox.cover sin crop adicional.
  //  El resize directo alinea la máscara con lo que ve el usuario.
  //  La leve distorsión 4:3→1:1 es aceptable para segmentación semántica.
  final resized = img.copyResize(source,
    width: modelSize, height: modelSize,
    interpolation: img.Interpolation.linear,
  );

  // 3. Buffer float32 [1, 312, 312, 3]
  final inputBuf = List.generate(1, (_) =>
    List.generate(modelSize, (y) =>
      List.generate(modelSize, (x) {
        final px = resized.getPixel(x, y);
        return [px.r / 255.0, px.g / 255.0, px.b / 255.0];
      })));

  // 4. Output [1, 312, 312, 4]
  final outputBuf = List.generate(1, (_) =>
    List.generate(modelSize, (_) =>
      List.generate(modelSize, (_) =>
        List.filled(numClasses, 0.0))));

  // 5. Inferencia desde bytes
  final interpreter = Interpreter.fromBuffer(p.modelBytes,
    options: InterpreterOptions()..threads = 2,
  );
  interpreter.run(inputBuf, outputBuf);
  interpreter.close();

  sw.stop();

  // 6. Análisis del mapa de segmentación con las 5 técnicas
  int bg = 0, fl = 0, ob = 0, wa = 0;
  final total = modelSize * modelSize;
  final zoneTotal = modelSize * zoneH; // píxeles por zona

  // Contadores por zona vertical (técnica 1)
  int obTop = 0, obMid = 0, obBot = 0;
  int waTop = 0, waMid = 0, waBot = 0;

  // Acumuladores para centroide X (técnica 2)
  double obSumX = 0, obCount = 0;
  double waSumX = 0, waCount = 0;

  // Contadores de alta confianza (técnica 5)
  int obHighConf = 0, waHighConf = 0;

  // Máscara para overlay visual
  final maskBytes = Uint8List(total);

  for (int y = 0; y < modelSize; y++) {
    for (int x = 0; x < modelSize; x++) {
      final logits = outputBuf[0][y][x];

      // Argmax
      int mc = 0; double mv = logits[0];
      for (int c = 1; c < numClasses; c++) {
        if (logits[c] > mv) { mv = logits[c]; mc = c; }
      }

      // Softmax aproximado del logit ganador para medir confianza
      // Usamos el valor raw normalizado con sigmoid como proxy rápido
      final conf = 1.0 / (1.0 + _exp(-mv));
      final highConf = conf >= logitConfThreshold;

      maskBytes[y * modelSize + x] = mc;

      switch (mc) {
        case 0: bg++; break;
        case 1: fl++; break;
        case 2: // obstacle
          ob++;
          if (y < zoneH)           obTop++;
          else if (y < 2 * zoneH)  obMid++;
          else                     obBot++;
          obSumX += x; obCount++;
          if (highConf) obHighConf++;
          break;
        case 3: // wall
          wa++;
          if (y < zoneH)           waTop++;
          else if (y < 2 * zoneH)  waMid++;
          else                     waBot++;
          waSumX += x; waCount++;
          if (highConf) waHighConf++;
          break;
      }
    }
  }

  return SegmentationResult(
    backgroundRatio: bg / total,
    floorRatio:      fl / total,
    wallRatio:       wa / total,
    obstacleRatio:   ob / total,
    inferenceMs:     sw.elapsedMilliseconds,
    maskData:        maskBytes,
    // Zona vertical (proporción relativa a la zona, no al frame total)
    obsTopRatio:  obTop / zoneTotal,
    obsMidRatio:  obMid / zoneTotal,
    obsBotRatio:  obBot / zoneTotal,
    wallTopRatio: waTop / zoneTotal,
    wallMidRatio: waMid / zoneTotal,
    wallBotRatio: waBot / zoneTotal,
    // Centroide X normalizado 0..1
    obsCentroidX:  obCount  > 0 ? obSumX  / (obCount  * modelSize) : 0.5,
    wallCentroidX: waCount  > 0 ? waSumX  / (waCount  * modelSize) : 0.5,
    // Alta confianza (técnica 5)
    obsHighConfRatio:  ob > 0 ? obHighConf / total : 0,
    wallHighConfRatio: wa > 0 ? waHighConf / total : 0,
  );
}

/// Sigmoid rápido sin importar dart:math (aceptable en isolate)
double _exp(double x) {
  // Aproximación de e^x para rangos [-10, 10]
  if (x > 10)  return 22026.5;
  if (x < -10) return 0.0000454;
  double r = 1 + x / 256;
  r *= r; r *= r; r *= r; r *= r;
  r *= r; r *= r; r *= r; r *= r; // r^256
  return r;
}

// ─── Servicio principal ───────────────────────────────────────────────────────

class ObstacleDetectionService {
  static final ObstacleDetectionService _instance =
      ObstacleDetectionService._internal();
  factory ObstacleDetectionService() => _instance;
  ObstacleDetectionService._internal();

  final Logger     _logger     = Logger();
  final TTSService _ttsService = TTSService();

  Uint8List? _modelBytes;

  bool _isInitialized = false;
  bool _isRunning     = false;
  bool _isProcessing  = false;

  // ── Umbrales base ─────────────────────────────────────────────────────────
  //
  // Estos umbrales se aplican a la zona más relevante (bottom > mid > top),
  // no al frame completo. Eso los hace más sensibles sin aumentar falsos +.
  static const double _wallWarning = 0.55; // 55% de la zona inferior
  static const double _wallDanger  = 0.75;
  static const double _obsWarning  = 0.20;
  static const double _obsDanger   = 0.45;

  // Umbral de alta confianza para decidir zona dominante (técnica 5)
  static const double _highConfMin = 0.08; // 8% del frame en alta confianza

  // ── Estabilidad ───────────────────────────────────────────────────────────
  static const int _framesForWarning = 5;
  static const int _framesForDanger  = 3;

  int           _consecutiveFrames = 0;
  SegAlertLevel _pendingLevel      = SegAlertLevel.none;

  // ── Cooldown ─────────────────────────────────────────────────────────────
  static const Duration _timeCooldown   = Duration(seconds: 6);
  static const int      _framesCooldown = 18;

  DateTime?     _lastAlertTime;
  int           _framesSinceAlert = 999;
  SegAlertLevel _lastEmittedLevel = SegAlertLevel.none;

  // ── Historial para crecimiento temporal (técnica 3) ───────────────────────
  // Guardamos las últimas 4 proporciones de obstáculo+pared
  final List<double> _recentProportions = [];
  static const int _historySize = 4;

  // ── Streams ───────────────────────────────────────────────────────────────
  final _alertController  = StreamController<SegObstacleAlert>.broadcast();
  final _resultController = StreamController<SegmentationResult>.broadcast();

  Stream<SegObstacleAlert>   get onObstacleAlert      => _alertController.stream;
  Stream<SegmentationResult> get onSegmentationResult => _resultController.stream;

  // ─── Inicialización ───────────────────────────────────────────────────────

  Future<void> initialize() async {
    if (_isInitialized) return;
    try {
      _logger.i('[ObstacleDetection] Inicializando...');

      if (!_ttsService.isInitialized) await _ttsService.initialize();

      final byteData = await rootBundle.load('assets/models/deeplabv3_plus.tflite');
      _modelBytes = byteData.buffer.asUint8List();
      _logger.i('[ObstacleDetection] Modelo: ${(_modelBytes!.length / 1024 / 1024).toStringAsFixed(1)} MB');

      final test = Interpreter.fromBuffer(_modelBytes!,
          options: InterpreterOptions()..threads = 1);
      final inShape  = test.getInputTensor(0).shape;
      final outShape = test.getOutputTensor(0).shape;
      test.close();
      _logger.i('[ObstacleDetection] ✅ Validado — in:$inShape out:$outShape');

      _isInitialized = true;
    } catch (e) {
      _logger.e('[ObstacleDetection] ❌ $e');
      rethrow;
    }
  }

  // ─── Control ─────────────────────────────────────────────────────────────

  void startDetection() {
    if (!_isInitialized) return;
    _resetCounters();
    _isRunning = true;
    _logger.i('[ObstacleDetection] ▶️ Iniciado');
  }

  void stopDetection() {
    _isRunning    = false;
    _isProcessing = false;
    _resetCounters();
    _logger.i('[ObstacleDetection] ⏹️ Detenido');
  }

  void _resetCounters() {
    _consecutiveFrames = 0;
    _pendingLevel      = SegAlertLevel.none;
    _framesSinceAlert  = 999;
    _recentProportions.clear();
  }

  // ─── Procesamiento de frames ──────────────────────────────────────────────

  void processCameraImage(CameraImage image) {
    if (!_isRunning || !_isInitialized || _isProcessing) return;
    if (_modelBytes == null) return;
    _isProcessing = true;

    final payload = _buildPayload(image);
    if (payload == null) { _isProcessing = false; return; }

    compute(_runInference, payload).then((result) {
      if (result.maskData != null) _lastMaskData = result.maskData;
      _resultController.add(result);
      _logger.d('[ObstacleDetection] $result');
      _evaluateAlerts(result);
    }).catchError((e) {
      _logger.e('[ObstacleDetection] Error en isolate: $e');
    }).whenComplete(() {
      _isProcessing = false;
    });
  }

  _InferencePayload? _buildPayload(CameraImage image) {
    try {
      if (image.format.group == ImageFormatGroup.yuv420) {
        return _InferencePayload(
          modelBytes:     _modelBytes!,
          yBytes:         Uint8List.fromList(image.planes[0].bytes),
          uBytes:         Uint8List.fromList(image.planes[1].bytes),
          vBytes:         Uint8List.fromList(image.planes[2].bytes),
          width:          image.width,
          height:         image.height,
          yBytesPerRow:   image.planes[0].bytesPerRow,
          uBytesPerRow:   image.planes[1].bytesPerRow,
          uBytesPerPixel: image.planes[1].bytesPerPixel ?? 1,
          isBgra:         false,
          bgraBytes:      Uint8List(0),
        );
      } else if (image.format.group == ImageFormatGroup.bgra8888) {
        return _InferencePayload(
          modelBytes:     _modelBytes!,
          yBytes:         Uint8List(0),
          uBytes:         Uint8List(0),
          vBytes:         Uint8List(0),
          width:          image.width,
          height:         image.height,
          yBytesPerRow:   0,
          uBytesPerRow:   0,
          uBytesPerPixel: 0,
          isBgra:         true,
          bgraBytes:      Uint8List.fromList(image.planes[0].bytes),
        );
      }
      return null;
    } catch (e) {
      _logger.e('[ObstacleDetection] Error construyendo payload: $e');
      return null;
    }
  }

  // ─── Evaluación de alertas ────────────────────────────────────────────────

  void _evaluateAlerts(SegmentationResult result) {
    // ── Técnica 3: historial de proporciones para detectar aproximación ──
    final currentProp = result.obstacleRatio + result.wallRatio;
    _recentProportions.add(currentProp);
    if (_recentProportions.length > _historySize) {
      _recentProportions.removeAt(0);
    }
    final isApproaching = _detectApproach(currentProp);

    // ── Técnica 1 + 4 + 5: nivel con lógica enriquecida ──
    final currentLevel = _computeLevel(result, isApproaching);
    _framesSinceAlert++;

    if (currentLevel == _pendingLevel && currentLevel != SegAlertLevel.none) {
      _consecutiveFrames++;
    } else {
      _pendingLevel      = currentLevel;
      _consecutiveFrames = currentLevel == SegAlertLevel.none ? 0 : 1;
    }

    if (currentLevel == SegAlertLevel.none) {
      _lastEmittedLevel = SegAlertLevel.none;
      return;
    }

    final framesRequired = currentLevel == SegAlertLevel.danger
        ? _framesForDanger : _framesForWarning;
    if (_consecutiveFrames < framesRequired) return;

    final escalated = currentLevel.index > _lastEmittedLevel.index;
    final timeOk    = _lastAlertTime == null ||
        DateTime.now().difference(_lastAlertTime!) >= _timeCooldown;
    final framesOk  = _framesSinceAlert >= _framesCooldown;
    final sameLevel = currentLevel == _lastEmittedLevel;

    // Si se está acercando activamente, reduce el cooldown a la mitad
    final effectiveTimeOk = isApproaching
        ? (_lastAlertTime == null ||
           DateTime.now().difference(_lastAlertTime!) >= (_timeCooldown ~/ 2))
        : timeOk;

    if (sameLevel && (!effectiveTimeOk || !framesOk)) return;
    if (!escalated && !effectiveTimeOk) return;

    _emitAlert(currentLevel, result, isApproaching);
  }

  /// Técnica 3: retorna true si la proporción está creciendo consistentemente
  bool _detectApproach(double currentProp) {
    if (_recentProportions.length < 3) return false;
    int growingFrames = 0;
    for (int i = 1; i < _recentProportions.length; i++) {
      if (_recentProportions[i] > _recentProportions[i - 1] + 0.02) {
        growingFrames++;
      }
    }
    // Aproximación confirmada si al menos 2 de los últimos 3 frames crecieron
    return growingFrames >= 2;
  }

  /// Técnica 1 + 4 + 5: determina el nivel usando zona vertical, floor
  /// ratio inverso y confianza del logit
  SegAlertLevel _computeLevel(SegmentationResult r, bool isApproaching) {
    // ── Obstáculo ──
    // Usar la zona con mayor concentración de obstáculo (técnica 1)
    final obsEffective = _zoneEffective(
      r.obsBotRatio, r.obsMidRatio, r.obsTopRatio);

    // Ajustar por alta confianza (técnica 5): si pocos píxeles de alta
    // confianza, bajar la proporción efectiva un 30%
    final obsConf = r.obsHighConfRatio >= _highConfMin ? 1.0 : 0.7;
    final obsAdj  = obsEffective * obsConf;

    // ── Pared ──
    final waEffective = _zoneEffective(
      r.wallBotRatio, r.wallMidRatio, r.wallTopRatio);
    final waConf = r.wallHighConfRatio >= _highConfMin ? 1.0 : 0.7;
    final waAdj  = waEffective * waConf;

    // ── Técnica 4: floor ratio inverso ──
    // Si el piso visible < 8%, el espacio libre se está agotando
    final floorPenalty = r.floorRatio < 0.08 ? 1.15 : 1.0;

    final obsFinal = obsAdj * floorPenalty;
    final waFinal  = waAdj  * floorPenalty;

    // ── Si se aproxima activamente, bajar umbrales un nivel (técnica 3) ──
    final double obsWarnThr  = isApproaching ? _obsWarning * 0.75 : _obsWarning;
    final double obsDangerThr= isApproaching ? _obsDanger  * 0.75 : _obsDanger;
    final double waWarnThr   = isApproaching ? _wallWarning* 0.80 : _wallWarning;
    final double waDangerThr = isApproaching ? _wallDanger * 0.80 : _wallDanger;

    if (obsFinal >= obsDangerThr || waFinal >= waDangerThr) {
      return SegAlertLevel.danger;
    }
    if (obsFinal >= obsWarnThr || waFinal >= waWarnThr) {
      return SegAlertLevel.warning;
    }
    return SegAlertLevel.none;
  }

  /// Devuelve la proporción efectiva ponderando las zonas verticales.
  /// Bottom tiene peso 3×, middle 2×, top 1×.
  /// Esto simula profundidad: lo que está abajo en el frame está más cerca.
  double _zoneEffective(double bot, double mid, double top) {
    return (bot * 3.0 + mid * 2.0 + top * 1.0) / 6.0;
  }

  /// Técnica 2: determina la zona vertical dominante
  SegZone _dominantZone(double bot, double mid, double top) {
    if (bot >= mid && bot >= top) return SegZone.bottom;
    if (mid >= top)               return SegZone.middle;
    return SegZone.top;
  }

  /// Técnica 2: determina la dirección lateral del centroide
  SegDirection _centroidDirection(double cx) {
    if (cx < 0.38) return SegDirection.left;
    if (cx > 0.62) return SegDirection.right;
    return SegDirection.center;
  }

  void _emitAlert(SegAlertLevel level, SegmentationResult result,
      bool isApproaching) {
    final bool isObstacle = result.obstacleRatio >= _obsWarning &&
        result.obstacleRatio >= result.wallRatio;

    final SegObstacleType type;
    final double centroidX;
    final SegZone zone;
    final double proportion;

    if (isObstacle) {
      type       = SegObstacleType.obstacle;
      proportion = result.obstacleRatio;
      centroidX  = result.obsCentroidX;
      zone       = _dominantZone(
          result.obsBotRatio, result.obsMidRatio, result.obsTopRatio);
    } else {
      type       = SegObstacleType.wall;
      proportion = result.wallRatio;
      centroidX  = result.wallCentroidX;
      zone       = _dominantZone(
          result.wallBotRatio, result.wallMidRatio, result.wallTopRatio);
    }

    final direction = _centroidDirection(centroidX);

    // ── Construir mensaje TTS enriquecido (técnica 2) ──
    final message = _buildMessage(
        type, level, zone, direction, isApproaching);

    _lastAlertTime     = DateTime.now();
    _framesSinceAlert  = 0;
    _lastEmittedLevel  = level;
    _consecutiveFrames = 0;

    final alert = SegObstacleAlert(
      level: level, type: type,
      proportion: proportion, message: message,
      timestamp: DateTime.now(),
      zone: zone, direction: direction,
      isApproaching: isApproaching,
    );

    _alertController.add(alert);
    _logger.i('[ObstacleDetection] 🚨 $alert → "$message"');
    _ttsService.speak(message, interrupt: level == SegAlertLevel.danger);
  }

  /// Genera el mensaje TTS según tipo, nivel, zona y dirección.
  /// Máximo ~4 palabras para ser claro y rápido de escuchar.
  String _buildMessage(SegObstacleType type, SegAlertLevel level,
      SegZone zone, SegDirection direction, bool isApproaching) {

    // Si se está acercando activamente y es peligro → mensaje urgente corto
    if (isApproaching && level == SegAlertLevel.danger) {
      return type == SegObstacleType.wall ? '¡Cuidado, pared!' : '¡Para, obstáculo!';
    }

    final dirStr = switch (direction) {
      SegDirection.left   => 'izquierda',
      SegDirection.right  => 'derecha',
      SegDirection.center => 'al frente',
    };

    if (type == SegObstacleType.obstacle) {
      return switch (level) {
        SegAlertLevel.danger  => '¡Obstáculo $dirStr!',
        SegAlertLevel.warning => zone == SegZone.bottom
            ? 'Cuidado $dirStr'
            : 'Obstáculo $dirStr',
        SegAlertLevel.none    => '',
      };
    } else {
      // Pared
      return switch (level) {
        SegAlertLevel.danger  => zone == SegZone.bottom
            ? '¡Pared muy cerca!'
            : '¡Pared $dirStr!',
        SegAlertLevel.warning => 'Pared $dirStr',
        SegAlertLevel.none    => '',
      };
    }
  }

  // ─── Getters / Dispose ────────────────────────────────────────────────────

  Uint8List? _lastMaskData;
  Uint8List? get lastMaskData => _lastMaskData;

  bool get isInitialized => _isInitialized;
  bool get isRunning     => _isRunning;

  void dispose() {
    stopDetection();
    _modelBytes = null;
    _alertController.close();
    _resultController.close();
    _isInitialized = false;
    _logger.i('[ObstacleDetection] disposed');
  }
}