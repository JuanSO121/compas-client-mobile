# COMPAS Client Mobile

Aplicación móvil en **Flutter** para asistencia de navegación accesible con interacción por voz, autenticación por código de acceso e integración con navegación AR mediante Unity.

> Este repositorio contiene el cliente móvil de COMPAS. Aunque Flutter permite compilar para varias plataformas, el flujo principal está pensado y probado principalmente para dispositivos móviles.

## Visión General

**COMPAS** es un asistente orientado a accesibilidad que combina:

- autenticación simple sin contraseña,
- anuncios por voz y semántica para lectores de pantalla,
- comandos de voz en español,
- modos de IA online/offline/auto,
- navegación AR con Unity,
- y persistencia segura de sesión con tokens.

**Repositorio:** https://github.com/JuanSO121/compas-client-mobile<br>
**Autores:** Juan José Sánchez Ocampo · Carlos Eduardo Rangel<br>
**Institución:** Universidad de San Buenaventura Cali, Ingeniería de Sistemas e Ingeniería Multimedia, 2026

## Estado Actual del Flujo

### Bienvenida

La app inicia con una pantalla de bienvenida accesible que anuncia las acciones disponibles mediante TTS y `SemanticsService`:

- **Iniciar Sesión**
- **Crear Cuenta**

Si ya existe una sesión válida, `AuthGate` omite la bienvenida y abre directamente la pantalla de navegación AR.

### Registro

El registro fue simplificado y ya no usa contraseña.

El flujo actual tiene 2 pasos:

1. **Correo electrónico**
   - Se valida el formato del email.
   - Incluye opciones de accesibilidad:
     - sin discapacidad visual,
     - baja visión,
     - ceguera,
     - uso de lector de pantalla.

2. **Nombre**
   - El nombre es obligatorio.
   - El apellido es opcional.

Después de crear la cuenta, el backend genera un **código de acceso permanente de 6 dígitos** y lo envía al correo registrado. La app redirige al login para que el usuario ingrese ese código.

### Login

El login principal ahora se realiza solo con el código de acceso de 6 dígitos.

Características del flujo:

- ingreso manual con teclado numérico,
- dictado opcional del código por voz,
- preferencia persistida para activar o desactivar dictado,
- confirmación dígito por dígito por TTS/STT,
- control anti-eco entre TTS y reconocimiento de voz,
- almacenamiento seguro de `accessToken` y `refreshToken` al iniciar sesión.

El flujo legacy de email + contraseña todavía existe en `AuthService`, pero no es el flujo principal de la interfaz.

### Solicitar Nuevo Código

Si el usuario olvida su código:

1. Ingresa el correo registrado.
2. El backend genera un nuevo código permanente.
3. El código anterior queda invalidado.
4. El nuevo código se envía por email.

Este flujo tampoco requiere contraseña.

## Características Principales

- **Autenticación accesible**
  - Registro sin contraseña.
  - Login por código permanente.
  - Recuperación de código por email.
  - Renovación automática de sesión con refresh token.

- **Voz**
  - STT con `speech_to_text`.
  - TTS con `flutter_tts`.
  - Guías auditivas en bienvenida, registro, login, recuperación y navegación.
  - Wake word preparado en assets y servicios, aunque la dependencia de Porcupine está comentada en `pubspec.yaml`.

- **IA de navegación**
  - Clasificación local con TensorFlow Lite.
  - Fallback por reglas/keywords.
  - Modo online con Groq cuando hay API key y conectividad.
  - Modos `auto`, `online` y `offline`.

- **AR con Unity**
  - Pantalla dedicada de navegación AR.
  - Tutorial de primera vez persistido con `SharedPreferences`.
  - Estados de inicialización, calibración, espera y navegación.
  - Comunicación Flutter ↔ Unity mediante `UnityBridgeService`.

- **Accesibilidad**
  - `SemanticsService.announce` para lectores de pantalla.
  - TTS propio aunque TalkBack/VoiceOver no estén activos.
  - Feedback háptico.
  - Labels, hints y regiones vivas en formularios y errores.

## Arquitectura Técnica

```text
lib/
  main.dart
  app/
  config/
    api_config.dart
  controllers/
    ar_navigation_controller.dart
  models/
    api_models.dart
    shared_models.dart
  screens/
    auth/
      welcome_screen.dart
      login_screen_integrated.dart
      register_screen_integrated.dart
      request_new_code_screen.dart
    ar_navigation_screen.dart
  services/
    AI/
      ai_mode_controller.dart
      conversation_service.dart
      groq_service.dart
      integrated_voice_command_service.dart
      navigation_coordinator.dart
      stt_session_manager.dart
      voice_command_classifier.dart
      wake_word_service.dart
      waypoint_context_service.dart
    api_client.dart
    auth_service.dart
    auth_tts_service.dart
    token_service.dart
    tts_service.dart
    unity_bridge_service.dart
    user_service.dart
  utils/
  widgets/
```

### Componentes Clave

- `AuthGate`: verifica tokens, renueva sesión si es posible y decide entre bienvenida o AR.
- `AuthService`: encapsula registro, login por código, solicitud de nuevo código, logout y refresh token.
- `AuthTTSService`: mensajes auditivos del flujo de autenticación.
- `TokenService`: persistencia segura de tokens con `flutter_secure_storage`.
- `ArNavigationController`: coordina Unity, tutorial, voz, estados de AR y overlays.
- `NavigationCoordinator`: orquesta STT, TTS, IA y comandos de navegación.
- `ApiConfig`: concentra URLs, endpoints, claves y timeouts.

## Backend

La app consume una API REST versionada bajo `/api/v1`.

Endpoints relevantes:

```text
POST /api/v1/auth/register
POST /api/v1/auth/login-with-code
POST /api/v1/auth/request-new-code
POST /api/v1/auth/refresh
POST /api/v1/auth/logout
GET/PUT /api/v1/users/profile
PUT /api/v1/accessibility/preferences
```

También quedan definidos endpoints legacy como `/auth/login`, `/auth/forgot-password` y `/auth/reset-password`, pero no hacen parte del flujo principal actual de la app.

## Requisitos

- Flutter `>= 3.27.0`
- Dart SDK `>= 3.8.0 < 4.0.0`
- Android Studio o Xcode según plataforma objetivo
- Backend COMPAS disponible
- API key de Groq si se desea usar IA online
- Proyecto Unity integrado si se desea ejecutar navegación AR

## Configuración del Entorno

Instala dependencias:

```bash
flutter pub get
```

Crea un archivo `.env` en la raíz:

```env
# Backend
BASE_URL=https://compas-api-fawn.vercel.app
BASE_URL_PC=http://127.0.0.1:8080

# IA online
GROQ_API_KEY=gsk_xxxxxxxxxxxxxxxxxxxxxxxxx

# Wake word, si se reactiva Porcupine
PICOVOICE_ACCESS_KEY=xxxxxxxxxxxxxxxxxxxxxxxxx
```

`BASE_URL` se usa como backend principal. `BASE_URL_PC` queda disponible para pruebas locales.

## Ejecución

Ejecutar en modo desarrollo:

```bash
flutter run
```

Listar dispositivos:

```bash
flutter devices
```

Ejecutar en un dispositivo específico:

```bash
flutter run -d <device_id>
```

Build Android release:

```bash
flutter build apk --release
```

## Pruebas y Validación

Ejecutar pruebas Flutter:

```bash
flutter test
```

Prueba de Groq:

```bash
flutter test test/groq_api_test.dart
```

Prueba de conexión con backend:

```bash
dart test/test_server_connection.dart
```

Algunas pruebas dependen de internet, claves válidas y backend accesible.

## Permisos

En móvil, revisar permisos de:

- micrófono,
- cámara,
- red,
- almacenamiento si aplica al flujo local.

## Integración con Unity

La comunicación con Unity se centraliza en `UnityBridgeService`. Entre los comandos soportados están:

- `navigate_to`
- `stop_navigation`
- `list_waypoints`
- `create_waypoint`
- `remove_waypoint`
- `save_session`
- `load_session`

La pantalla AR espera a que Unity esté lista, muestra estados de calibración y solo activa el micrófono cuando el tutorial de primera vez finaliza.

## Stack Tecnológico

- **Framework:** Flutter
- **Lenguaje:** Dart
- **STT:** `speech_to_text`
- **TTS:** `flutter_tts`
- **IA online:** Groq API compatible con OpenAI
- **IA offline:** TensorFlow Lite
- **Networking:** `http`, `dio`
- **Conectividad:** `connectivity_plus`
- **Persistencia segura:** `flutter_secure_storage`
- **Preferencias locales:** `shared_preferences`
- **AR:** `flutter_unity_widget` desde fork con soporte Unity 6

## Problemas Comunes

### No conecta al backend

- Verifica `BASE_URL`.
- Si usas dispositivo físico, no uses `localhost`; usa una IP accesible desde el teléfono.
- Confirma que el backend esté corriendo y que el endpoint `/api/v1` responda.

### No llega el código al correo

- Revisa spam o correo no deseado.
- Verifica que el email esté bien escrito.
- Confirma que el backend tenga configurado el servicio de correo.

### Login no acepta el código

- El código debe tener 6 dígitos.
- Si solicitaste un nuevo código, el anterior queda invalidado.
- Revisa que la app esté apuntando al mismo backend que generó el código.

### El dictado por voz no funciona

- Verifica permisos de micrófono.
- Prueba el ingreso manual para aislar si el problema es STT o autenticación.
- Revisa que el idioma de reconocimiento esté disponible en el dispositivo.

### Unity no recibe comandos

- Confirma que la escena Unity esté cargada.
- Verifica los nombres del `GameObject` y métodos puente.
- Revisa los mensajes de estado enviados por `UnityBridgeService`.

## Licencia

Actualmente este repositorio no incluye un archivo de licencia explícito.

Si el proyecto se va a distribuir públicamente o abrir a colaboración externa, agrega un `LICENSE` acorde al modelo legal elegido.
