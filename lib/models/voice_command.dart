// lib/models/voice_command.dart
// ✅ SOLO MODELOS ESPECÍFICOS DE COMANDOS (sin duplicar shared_models.dart)

/// Comando de voz procesado
class VoiceCommand {
  final String text;
  final String intent;
  final double confidence;
  final DateTime timestamp;
  final Map<String, dynamic>? metadata;

  VoiceCommand({
    required this.text,
    required this.intent,
    required this.confidence,
    DateTime? timestamp,
    this.metadata,
  }) : timestamp = timestamp ?? DateTime.now();

  bool get isHighConfidence => confidence >= 0.7;
  bool get isMediumConfidence => confidence >= 0.5 && confidence < 0.7;
  bool get isLowConfidence => confidence < 0.5;

  Map<String, dynamic> toJson() => {
    'text': text,
    'intent': intent,
    'confidence': confidence,
    'timestamp': timestamp.toIso8601String(),
    'metadata': metadata,
  };

  factory VoiceCommand.fromJson(Map<String, dynamic> json) {
    return VoiceCommand(
      text: json['text'] as String,
      intent: json['intent'] as String,
      confidence: (json['confidence'] as num).toDouble(),
      timestamp: DateTime.parse(json['timestamp'] as String),
      metadata: json['metadata'] as Map<String, dynamic>?,
    );
  }

  @override
  String toString() =>
      'VoiceCommand("$text" → $intent, ${(confidence * 100).toStringAsFixed(1)}%)';
}

/// Historial de comandos de voz
class VoiceCommandHistory {
  final List<VoiceCommand> _commands = [];
  static const int maxHistorySize = 50;

  void add(VoiceCommand command) {
    _commands.insert(0, command);

    // Mantener solo los últimos N comandos
    if (_commands.length > maxHistorySize) {
      _commands.removeRange(maxHistorySize, _commands.length);
    }
  }

  List<VoiceCommand> get commands => List.unmodifiable(_commands);

  VoiceCommand? get lastCommand => _commands.isNotEmpty ? _commands.first : null;

  List<VoiceCommand> getRecentCommands({int count = 10}) {
    return _commands.take(count).toList();
  }

  List<VoiceCommand> getCommandsByIntent(String intent) {
    return _commands.where((cmd) => cmd.intent == intent).toList();
  }

  void clear() {
    _commands.clear();
  }

  int get length => _commands.length;

  Map<String, dynamic> getStatistics() {
    if (_commands.isEmpty) {
      return {
        'total': 0,
        'average_confidence': 0.0,
        'intents': {},
      };
    }

    final intentCounts = <String, int>{};
    double totalConfidence = 0.0;

    for (final cmd in _commands) {
      intentCounts[cmd.intent] = (intentCounts[cmd.intent] ?? 0) + 1;
      totalConfidence += cmd.confidence;
    }

    return {
      'total': _commands.length,
      'average_confidence': totalConfidence / _commands.length,
      'intents': intentCounts,
      'last_command': lastCommand?.toJson(),
    };
  }
}