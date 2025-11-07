// lib/models/voice_command.dart
class VoiceCommandResult {
  final bool success;
  final String? transcription;
  final String? aiResponse;
  final String? commandType;
  final double? confidence;
  final bool? robotAction;
  final String? error;
  final double? timestamp;
  final double? processingTime;

  VoiceCommandResult({
    required this.success,
    this.transcription,
    this.aiResponse,
    this.commandType,
    this.confidence,
    this.robotAction,
    this.error,
    this.timestamp,
    this.processingTime,
  });

  factory VoiceCommandResult.fromJson(Map<String, dynamic> json) {
    return VoiceCommandResult(
      success: json['success'] ?? false,
      transcription: json['transcription'],
      aiResponse: json['ai_response'],
      commandType: json['command_type'],
      confidence: json['confidence']?.toDouble(),
      robotAction: json['robot_action'],
      error: json['error'],
      timestamp: json['timestamp']?.toDouble(),
      processingTime: json['processing_time']?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'success': success,
      'transcription': transcription,
      'ai_response': aiResponse,
      'command_type': commandType,
      'confidence': confidence,
      'robot_action': robotAction,
      'error': error,
      'timestamp': timestamp,
      'processing_time': processingTime,
    };
  }

  @override
  String toString() {
    return 'VoiceCommandResult(success: $success, transcription: $transcription, aiResponse: $aiResponse, processingTime: $processingTime)';
  }
}
