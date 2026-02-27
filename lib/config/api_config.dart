import 'package:flutter_dotenv/flutter_dotenv.dart';

class ApiConfig {
  // ======================
  // BASE URLS
  // ======================
  static String get baseUrlPC =>
      dotenv.env['BASE_URL_PC'] ?? 'http://127.0.0.1:8080';

  static String get baseUrl =>
      dotenv.env['BASE_URL'] ?? 'http://192.168.1.5:8080';

  // ======================
  // API KEYS (NO GIT)
  // ======================
  static String get groqApiKey =>
      dotenv.env['GROQ_API_KEY'] ?? '';

  static String get picovoiceAccessKey =>
      dotenv.env['PICOVOICE_ACCESS_KEY'] ?? '';

  // ======================
  // GROQ CONFIGURATION
  // ======================
  static const String groqBaseUrl = 'https://api.groq.com/openai/v1';

  // Modelo optimizado para comandos rápidos
  static const String groqCommandModel = 'llama-3.3-70b-versatile';

  // Modelo para conversación más compleja
  static const String groqConversationModel = 'llama-3.3-70b-versatile';

  // ======================
  // API VERSION
  // ======================
  static const String apiVersion = '/api/v1';

  // ======================
  // AUTH ENDPOINTS
  // ======================
  static const String register = '$apiVersion/auth/register';
  static const String login = '$apiVersion/auth/login';
  static const String logout = '$apiVersion/auth/logout';
  static const String refreshToken = '$apiVersion/auth/refresh';
  static const String forgotPassword = '$apiVersion/auth/forgot-password';
  static const String resetPassword = '$apiVersion/auth/reset-password';
  static const String verifyEmail = '$apiVersion/auth/verify-email';

  // ======================
  // USER ENDPOINTS
  // ======================
  static const String userProfile = '$apiVersion/users/profile';
  static const String updateProfile = '$apiVersion/users/profile';
  static const String deleteAccount = '$apiVersion/users/account';
  static const String activityLog = '$apiVersion/users/activity-log';

  // ======================
  // ACCESSIBILITY
  // ======================
  static const String updateAccessibility =
      '$apiVersion/accessibility/preferences';

  // ======================
  // TIMEOUTS
  // ======================
  static const Duration connectTimeout = Duration(seconds: 30);
  static const Duration receiveTimeout = Duration(seconds: 30);
  static const Duration groqTimeout = Duration(seconds: 3); // Era 5, ahora 3

  // ======================
  // HEADERS
  // ======================
  static Map<String, String> get defaultHeaders => {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  static Map<String, String> authHeaders(String token) => {
    ...defaultHeaders,
    'Authorization': 'Bearer $token',
  };

  static Map<String, String> get groqHeaders => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $groqApiKey',
  };

  // ======================
  // VALIDATION
  // ======================
  static bool get isConfigured =>
      groqApiKey.isNotEmpty && picovoiceAccessKey.isNotEmpty;
}