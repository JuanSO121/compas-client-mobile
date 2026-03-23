// lib/services/token_service.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class TokenService {
  static final TokenService _instance = TokenService._internal();
  factory TokenService() => _instance;
  TokenService._internal();

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock,
    ),
  );

  static const String _accessTokenKey = 'access_token';
  static const String _refreshTokenKey = 'refresh_token';
  static const String _tokenTypeKey = 'token_type';
  static const String _expiresInKey = 'expires_in';

  // ── NUEVO: guardamos la fecha exacta de expiración del access token ──
  // Esto nos permite saber si hay que refrescar sin hacer una llamada al
  // servidor innecesaria. Se guarda como milisegundos desde epoch (int).
  static const String _accessTokenExpiresAtKey = 'access_token_expires_at';

  // ===== GUARDAR TOKENS =====
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    String tokenType = 'bearer',
    int? expiresIn, // segundos que dura el access token
  }) async {
    try {
      // Calcular el timestamp exacto de expiración.
      // Restamos 60 segundos como margen de seguridad para evitar usar
      // un token que expira justo mientras viaja la request al servidor.
      final expiresAt = expiresIn != null
          ? DateTime.now()
              .add(Duration(seconds: expiresIn - 60))
              .millisecondsSinceEpoch
              .toString()
          : null;

      await Future.wait([
        _storage.write(key: _accessTokenKey, value: accessToken),
        _storage.write(key: _refreshTokenKey, value: refreshToken),
        _storage.write(key: _tokenTypeKey, value: tokenType),
        if (expiresIn != null)
          _storage.write(key: _expiresInKey, value: expiresIn.toString()),
        if (expiresAt != null)
          _storage.write(key: _accessTokenExpiresAtKey, value: expiresAt),
      ]);

      debugPrint('✅ Tokens guardados. Expiran en ${expiresIn ?? "?"} segundos');
    } catch (e) {
      debugPrint('❌ Error guardando tokens: $e');
      rethrow;
    }
  }

  // ===== OBTENER ACCESS TOKEN =====
  Future<String?> getAccessToken() async {
    try {
      return await _storage.read(key: _accessTokenKey);
    } catch (e) {
      debugPrint('❌ Error obteniendo access token: $e');
      return null;
    }
  }

  // ===== OBTENER REFRESH TOKEN =====
  Future<String?> getRefreshToken() async {
    try {
      return await _storage.read(key: _refreshTokenKey);
    } catch (e) {
      debugPrint('❌ Error obteniendo refresh token: $e');
      return null;
    }
  }

  // ===== VERIFICAR SI HAY TOKENS =====
  Future<bool> hasTokens() async {
    try {
      final accessToken = await getAccessToken();
      return accessToken != null && accessToken.isNotEmpty;
    } catch (e) {
      debugPrint('❌ Error verificando tokens: $e');
      return false;
    }
  }

  // ===== NUEVO: ¿El access token sigue vigente? =====
  // Retorna true si el token existe Y no ha expirado aún.
  // Retorna false si expiró O si no hay fecha guardada (legacy).
  Future<bool> isAccessTokenValid() async {
    try {
      final token = await getAccessToken();
      if (token == null || token.isEmpty) return false;

      final expiresAtStr = await _storage.read(key: _accessTokenExpiresAtKey);
      if (expiresAtStr == null) {
        // No tenemos fecha de expiración guardada (tokens viejos antes del fix).
        // Asumimos que expiró para forzar un refresh seguro.
        debugPrint('⚠️ Sin fecha de expiración guardada, asumiendo expirado');
        return false;
      }

      final expiresAt =
          DateTime.fromMillisecondsSinceEpoch(int.parse(expiresAtStr));
      final isValid = DateTime.now().isBefore(expiresAt);

      debugPrint(isValid
          ? '✅ Access token vigente hasta $expiresAt'
          : '⏰ Access token expirado el $expiresAt');

      return isValid;
    } catch (e) {
      debugPrint('❌ Error verificando vigencia del token: $e');
      return false;
    }
  }

  // ===== NUEVO: ¿Hay refresh token disponible? =====
  Future<bool> hasRefreshToken() async {
    try {
      final token = await getRefreshToken();
      return token != null && token.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  // ===== LIMPIAR TOKENS =====
  Future<void> clearTokens() async {
    try {
      await Future.wait([
        _storage.delete(key: _accessTokenKey),
        _storage.delete(key: _refreshTokenKey),
        _storage.delete(key: _tokenTypeKey),
        _storage.delete(key: _expiresInKey),
        _storage.delete(key: _accessTokenExpiresAtKey), // ← limpiar también
      ]);
      debugPrint('✅ Tokens eliminados exitosamente');
    } catch (e) {
      debugPrint('❌ Error eliminando tokens: $e');
      rethrow;
    }
  }

  // ===== LIMPIAR TODO EL STORAGE =====
  Future<void> clearAll() async {
    try {
      await _storage.deleteAll();
      debugPrint('✅ Storage limpiado completamente');
    } catch (e) {
      debugPrint('❌ Error limpiando storage: $e');
      rethrow;
    }
  }
}