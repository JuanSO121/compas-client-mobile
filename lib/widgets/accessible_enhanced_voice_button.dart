// lib/widgets/accessible_enhanced_voice_button.dart - BOTÓN GIGANTE PROFESIONAL
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';

class AccessibleEnhancedVoiceButton extends StatefulWidget {
  final bool isRecording;
  final bool isProcessing;
  final bool whisperAvailable;
  final VoidCallback? onStartRecording;
  final VoidCallback? onStopRecording;

  const AccessibleEnhancedVoiceButton({
    Key? key,
    required this.isRecording,
    required this.isProcessing,
    required this.whisperAvailable,
    this.onStartRecording,
    this.onStopRecording,
  }) : super(key: key);

  @override
  _AccessibleEnhancedVoiceButtonState createState() =>
      _AccessibleEnhancedVoiceButtonState();
}

class _AccessibleEnhancedVoiceButtonState
    extends State<AccessibleEnhancedVoiceButton>
    with TickerProviderStateMixin {

  late AnimationController _pulseController;
  late AnimationController _waveController;
  late Animation<double> _pulseAnimation;
  late Animation<double> _waveAnimation;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );

    _waveController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    );

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.08).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _waveAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _waveController, curve: Curves.linear),
    );
  }

  @override
  void didUpdateWidget(AccessibleEnhancedVoiceButton oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.isRecording && !oldWidget.isRecording) {
      _pulseController.repeat(reverse: true);
      _waveController.repeat();
      SemanticsService.announce('Grabando', TextDirection.ltr);
    } else if (!widget.isRecording && oldWidget.isRecording) {
      _pulseController.stop();
      _waveController.stop();
      _pulseController.reset();
      _waveController.reset();
      SemanticsService.announce('Grabación detenida', TextDirection.ltr);
    }

    if (widget.isProcessing && !oldWidget.isProcessing) {
      SemanticsService.announce('Procesando', TextDirection.ltr);
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _waveController.dispose();
    super.dispose();
  }

  void _handleTap() {
    if (!widget.whisperAvailable) {
      SemanticsService.announce('Servicio no disponible', TextDirection.ltr);
      HapticFeedback.vibrate();
      return;
    }

    if (widget.isProcessing) {
      SemanticsService.announce('Procesando, espere', TextDirection.ltr);
      return;
    }

    if (widget.isRecording) {
      HapticFeedback.lightImpact();
      widget.onStopRecording?.call();
    } else {
      HapticFeedback.mediumImpact();
      widget.onStartRecording?.call();
    }
  }

  String _getSemanticLabel() {
    if (!widget.whisperAvailable) {
      return 'Servicio de voz no disponible';
    } else if (widget.isProcessing) {
      return 'Procesando comando';
    } else if (widget.isRecording) {
      return 'Toque para detener grabación';
    } else {
      return 'Toque para grabar comando de voz';
    }
  }

  String _getStatusText() {
    if (!widget.whisperAvailable) return 'No disponible';
    if (widget.isProcessing) return 'Procesando...';
    if (widget.isRecording) return 'Grabando';
    return 'En que puedo Ayudarte?';
  }

  Color _getButtonColor(ThemeData theme) {
    if (!widget.whisperAvailable) return Colors.grey.shade400;
    if (widget.isProcessing) return theme.colorScheme.primary;
    if (widget.isRecording) return theme.colorScheme.error;
    return theme.colorScheme.secondary;
  }

  IconData _getButtonIcon() {
    if (widget.isProcessing) return Icons.hourglass_empty_rounded;
    if (widget.isRecording) return Icons.stop_rounded;
    return Icons.mic_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.of(context).size;
    final buttonSize = size.width * 0.45;
    final iconSize = buttonSize * 0.35;
    double safeOpacity = (0.5 + _pulseAnimation.value * 0.5).clamp(0.0, 1.0);

    return Semantics(
      label: _getSemanticLabel(),
      button: true,
      enabled: widget.whisperAvailable && !widget.isProcessing,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // BOTÓN PRINCIPAL GIGANTE
          GestureDetector(
            onTap: _handleTap,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Ondas de pulso al grabar
                if (widget.isRecording)
                  AnimatedBuilder(
                    animation: _waveAnimation,
                    builder: (context, child) {
                      return Container(
                        width: buttonSize * (1 + _waveAnimation.value * 0.3),
                        height: buttonSize * (1 + _waveAnimation.value * 0.3),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _getButtonColor(theme).withValues(alpha: safeOpacity),
                            width: 3,
                          ),
                        ),
                      );
                    },
                  ),

                // Botón animado
                AnimatedBuilder(
                  animation: widget.isRecording ? _pulseAnimation : const AlwaysStoppedAnimation(1.0),
                  builder: (context, child) {
                    return Container(
                      width: buttonSize * (widget.isRecording ? _pulseAnimation.value : 1.0),
                      height: buttonSize * (widget.isRecording ? _pulseAnimation.value : 1.0),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _getButtonColor(theme),
                        boxShadow: [
                          BoxShadow(
                              color: _getButtonColor(theme).withValues(
                                alpha: (0.5 * (1 - _waveAnimation.value)).clamp(0.0, 1.0),
                              ),
                            blurRadius: widget.isRecording ? 30 : 20,
                            spreadRadius: widget.isRecording ? 8 : 4,
                          ),
                        ],
                      ),
                      child: Center(
                        child: widget.isProcessing
                            ? SizedBox(
                          width: iconSize * 0.8,
                          height: iconSize * 0.8,
                          child: const CircularProgressIndicator(
                            strokeWidth: 5,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        )
                            : Icon(
                          _getButtonIcon(),
                          size: iconSize,
                          color: Colors.white,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 32),

          // ESTADO DEL BOTÓN
          Semantics(
            label: 'Estado: ${_getStatusText()}',
            readOnly: true,
            liveRegion: true,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              decoration: BoxDecoration(
                color: _getButtonColor(theme).withValues(alpha: 0.1),

                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _getButtonColor(theme).withValues(alpha: 0.3),

                  width: 2,
                ),
              ),
              child: Text(
                _getStatusText(),
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: _getButtonColor(theme),
                  letterSpacing: 0.5,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),

          // INDICADOR DE GRABACIÓN
          if (widget.isRecording) ...[
            const SizedBox(height: 24),
            Semantics(
              label: 'Grabando ahora',
              liveRegion: true,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnimatedBuilder(
                    animation: _pulseController,
                    builder: (context, child) {
                      return Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: theme.colorScheme.error,
                          boxShadow: [
                            BoxShadow(
                              color: theme.colorScheme.error.withValues(
                                alpha: (0.5 + _pulseAnimation.value * 0.5).clamp(0.0,1.0),
                              ),

                              blurRadius: 8,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'REC',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.error,
                      letterSpacing: 2,
                    ),
                  ),
                ],
              ),
            ),
          ],

          // BARRA DE PROGRESO
          if (widget.isProcessing) ...[
            const SizedBox(height: 24),
            Semantics(
              label: 'Procesando audio',
              liveRegion: true,
              child: SizedBox(
                width: 200,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: LinearProgressIndicator(
                    minHeight: 6,
                    backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.2),

                    valueColor: AlwaysStoppedAnimation<Color>(
                      theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}