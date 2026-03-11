// lib/services/api_client.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../config/api_config.dart';
import '../models/api_models.dart';
import 'token_service.dart';

class ApiClient {
  final TokenService _tokenService = TokenService();

  // ===== GET REQUEST =====
  Future<ApiResponse<T>> get<T>(
      String endpoint, {
        Map<String, String>? headers,
        T Function(dynamic)? fromJson,
      }) async {
    try {
      final token = await _tokenService.getAccessToken();
      final allHeaders = {
        ...ApiConfig.defaultHeaders,
        if (token != null) 'Authorization': 'Bearer $token',
        ...?headers,
      };

      debugPrint('🌐 GET: ${ApiConfig.baseUrl}$endpoint');

      final response = await http
          .get(
        Uri.parse('${ApiConfig.baseUrl}$endpoint'),
        headers: allHeaders,
      )
          .timeout(ApiConfig.receiveTimeout);

      return _handleResponse<T>(response, fromJson);
    } on SocketException {
      return _errorResponse<T>(
        'No hay conexión a internet. Verifique su conexión.',
        'sin_conexion',
      );
    } on TimeoutException {
      return _errorResponse<T>(
        'La solicitud tomó demasiado tiempo. Intente nuevamente.',
        'timeout',
      );
    } catch (e) {
      debugPrint('❌ Error en GET: $e');
      return _errorResponse<T>(
        'Error de conexión: ${e.toString()}',
        'error_conexion',
      );
    }
  }

  // ===== POST REQUEST =====
  Future<ApiResponse<T>> post<T>(
      String endpoint, {
        Map<String, dynamic>? body,
        Map<String, String>? headers,
        T Function(dynamic)? fromJson,
      }) async {
    try {
      final token = await _tokenService.getAccessToken();
      final allHeaders = {
        ...ApiConfig.defaultHeaders,
        if (token != null) 'Authorization': 'Bearer $token',
        ...?headers,
      };

      debugPrint('🌐 POST: ${ApiConfig.baseUrl}$endpoint');
      debugPrint('📦 Body: ${jsonEncode(body)}');

      final response = await http
          .post(
        Uri.parse('${ApiConfig.baseUrl}$endpoint'),
        headers: allHeaders,
        body: jsonEncode(body),
      )
          .timeout(ApiConfig.receiveTimeout);

      return _handleResponse<T>(response, fromJson);
    } on SocketException {
      return _errorResponse<T>(
        'No hay conexión a internet. Verifique su conexión.',
        'sin_conexion',
      );
    } on TimeoutException {
      return _errorResponse<T>(
        'La solicitud tomó demasiado tiempo. Intente nuevamente.',
        'timeout',
      );
    } catch (e) {
      debugPrint('❌ Error en POST: $e');
      return _errorResponse<T>(
        'Error de conexión: ${e.toString()}',
        'error_conexion',
      );
    }
  }

  // ===== PUT REQUEST =====
  Future<ApiResponse<T>> put<T>(
      String endpoint, {
        Map<String, dynamic>? body,
        Map<String, String>? headers,
        T Function(dynamic)? fromJson,
      }) async {
    try {
      final token = await _tokenService.getAccessToken();
      final allHeaders = {
        ...ApiConfig.defaultHeaders,
        if (token != null) 'Authorization': 'Bearer $token',
        ...?headers,
      };

      debugPrint('🌐 PUT: ${ApiConfig.baseUrl}$endpoint');

      final response = await http
          .put(
        Uri.parse('${ApiConfig.baseUrl}$endpoint'),
        headers: allHeaders,
        body: jsonEncode(body),
      )
          .timeout(ApiConfig.receiveTimeout);

      return _handleResponse<T>(response, fromJson);
    } catch (e) {
      debugPrint('❌ Error en PUT: $e');
      return _errorResponse<T>(
        'Error de conexión: ${e.toString()}',
        'error_conexion',
      );
    }
  }

  // ===== DELETE REQUEST =====
  Future<ApiResponse<T>> delete<T>(
      String endpoint, {
        Map<String, dynamic>? body,
        Map<String, String>? headers,
        T Function(dynamic)? fromJson,
      }) async {
    try {
      final token = await _tokenService.getAccessToken();
      final allHeaders = {
        ...ApiConfig.defaultHeaders,
        if (token != null) 'Authorization': 'Bearer $token',
        ...?headers,
      };

      debugPrint('🌐 DELETE: ${ApiConfig.baseUrl}$endpoint');

      final response = await http
          .delete(
        Uri.parse('${ApiConfig.baseUrl}$endpoint'),
        headers: allHeaders,
        body: body != null ? jsonEncode(body) : null,
      )
          .timeout(ApiConfig.receiveTimeout);

      return _handleResponse<T>(response, fromJson);
    } catch (e) {
      debugPrint('❌ Error en DELETE: $e');
      return _errorResponse<T>(
        'Error de conexión: ${e.toString()}',
        'error_conexion',
      );
    }
  }

  // ===== MANEJAR RESPUESTA =====
  ApiResponse<T> _handleResponse<T>(
      http.Response response,
      T Function(dynamic)? fromJson,
      ) {
    debugPrint('📡 Status: ${response.statusCode}');
    debugPrint('📄 Response: ${response.body}');

    try {
      final Map<String, dynamic> jsonResponse = jsonDecode(response.body);

      // ── Error HTTP (4xx / 5xx) ──────────────────────────────────────────
      if (response.statusCode >= 400) {
        return ApiResponse<T>(
          success: false,
          message: jsonResponse['message'] ?? 'Error del servidor',
          messageType: jsonResponse['message_type'] ?? 'error',
          accessibilityInfo: jsonResponse['accessibility_info'] != null
              ? AccessibilityInfo.fromJson(
              jsonResponse['accessibility_info'] as Map<String, dynamic>)
              : null,
          errors: jsonResponse['errors'] != null
              ? (jsonResponse['errors'] as List)
              .map((e) => ApiError.fromJson(e as Map<String, dynamic>))
              .toList()
              : null,
        );
      }

      // ── FIX: El servidor devuelve HTTP 200 con success:false ────────────
      // Antes solo se revisaba el statusCode, por lo que success:false con
      // HTTP 200 entraba al bloque "exitoso" e intentaba parsear data:{}
      // como un modelo tipado, causando crashes o sesiones no guardadas.
      final bool isSuccess = jsonResponse['success'] == true;

      if (!isSuccess) {
        return ApiResponse<T>(
          success: false,
          message: jsonResponse['message'] ?? 'Error desconocido',
          messageType: jsonResponse['message_type'] ?? 'error',
          accessibilityInfo: jsonResponse['accessibility_info'] != null
              ? AccessibilityInfo.fromJson(
              jsonResponse['accessibility_info'] as Map<String, dynamic>)
              : null,
          errors: jsonResponse['errors'] != null
              ? (jsonResponse['errors'] as List)
              .map((e) => ApiError.fromJson(e as Map<String, dynamic>))
              .toList()
              : null,
          timestamp: jsonResponse['timestamp'] as String?,
        );
      }

      // ── Respuesta exitosa: parsear data ────────────────────────────────
      // FIX: Se pasa jsonResponse['data'] al fromJson (no el JSON completo).
      // El fromJson de cada servicio debe trabajar directamente con `data`,
      // no buscar map['data'] dentro de él.
      T? parsedData;
      if (fromJson != null) {
        final rawData = jsonResponse['data'];
        // Solo parsear si data no es null y no es un mapa vacío
        if (rawData != null && !(rawData is Map && rawData.isEmpty)) {
          parsedData = fromJson(rawData);
        }
      }

      return ApiResponse<T>(
        success: true,
        message: jsonResponse['message'] ?? '',
        messageType: jsonResponse['message_type'],
        data: parsedData,
        accessibilityInfo: jsonResponse['accessibility_info'] != null
            ? AccessibilityInfo.fromJson(
            jsonResponse['accessibility_info'] as Map<String, dynamic>)
            : null,
        errors: jsonResponse['errors'] != null
            ? (jsonResponse['errors'] as List)
            .map((e) => ApiError.fromJson(e as Map<String, dynamic>))
            .toList()
            : null,
        timestamp: jsonResponse['timestamp'] as String?,
      );
    } catch (e) {
      debugPrint('❌ Error parseando respuesta: $e');
      return _errorResponse<T>(
        'Error procesando la respuesta del servidor',
        'error_parse',
      );
    }
  }

  // ===== RESPUESTA DE ERROR =====
  ApiResponse<T> _errorResponse<T>(String message, String announcement) {
    return ApiResponse<T>(
      success: false,
      message: message,
      messageType: 'error',
      accessibilityInfo: AccessibilityInfo(
        announcement: announcement,
        hapticPattern: 'error',
      ),
    );
  }
}