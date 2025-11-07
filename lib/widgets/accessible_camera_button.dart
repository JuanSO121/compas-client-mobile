// lib/widgets/accessible_camera_button.dart - ESTILO POKÉMON GO
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

class AccessibleCameraButton extends StatefulWidget {
  final bool isStreaming;
  final bool isProcessing;
  final bool isConnected;
  final VoidCallback? onStartStream;
  final VoidCallback? onStopStream;

  const AccessibleCameraButton({
    Key? key,
    required this.isStreaming,
    required this.isProcessing,
    required this.isConnected,
    this.onStartStream,
    this.onStopStream,
  }) : super(key: key);

  @override
  State<AccessibleCameraButton> createState() => _AccessibleCameraButtonState();
}

class _AccessibleCameraButtonState extends State<AccessibleCameraButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    if (widget.isStreaming) {
      _pulseController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(AccessibleCameraButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isStreaming && !oldWidget.isStreaming) {
      _pulseController.repeat(reverse: true);
    } else if (!widget.isStreaming && oldWidget.isStreaming) {
      _pulseController.stop();
      _pulseController.reset();
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  String _getSemanticLabel() {
    if (!widget.isConnected) {
      return 'Botón de cámara deshabilitado. Sin conexión al servidor';
    }
    if (widget.isProcessing) {
      return 'Procesando video, por favor espere';
    }
    if (widget.isStreaming) {
      return 'Detener transmisión de video en tiempo real. Mantén presionado para parar';
    }
    return 'Iniciar transmisión de video en tiempo real. Mantén presionado para comenzar';
  }

  String _getSemanticHint() {
    if (!widget.isConnected) {
      return 'Necesita conexión al servidor para transmitir video';
    }
    if (widget.isProcessing) {
      return 'El análisis se completará en unos momentos';
    }
    if (widget.isStreaming) {
      return 'Mantén presionado el botón para detener la transmisión';
    }
    return 'Mantén presionado el botón para iniciar la transmisión de video';
  }

  void _handlePress() {
    if (!widget.isConnected || widget.isProcessing) return;

    HapticFeedback.mediumImpact();

    if (widget.isStreaming) {
      widget.onStopStream?.call();
      SemanticsService.announce(
        'Deteniendo transmisión',
        TextDirection.ltr,
      );
    } else {
      widget.onStartStream?.call();
      SemanticsService.announce(
        'Iniciando transmisión de video',
        TextDirection.ltr,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.of(context).size;

    return Semantics(
      label: _getSemanticLabel(),
      hint: _getSemanticHint(),
      button: true,
      enabled: widget.isConnected && !widget.isProcessing,
      child: Center(
        child: GestureDetector(
          onLongPress: widget.isConnected && !widget.isProcessing
              ? _handlePress
              : null,
          child: AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (context, child) {
              return Transform.scale(
                scale: widget.isStreaming ? _pulseAnimation.value : 1.0,
                child: child,
              );
            },
            child: Container(
              width: 160,
              height: 160,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _getButtonColor(theme),
                boxShadow: [
                  if (widget.isStreaming)
                    BoxShadow(
                      color: theme.colorScheme.error.withOpacity(0.6),
                      blurRadius: 40,
                      spreadRadius: 10,
                    )
                  else if (widget.isConnected && !widget.isProcessing)
                    BoxShadow(
                      color: theme.colorScheme.primary.withOpacity(0.4),
                      blurRadius: 30,
                      spreadRadius: 8,
                    ),
                ],
                border: Border.all(
                  color: Colors.white.withOpacity(0.3),
                  width: 6,
                ),
              ),
              child: _buildButtonContent(theme),
            ),
          ),
        ),
      ),
    );
  }

  Color _getButtonColor(ThemeData theme) {
    if (!widget.isConnected) {
      return Colors.grey.shade600;
    }
    if (widget.isProcessing) {
      return Colors.orange.shade700;
    }
    if (widget.isStreaming) {
      return theme.colorScheme.error;
    }
    return theme.colorScheme.primary;
  }

  Widget _buildButtonContent(ThemeData theme) {
    if (widget.isProcessing) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 50,
            height: 50,
            child: CircularProgressIndicator(
              strokeWidth: 5,
              valueColor: AlwaysStoppedAnimation(Colors.white),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Analizando',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      );
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          widget.isStreaming
              ? Icons.stop_circle_rounded
              : Icons.videocam_rounded,
          size: 70,
          color: Colors.white,
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}