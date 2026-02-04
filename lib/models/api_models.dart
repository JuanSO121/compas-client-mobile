// lib/models/api_models.dart
import 'package:json_annotation/json_annotation.dart';
part 'api_models.g.dart';


// ===== RESPUESTA BASE DEL BACKEND =====
@JsonSerializable(genericArgumentFactories: true)
class ApiResponse<T> {

  final bool success;
  final String message;
  @JsonKey(name: 'message_type')
  final String? messageType;
  final T? data;
  @JsonKey(name: 'accessibility_info')
  final AccessibilityInfo? accessibilityInfo;
  final List<ApiError>? errors;
  final String? timestamp;

  ApiResponse({
    required this.success,
    required this.message,
    this.messageType,
    this.data,
    this.accessibilityInfo,
    this.errors,
    this.timestamp,
  });

  factory ApiResponse.fromJson(
      Map<String, dynamic> json,
      T Function(Object? json) fromJsonT,
      ) =>
      _$ApiResponseFromJson(json, fromJsonT);

  Map<String, dynamic> toJson(Object Function(T value) toJsonT) =>
      _$ApiResponseToJson(this, toJsonT);
}

// ===== INFO DE ACCESIBILIDAD =====
@JsonSerializable()
class AccessibilityInfo {
  final String? announcement;
  @JsonKey(name: 'focus_element')
  final String? focusElement;
  @JsonKey(name: 'haptic_pattern')
  final String? hapticPattern;

  AccessibilityInfo({
    this.announcement,
    this.focusElement,
    this.hapticPattern,
  });

  factory AccessibilityInfo.fromJson(Map<String, dynamic> json) =>
      _$AccessibilityInfoFromJson(json);
  Map<String, dynamic> toJson() => _$AccessibilityInfoToJson(this);
}

// ===== ERROR DEL API =====
@JsonSerializable()
class ApiError {
  final String field;
  final String message;
  final String? suggestion;

  ApiError({
    required this.field,
    required this.message,
    this.suggestion,
  });

  factory ApiError.fromJson(Map<String, dynamic> json) =>
      _$ApiErrorFromJson(json);
  Map<String, dynamic> toJson() => _$ApiErrorToJson(this);
}

// ===== MODELOS DE AUTENTICACIÓN =====
@JsonSerializable()
class LoginRequest {
  final String email;
  final String password;
  @JsonKey(name: 'remember_me')
  final bool rememberMe;

  LoginRequest({
    required this.email,
    required this.password,
    this.rememberMe = false,
  });

  factory LoginRequest.fromJson(Map<String, dynamic> json) =>
      _$LoginRequestFromJson(json);
  Map<String, dynamic> toJson() => _$LoginRequestToJson(this);
}

@JsonSerializable()
class RegisterRequest {
  final String email;
  final String password;
  @JsonKey(name: 'confirm_password')
  final String confirmPassword;
  @JsonKey(name: 'first_name')
  final String? firstName;
  @JsonKey(name: 'last_name')
  final String? lastName;
  @JsonKey(name: 'preferred_language')
  final String preferredLanguage;
  @JsonKey(name: 'visual_impairment_level')
  final String visualImpairmentLevel;
  @JsonKey(name: 'screen_reader_user')
  final bool screenReaderUser;

  RegisterRequest({
    required this.email,
    required this.password,
    required this.confirmPassword,
    this.firstName,
    this.lastName,
    this.preferredLanguage = 'es',
    this.visualImpairmentLevel = 'none',
    this.screenReaderUser = false,
  });

  factory RegisterRequest.fromJson(Map<String, dynamic> json) =>
      _$RegisterRequestFromJson(json);
  Map<String, dynamic> toJson() => _$RegisterRequestToJson(this);
}

@JsonSerializable()
class TokenPair {
  @JsonKey(name: 'access_token')
  final String accessToken;
  @JsonKey(name: 'refresh_token')
  final String refreshToken;
  @JsonKey(name: 'token_type')
  final String tokenType;
  @JsonKey(name: 'expires_in')
  final int expiresIn;

  TokenPair({
    required this.accessToken,
    required this.refreshToken,
    this.tokenType = 'bearer',
    required this.expiresIn,
  });

  factory TokenPair.fromJson(Map<String, dynamic> json) =>
      _$TokenPairFromJson(json);
  Map<String, dynamic> toJson() => _$TokenPairToJson(this);
}

@JsonSerializable()
class AuthData {
  final TokenPair tokens;
  final UserData user;

  AuthData({
    required this.tokens,
    required this.user,
  });

  factory AuthData.fromJson(Map<String, dynamic> json) =>
      _$AuthDataFromJson(json);
  Map<String, dynamic> toJson() => _$AuthDataToJson(this);
}

@JsonSerializable()
class UserData {
  final String id;
  final String email;
  final UserProfile? profile;
  final AccessibilityPreferences? accessibility;
  @JsonKey(name: 'last_login')
  final String? lastLogin;

  UserData({
    required this.id,
    required this.email,
    this.profile,
    this.accessibility,
    this.lastLogin,
  });

  factory UserData.fromJson(Map<String, dynamic> json) =>
      _$UserDataFromJson(json);
  Map<String, dynamic> toJson() => _$UserDataToJson(this);
}

@JsonSerializable()
class UserProfile {
  @JsonKey(name: 'first_name')
  final String? firstName;
  @JsonKey(name: 'last_name')
  final String? lastName;
  final String? phone;
  @JsonKey(name: 'preferred_language')
  final String? preferredLanguage;
  final String? timezone;

  UserProfile({
    this.firstName,
    this.lastName,
    this.phone,
    this.preferredLanguage,
    this.timezone,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) =>
      _$UserProfileFromJson(json);
  Map<String, dynamic> toJson() => _$UserProfileToJson(this);
}

@JsonSerializable()
class AccessibilityPreferences {
  @JsonKey(name: 'visual_impairment_level')
  final String? visualImpairmentLevel;
  @JsonKey(name: 'screen_reader_user')
  final bool? screenReaderUser;
  @JsonKey(name: 'preferred_tts_speed')
  final double? preferredTtsSpeed;
  @JsonKey(name: 'high_contrast_mode')
  final bool? highContrastMode;
  @JsonKey(name: 'dark_mode_enabled')
  final bool? darkModeEnabled;
  @JsonKey(name: 'haptic_feedback_enabled')
  final bool? hapticFeedbackEnabled;

  AccessibilityPreferences({
    this.visualImpairmentLevel,
    this.screenReaderUser,
    this.preferredTtsSpeed,
    this.highContrastMode,
    this.darkModeEnabled,
    this.hapticFeedbackEnabled,
  });

  factory AccessibilityPreferences.fromJson(Map<String, dynamic> json) =>
      _$AccessibilityPreferencesFromJson(json);
  Map<String, dynamic> toJson() => _$AccessibilityPreferencesToJson(this);
}