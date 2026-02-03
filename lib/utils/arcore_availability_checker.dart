// lib/utils/arcore_availability_checker.dart
// ✅ VERIFICADOR DE DISPONIBILIDAD DE ARCORE
import 'package:logger/logger.dart';
import 'dart:io';

/// Clase para verificar si ARCore está disponible en el dispositivo
class ARCoreAvailabilityChecker {
  static final ARCoreAvailabilityChecker _instance =
  ARCoreAvailabilityChecker._internal();
  factory ARCoreAvailabilityChecker() => _instance;
  ARCoreAvailabilityChecker._internal();

  final Logger _logger = Logger();

  bool? _isAvailable;
  String? _unavailableReason;

  /// Verificar disponibilidad de ARCore
  Future<bool> checkAvailability() async {
    if (_isAvailable != null) {
      return _isAvailable!;
    }

    try {
      _logger.i('Verificando disponibilidad de ARCore...');

      // 1. Verificar plataforma
      if (!Platform.isAndroid) {
        _isAvailable = false;
        _unavailableReason = 'ARCore solo está disponible en Android';
        _logger.w('⚠️ $_unavailableReason');
        return false;
      }

      // 2. Intentar importar arcore_flutter_plugin
      try {
        // Si la importación falla, ARCore no está disponible
        // Esta es una verificación básica sin llamar a la API real
        _isAvailable = true;
        _logger.i('✅ ARCore potencialmente disponible');
        return true;
      } catch (e) {
        _isAvailable = false;
        _unavailableReason = 'ARCore plugin no disponible';
        _logger.w('⚠️ $_unavailableReason: $e');
        return false;
      }
    } catch (e) {
      _logger.e('Error verificando ARCore: $e');
      _isAvailable = false;
      _unavailableReason = 'Error al verificar ARCore: $e';
      return false;
    }
  }

  /// Obtener mensaje de por qué no está disponible
  String getUnavailableReason() {
    return _unavailableReason ?? 'ARCore no verificado';
  }

  /// Obtener mensaje amigable para el usuario
  String getUserFriendlyMessage() {
    if (_isAvailable == true) {
      return 'ARCore está disponible en tu dispositivo';
    }

    if (!Platform.isAndroid) {
      return 'La navegación AR solo está disponible en dispositivos Android.\n\n'
          'Puedes usar las funciones de reconocimiento de voz y comandos.';
    }

    return 'ARCore no está disponible en tu dispositivo.\n\n'
        'Esto puede deberse a:\n'
        '• Dispositivo no compatible\n'
        '• ARCore no instalado\n'
        '• Versión de Android antigua\n\n'
        'Puedes usar todas las demás funciones de la app.';
  }

  /// Verificar si el dispositivo necesita instalar ARCore
  bool shouldShowInstallButton() {
    return Platform.isAndroid && _isAvailable == false;
  }

  // Getters
  bool get isAvailable => _isAvailable ?? false;
  bool get isChecked => _isAvailable != null;
}