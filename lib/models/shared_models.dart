// lib/models/shared_models.dart
// ============================================================================
// MODELOS COMPARTIDOS ENTRE TODOS LOS SERVICIOS
// ============================================================================

/// Enum de tipos de intención de navegación
enum IntentType { navigate, describe, obstacle, stop, help, unknown }

/// Enum de niveles de riesgo
enum RiskLevel { critical, high, medium, low }

/// Intención de navegación detectada por IA
class NavigationIntent {
  final IntentType type;
  final String target;
  final int priority;
  final String suggestedResponse;

  NavigationIntent({
    required this.type,
    required this.target,
    required this.priority,
    required this.suggestedResponse,
  });

  factory NavigationIntent.unknown() => NavigationIntent(
    type: IntentType.unknown,
    target: '',
    priority: 1,
    suggestedResponse: 'No entendí el comando',
  );

  factory NavigationIntent.waiting() => NavigationIntent(
    type: IntentType.unknown,
    target: '',
    priority: 0,
    suggestedResponse: 'Procesando comando anterior',
  );

  factory NavigationIntent.error(String msg) => NavigationIntent(
    type: IntentType.unknown,
    target: '',
    priority: 0,
    suggestedResponse: msg,
  );

  Map<String, dynamic> toJson() => {
    'type': type.toString(),
    'target': target,
    'priority': priority,
    'suggestedResponse': suggestedResponse,
  };

  @override
  String toString() => 'NavigationIntent($type: $target)';
}

/// Análisis espacial del entorno
class SpatialAnalysis {
  final String spaceType;
  final String dimensions;
  final String obstacles;
  final String navigationSuggestion;
  final bool hasError;
  final String description;
  final List<String> detectedObjects;
  final double confidenceScore;

  SpatialAnalysis({
    this.spaceType = 'desconocido',
    this.dimensions = '',
    this.obstacles = '',
    this.navigationSuggestion = '',
    this.hasError = false,
    this.description = '',
    this.detectedObjects = const [],
    this.confidenceScore = 0.0,
  });

  factory SpatialAnalysis.error(String msg) => SpatialAnalysis(
    spaceType: 'desconocido',
    navigationSuggestion: msg,
    hasError: true,
  );

  Map<String, dynamic> toJson() => {
    'spaceType': spaceType,
    'dimensions': dimensions,
    'obstacles': obstacles,
    'navigationSuggestion': navigationSuggestion,
    'description': description,
    'detectedObjects': detectedObjects,
    'confidenceScore': confidenceScore,
  };
}

/// Alerta de obstáculo detectado
class ObstacleAlert {
  final RiskLevel riskLevel;
  final double distance;
  final String direction;
  final String recommendedAction;
  final DateTime timestamp;
  final bool isCritical;

  ObstacleAlert({
    required this.riskLevel,
    required this.distance,
    required this.direction,
    this.recommendedAction = 'Precaución',
    DateTime? timestamp,
    bool? isCritical,
  })  : timestamp = timestamp ?? DateTime.now(),
        isCritical = isCritical ?? (riskLevel == RiskLevel.critical);

  bool get isRecent =>
      DateTime.now().difference(timestamp).inMilliseconds < 1000;

  Map<String, dynamic> toJson() => {
    'riskLevel': riskLevel.toString(),
    'distance': distance,
    'direction': direction,
    'recommendedAction': recommendedAction,
    'timestamp': timestamp.toIso8601String(),
    'isCritical': isCritical,
  };

  @override
  String toString() => 'ObstacleAlert($riskLevel: ${distance.toStringAsFixed(1)}m $direction)';
}

/// Punto de anclaje AR
class AnchorPoint {
  final double distance;
  final double bearing;
  final double elevation;

  AnchorPoint({
    required this.distance,
    required this.bearing,
    required this.elevation,
  });

  Map<String, dynamic> toJson() => {
    'distance': distance,
    'bearing': bearing,
    'elevation': elevation,
  };

  @override
  String toString() => 'AnchorPoint(${distance.toStringAsFixed(2)}m @ ${bearing.toStringAsFixed(0)}°)';
}

/// Detección de plano AR
class PlaneDetection {
  final String type; // floor, wall, ceiling, table
  final double area;
  final String orientation;

  PlaneDetection({
    required this.type,
    required this.area,
    required this.orientation,
  });

  Map<String, dynamic> toJson() => {
    'type': type,
    'area': area,
    'orientation': orientation,
  };
}

/// Modo de navegación
enum NavigationMode {
  /// Modo basado en eventos (wake word, cambios AR)
  /// Mejor para batería
  eventBased,

  /// Análisis continuo cada 2 segundos
  /// Máxima seguridad, mayor consumo
  continuous,
}

// ============================================================================
// ✅ MODELOS PARA CLASIFICACIÓN DE VOZ
// ============================================================================

/// Resultado de clasificación de comando de voz
class VoiceCommandResult {
  final String label;
  final double confidence;
  final bool passesThreshold;
  final double threshold;
  final int inferenceTimeMs;
  final List<double> logits;
  final bool hasError;
  final String? errorMessage;

  VoiceCommandResult({
    required this.label,
    required this.confidence,
    required this.passesThreshold,
    required this.threshold,
    required this.inferenceTimeMs,
    required this.logits,
    this.hasError = false,
    this.errorMessage,
  });

  factory VoiceCommandResult.empty() => VoiceCommandResult(
    label: 'UNKNOWN',
    confidence: 0.0,
    passesThreshold: false,
    threshold: 0.5,
    inferenceTimeMs: 0,
    logits: [],
    hasError: false,
  );

  factory VoiceCommandResult.error(String message) => VoiceCommandResult(
    label: 'ERROR',
    confidence: 0.0,
    passesThreshold: false,
    threshold: 0.0,
    inferenceTimeMs: 0,
    logits: [],
    hasError: true,
    errorMessage: message,
  );

  bool get isValid => !hasError && passesThreshold;
  bool get isCritical => label == 'STOP' || label == 'HELP';

  Map<String, dynamic> toJson() => {
    'label': label,
    'confidence': confidence,
    'passesThreshold': passesThreshold,
    'threshold': threshold,
    'inferenceTimeMs': inferenceTimeMs,
    'hasError': hasError,
    'errorMessage': errorMessage,
  };

  @override
  String toString() =>
      'VoiceCommandResult($label: ${(confidence * 100).toStringAsFixed(1)}%, ${passesThreshold ? "✅" : "❌"})';
}

/// Predicción de clase con confianza
class ClassPrediction {
  final String label;
  final double confidence;

  ClassPrediction({
    required this.label,
    required this.confidence,
  });

  @override
  String toString() => '$label: ${(confidence * 100).toStringAsFixed(1)}%';
}