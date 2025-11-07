// lib/screens/environment_recognition_screen.dart - ESTILO POKÉMON GO
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'dart:async';
import '../services/enhanced_websocket_service.dart';
import '../widgets/accessible_camera_button.dart';
import 'package:proximity_sensor/proximity_sensor.dart';

class EnvironmentRecognitionScreen extends StatefulWidget {
  final bool isConnected;
  final EnhancedWebSocketService webSocketService;
  final VoidCallback? onReconnect;

  const EnvironmentRecognitionScreen({
    Key? key,
    required this.isConnected,
    required this.webSocketService,
    this.onReconnect,
  }) : super(key: key);

  @override
  State<EnvironmentRecognitionScreen> createState() => _EnvironmentRecognitionScreenState();
}

class _EnvironmentRecognitionScreenState extends State<EnvironmentRecognitionScreen>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {

  CameraController? _cameraController;
  List<CameraDescription>? _cameras;
  bool _isCameraInitialized = false;
  bool _isStreaming = false;
  bool _isProcessing = false;
  bool _isProximityBlocked = false; // Sensor de proximidad

  String _lastResponse = '';
  String _detectedObjects = '';
  double? _processingTime;

  // Stream del sensor de proximidad
  StreamSubscription<int>? _proximitySubscription;

  Timer? _streamingTimer;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
    _setupProximitySensor();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      SemanticsService.announce(
        'Pantalla de reconocimiento de entorno. Cámara en tiempo real activada',
        TextDirection.ltr,
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = _cameraController;

    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      cameraController.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  Future<void> _initializeCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) {
        _showSnackBar('No se encontró cámara', isError: true);
        return;
      }

      // Seleccionar cámara trasera
      final camera = _cameras!.firstWhere(
            (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras!.first,
      );

      _cameraController = CameraController(
        camera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await _cameraController!.initialize();

      if (mounted) {
        setState(() => _isCameraInitialized = true);
        SemanticsService.announce('Cámara lista', TextDirection.ltr);
      }
    } catch (e) {
      _showSnackBar('Error al iniciar cámara', isError: true);
    }
  }

  void _setupProximitySensor() {
    _proximitySubscription = ProximitySensor.events.listen((int event) {
      bool isClose = event > 0; // 1 = cerca, 0 = lejos

      if (mounted && _isStreaming) {
        setState(() {
          _isProximityBlocked = isClose;
        });

        SemanticsService.announce(
          isClose ? 'Pantalla bloqueada por proximidad' : 'Pantalla desbloqueada',
          TextDirection.ltr,
        );
      }
    });
  }

  Future<void> _startVideoStream() async {
    if (!widget.isConnected) {
      _showSnackBar('Sin conexión al servidor', isError: true);
      return;
    }

    if (!_isCameraInitialized || _cameraController == null) {
      _showSnackBar('Cámara no disponible', isError: true);
      return;
    }

    setState(() => _isStreaming = true);
    HapticFeedback.mediumImpact();
    SemanticsService.announce('Transmisión iniciada', TextDirection.ltr);

    _showSnackBar('Transmitiendo video...');

    // Simular envío de frames cada 500ms
    _streamingTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
      if (!_isStreaming || _cameraController == null) {
        timer.cancel();
        return;
      }

      try {
        // Aquí capturaríamos y enviaríamos frames al servidor
        // final image = await _cameraController!.takePicture();
        // await widget.webSocketService.sendVideoFrame(image.path);

        // Por ahora solo simulamos
        if (mounted) {
          setState(() {
            _detectedObjects = 'Detectando objetos...';
          });
        }
      } catch (e) {
        // Manejar error silenciosamente
      }
    });
  }

  Future<void> _stopVideoStream() async {
    if (!_isStreaming) return;

    _streamingTimer?.cancel();
    _streamingTimer = null;

    setState(() {
      _isStreaming = false;
      _isProcessing = true;
      _isProximityBlocked = false;
    });

    HapticFeedback.lightImpact();
    SemanticsService.announce('Procesando análisis final', TextDirection.ltr);

    // Simular procesamiento final
    await Future.delayed(const Duration(seconds: 2));

    setState(() {
      _isProcessing = false;
      _lastResponse = 'Análisis completado. Se detectaron múltiples objetos en el entorno.';
      _detectedObjects = 'Silla, Mesa, Persona, Puerta, Ventana';
      _processingTime = 1.8;
    });

    _showSnackBar('Análisis completado');
    SemanticsService.announce('Análisis completado', TextDirection.ltr);
  }

  Future<void> _captureFrame() async {
    if (!widget.isConnected) {
      _showSnackBar('Sin conexión al servidor', isError: true);
      return;
    }

    if (!_isCameraInitialized || _cameraController == null) {
      _showSnackBar('Cámara no disponible', isError: true);
      return;
    }

    setState(() => _isProcessing = true);
    HapticFeedback.lightImpact();
    SemanticsService.announce('Capturando imagen', TextDirection.ltr);

    try {
      // Capturar imagen
      final image = await _cameraController!.takePicture();

      // Aquí enviarías la imagen al servidor
      // await widget.webSocketService.sendImage(image.path);

      // Simular procesamiento
      await Future.delayed(const Duration(seconds: 2));

      setState(() {
        _isProcessing = false;
        _lastResponse = 'Imagen capturada y analizada correctamente.';
        _detectedObjects = 'Escritorio, Monitor, Teclado, Mouse, Lámpara';
        _processingTime = 1.5;
      });

      _showSnackBar('Imagen analizada');
    } catch (e) {
      setState(() => _isProcessing = false);
      _showSnackBar('Error al capturar', isError: true);
    }
  }

  void _switchCamera() async {
    if (_cameras == null || _cameras!.length < 2) {
      _showSnackBar('Solo hay una cámara disponible', isError: false);
      return;
    }

    final currentLens = _cameraController?.description.lensDirection;
    CameraDescription newCamera;

    if (currentLens == CameraLensDirection.back) {
      newCamera = _cameras!.firstWhere(
            (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => _cameras!.first,
      );
    } else {
      newCamera = _cameras!.firstWhere(
            (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras!.first,
      );
    }

    await _cameraController?.dispose();

    _cameraController = CameraController(
      newCamera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await _cameraController!.initialize();
      if (mounted) {
        setState(() {});
        HapticFeedback.lightImpact();
      }
    } catch (e) {
      _showSnackBar('Error al cambiar cámara', isError: true);
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    SemanticsService.announce(message, TextDirection.ltr);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        backgroundColor: isError
            ? Theme.of(context).colorScheme.error
            : Theme.of(context).colorScheme.secondary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
        duration: Duration(seconds: isError ? 3 : 2),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _streamingTimer?.cancel();
    _proximitySubscription?.cancel();
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final size = MediaQuery.of(context).size;

    return Stack(
      children: [
        // VISTA DE CÁMARA EN TIEMPO REAL (FULLSCREEN)
        if (_isCameraInitialized && _cameraController != null)
          Positioned.fill(
            child: _buildCameraPreview(),
          )
        else
          Positioned.fill(
            child: Container(
              color: Colors.black,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation(theme.colorScheme.primary),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Iniciando cámara...',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

        // OVERLAY DE BLOQUEO POR PROXIMIDAD
        if (_isProximityBlocked)
          Positioned.fill(
            child: Container(
              color: Colors.black,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.screen_lock_portrait_rounded,
                      size: 80,
                      color: Colors.white54,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Pantalla Bloqueada',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Aleja el objeto para continuar',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

        // CONTROLES SUPERIORES
        if (!_isProximityBlocked)
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: _buildTopControls(theme),
          ),

        // INDICADOR DE STREAMING
        if (_isStreaming && !_isProximityBlocked)
          Positioned(
            top: 80,
            left: 0,
            right: 0,
            child: _buildStreamingIndicator(theme),
          ),

        // CONTROLES INFERIORES
        if (!_isProximityBlocked)
          Positioned(
            bottom: 32,
            left: 0,
            right: 0,
            child: _buildBottomControls(theme),
          ),

        // RESULTADOS DEL ANÁLISIS
        if (_lastResponse.isNotEmpty && !_isStreaming && !_isProximityBlocked)
          Positioned(
            bottom: 200,
            left: 16,
            right: 16,
            child: _buildResultsCard(theme),
          ),
      ],
    );
  }

  Widget _buildCameraPreview() {
    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: _cameraController!.value.previewSize!.height,
            height: _cameraController!.value.previewSize!.width,
            child: CameraPreview(_cameraController!),
          ),
        ),
      ),
    );
  }

  Widget _buildTopControls(ThemeData theme) {
    return Semantics(
      label: 'Controles superiores',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.6),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.white.withOpacity(0.2),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            // Estado de conexión
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: widget.isConnected
                    ? theme.colorScheme.secondary.withOpacity(0.3)
                    : theme.colorScheme.error.withOpacity(0.3),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    widget.isConnected ? Icons.wifi : Icons.wifi_off,
                    size: 16,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    widget.isConnected ? 'Conectado' : 'Sin conexión',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),

            const Spacer(),

            // Botón cambiar cámara
            Semantics(
              label: 'Cambiar cámara',
              button: true,
              child: Material(
                color: Colors.white.withOpacity(0.2),
                shape: const CircleBorder(),
                child: InkWell(
                  onTap: _isStreaming ? null : _switchCamera,
                  customBorder: const CircleBorder(),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    child: const Icon(
                      Icons.flip_camera_ios_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStreamingIndicator(ThemeData theme) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.error.withOpacity(0.9),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: theme.colorScheme.error.withOpacity(0.5),
              blurRadius: 20,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.circle, size: 12, color: Colors.white),
            SizedBox(width: 10),
            Text(
              'EN VIVO',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
                letterSpacing: 2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomControls(ThemeData theme) {
    return Column(
      children: [
        // BOTÓN DE CÁMARA PRINCIPAL
        if (widget.isConnected)
          AccessibleCameraButton(
            isStreaming: _isStreaming,
            isProcessing: _isProcessing,
            isConnected: widget.isConnected,
            onStartStream: _startVideoStream,
            onStopStream: _stopVideoStream,
          ),

        const SizedBox(height: 24),

        // BOTÓN DE CAPTURA RÁPIDA
        if (!_isStreaming && !_isProcessing)
          Semantics(
            label: 'Capturar imagen única',
            button: true,
            child: Material(
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(20),
              child: InkWell(
                onTap: _captureFrame,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(
                        Icons.camera_alt_rounded,
                        color: Colors.white,
                        size: 24,
                      ),
                      SizedBox(width: 12),
                      Text(
                        'Capturar Imagen',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildResultsCard(ThemeData theme) {
    return Semantics(
      label: 'Resultados del análisis',
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.85),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: theme.colorScheme.secondary.withOpacity(0.3),
            width: 2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // HEADER
            Row(
              children: [
                Icon(
                  Icons.visibility_rounded,
                  size: 20,
                  color: theme.colorScheme.secondary,
                ),
                const SizedBox(width: 10),
                const Text(
                  'Análisis Visual',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // RESPUESTA
            Text(
              _lastResponse,
              style: const TextStyle(
                fontSize: 16,
                color: Colors.white,
                height: 1.4,
              ),
            ),

            const SizedBox(height: 16),

            // OBJETOS DETECTADOS
            if (_detectedObjects.isNotEmpty) ...[
              const Text(
                'Objetos:',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.white70,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _detectedObjects.split(', ').map((obj) {
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: theme.colorScheme.primary.withOpacity(0.5),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      obj,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}