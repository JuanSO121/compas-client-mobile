// lib/utils/password_validator.dart

class PasswordValidationResult {
  final bool isValid;
  final int strengthScore;
  final String strengthLevel;
  final String strengthMessage;
  final List<String> errors;
  final List<String> suggestions;
  final String message;

  PasswordValidationResult({
    required this.isValid,
    required this.strengthScore,
    required this.strengthLevel,
    required this.strengthMessage,
    required this.errors,
    required this.suggestions,
    required this.message,
  });

  // Para accesibilidad: descripción completa para TTS
  String get accessibleDescription {
    if (isValid) {
      return 'Contraseña $strengthLevel. $strengthMessage';
    } else {
      final errorList = errors.join(', ');
      return 'Contraseña inválida. $errorList';
    }
  }

  // Para mostrar en UI
  String get displayMessage {
    if (isValid) return strengthMessage;
    return errors.isNotEmpty ? errors.first : message;
  }
}

class PasswordValidator {
  /// Validar contraseña con las mismas reglas que el backend
  static PasswordValidationResult validate(String password) {
    if (password.isEmpty) {
      return PasswordValidationResult(
        isValid: false,
        strengthScore: 0,
        strengthLevel: 'muy débil',
        strengthMessage: 'Contraseña requerida',
        errors: ['la contraseña es requerida'],
        suggestions: ['Ingrese una contraseña segura'],
        message: 'La contraseña es requerida',
      );
    }

    final errors = <String>[];
    final suggestions = <String>[];
    int strengthScore = 0;

    // 1. Longitud mínima
    if (password.length < 8) {
      errors.add('debe tener al menos 8 caracteres');
      suggestions.add('Agregue más caracteres para mayor seguridad');
    } else {
      strengthScore += 1;
    }

    // Bonus por longitud
    if (password.length >= 12) {
      strengthScore += 1;
    }

    // 2. Mayúsculas
    if (!RegExp(r'[A-Z]').hasMatch(password)) {
      errors.add('debe incluir al menos una letra mayúscula');
      suggestions.add('Agregue una letra mayúscula (A-Z)');
    } else {
      strengthScore += 1;
    }

    // 3. Minúsculas
    if (!RegExp(r'[a-z]').hasMatch(password)) {
      errors.add('debe incluir al menos una letra minúscula');
      suggestions.add('Agregue una letra minúscula (a-z)');
    } else {
      strengthScore += 1;
    }

    // 4. Números
    if (!RegExp(r'\d').hasMatch(password)) {
      errors.add('debe incluir al menos un número');
      suggestions.add('Agregue un número (0-9)');
    } else {
      strengthScore += 1;
    }

    // 5. Caracteres especiales
    if (!RegExp(r'[!@#$%^&*(),.?":{}|<>]').hasMatch(password)) {
      errors.add('debe incluir al menos un símbolo especial');
      suggestions.add('Agregue un símbolo especial (!@#\$%^&* etc.)');
    } else {
      strengthScore += 1;
    }

    // 6. Patrones comunes débiles
    final weakPatterns = {
      r'123': 'Evite secuencias numéricas como 123',
      r'abc': 'Evite secuencias alfabéticas como abc',
      r'password': 'Evite usar la palabra "password"',
      r'qwerty': 'Evite patrones del teclado como qwerty',
      r'admin': 'Evite palabras comunes como "admin"',
    };

    for (final entry in weakPatterns.entries) {
      if (RegExp(entry.key, caseSensitive: false).hasMatch(password)) {
        suggestions.add(entry.value);
        strengthScore = (strengthScore - 1).clamp(0, 6);
      }
    }

    // Determinar nivel de fortaleza
    String strengthLevel;
    String strengthMessage;

    if (strengthScore >= 5) {
      strengthLevel = 'muy fuerte';
      strengthMessage = 'Excelente contraseña';
    } else if (strengthScore >= 4) {
      strengthLevel = 'fuerte';
      strengthMessage = 'Buena contraseña';
    } else if (strengthScore >= 3) {
      strengthLevel = 'moderada';
      strengthMessage = 'Contraseña aceptable pero puede mejorar';
    } else if (strengthScore >= 2) {
      strengthLevel = 'débil';
      strengthMessage = 'Contraseña débil, necesita mejoras';
    } else {
      strengthLevel = 'muy débil';
      strengthMessage = 'Contraseña muy débil, requiere cambios importantes';
    }

    final isValid = errors.isEmpty;
    final message = isValid
        ? strengthMessage
        : 'La contraseña ${errors.join(', ')}';

    return PasswordValidationResult(
      isValid: isValid,
      strengthScore: strengthScore,
      strengthLevel: strengthLevel,
      strengthMessage: strengthMessage,
      errors: errors,
      suggestions: suggestions.isEmpty && !isValid
          ? ['Verifique que cumpla todos los requisitos']
          : suggestions,
      message: message,
    );
  }

  /// Validar que las contraseñas coincidan
  static String? validatePasswordMatch(String password, String confirmPassword) {
    if (confirmPassword.isEmpty) {
      return 'Por favor confirme su contraseña';
    }

    if (password != confirmPassword) {
      return 'Las contraseñas no coinciden';
    }

    return null; // válido
  }

  /// Obtener requisitos de contraseña para mostrar
  static List<PasswordRequirement> getRequirements() {
    return [
      PasswordRequirement(
        text: 'Al menos 8 caracteres',
        icon: '🔢',
      ),
      PasswordRequirement(
        text: 'Una letra mayúscula (A-Z)',
        icon: '🔠',
      ),
      PasswordRequirement(
        text: 'Una letra minúscula (a-z)',
        icon: '🔡',
      ),
      PasswordRequirement(
        text: 'Un número (0-9)',
        icon: '🔢',
      ),
      PasswordRequirement(
        text: 'Un símbolo especial (!@#\$%)',
        icon: '🔐',
      ),
    ];
  }

  /// Verificar requisito específico
  static bool checkRequirement(String password, int requirementIndex) {
    if (password.isEmpty) return false;

    switch (requirementIndex) {
      case 0: // Longitud
        return password.length >= 8;
      case 1: // Mayúscula
        return RegExp(r'[A-Z]').hasMatch(password);
      case 2: // Minúscula
        return RegExp(r'[a-z]').hasMatch(password);
      case 3: // Número
        return RegExp(r'\d').hasMatch(password);
      case 4: // Símbolo especial
        return RegExp(r'[!@#$%^&*(),.?":{}|<>]').hasMatch(password);
      default:
        return false;
    }
  }

  /// Obtener color según fortaleza
  static PasswordStrengthColor getStrengthColor(int score) {
    if (score >= 5) {
      return PasswordStrengthColor.veryStrong;
    } else if (score >= 4) {
      return PasswordStrengthColor.strong;
    } else if (score >= 3) {
      return PasswordStrengthColor.moderate;
    } else if (score >= 2) {
      return PasswordStrengthColor.weak;
    } else {
      return PasswordStrengthColor.veryWeak;
    }
  }
}

class PasswordRequirement {
  final String text;
  final String icon;

  PasswordRequirement({
    required this.text,
    required this.icon,
  });
}

enum PasswordStrengthColor {
  veryWeak,
  weak,
  moderate,
  strong,
  veryStrong,
}