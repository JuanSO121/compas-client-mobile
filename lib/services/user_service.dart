// lib/services/user_service.dart
import 'package:flutter/foundation.dart';
import '../config/api_config.dart';
import '../models/api_models.dart';
import 'api_client.dart';

class UserService {
  final ApiClient _apiClient = ApiClient();

  // ===== OBTENER PERFIL =====
  Future<ApiResponse<UserData>> getProfile() async {
    try {
      debugPrint('👤 Obteniendo perfil de usuario');

      final response = await _apiClient.get<UserData>(
        ApiConfig.userProfile,
        fromJson: (json) => UserData.fromJson((json as Map<String, dynamic>)['user']),
      );

      if (response.success) {
        debugPrint('✅ Perfil obtenido exitosamente');
      }

      return response;
    } catch (e) {
      debugPrint('❌ Error obteniendo perfil: $e');
      return ApiResponse(
        success: false,
        message: 'Error al obtener perfil: ${e.toString()}',
        accessibilityInfo: AccessibilityInfo(
          announcement: 'Error al cargar perfil',
          hapticPattern: 'error',
        ),
      );
    }
  }

  // ===== ACTUALIZAR PERFIL =====
  Future<ApiResponse<void>> updateProfile({
    String? firstName,
    String? lastName,
    String? phone,
  }) async {
    try {
      debugPrint('📝 Actualizando perfil');

      final body = <String, dynamic>{};
      if (firstName != null) body['first_name'] = firstName;
      if (lastName != null) body['last_name'] = lastName;
      if (phone != null) body['phone'] = phone;

      final response = await _apiClient.put<void>(
        ApiConfig.updateProfile,
        body: body,
      );

      if (response.success) {
        debugPrint('✅ Perfil actualizado exitosamente');
      }

      return response;
    } catch (e) {
      debugPrint('❌ Error actualizando perfil: $e');
      return ApiResponse(
        success: false,
        message: 'Error al actualizar perfil: ${e.toString()}',
        accessibilityInfo: AccessibilityInfo(
          announcement: 'Error al actualizar perfil',
          hapticPattern: 'error',
        ),
      );
    }
  }

  // ===== ACTUALIZAR PREFERENCIAS DE ACCESIBILIDAD =====
  Future<ApiResponse<void>> updateAccessibilityPreferences({
    String? visualImpairmentLevel,
    bool? screenReaderUser,
    double? preferredTtsSpeed,
    bool? highContrastMode,
    bool? darkModeEnabled,
    bool? hapticFeedbackEnabled,
  }) async {
    try {
      debugPrint('♿ Actualizando preferencias de accesibilidad');

      final body = <String, dynamic>{};
      if (visualImpairmentLevel != null) body['visual_impairment_level'] = visualImpairmentLevel;
      if (screenReaderUser != null) body['screen_reader_user'] = screenReaderUser;
      if (preferredTtsSpeed != null) body['preferred_tts_speed'] = preferredTtsSpeed;
      if (highContrastMode != null) body['high_contrast_mode'] = highContrastMode;
      if (darkModeEnabled != null) body['dark_mode_enabled'] = darkModeEnabled;
      if (hapticFeedbackEnabled != null) body['haptic_feedback_enabled'] = hapticFeedbackEnabled;

      final response = await _apiClient.put<void>(
        ApiConfig.updateAccessibility,
        body: body,
      );

      if (response.success) {
        debugPrint('✅ Preferencias de accesibilidad actualizadas');
      }

      return response;
    } catch (e) {
      debugPrint('❌ Error actualizando preferencias: $e');
      return ApiResponse(
        success: false,
        message: 'Error al actualizar preferencias: ${e.toString()}',
        accessibilityInfo: AccessibilityInfo(
          announcement: 'Error al actualizar preferencias',
          hapticPattern: 'error',
        ),
      );
    }
  }

  // ===== ELIMINAR CUENTA =====
  Future<ApiResponse<void>> deleteAccount({
    required String confirmationText,
    String? password,
  }) async {
    try {
      debugPrint('🗑️ Eliminando cuenta');

      final body = {
        'confirm_deletion': confirmationText,
        if (password != null) 'password': password,
      };

      final response = await _apiClient.delete<void>(
        ApiConfig.deleteAccount,
        body: body,
      );

      if (response.success) {
        debugPrint('✅ Cuenta eliminada exitosamente');
      }

      return response;
    } catch (e) {
      debugPrint('❌ Error eliminando cuenta: $e');
      return ApiResponse(
        success: false,
        message: 'Error al eliminar cuenta: ${e.toString()}',
        accessibilityInfo: AccessibilityInfo(
          announcement: 'Error al eliminar cuenta',
          hapticPattern: 'error',
        ),
      );
    }
  }

  // ===== OBTENER LOG DE ACTIVIDAD =====
  Future<ApiResponse<List<dynamic>>> getActivityLog({int limit = 50}) async {
    try {
      debugPrint('📊 Obteniendo log de actividad');

      final response = await _apiClient.get<List<dynamic>>(
        '${ApiConfig.activityLog}?limit=$limit',
        fromJson: (json) => (json as Map<String, dynamic>)['activity_logs'] as List<dynamic>,
      );

      if (response.success) {
        debugPrint('✅ Log de actividad obtenido');
      }

      return response;
    } catch (e) {
      debugPrint('❌ Error obteniendo log: $e');
      return ApiResponse(
        success: false,
        message: 'Error al obtener historial: ${e.toString()}',
        accessibilityInfo: AccessibilityInfo(
          announcement: 'Error al cargar historial',
          hapticPattern: 'error',
        ),
      );
    }
  }
}