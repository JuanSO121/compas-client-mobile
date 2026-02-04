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

  // ===== GUARDAR TOKENS =====
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    String tokenType = 'bearer',
    int? expiresIn,
  }) async {
    try {
      await Future.wait([
        _storage.write(key: _accessTokenKey, value: accessToken),
        _storage.write(key: _refreshTokenKey, value: refreshToken),
        _storage.write(key: _tokenTypeKey, value: tokenType),
        if (expiresIn != null)
          _storage.write(key: _expiresInKey, value: expiresIn.toString()),
      ]);
      debugPrint('✅ Tokens guardados exitosamente');
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

  // ===== LIMPIAR TOKENS =====
  Future<void> clearTokens() async {
    try {
      await Future.wait([
        _storage.delete(key: _accessTokenKey),
        _storage.delete(key: _refreshTokenKey),
        _storage.delete(key: _tokenTypeKey),
        _storage.delete(key: _expiresInKey),
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