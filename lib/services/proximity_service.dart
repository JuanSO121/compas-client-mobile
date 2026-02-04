// lib/services/proximity_service.dart
import 'dart:async';

/// Servicio simplificado de proximidad
/// En una versión completa, esto usaría sensores reales
class ProximityService {
  static final StreamController<bool> _controller = StreamController<bool>.broadcast();

  static Stream<bool> get proximityStream => _controller.stream;

  static void dispose() {
    _controller.close();
  }
}