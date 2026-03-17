# COMPAS Mobile (Flutter) — Asistente de navegación por voz accesible con IA híbrida

> Aplicación móvil Flutter para asistencia de navegación y reconocimiento de entorno, diseñada con enfoque de accesibilidad para personas con discapacidad visual. Integra procesamiento de voz, inferencia local (offline), inferencia en la nube (Groq), y puente con Unity para navegación AR.

---

## Tabla de contenido

1. [Resumen ejecutivo](#resumen-ejecutivo)
2. [Objetivo del sistema](#objetivo-del-sistema)
3. [Arquitectura técnica](#arquitectura-técnica)
4. [Tecnologías y dependencias](#tecnologías-y-dependencias)
5. [Estructura del proyecto](#estructura-del-proyecto)
6. [Módulos funcionales](#módulos-funcionales)
7. [Lógica de negocio y flujos](#lógica-de-negocio-y-flujos)
8. [Configuración de entorno](#configuración-de-entorno)
9. [Instalación y ejecución](#instalación-y-ejecución)
10. [Pruebas y validación](#pruebas-y-validación)
11. [Seguridad, privacidad y accesibilidad](#seguridad-privacidad-y-accesibilidad)
12. [Integración con backend y Unity](#integración-con-backend-y-unity)
13. [Limitaciones actuales y mejoras recomendadas](#limitaciones-actuales-y-mejoras-recomendadas)
14. [Uso de este README como referencia de trabajo de grado](#uso-de-este-readme-como-referencia-de-trabajo-de-grado)

---

## Resumen ejecutivo

COMPAS Mobile es un cliente Flutter multiplataforma (Android/iOS/Web/Desktop generado por Flutter) cuyo foco principal es Android/iOS para interacción en tiempo real mediante voz y asistencia de navegación.

El sistema implementa un **enfoque híbrido de IA**:

- **Modo offline** para continuidad operacional (clasificación local con TensorFlow Lite).
- **Modo online** con Groq para comprensión conversacional avanzada.
- **Modo auto** que selecciona estrategia según conectividad y disponibilidad.

Adicionalmente, integra:

- **Wake word** local con Porcupine (`"Oye COMPAS"`), si hay licencia válida.
- **TTS** para guía auditiva continua.
- **Puente Unity** para ejecutar acciones de navegación AR (waypoints, estado de navegación, sesión AR).
- **Autenticación JWT** (registro/login/refresh/logout) con almacenamiento seguro local.

---

## Objetivo del sistema

### Objetivo general

Proveer una interfaz de interacción natural y accesible para navegación asistida, combinando comandos de voz, retroalimentación auditiva y visual, e integración con un motor AR (Unity).

### Objetivos específicos

- Reducir fricción de uso mediante comandos de voz y activación por palabra clave.
- Mantener funcionalidad degradada en ausencia de conectividad.
- Exponer estados del sistema de forma accesible (semántica, háptica, mensajes claros).
- Permitir operación con backend de autenticación y servicios IA.
- Sincronizar intents de usuario con acciones de navegación en Unity.

---

## Arquitectura técnica

### Vista por capas

1. **Presentación (UI Flutter)**
   - Pantallas de autenticación, comandos de voz, reconocimiento de entorno y AR.
2. **Orquestación de dominio**
   - `NavigationCoordinator`, `ConversationService`, `AIModeController`, `VoiceNavigationService`.
3. **Servicios de infraestructura**
   - STT/TTS, wake word, cliente HTTP, almacenamiento de tokens, bridge Unity.
4. **Integraciones externas**
   - Backend REST, API Groq, Porcupine, motor Unity.

### Patrones identificados

- **Singleton services** en servicios de voz/IA/bridge para evitar instancias duplicadas y conflictos de recursos.
- **Coordinator pattern** para centralizar estado y transición de eventos de voz.
- **State-driven UI** mediante `StatefulWidget`, `ValueNotifier`, callbacks y streams.
- **Fallback progresivo** (online → offline/manual) según disponibilidad real.

---

## Tecnologías y dependencias

### Núcleo

- **Flutter** `>=3.27.0`
- **Dart** `>=3.8.0 <4.0.0`

### IA y voz

- `google_generative_ai` (Gemini, uso potencial/soporte)
- `tflite_flutter` (inferencia local)
- `speech_to_text` (STT)
- `flutter_tts` (TTS)
- `porcupine_flutter` (wake word)

### Audio

- `record`, `audioplayers`, `audio_session`

### Cámara y sensores

- `camera`
- `proximity` (simulado actualmente en servicio base)

### Networking y datos

- `http`, `dio`, `connectivity_plus`
- `flutter_secure_storage`, `shared_preferences`, `path_provider`

### UI/estado/utilidades

- `provider`
- `logger`
- `permission_handler`
- `flutter_dotenv`

### Integración AR

- `flutter_unity_widget` (fork experimental para Unity 6)

---

## Estructura del proyecto

```text
lib/
  config/
    api_config.dart                    # Endpoints, timeouts, keys, headers
  models/
    api_models.dart                    # Contratos tipados backend/auth
    shared_models.dart                 # Intentos, riesgo, análisis, navegación
  screens/
    auth/
      welcome_screen.dart
      login_screen_integrated.dart
      register_screen_integrated.dart
    voice_navigation_screen.dart       # UI de comandos de voz
    environment_recognition_screen.dart# Cámara + análisis de entorno (UI/flujo)
    ar_navigation_screen.dart          # Integración AR + Unity + voz
  services/
    AI/
      ai_mode_controller.dart
      conversation_service.dart
      integrated_voice_command_service.dart
      navigation_coordinator.dart
      portable_tokenizer.dart
      robot_fsm.dart
      stt_session_manager.dart
      voice_command_classifier.dart
      wake_word_service.dart
      groq_service.dart
      waypoint_context_service.dart
    api_client.dart
    auth_service.dart
    token_service.dart
    tts_service.dart
    voice_navigation_service.dart
    unity_bridge_service.dart
    user_service.dart
    proximity_service.dart
  utils/
    password_validator.dart
  widgets/
    accessible_camera_button.dart

assets/
  images/
  models/
  wake_words/

test/
  groq_api_test.dart
  test_server_connection.dart
```

---

## Módulos funcionales

### 1) Autenticación y sesión

- Registro con validación de contraseña y perfil básico de accesibilidad.
- Login con persistencia segura de tokens.
- `AuthGate` ejecuta lógica de sesión al inicio:
  - valida si hay tokens,
  - intenta refresh,
  - si falla, limpia sesión local sin forzar logout remoto.

### 2) Motor de comandos de voz

- `NavigationCoordinator` concentra el ciclo operativo:
  - idle → wake word/listening → processing → speaking → idle.
- Maneja callbacks UI (`onStatusUpdate`, `onIntentDetected`, etc.).
- Incluye protecciones anti-duplicación de intents y control de eco TTS/STT.

### 3) Selección inteligente de modo IA

- `AIModeController` soporta: `auto`, `online`, `offline`.
- Verifica conectividad y disponibilidad de Groq con caché temporal (TTL) para reducir latencia.

### 4) Conversación e interpretación

- `ConversationService` construye prompt y extrae acciones/targets.
- Integra contexto de waypoints reales vía `WaypointContextService` para desambiguación semántica.

### 5) Integración AR con Unity

- `UnityBridgeService` abstrae el canal bidireccional Flutter ↔ Unity.
- Comandos soportados: navegación, listar/crear/eliminar waypoints, guardar/cargar sesión.
- Parseo de respuestas JSON y callbacks especializados (waypoints, tracking, respuesta genérica).

### 6) Reconocimiento de entorno

- `EnvironmentRecognitionScreen` usa cámara y flujo de “streaming/análisis”.
- Actualmente presenta una capa funcional orientada a UX y accesibilidad, con resultados de objetos de ejemplo (modo demostración/prototipo para inferencia visual real futura).

### 7) Accesibilidad transversal

- Uso intensivo de `SemanticsService.announce`.
- Feedback háptico por contexto.
- Mensajes de estado y errores orientados a lector de pantalla.
- Flujos de autenticación con hints accesibles.

---

## Lógica de negocio y flujos

### Flujo A — Inicio de app y sesión

1. Carga `.env`.
2. Fuerza orientación vertical.
3. `AuthGate` valida sesión.
4. Si autenticado: `MainScreen` (voz + reconocimiento).
5. Si no autenticado: `WelcomeScreen`.

### Flujo B — Comando de voz estándar

1. Usuario activa sistema (botón o wake word).
2. STT capta frase.
3. Coordinator delega a interpretación IA (online/offline/auto).
4. Se genera `NavigationIntent`.
5. UI muestra intent + feedback háptico/semántico.
6. Si aplica, se envía acción a Unity.
7. TTS confirma/guía.

### Flujo C — AR readiness por etapas

1. Estado `initializing`: carga Flutter + Unity.
2. Estado `waitingUser`: espera confirmación de usuario.
3. Estado `loadingSession`: solicita `load_session` con timeout de seguridad.
4. Estado `ready`: solicita waypoints y habilita navegación.

### Flujo D — Fallback operativo

- Sin clave válida Groq o sin internet: modo offline.
- Sin wake word: modo manual por botón.
- Errores de red: respuestas tipadas con mensajes accesibles.

---

## Configuración de entorno

Crear archivo `.env` en la raíz:

```env
# Backend
BASE_URL=http://192.168.X.X:8080
BASE_URL_PC=http://127.0.0.1:8080

# IA online
GROQ_API_KEY=gsk_xxxxxxxxxxxxxxxxxxxxxxxxx

# Wake word
PICOVOICE_ACCESS_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

### Notas

- Si faltan claves o son placeholders, el sistema degrada funcionalidad (p. ej. sin wake word).
- No se deben versionar claves reales en Git.

---

## Instalación y ejecución

### 1) Dependencias

```bash
flutter pub get
```

### 2) Verificar entorno Flutter

```bash
flutter doctor
```

### 3) Ejecutar app (ejemplo Android)

```bash
flutter run
```

### 4) Ejecutar con dispositivo específico

```bash
flutter devices
flutter run -d <device_id>
```

---

## Pruebas y validación

### Suite Flutter

```bash
flutter test
```

### Pruebas específicas del proyecto

```bash
flutter test test/groq_api_test.dart
```

> Requiere `GROQ_API_KEY` válida y salida a internet.

```bash
dart run test/test_server_connection.dart
```

> Script de conectividad contra un servidor IP/puerto fijo (ajustar valores antes de usar).

---

## Seguridad, privacidad y accesibilidad

### Seguridad

- Tokens de sesión almacenados en `flutter_secure_storage`.
- Refresh token manejado por servicio dedicado.
- Cabeceras `Authorization: Bearer` inyectadas automáticamente.
- Manejo explícito de respuestas `HTTP 200 + success:false` para evitar estados inconsistentes.

### Privacidad

- La app puede operar parcialmente offline para reducir dependencia de nube.
- Debe documentarse claramente qué datos de voz se envían al backend o a APIs externas en despliegues reales.

### Accesibilidad

- Anuncios auditivos en eventos críticos.
- Controles con etiquetas semánticas.
- Flujo de feedback multimodal (voz + háptica + visual).

---

## Integración con backend y Unity

### Backend REST esperado

- Rutas de auth bajo `/api/v1/auth/*`.
- Rutas de usuario y accesibilidad configuradas en `ApiConfig`.
- Contrato de respuesta esperado:
  - `success` (bool),
  - `message`,
  - `data` (payload),
  - `errors` y `accessibility_info` opcionales.

### Canal Unity

- GameObject objetivo: `FlutterBridge`.
- Método: `OnFlutterCommand`.
- Mensajes JSON con `action` y parámetros.
- Eventos de retorno vía `OnUnityResponse`.

Acciones relevantes:

- `navigate_to`
- `stop_navigation`
- `nav_status`
- `list_waypoints`
- `create_waypoint`
- `remove_waypoint`
- `clear_waypoints`
- `save_session`
- `load_session`

---

## Limitaciones actuales y mejoras recomendadas

1. **Reconocimiento de entorno**
   - El flujo visual actual está orientado a prototipo UX; se recomienda conectar inferencia real (ej. YOLO/SSD/TFLite Vision) y pipeline de post-procesamiento.

2. **Cobertura de pruebas automatizadas**
   - Existen pruebas de API y scripts de conectividad, pero falta ampliar pruebas unitarias de servicios núcleo (coordinator, parser de intents, bridge).

3. **Observabilidad**
   - Se recomienda telemetría estructurada (latencia STT/LLM/TTS, tasa de intents fallidos, disponibilidad de servicios).

4. **Hardening de seguridad**
   - Agregar certificate pinning (si aplica), rotación de tokens y auditoría de políticas de retención de datos de voz.

5. **Arquitectura de estado**
   - Evolucionar a una capa de gestión de estado unificada (p. ej. Riverpod/BLoC) para escalabilidad en módulos complejos.

---

## Uso de este README como referencia de trabajo de grado

Este documento puede ser usado como base técnica para:

- **Capítulo de ingeniería de software** (arquitectura por capas, patrones y flujos).
- **Capítulo de IA aplicada** (modo híbrido online/offline, inferencia local, prompt contextual).
- **Capítulo de accesibilidad** (diseño inclusivo, interacción multimodal).
- **Capítulo de integración de sistemas** (Flutter + Backend + Unity + servicios de voz).
- **Capítulo de evaluación** (métricas sugeridas: latencia end-to-end, tasa de éxito por comando, robustez sin internet, usabilidad accesible).

---

## Créditos y licencia

Proyecto académico/aplicado desarrollado sobre Flutter con integración de tecnologías de IA y AR. Definir en este repositorio el tipo de licencia final (MIT, Apache-2.0, GPL, etc.) según requisitos institucionales y de distribución.
