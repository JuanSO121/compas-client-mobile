# COMPAS Client Mobile

Aplicación móvil en **Flutter** para asistencia de navegación accesible con interacción por voz, integración con backend de autenticación/IA y soporte de navegación AR con Unity.

> Este repositorio contiene el cliente móvil (Android/iOS/Linux/macOS/Windows/Web) de COMPAS. El flujo principal está optimizado para uso en dispositivos móviles.

---

## Tabla de contenido

- [Visión general](#visión-general)
- [Características principales](#características-principales)
- [Arquitectura técnica](#arquitectura-técnica)
- [Estructura del proyecto](#estructura-del-proyecto)
- [Requisitos](#requisitos)
- [Configuración del entorno](#configuración-del-entorno)
- [Ejecución](#ejecución)
- [Pruebas y validación](#pruebas-y-validación)
- [Integración con backend y Unity](#integración-con-backend-y-unity)
- [Accesibilidad](#accesibilidad)
- [Problemas comunes](#problemas-comunes)
- [Stack tecnológico](#stack-tecnológico)
- [Licencia](#licencia)

---

## Visión general

**COMPAS** es un asistente de voz orientado a accesibilidad, diseñado para:

- reconocer comandos de voz en español,
- clasificar intenciones de navegación,
- operar en modo **online/offline/auto**,
- coordinar instrucciones de navegación con una escena de **Unity AR**,
- y mantener una experiencia accesible (anuncios semánticos, feedback háptico y mensajes auditivos).

Además, incluye un módulo de autenticación con tokens y gestión de perfil/preferencias de accesibilidad.

---

**Repositorio:** https://github.com/JuanSO121/compas-client-mobile  
**Autores:** Juan José Sánchez Ocampo · Carlos Eduardo Rangel  
**Institución:** Universidad de San Buenaventura Cali — Ingeniería de Sistemas e Ingeniería Multimedia, 2026

### 1) Interacción por voz inteligente
- Detección de comandos mediante `speech_to_text`.
- Clasificación de intención híbrida:
  - modelo local TFLite (cuando está disponible),
  - fallback por reglas/keywords,
  - soporte de decisión por IA externa.
- Modo wake word opcional con Picovoice (“Oye COMPAS”).

### 2) Coordinación de navegación
- `NavigationCoordinator` centraliza estados de escucha, procesamiento, respuesta y ejecución.
- Evita ejecuciones duplicadas de comandos de navegación.
- Control de reactivación de STT para prevenir eco de TTS.

### 3) Modos de IA
- **Auto**: decide online/offline según conectividad y disponibilidad de Groq.
- **Online**: prioriza inferencia remota (Groq).
- **Offline**: operación local sin dependencia de internet.

### 4) Módulo AR con Unity
- Pantalla dedicada de navegación AR.
- Máquina de estados de inicialización para evitar race conditions entre Flutter y Unity.
- Canal bidireccional de comandos/respuestas (`navigate_to`, `list_waypoints`, `save_session`, etc.).

### 5) Autenticación y sesión
- Registro, login, refresh token, logout.
- Persistencia segura de tokens con `flutter_secure_storage`.
- Restauración de sesión al iniciar la app (`AuthGate`).

### 6) Reconocimiento de entorno
- Pantalla de cámara para captura/streaming.
- Bloqueo por proximidad y anuncios de accesibilidad.

---

## Arquitectura técnica

### Capas principales

- **UI / Presentación** (`lib/screens`, `lib/widgets`)
  - Pantallas de autenticación.
  - Pantalla de comandos de voz.
  - Pantalla de reconocimiento de entorno.
  - Pantalla AR de navegación.

- **Orquestación de dominio** (`lib/services/AI`)
  - `NavigationCoordinator`: ciclo de vida de voz y comandos.
  - `AIModeController`: conectividad + selección de modo IA.
  - `IntegratedVoiceCommandService`: STT + clasificación de intención.
  - `ConversationService`, `WakeWordService`, `WaypointContextService`.

- **Integración externa** (`lib/services`)
  - `ApiClient`: capa HTTP genérica para backend REST.
  - `AuthService`, `UserService`, `TokenService`.
  - `UnityBridgeService`: mensajería Flutter ↔ Unity.
  - `VoiceNavigationService`, `TTSService`, `ProximityService`.

- **Modelos y configuración**
  - `lib/models`: contratos de API y modelos compartidos.
  - `lib/config/api_config.dart`: URLs, endpoints, claves y timeouts.

---

### Funcionalidades implementadas

```text
lib/
  app/
  config/
    api_config.dart
  models/
    api_models.dart
    shared_models.dart
  screens/
    auth/
    ar_navigation_screen.dart
    environment_recognition_screen.dart
    voice_navigation_screen.dart
  services/
    AI/
    api_client.dart
    auth_service.dart
    token_service.dart
    tts_service.dart
    unity_bridge_service.dart
    user_service.dart
    voice_navigation_service.dart
  utils/
  widgets/

test/
  groq_api_test.dart
  test_server_connection.dart
```

---

## Requisitos

- Flutter `>= 3.27.0`
- Dart SDK `>= 3.8.0 < 4.0.0`
- Android Studio / Xcode (según plataforma objetivo)
- Backend COMPAS disponible (API REST)
- (Opcional) cuenta/API key de Groq
- (Opcional) Access Key de Picovoice para wake word
- (Opcional) proyecto Unity integrado para navegación AR

---

## Configuración del entorno

### 1) Instalar dependencias

```bash
flutter pub get
```

### 2) Crear archivo `.env` en la raíz

Ejemplo mínimo:

```env
# Backend
BASE_URL=http://192.168.1.5:8080
BASE_URL_PC=http://127.0.0.1:8080

# IA online
GROQ_API_KEY=gsk_xxxxxxxxxxxxxxxxxxxxxxxxx

# Wake word (Picovoice)
PICOVOICE_ACCESS_KEY=xxxxxxxxxxxxxxxxxxxxxxxxx
```

> Si no defines `GROQ_API_KEY` o `PICOVOICE_ACCESS_KEY`, la app sigue funcionando con degradación controlada (por ejemplo, modo offline o modo manual sin wake word).

### 3) Permisos móviles

Asegura permisos de:
- micrófono,
- cámara,
- red,
- almacenamiento (si aplica a flujos locales).

---

## Ejecución

### Desarrollo local

```bash
flutter run
```

### Ejecutar en un dispositivo específico

```bash
flutter devices
flutter run -d <device_id>
```

### Build de release (ejemplo Android)

```bash
flutter build apk --release
```

---

## Pruebas y validación

### Ejecutar pruebas Flutter

```bash
flutter test
```

### Prueba específica de Groq

```bash
flutter test test/groq_api_test.dart
```

### Script de conectividad con backend

```bash
dart test/test_server_connection.dart
```

> Nota: algunas pruebas dependen de internet, claves válidas y backend accesible en red local.

---

## Integración con backend y Unity

### Backend (REST)

La app consume endpoints versionados (`/api/v1/...`) para:

- autenticación (`register`, `login`, `refresh`, `logout`),
- perfil y preferencias,
- operaciones auxiliares de navegación.

### Unity (AR)

`UnityBridgeService` implementa comandos como:

- `navigate_to`
- `stop_navigation`
- `list_waypoints`
- `create_waypoint`
- `remove_waypoint`
- `save_session`
- `load_session`

Además, procesa respuestas estructuradas desde Unity e indicadores de estado de tracking.

---

## Accesibilidad

El proyecto incluye decisiones explícitas de accesibilidad:

- anuncios con `SemanticsService` para lectores de pantalla,
- feedback háptico contextual,
- jerarquías visuales con alto contraste,
- componentes de interacción con labels/hints accesibles,
- mensajería auditiva con TTS para confirmaciones e instrucciones.

---

## Problemas comunes

### 1) Wake word no se activa
- Verifica `PICOVOICE_ACCESS_KEY`.
- Revisa que los assets `.ppn` y `.pv` estén declarados en `pubspec.yaml`.
- Confirma permisos de micrófono.

### 2) Modo online no responde
- Verifica `GROQ_API_KEY`.
- Confirma conectividad real a internet.
- Revisa latencia/firewall hacia `api.groq.com`.

### 3) No conecta al backend
- Revisa `BASE_URL` y puerto.
- Si usas dispositivo físico, usa IP de red local (no `localhost`).
- Comprueba que el backend esté corriendo y accesible.

### 4) Unity no recibe comandos
- Verifica que el `GameObject` y método puente coincidan con la configuración Flutter.
- Confirma que la escena Unity esté cargada antes de enviar comandos.

---

## Stack tecnológico

- **Framework**: Flutter
- **Lenguaje**: Dart
- **STT**: `speech_to_text`
- **TTS**: `flutter_tts`
- **Wake word**: `porcupine_flutter`
- **IA online**: Groq (API compatible OpenAI)
- **IA offline**: TensorFlow Lite (`tflite_flutter`)
- **Networking**: `http`, `dio`
- **Seguridad local**: `flutter_secure_storage`
- **AR bridge**: `flutter_unity_widget` (fork con soporte Unity 6)

---

## Repositorios relacionados

Actualmente este repositorio no incluye un archivo de licencia explícito.

Si planeas distribución pública o colaboración externa, agrega un `LICENSE` (MIT, Apache-2.0, GPL, etc.) según el modelo legal del proyecto.
