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
  // REGISTRO — sin contraseña
  // ════════════════════════════════════════════════════════════
  /// El usuario solo da su email y nombre opcional.
  /// El backend genera el código de acceso y lo envía al email.
  Future<ApiResponse<Map<String, dynamic>>> register({
    required String email,
    String? firstName,
    String? lastName,
    String visualImpairmentLevel = 'none',
    bool screenReaderUser = false,
  }) async {
    try {
      debugPrint('📝 Registrando usuario: $email');

      final body = <String, dynamic>{
        'email': email.trim(),
        'visual_impairment_level': visualImpairmentLevel,
        'screen_reader_user': screenReaderUser,
      };
      if (firstName != null && firstName.isNotEmpty) {
        body['first_name'] = firstName.trim();
      }
      if (lastName != null && lastName.isNotEmpty) {
        body['last_name'] = lastName.trim();
      }

      final response = await _apiClient.post<Map<String, dynamic>>(
        ApiConfig.register,
        body: body,
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
  // LOGIN CON CÓDIGO PERMANENTE — flujo principal
  // ════════════════════════════════════════════════════════════
  Future<ApiResponse<AuthData>> loginWithCode({required String code}) async {
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
        debugPrint('✅ Login exitoso — tokens guardados');
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
  // SOLICITAR NUEVO CÓDIGO — solo email, sin contraseña
  // ════════════════════════════════════════════════════════════
  /// El usuario olvidó su código. Con solo el email el backend
  /// genera un nuevo código permanente y lo envía al correo.
  /// El código anterior deja de funcionar.
  Future<ApiResponse<void>> requestNewCode({required String email}) async {
    try {
      debugPrint('📧 Solicitando nuevo código para $email');

      return await _apiClient.post<void>(
        ApiConfig.requestNewCode,
        body: {'email': email.trim()},
      );
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
  // LOGIN CON EMAIL + CONTRASEÑA — solo usuarios legacy
  // ════════════════════════════════════════════════════════════
  Future<ApiResponse<AuthData>> login({
    required String email,
    required String password,
    bool rememberMe = false,
  }) async {
    try {
      debugPrint('🔑 Login legacy con email: $email');

      final response = await _apiClient.post<AuthData>(
        ApiConfig.login,
        body: {
          'email': email.trim(),
          'password': password,
          'remember_me': rememberMe,
        },
        fromJson: (data) => AuthData.fromJson(data as Map<String, dynamic>),
      );

      if (response.success && response.data != null) {
        await _tokenService.saveTokens(
          accessToken: response.data!.tokens.accessToken,
          refreshToken: response.data!.tokens.refreshToken,
          tokenType: response.data!.tokens.tokenType,
          expiresIn: response.data!.tokens.expiresIn,
        );
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
  // LOGOUT
  // ════════════════════════════════════════════════════════════
  Future<ApiResponse<void>> logout() async {
    try {
      final response = await _apiClient.post<void>(ApiConfig.logout);
      await _tokenService.clearTokens();
      return response;
    } catch (e) {
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

  Future<void> clearLocalSession() async {
    await _tokenService.clearTokens();
  }

  // ════════════════════════════════════════════════════════════
  // RENOVAR TOKEN
  // ════════════════════════════════════════════════════════════
  Future<ApiResponse<TokenPair>> refreshToken() async {
    try {
      final storedRefreshToken = await _tokenService.getRefreshToken();
      if (storedRefreshToken == null) {
        return ApiResponse(
          success: false,
          message: 'No hay sesión activa',
          accessibilityInfo: AccessibilityInfo(
            announcement: 'Sesión no encontrada',
            hapticPattern: 'warning',
          ),
        );
      }

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
      }
      return response;
    } catch (e) {
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
  // VERIFICAR AUTENTICACIÓN
  // ════════════════════════════════════════════════════════════
  Future<bool> isAuthenticated() => _tokenService.hasTokens();
  Future<bool> isAccessTokenValid() => _tokenService.isAccessTokenValid();
  Future<bool> hasRefreshToken() => _tokenService.hasRefreshToken();
}