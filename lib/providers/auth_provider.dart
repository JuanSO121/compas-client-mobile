// lib/providers/auth_provider.dart
import 'package:flutter/foundation.dart';
import '../models/api_models.dart';
import '../services/auth_service.dart';
import '../services/token_service.dart';
import '../services/user_service.dart';

enum AuthStatus {
  initial,
  authenticated,
  unauthenticated,
  loading,
}

class AuthProvider extends ChangeNotifier {
  final AuthService _authService = AuthService();
  final TokenService _tokenService = TokenService();
  final UserService _userService = UserService();

  AuthStatus _status = AuthStatus.initial;
  UserData? _currentUser;
  String? _errorMessage;
  AccessibilityInfo? _lastAccessibilityInfo;

  // Getters
  AuthStatus get status => _status;
  UserData? get currentUser => _currentUser;
  String? get errorMessage => _errorMessage;
  AccessibilityInfo? get lastAccessibilityInfo => _lastAccessibilityInfo;
  bool get isAuthenticated => _status == AuthStatus.authenticated;
  bool get isLoading => _status == AuthStatus.loading;

  // ===== INICIALIZAR =====
  Future<void> initialize() async {
    try {
      _status = AuthStatus.loading;
      notifyListeners();

      final hasTokens = await _tokenService.hasTokens();

      if (hasTokens) {
        // Intentar obtener perfil con el token existente
        final profileResponse = await _userService.getProfile();

        if (profileResponse.success && profileResponse.data != null) {
          _currentUser = profileResponse.data;
          _status = AuthStatus.authenticated;
          debugPrint('✅ Sesión restaurada exitosamente');
        } else {
          // Token inválido, limpiar
          await _tokenService.clearTokens();
          _status = AuthStatus.unauthenticated;
          debugPrint('⚠️ Token inválido, sesión cerrada');
        }
      } else {
        _status = AuthStatus.unauthenticated;
        debugPrint('ℹ️ No hay sesión activa');
      }
    } catch (e) {
      debugPrint('❌ Error inicializando auth: $e');
      _status = AuthStatus.unauthenticated;
    }

    notifyListeners();
  }

  // ===== LOGIN =====
  Future<bool> login({
    required String email,
    required String password,
    bool rememberMe = false,
  }) async {
    try {
      _status = AuthStatus.loading;
      _errorMessage = null;
      notifyListeners();

      final response = await _authService.login(
        email: email,
        password: password,
        rememberMe: rememberMe,
      );

      if (response.success && response.data != null) {
        _currentUser = response.data!.user;
        _lastAccessibilityInfo = response.accessibilityInfo;
        _status = AuthStatus.authenticated;
        _errorMessage = null;

        debugPrint('✅ Login exitoso: ${_currentUser!.email}');
        notifyListeners();
        return true;
      } else {
        _errorMessage = response.message;
        _lastAccessibilityInfo = response.accessibilityInfo;
        _status = AuthStatus.unauthenticated;

        debugPrint('❌ Login fallido: $_errorMessage');
        notifyListeners();
        return false;
      }
    } catch (e) {
      _errorMessage = 'Error de conexión: ${e.toString()}';
      _status = AuthStatus.unauthenticated;

      debugPrint('❌ Error en login: $e');
      notifyListeners();
      return false;
    }
  }

  // ===== REGISTRO =====
  Future<bool> register({
    required String email,
    required String password,
    required String confirmPassword,
    String? firstName,
    String? lastName,
    String visualImpairmentLevel = 'none',
    bool screenReaderUser = false,
  }) async {
    try {
      _status = AuthStatus.loading;
      _errorMessage = null;
      notifyListeners();

      final response = await _authService.register(
        email: email,
        password: password,
        confirmPassword: confirmPassword,
        firstName: firstName,
        lastName: lastName,
        visualImpairmentLevel: visualImpairmentLevel,
        screenReaderUser: screenReaderUser,
      );

      if (response.success) {
        _lastAccessibilityInfo = response.accessibilityInfo;
        _status = AuthStatus.unauthenticated;
        _errorMessage = null;

        debugPrint('✅ Registro exitoso');
        notifyListeners();
        return true;
      } else {
        _errorMessage = response.message;
        _lastAccessibilityInfo = response.accessibilityInfo;
        _status = AuthStatus.unauthenticated;

        debugPrint('❌ Registro fallido: $_errorMessage');
        notifyListeners();
        return false;
      }
    } catch (e) {
      _errorMessage = 'Error de conexión: ${e.toString()}';
      _status = AuthStatus.unauthenticated;

      debugPrint('❌ Error en registro: $e');
      notifyListeners();
      return false;
    }
  }

  // ===== LOGOUT =====
  Future<void> logout() async {
    try {
      _status = AuthStatus.loading;
      notifyListeners();

      await _authService.logout();

      _currentUser = null;
      _errorMessage = null;
      _status = AuthStatus.unauthenticated;

      debugPrint('✅ Logout exitoso');
      notifyListeners();
    } catch (e) {
      debugPrint('❌ Error en logout: $e');
      // Aún así limpiar el estado local
      _currentUser = null;
      _status = AuthStatus.unauthenticated;
      notifyListeners();
    }
  }

  // ===== REFRESCAR TOKEN =====
  Future<bool> refreshToken() async {
    try {
      final response = await _authService.refreshToken();

      if (response.success) {
        debugPrint('✅ Token renovado exitosamente');
        return true;
      } else {
        debugPrint('❌ Error renovando token');
        // Si falla, cerrar sesión
        await logout();
        return false;
      }
    } catch (e) {
      debugPrint('❌ Error en refresh token: $e');
      await logout();
      return false;
    }
  }

  // ===== ACTUALIZAR PERFIL =====
  Future<bool> updateProfile({
    String? firstName,
    String? lastName,
    String? phone,
  }) async {
    try {
      final response = await _userService.updateProfile(
        firstName: firstName,
        lastName: lastName,
        phone: phone,
      );

      if (response.success && _currentUser != null) {
        // Actualizar usuario local
        _currentUser = UserData(
          id: _currentUser!.id,
          email: _currentUser!.email,
          profile: UserProfile(
            firstName: firstName ?? _currentUser!.profile?.firstName,
            lastName: lastName ?? _currentUser!.profile?.lastName,
            phone: phone ?? _currentUser!.profile?.phone,
            preferredLanguage: _currentUser!.profile?.preferredLanguage,
            timezone: _currentUser!.profile?.timezone,
          ),
          accessibility: _currentUser!.accessibility,
          lastLogin: _currentUser!.lastLogin,
        );

        _lastAccessibilityInfo = response.accessibilityInfo;
        debugPrint('✅ Perfil actualizado');
        notifyListeners();
        return true;
      } else {
        _errorMessage = response.message;
        debugPrint('❌ Error actualizando perfil');
        notifyListeners();
        return false;
      }
    } catch (e) {
      _errorMessage = 'Error de conexión: ${e.toString()}';
      debugPrint('❌ Error en update profile: $e');
      notifyListeners();
      return false;
    }
  }

  // ===== ACTUALIZAR PREFERENCIAS DE ACCESIBILIDAD =====
  Future<bool> updateAccessibilityPreferences({
    String? visualImpairmentLevel,
    bool? screenReaderUser,
    double? preferredTtsSpeed,
    bool? highContrastMode,
    bool? darkModeEnabled,
    bool? hapticFeedbackEnabled,
  }) async {
    try {
      final response = await _userService.updateAccessibilityPreferences(
        visualImpairmentLevel: visualImpairmentLevel,
        screenReaderUser: screenReaderUser,
        preferredTtsSpeed: preferredTtsSpeed,
        highContrastMode: highContrastMode,
        darkModeEnabled: darkModeEnabled,
        hapticFeedbackEnabled: hapticFeedbackEnabled,
      );

      if (response.success && _currentUser != null) {
        // Actualizar usuario local
        _currentUser = UserData(
          id: _currentUser!.id,
          email: _currentUser!.email,
          profile: _currentUser!.profile,
          accessibility: AccessibilityPreferences(
            visualImpairmentLevel: visualImpairmentLevel ??
                _currentUser!.accessibility?.visualImpairmentLevel,
            screenReaderUser: screenReaderUser ??
                _currentUser!.accessibility?.screenReaderUser,
            preferredTtsSpeed: preferredTtsSpeed ??
                _currentUser!.accessibility?.preferredTtsSpeed,
            highContrastMode: highContrastMode ??
                _currentUser!.accessibility?.highContrastMode,
            darkModeEnabled: darkModeEnabled ??
                _currentUser!.accessibility?.darkModeEnabled,
            hapticFeedbackEnabled: hapticFeedbackEnabled ??
                _currentUser!.accessibility?.hapticFeedbackEnabled,
          ),
          lastLogin: _currentUser!.lastLogin,
        );

        _lastAccessibilityInfo = response.accessibilityInfo;
        debugPrint('✅ Preferencias de accesibilidad actualizadas');
        notifyListeners();
        return true;
      } else {
        _errorMessage = response.message;
        debugPrint('❌ Error actualizando preferencias');
        notifyListeners();
        return false;
      }
    } catch (e) {
      _errorMessage = 'Error de conexión: ${e.toString()}';
      debugPrint('❌ Error en update accessibility: $e');
      notifyListeners();
      return false;
    }
  }

  // ===== RECARGAR PERFIL =====
  Future<void> reloadProfile() async {
    try {
      final response = await _userService.getProfile();

      if (response.success && response.data != null) {
        _currentUser = response.data;
        debugPrint('✅ Perfil recargado');
        notifyListeners();
      }
    } catch (e) {
      debugPrint('❌ Error recargando perfil: $e');
    }
  }

  // ===== LIMPIAR ERRORES =====
  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }
}