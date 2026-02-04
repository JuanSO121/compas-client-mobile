// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'api_models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ApiResponse<T> _$ApiResponseFromJson<T>(
  Map<String, dynamic> json,
  T Function(Object? json) fromJsonT,
) => ApiResponse<T>(
  success: json['success'] as bool,
  message: json['message'] as String,
  messageType: json['message_type'] as String?,
  data: _$nullableGenericFromJson(json['data'], fromJsonT),
  accessibilityInfo: json['accessibility_info'] == null
      ? null
      : AccessibilityInfo.fromJson(
          json['accessibility_info'] as Map<String, dynamic>,
        ),
  errors: (json['errors'] as List<dynamic>?)
      ?.map((e) => ApiError.fromJson(e as Map<String, dynamic>))
      .toList(),
  timestamp: json['timestamp'] as String?,
);

Map<String, dynamic> _$ApiResponseToJson<T>(
  ApiResponse<T> instance,
  Object? Function(T value) toJsonT,
) => <String, dynamic>{
  'success': instance.success,
  'message': instance.message,
  'message_type': instance.messageType,
  'data': _$nullableGenericToJson(instance.data, toJsonT),
  'accessibility_info': instance.accessibilityInfo,
  'errors': instance.errors,
  'timestamp': instance.timestamp,
};

T? _$nullableGenericFromJson<T>(
  Object? input,
  T Function(Object? json) fromJson,
) => input == null ? null : fromJson(input);

Object? _$nullableGenericToJson<T>(
  T? input,
  Object? Function(T value) toJson,
) => input == null ? null : toJson(input);

AccessibilityInfo _$AccessibilityInfoFromJson(Map<String, dynamic> json) =>
    AccessibilityInfo(
      announcement: json['announcement'] as String?,
      focusElement: json['focus_element'] as String?,
      hapticPattern: json['haptic_pattern'] as String?,
    );

Map<String, dynamic> _$AccessibilityInfoToJson(AccessibilityInfo instance) =>
    <String, dynamic>{
      'announcement': instance.announcement,
      'focus_element': instance.focusElement,
      'haptic_pattern': instance.hapticPattern,
    };

ApiError _$ApiErrorFromJson(Map<String, dynamic> json) => ApiError(
  field: json['field'] as String,
  message: json['message'] as String,
  suggestion: json['suggestion'] as String?,
);

Map<String, dynamic> _$ApiErrorToJson(ApiError instance) => <String, dynamic>{
  'field': instance.field,
  'message': instance.message,
  'suggestion': instance.suggestion,
};

LoginRequest _$LoginRequestFromJson(Map<String, dynamic> json) => LoginRequest(
  email: json['email'] as String,
  password: json['password'] as String,
  rememberMe: json['remember_me'] as bool? ?? false,
);

Map<String, dynamic> _$LoginRequestToJson(LoginRequest instance) =>
    <String, dynamic>{
      'email': instance.email,
      'password': instance.password,
      'remember_me': instance.rememberMe,
    };

RegisterRequest _$RegisterRequestFromJson(Map<String, dynamic> json) =>
    RegisterRequest(
      email: json['email'] as String,
      password: json['password'] as String,
      confirmPassword: json['confirm_password'] as String,
      firstName: json['first_name'] as String?,
      lastName: json['last_name'] as String?,
      preferredLanguage: json['preferred_language'] as String? ?? 'es',
      visualImpairmentLevel:
          json['visual_impairment_level'] as String? ?? 'none',
      screenReaderUser: json['screen_reader_user'] as bool? ?? false,
    );

Map<String, dynamic> _$RegisterRequestToJson(RegisterRequest instance) =>
    <String, dynamic>{
      'email': instance.email,
      'password': instance.password,
      'confirm_password': instance.confirmPassword,
      'first_name': instance.firstName,
      'last_name': instance.lastName,
      'preferred_language': instance.preferredLanguage,
      'visual_impairment_level': instance.visualImpairmentLevel,
      'screen_reader_user': instance.screenReaderUser,
    };

TokenPair _$TokenPairFromJson(Map<String, dynamic> json) => TokenPair(
  accessToken: json['access_token'] as String,
  refreshToken: json['refresh_token'] as String,
  tokenType: json['token_type'] as String? ?? 'bearer',
  expiresIn: (json['expires_in'] as num).toInt(),
);

Map<String, dynamic> _$TokenPairToJson(TokenPair instance) => <String, dynamic>{
  'access_token': instance.accessToken,
  'refresh_token': instance.refreshToken,
  'token_type': instance.tokenType,
  'expires_in': instance.expiresIn,
};

AuthData _$AuthDataFromJson(Map<String, dynamic> json) => AuthData(
  tokens: TokenPair.fromJson(json['tokens'] as Map<String, dynamic>),
  user: UserData.fromJson(json['user'] as Map<String, dynamic>),
);

Map<String, dynamic> _$AuthDataToJson(AuthData instance) => <String, dynamic>{
  'tokens': instance.tokens,
  'user': instance.user,
};

UserData _$UserDataFromJson(Map<String, dynamic> json) => UserData(
  id: json['id'] as String,
  email: json['email'] as String,
  profile: json['profile'] == null
      ? null
      : UserProfile.fromJson(json['profile'] as Map<String, dynamic>),
  accessibility: json['accessibility'] == null
      ? null
      : AccessibilityPreferences.fromJson(
          json['accessibility'] as Map<String, dynamic>,
        ),
  lastLogin: json['last_login'] as String?,
);

Map<String, dynamic> _$UserDataToJson(UserData instance) => <String, dynamic>{
  'id': instance.id,
  'email': instance.email,
  'profile': instance.profile,
  'accessibility': instance.accessibility,
  'last_login': instance.lastLogin,
};

UserProfile _$UserProfileFromJson(Map<String, dynamic> json) => UserProfile(
  firstName: json['first_name'] as String?,
  lastName: json['last_name'] as String?,
  phone: json['phone'] as String?,
  preferredLanguage: json['preferred_language'] as String?,
  timezone: json['timezone'] as String?,
);

Map<String, dynamic> _$UserProfileToJson(UserProfile instance) =>
    <String, dynamic>{
      'first_name': instance.firstName,
      'last_name': instance.lastName,
      'phone': instance.phone,
      'preferred_language': instance.preferredLanguage,
      'timezone': instance.timezone,
    };

AccessibilityPreferences _$AccessibilityPreferencesFromJson(
  Map<String, dynamic> json,
) => AccessibilityPreferences(
  visualImpairmentLevel: json['visual_impairment_level'] as String?,
  screenReaderUser: json['screen_reader_user'] as bool?,
  preferredTtsSpeed: (json['preferred_tts_speed'] as num?)?.toDouble(),
  highContrastMode: json['high_contrast_mode'] as bool?,
  darkModeEnabled: json['dark_mode_enabled'] as bool?,
  hapticFeedbackEnabled: json['haptic_feedback_enabled'] as bool?,
);

Map<String, dynamic> _$AccessibilityPreferencesToJson(
  AccessibilityPreferences instance,
) => <String, dynamic>{
  'visual_impairment_level': instance.visualImpairmentLevel,
  'screen_reader_user': instance.screenReaderUser,
  'preferred_tts_speed': instance.preferredTtsSpeed,
  'high_contrast_mode': instance.highContrastMode,
  'dark_mode_enabled': instance.darkModeEnabled,
  'haptic_feedback_enabled': instance.hapticFeedbackEnabled,
};
