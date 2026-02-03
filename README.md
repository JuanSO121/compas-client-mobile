# Control de Voz Accesible para Robot

Aplicación Flutter enfocada en accesibilidad para controlar un robot mediante voz. Incluye detección automática del servidor, transcripción de audio con Whisper, retroalimentación por texto a voz (TTS) y una interfaz optimizada para usuarios con discapacidad visual.

## Características principales

- **Control por voz con transcripción** usando un servicio FastAPI/Whisper.
- **Detección automática de servidor** en red local para evitar configuración manual de IP.
- **Accesibilidad reforzada**: anuncios de estado con `SemanticsService`, tipografías legibles, contraste y soporte de escalado.
- **TTS integrado** para feedback auditivo.
- **Gestión de conexión** con reintentos y verificación de salud del servidor.

## Requisitos

- **Flutter** >= 3.0.0
- **Dart** >= 3.0.0
- **Servidor FastAPI** con endpoint de salud `/health` y servicios de transcripción (Whisper) y control del robot.
- Acceso de red local entre el dispositivo y el servidor (por defecto puerto **8000**).

## Configuración rápida

1. Instala dependencias:
   ```bash
   flutter pub get
   ```
2. Inicia el servidor FastAPI en la red local (puerto 8000).
3. Ejecuta la app:
   ```bash
   flutter run
   ```

## Flujo de uso

1. Abre la aplicación en el dispositivo.
2. La app **detecta automáticamente** el servidor disponible en la red.
3. Presiona el botón de grabación para enviar audio.
4. Recibe transcripción, respuesta y feedback accesible.

## Estructura del proyecto

```
lib/
  main.dart                  # Entrada principal y UI
  models/                    # Modelos de datos
  screens/                   # Pantallas
  services/                  # Lógica de red, audio, TTS y detección de IP
  utils/                     # Utilidades
  widgets/                   # Componentes accesibles reutilizables
```

## Notas de accesibilidad

- Tipografías personalizadas para legibilidad (`AccessibleSans`, `AccessibleMono`).
- Anuncios de estado en tiempo real para lectores de pantalla.
- Soporte para escalado de texto y modo oscuro.

## Licencia

Este proyecto se distribuye bajo la licencia que defina el equipo. Si necesitas una licencia específica, agrega el archivo correspondiente.
