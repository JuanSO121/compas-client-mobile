// lib/config/logger_config.dart
// ✅ CONFIGURACIÓN DE LOGGER SIN DEPRECATED

import 'package:logger/logger.dart';

/// Configuración centralizada de Logger
class LoggerConfig {
  static Logger getLogger({Level level = Level.info}) {
    return Logger(
      printer: PrettyPrinter(
        methodCount: 0,
        errorMethodCount: 5,
        lineLength: 80,
        colors: true,
        printEmojis: true,
        dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
      ),
      level: level,
    );
  }

  /// Logger para desarrollo (verbose)
  static Logger getDevelopmentLogger() {
    return Logger(
      printer: PrettyPrinter(
        methodCount: 2,
        errorMethodCount: 8,
        lineLength: 120,
        colors: true,
        printEmojis: true,
        dateTimeFormat: DateTimeFormat.dateAndTime,
      ),
      level: Level.trace, // Reemplaza Level.verbose
    );
  }

  /// Logger para producción (solo warnings y errors)
  static Logger getProductionLogger() {
    return Logger(
      printer: SimplePrinter(),
      level: Level.warning,
    );
  }
}

/// Extension para uso fácil
extension LoggerExtension on Logger {
  // Reemplazar v() con t() (trace)
  void trace(dynamic message, {DateTime? time, Object? error, StackTrace? stackTrace}) {
    t(message, time: time, error: error, stackTrace: stackTrace);
  }
}