// lib/services/auth_service.dart
import 'package:flutter/foundation.dart';
import '../config/api_config.dart';
import '../models/api_models.dart';
import 'api_client.dart';
import 'token_service.dart';

class AuthService {
  final ApiClient _apiClient = ApiClient();
  final TokenService _tokenService = TokenService();

  // ===== REGISTRO =====
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
        fromJson: (json) => json as Map<String, dynamic>,
      );

      if (response.success) {
        debugPrint('✅ Usuario registrado exitosamente');
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

  // ===== LOGIN =====
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

      debugPrint('🔑 Iniciando sesión: $email');

      final response = await _apiClient.post<AuthData>(
        ApiConfig.login,
        body: request.toJson(),
        fromJson: (json) => AuthData.fromJson(json as Map<String, dynamic>),
      );

      if (response.success && response.data != null) {
        // Guardar tokens
        await _tokenService.saveTokens(
          accessToken: response.data!.tokens.accessToken,
          refreshToken: response.data!.tokens.refreshToken,
          tokenType: response.data!.tokens.tokenType,
          expiresIn: response.data!.tokens.expiresIn,
        );
        debugPrint('✅ Sesión iniciada exitosamente');
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

  // ===== LOGOUT =====
  Future<ApiResponse<void>> logout() async {
    try {
      debugPrint('👋 Cerrando sesión');

      final response = await _apiClient.post<void>(
        ApiConfig.logout,
      );

      // Limpiar tokens locales independientemente de la respuesta del servidor
      await _tokenService.clearTokens();
      debugPrint('✅ Sesión cerrada exitosamente');

      return response;
    } catch (e) {
      debugPrint('❌ Error en logout: $e');
      // Aún así limpiar tokens locales
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

  // ===== RENOVAR TOKEN =====
  Future<ApiResponse<TokenPair>> refreshToken() async {
    try {
      final refreshToken = await _tokenService.getRefreshToken();
      if (refreshToken == null) {
        throw Exception('No hay refresh token disponible');
      }

      debugPrint('🔄 Renovando token');

      final response = await _apiClient.post<TokenPair>(
        ApiConfig.refreshToken,
        body: {'refresh_token': refreshToken},
        fromJson: (json) =>
            TokenPair.fromJson((json as Map<String, dynamic>)['tokens']),
      );

      if (response.success && response.data != null) {
        // Guardar nuevos tokens
        await _tokenService.saveTokens(
          accessToken: response.data!.accessToken,
          refreshToken: response.data!.refreshToken,
          tokenType: response.data!.tokenType,
          expiresIn: response.data!.expiresIn,
        );
        debugPrint('✅ Token renovado exitosamente');
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

  // ===== OLVIDÉ MI CONTRASEÑA =====
  Future<ApiResponse<void>> forgotPassword(String email) async {
    try {
      debugPrint('📧 Solicitando reseteo de contraseña: $email');

      final response = await _apiClient.post<void>(
        ApiConfig.forgotPassword,
        body: {'email': email},
      );

      return response;
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

  // ===== RESETEAR CONTRASEÑA =====
  Future<ApiResponse<void>> resetPassword({
    required String token,
    required String newPassword,
    required String confirmPassword,
  }) async {
    try {
      debugPrint('🔐 Reseteando contraseña');

      final response = await _apiClient.post<void>(
        ApiConfig.resetPassword,
        body: {
          'token': token,
          'new_password': newPassword,
          'confirm_password': confirmPassword,
        },
      );

      return response;
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

  // ===== VERIFICAR EMAIL =====
  Future<ApiResponse<void>> verifyEmail(String token) async {
    try {
      debugPrint('✉️ Verificando email');

      final response = await _apiClient.post<void>(
        ApiConfig.verifyEmail,
        body: {'token': token},
      );

      return response;
    } catch (e) {
      debugPrint('❌ Error en verify email: $e');
      return ApiResponse(
        success: false,
        message: 'Error al verificar email: ${e.toString()}',
        accessibilityInfo: AccessibilityInfo(
          announcement: 'Error al verificar email',
          hapticPattern: 'error',
        ),
      );
    }
  }

  // ===== VERIFICAR SI ESTÁ AUTENTICADO =====
  Future<bool> isAuthenticated() async {
    return await _tokenService.hasTokens();
  }
}