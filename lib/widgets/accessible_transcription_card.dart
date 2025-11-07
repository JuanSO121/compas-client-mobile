// lib/widgets/accessible_transcription_card.dart - VERSIÓN MINIMALISTA PROFESIONAL
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

class AccessibleTranscriptionCard extends StatelessWidget {
  final String transcription;
  final String aiResponse;
  final double? confidence;
  final double? processingTime;
  final bool publishedToRos;
  final bool autoSpeak;

  const AccessibleTranscriptionCard({
    Key? key,
    required this.transcription,
    required this.aiResponse,
    this.confidence,
    this.processingTime,
    required this.publishedToRos,
    required this.autoSpeak,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Semantics(
      label: 'Respuesta del robot',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: theme.colorScheme.primary.withOpacity(0.2),
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isDark ? 0.3 : 0.08),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // TU COMANDO
            if (transcription.isNotEmpty) ...[
              Semantics(
                label: 'Tu comando',
                header: true,
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        Icons.person_rounded,
                        size: 20,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Tu comando',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface.withOpacity(0.6),
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Semantics(
                label: 'Comando: $transcription',
                readOnly: true,
                child: Text(
                  transcription,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.onSurface,
                    height: 1.5,
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],

            // RESPUESTA DEL ROBOT
            if (aiResponse.isNotEmpty) ...[
              Semantics(
                label: 'Respuesta del robot',
                header: true,
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.secondary.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        Icons.smart_toy_outlined,
                        size: 20,
                        color: theme.colorScheme.secondary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Robot',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface.withOpacity(0.6),
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Semantics(
                label: 'Respuesta: $aiResponse',
                readOnly: true,
                liveRegion: true,
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondary.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    aiResponse,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.onSurface,
                      height: 1.6,
                    ),
                  ),
                ),
              ),
            ],

            // METADATA (CONFIANZA Y TIEMPO)
            if (confidence != null || processingTime != null) ...[
              const SizedBox(height: 16),
              Semantics(
                label: _buildMetadataLabel(),
                readOnly: true,
                child: Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    if (confidence != null)
                      _buildMetadataChip(
                        icon: Icons.graphic_eq_rounded,
                        label: '${(confidence! * 100).toStringAsFixed(0)}%',
                        color: _getConfidenceColor(confidence!, theme),
                      ),
                    if (processingTime != null)
                      _buildMetadataChip(
                        icon: Icons.speed_rounded,
                        label: '${processingTime!.toStringAsFixed(1)}s',
                        color: theme.colorScheme.primary,
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMetadataChip({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Color _getConfidenceColor(double confidence, ThemeData theme) {
    if (confidence >= 0.8) return theme.colorScheme.secondary;
    if (confidence >= 0.6) return theme.colorScheme.primary;
    return theme.colorScheme.error;
  }

  String _buildMetadataLabel() {
    final parts = <String>[];
    if (confidence != null) {
      parts.add('Confianza: ${(confidence! * 100).toStringAsFixed(0)} por ciento');
    }
    if (processingTime != null) {
      parts.add('Tiempo: ${processingTime!.toStringAsFixed(1)} segundos');
    }
    return parts.join(', ');
  }
}