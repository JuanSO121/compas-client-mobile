# COMPAS Mobile (Flutter)

> Aplicación móvil Flutter para asistencia de navegación en interiores mediante voz e inteligencia artificial, orientada a personas con discapacidad visual. Integra procesamiento de voz híbrido (local y en la nube), autenticación accesible y puente bidireccional con Unity para navegación AR.

**Repositorio:** https://github.com/JuanSO121/compas-client-mobile  
**Autores:** Juan José Sánchez Ocampo · Carlos Eduardo Rangel  
**Institución:** Universidad de San Buenaventura Cali — Ingeniería de Sistemas e Ingeniería Multimedia, 2026

---

## Tabla de contenido

- [Resumen ejecutivo](#resumen-ejecutivo)
- [Arquitectura general](#arquitectura-general)
- [Tecnologías y dependencias](#tecnologías-y-dependencias)
- [Módulos funcionales](#módulos-funcionales)
- [Flujo de interacción](#flujo-de-interacción)
- [Configuración de entorno](#configuración-de-entorno)
- [Instalación y ejecución](#instalación-y-ejecución)
- [Integración con Unity y backend](#integración-con-unity-y-backend)
- [Limitaciones actuales](#limitaciones-actuales)
- [Repositorios relacionados](#repositorios-relacionados)

---

## Resumen ejecutivo

COMPAS Mobile es la capa de interfaz del sistema COMPAS. Gestiona toda la interacción con el usuario: autenticación accesible por código de seis dígitos, activación por palabra clave ("Oye COMPAS"), transcripción de voz a texto (STT), clasificación de intenciones mediante IA híbrida (local u online vía Groq), síntesis de respuestas auditivas (TTS) y comunicación bidireccional con el módulo Unity de navegación AR.

La aplicación opera principalmente sobre Android y está diseñada para ser usada sin interacción táctil durante la navegación, priorizando retroalimentación auditiva clara y compatible con lectores de pantalla.

### Funcionalidades implementadas

- Autenticación accesible: registro en tres pasos, login por código de seis dígitos y recuperación por correo.
- Persistencia de sesión con `flutter_secure_storage` y refresh automático de tokens.
- Activación por palabra clave "Oye COMPAS" mediante STT continuo.
- Clasificación de intenciones en cinco categorías: `START_NAVIGATION`, `STOP`, `REPEAT`, `STATUS` y `HELP`.
- Modo IA híbrido: clasificación online vía Groq cuando hay conexión, clasificador local por patrones de texto sin red.
- Integración con Unity: cargar sesión, listar balizas, iniciar y detener navegación, recibir eventos de tracking AR y estado TTS.
- Cola de prioridad de mensajes TTS para evitar saturación durante la navegación activa.
- Gestión de waypoints por voz: crear, listar, eliminar y limpiar puntos de interés.

---

## Arquitectura general

```
Entrada: main.dart → AuthGate
         ↓
AuthGate → WelcomeScreen (sin sesión) | ArNavigationScreen (con sesión)

Capas:
1. Presentación (UI Flutter)
2. Orquestación: NavigationCoordinator, ConversationService, AIModeController
3. Servicios: STT/TTS, wake word, cliente HTTP, token storage, Unity bridge
4. Integraciones externas: Backend REST (FastAPI/Vercel), API Groq, Motor Unity
```

### Patrones utilizados

- Singleton para servicios de voz, IA y Unity bridge.
- Coordinator pattern para centralizar eventos de voz.
- Fallback progresivo: online → offline según conectividad disponible.
- Cola de prioridad TTS: instrucciones críticas interrumpen mensajes de menor prioridad.

---

## Tecnologías y dependencias

| Categoría | Tecnología | Uso |
|-----------|-----------|-----|
| Framework | Flutter ≥3.27.0, Dart ≥3.8.0 | Base de la aplicación |
| Voz | `speech_to_text`, `flutter_tts` | STT y TTS locales |
| IA | Groq (API REST) | Clasificación de intenciones online |
| Seguridad | `flutter_secure_storage` | Almacenamiento de tokens JWT |
| Red | `http`, `dio`, `connectivity_plus` | Comunicación con backend y Groq |
| AR | `flutter_unity_widget` | Puente Flutter ↔ Unity |
| Cámara | `camera` | Captura de frames para segmentación |
| Permisos | `permission_handler` | Micrófono, cámara y almacenamiento |
| Estado | `provider` | Gestión de estado reactivo |

---

## Módulos funcionales

### Autenticación (`screens/auth/`)

Flujo de tres pasos para registro (correo, contraseña, nombre) y login por código de seis dígitos enviado al correo. Cada campo ocupa la pantalla completa con anuncios de voz al avanzar entre pasos.

### Coordinador de voz (`services/AI/navigation_coordinator.dart`)

Orquesta el ciclo completo: detección de palabra clave → STT → clasificación de intención → ejecución de comando → respuesta TTS. Implementa reintentos ante comandos no reconocidos (máximo 3) y fallback local sin conexión.

### Clasificador de intenciones (`services/AI/voice_command_classifier.dart`)

Clasifica el texto transcrito en cinco intenciones con umbral de confianza configurable. Con conexión usa la API de Groq; sin conexión usa patrones de texto locales para comandos frecuentes.

### Unity Bridge (`services/unity_bridge_service.dart`)

Envía comandos JSON al módulo Unity y procesa las respuestas recibidas. Implementa cola de comandos con clasificación por prioridad (Critical, Session, Navigation) compatible con el estado del bridge en Unity (Initializing, SessionLoading, Ready).

### TTS Service (`services/tts_service.dart`)

Gestiona la síntesis de voz con cola de prioridad. Las instrucciones de prioridad 3 (obstáculos, giros urgentes) interrumpen las de menor prioridad. Notifica a Unity el estado del TTS (`done`/`cancel`) para liberar el flag `_ttsBusy` del guía de voz.

---

## Flujo de interacción

```
Usuario habla → "Oye COMPAS llévame a la biblioteca"
     ↓
STT transcribe el audio
     ↓
Wake word detectado → captura comando → "llévame a la biblioteca"
     ↓
Clasificador → START_NAVIGATION, destino: "biblioteca"
     ↓
UnityBridgeService → navigate_to {"name": "biblioteca"}
     ↓
Unity calcula ruta y responde → guide_announcement
     ↓
TTS → "Listo, vamos a la biblioteca. 45 pasos recto, luego gira a las 3."
```

---

## Configuración de entorno

Crear archivo `.env` en la raíz del proyecto:

```env
API_BASE_URL=https://tu-backend.vercel.app
GROQ_API_KEY=tu_clave_groq
```

---

## Instalación y ejecución

```bash
# Clonar repositorio
git clone https://github.com/JuanSO121/compas-client-mobile.git
cd compas-client-mobile

# Instalar dependencias
flutter pub get

# Ejecutar en dispositivo Android
flutter run
```

**Requisitos:**
- Flutter ≥3.27.0
- Android SDK API 26+
- Dispositivo Android compatible con ARCore para funcionalidad completa

---

## Integración con Unity y backend

### Unity

La comunicación con el módulo AR se realiza mediante `flutter_unity_widget`. Flutter envía comandos JSON al GameObject `FlutterBridge` de la escena Unity y recibe respuestas a través del callback `OnUnityResponse`.

Comandos principales enviados a Unity:

| Acción | Descripción |
|--------|-------------|
| `navigate_to` | Inicia navegación hacia un waypoint |
| `stop_navigation` | Detiene la navegación activa |
| `list_waypoints` | Solicita waypoints disponibles |
| `create_waypoint` | Crea waypoint en posición actual |
| `remove_waypoint` | Elimina un waypoint por nombre |
| `clear_waypoints` | Elimina todos los waypoints |
| `save_session` | Persiste sesión en disco |
| `load_session` | Restaura sesión guardada |
| `tts_status` | Notifica estado del TTS a Unity |

### Backend (FastAPI/Vercel)

El backend REST gestiona autenticación JWT, persistencia de sesión y preferencias del usuario. La base de datos es MongoDB Atlas con conexión asíncrona.

---

## Limitaciones actuales

- La funcionalidad AR completa requiere dispositivo físico compatible con ARCore.
- La clasificación offline cubre solo los comandos más frecuentes; comandos complejos requieren conexión a Groq.
- El reconocimiento de entorno visual ocurre en Unity; Flutter solo gestiona las alertas auditivas resultantes.

---

## Repositorios relacionados

| Módulo | Repositorio |
|--------|------------|
| Módulo AR (Unity) | https://github.com/JuanSO121/Compas_AR |
| Backend (API REST) | https://github.com/JuanSO121/compas-api |