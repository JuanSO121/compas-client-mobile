// lib/services/auth_service.dart
import 'package:flutter/foundation.dart';
import '../config/api_config.dart';
import '../models/api_models.dart';
import 'api_client.dart';
import 'token_service.dart';

class AuthService {
  final ApiClient _apiClient = ApiClient();
  final TokenService _tokenService = TokenService();

  // ════════════════════════════════════════════════════════════
  // LOGIN CON CÓDIGO PERMANENTE — FLUJO PRINCIPAL
  // ════════════════════════════════════════════════════════════
  /// El usuario solo ingresa el código de 6 dígitos que recibió por email.
  /// No necesita email ni contraseña.
  /// Si es el primer login, el backend verifica la cuenta automáticamente.
  Future<ApiResponse<AuthData>> loginWithCode({
    required String code,
  }) async {
    try {
      debugPrint('🔑 Login con código permanente');

      final response = await _apiClient.post<AuthData>(
        ApiConfig.loginWithCode,
        body: {'code': code.trim()},
        fromJson: (data) => AuthData.fromJson(data as Map<String, dynamic>),
      );

      if (response.success && response.data != null) {
        await _tokenService.saveTokens(
          accessToken: response.data!.tokens.accessToken,
          refreshToken: response.data!.tokens.refreshToken,
          tokenType: response.data!.tokens.tokenType,
          expiresIn: response.data!.tokens.expiresIn,
        );
        debugPrint('✅ Login con código exitoso — tokens guardados');
      }

      return response;
    } catch (e) {
      debugPrint('❌ Error en loginWithCode: $e');
      return ApiResponse(
        success: false,
        message: 'Error al iniciar sesión: ${e.toString()}',
        accessibilityInfo: AccessibilityInfo(
          announcement: 'Error al iniciar sesión',
          hapticPattern: 'error',
        ),
      );
    }
  }

  // ════════════════════════════════════════════════════════════
  // SOLICITAR NUEVO CÓDIGO — RECUPERACIÓN
  // ════════════════════════════════════════════════════════════
  /// El usuario olvidó su código. Ingresa email + contraseña para verificar
  /// su identidad y el backend genera un nuevo código permanente y lo envía.
  /// El código anterior deja de funcionar inmediatamente.
  Future<ApiResponse<void>> requestNewCode({
    required String email,
    required String password,
  }) async {
    try {
      debugPrint('📧 Solicitando nuevo código de acceso para $email');

      final response = await _apiClient.post<void>(
        ApiConfig.requestNewCode,
        body: {
          'email': email.trim(),
          'password': password,
        },
      );

      return response;
    } catch (e) {
      debugPrint('❌ Error en requestNewCode: $e');
      return ApiResponse(
        success: false,
        message: 'Error al solicitar nuevo código: ${e.toString()}',
        accessibilityInfo: AccessibilityInfo(
          announcement: 'Error al solicitar código',
          hapticPattern: 'error',
        ),
      );
    }
  }

  // ════════════════════════════════════════════════════════════
  // REGISTRO
  // ════════════════════════════════════════════════════════════
  Future<ApiResponse<Map<String, dynamic>>> register({
    required String email,
    required String password,
    required String confirmPassword,
    String? firstName,
    String? lastName,
    String visualImpairmentLevel = 'none',
    bool screenReaderUser = false,
  }) async {
    try {
      final request = RegisterRequest(
        email: email,
        password: password,
        confirmPassword: confirmPassword,
        firstName: firstName,
        lastName: lastName,
        visualImpairmentLevel: visualImpairmentLevel,
        screenReaderUser: screenReaderUser,
      );

      debugPrint('📝 Registrando usuario: $email');

      final response = await _apiClient.post<Map<String, dynamic>>(
        ApiConfig.register,
        body: request.toJson(),
        fromJson: (data) => data as Map<String, dynamic>,
      );

      if (response.success) {
        debugPrint('✅ Usuario registrado. Código enviado al email.');
      }

      return response;
    } catch (e) {
      debugPrint('❌ Error en registro: $e');
      return ApiResponse(
        success: false,
        message: 'Error al registrar usuario: ${e.toString()}',
        accessibilityInfo: AccessibilityInfo(
          announcement: 'Error al registrar',
          hapticPattern: 'error',
        ),
      );
    }
  }

  // ════════════════════════════════════════════════════════════
  // LOGIN CON EMAIL + CONTRASEÑA — SECUNDARIO / ADMIN
  // ════════════════════════════════════════════════════════════
  Future<ApiResponse<AuthData>> login({
    required String email,
    required String password,
    bool rememberMe = false,
  }) async {
    try {
      final request = LoginRequest(
        email: email,
        password: password,
        rememberMe: rememberMe,
      );

      debugPrint('🔑 Iniciando sesión con email: $email');

      final response = await _apiClient.post<AuthData>(
        ApiConfig.login,
        body: request.toJson(),
        fromJson: (data) => AuthData.fromJson(data as Map<String, dynamic>),
      );

      if (response.success && response.data != null) {
        await _tokenService.saveTokens(
          accessToken: response.data!.tokens.accessToken,
          refreshToken: response.data!.tokens.refreshToken,
          tokenType: response.data!.tokens.tokenType,
          expiresIn: response.data!.tokens.expiresIn,
        );
        debugPrint('✅ Sesión iniciada y tokens guardados');
      }

      return response;
    } catch (e) {
      debugPrint('❌ Error en login: $e');
      return ApiResponse(
        success: false,
        message: 'Error al iniciar sesión: ${e.toString()}',
        accessibilityInfo: AccessibilityInfo(
          announcement: 'Error al iniciar sesión',
          hapticPattern: 'error',
        ),
      );
    }
  }

  // ════════════════════════════════════════════════════════════
  // LOGOUT COMPLETO (servidor + local)
  // ════════════════════════════════════════════════════════════
  Future<ApiResponse<void>> logout() async {
    try {
      debugPrint('👋 Cerrando sesión');
      final response = await _apiClient.post<void>(ApiConfig.logout);
      await _tokenService.clearTokens();
      debugPrint('✅ Sesión cerrada exitosamente');
      return response;
    } catch (e) {
      debugPrint('❌ Error en logout: $e');
      await _tokenService.clearTokens();
      return ApiResponse(
        success: true,
        message: 'Sesión cerrada localmente',
        accessibilityInfo: AccessibilityInfo(
          announcement: 'Sesión cerrada',
          hapticPattern: 'success',
        ),
      );
    }
  }

  // ════════════════════════════════════════════════════════════
  // LIMPIAR SESIÓN LOCAL (sin llamar al servidor)
  // ════════════════════════════════════════════════════════════
  Future<void> clearLocalSession() async {
    try {
      await _tokenService.clearTokens();
      debugPrint('🧹 Sesión local limpiada');
    } catch (e) {
      debugPrint('❌ Error limpiando sesión local: $e');
    }
  }

  // ════════════════════════════════════════════════════════════
  // RENOVAR TOKEN
  // ════════════════════════════════════════════════════════════
  Future<ApiResponse<TokenPair>> refreshToken() async {
    try {
      final storedRefreshToken = await _tokenService.getRefreshToken();
      if (storedRefreshToken == null) {
        debugPrint('⚠️ No hay refresh token guardado');
        return ApiResponse(
          success: false,
          message: 'No hay sesión activa',
          accessibilityInfo: AccessibilityInfo(
            announcement: 'Sesión no encontrada',
            hapticPattern: 'warning',
          ),
        );
      }

      debugPrint('🔄 Renovando token');

      final response = await _apiClient.post<TokenPair>(
        ApiConfig.refreshToken,
        body: {'refresh_token': storedRefreshToken},
        fromJson: (data) {
          final map = data as Map<String, dynamic>;
          if (map.containsKey('tokens')) {
            return TokenPair.fromJson(map['tokens'] as Map<String, dynamic>);
          }
          return TokenPair.fromJson(map);
        },
      );

      if (response.success && response.data != null) {
        await _tokenService.saveTokens(
          accessToken: response.data!.accessToken,
          refreshToken: response.data!.refreshToken,
          tokenType: response.data!.tokenType,
          expiresIn: response.data!.expiresIn,
        );
        debugPrint('✅ Token renovado y guardado');
      }

      return response;
    } catch (e) {
      debugPrint('❌ Error renovando token: $e');
      return ApiResponse(
        success: false,
        message: 'Error al renovar sesión: ${e.toString()}',
        accessibilityInfo: AccessibilityInfo(
          announcement: 'Sesión expirada',
          hapticPattern: 'warning',
        ),
      );
    }
  }

  // ════════════════════════════════════════════════════════════
  // OLVIDÉ MI CONTRASEÑA / RESETEAR CONTRASEÑA
  // ════════════════════════════════════════════════════════════
  Future<ApiResponse<void>> forgotPassword(String email) async {
    try {
      debugPrint('📧 Solicitando reseteo de contraseña: $email');
      return await _apiClient.post<void>(
        ApiConfig.forgotPassword,
        body: {'email': email},
      );
    } catch (e) {
      debugPrint('❌ Error en forgot password: $e');
      return ApiResponse(
        success: false,
        message: 'Error al solicitar reseteo: ${e.toString()}',
        accessibilityInfo: AccessibilityInfo(
          announcement: 'Error al solicitar reseteo',
          hapticPattern: 'error',
        ),
      );
    }
  }

  Future<ApiResponse<void>> resetPassword({
    required String token,
    required String newPassword,
    required String confirmPassword,
  }) async {
    try {
      debugPrint('🔐 Reseteando contraseña');
      return await _apiClient.post<void>(
        ApiConfig.resetPassword,
        body: {
          'token': token,
          'new_password': newPassword,
          'confirm_password': confirmPassword,
        },
      );
    } catch (e) {
      debugPrint('❌ Error en reset password: $e');
      return ApiResponse(
        success: false,
        message: 'Error al resetear contraseña: ${e.toString()}',
        accessibilityInfo: AccessibilityInfo(
          announcement: 'Error al resetear contraseña',
          hapticPattern: 'error',
        ),
      );
    }
  }

  // ════════════════════════════════════════════════════════════
  // VERIFICAR AUTENTICACIÓN
  // ════════════════════════════════════════════════════════════
  Future<bool> isAuthenticated() async {
    return await _tokenService.hasTokens();
  }

  /// Verifica si el access token sigue siendo válido sin llamar al servidor.
  Future<bool> isAccessTokenValid() async {
    return await _tokenService.isAccessTokenValid();
  }

  /// Verifica si hay refresh token disponible para renovar.
  Future<bool> hasRefreshToken() async {
    return await _tokenService.hasRefreshToken();
  }
}