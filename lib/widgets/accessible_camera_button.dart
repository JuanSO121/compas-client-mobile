// lib/widgets/accessible_camera_button.dart
import 'package:flutter/material.dart';

class AccessibleCameraButton extends StatelessWidget {
  final bool isStreaming;
  final bool isProcessing;
  final bool isConnected;
  final VoidCallback onStartStream;
  final VoidCallback onStopStream;

  const AccessibleCameraButton({
    super.key,
    required this.isStreaming,
    required this.isProcessing,
    required this.isConnected,
    required this.onStartStream,
    required this.onStopStream,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: GestureDetector(
        onTap: isProcessing
            ? null
            : (isStreaming ? onStopStream : onStartStream),
        child: Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isStreaming
                ? theme.colorScheme.error
                : theme.colorScheme.secondary,
            boxShadow: [
              BoxShadow(
                color: (isStreaming
                    ? theme.colorScheme.error
                    : theme.colorScheme.secondary).withOpacity(0.5),
                blurRadius: 20,
                spreadRadius: 5,
              ),
            ],
          ),
          child: Icon(
            isProcessing
                ? Icons.hourglass_empty
                : (isStreaming ? Icons.stop : Icons.videocam),
            color: Colors.white,
            size: 56,
          ),
        ),
      ),
    );
  }
}