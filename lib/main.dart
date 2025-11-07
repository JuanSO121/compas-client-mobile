// lib/main.dart - NAVEGACIÓN INFERIOR ACCESIBLE PARA CEGUERA
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'services/enhanced_websocket_service.dart';
import 'services/audio_service.dart';
import 'services/tts_service.dart';
import 'services/dynamic_ip_detector.dart';
import 'widgets/accessible_enhanced_voice_button.dart';
import 'widgets/accessible_transcription_card.dart';
import 'dart:async';
import '/screens/auth/welcome_screen.dart';
import 'screens/environment_recognition_screen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Control de Voz para Robot',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: const ColorScheme.light(
          primary: Color(0xFFFFB300),
          secondary: Color(0xFF2E7D32),
          error: Color(0xFFC62828),
          surface: Colors.white,
          onSurface: Color(0xFF212121),
          background: Color(0xFFFAFAFA),
        ),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(fontSize: 18, height: 1.5, color: Color(0xFF212121)),
          bodyMedium: TextStyle(fontSize: 16, height: 1.5, color: Color(0xFF424242)),
          titleLarge: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF212121)),
          titleMedium: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Color(0xFF212121)),
        ),
        scaffoldBackgroundColor: Colors.white,
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          color: Colors.white,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFFD54F),
          secondary: Color(0xFF66BB6A),
          error: Color(0xFFEF5350),
          surface: Color(0xFF1E1E1E),
          onSurface: Colors.white,
          background: Color(0xFF121212),
        ),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(fontSize: 18, height: 1.5, color: Colors.white),
          bodyMedium: TextStyle(fontSize: 16, height: 1.5, color: Color(0xFFE0E0E0)),
          titleLarge: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
          titleMedium: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white),
        ),
        scaffoldBackgroundColor: const Color(0xFF121212),
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          color: const Color(0xFF1E1E1E),
        ),
      ),
      themeMode: ThemeMode.system,
      home: const WelcomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class AccessibleVoiceControlScreen extends StatefulWidget {
  const AccessibleVoiceControlScreen({super.key});

  @override
  AccessibleVoiceControlScreenState createState() => AccessibleVoiceControlScreenState();
}

class AccessibleVoiceControlScreenState extends State<AccessibleVoiceControlScreen>
    with SingleTickerProviderStateMixin {
  final EnhancedWebSocketService _webSocketService = EnhancedWebSocketService();
  final AudioService _audioService = AudioService();
  final TTSService _ttsService = TTSService();
  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFieldFocusNode = FocusNode();

  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isSearchingServer = false;
  String _connectionStatus = 'Desconectado';
  String? _discoveredIP;

  bool _isRecording = false;
  bool _isProcessingAudio = false;
  bool _audioServiceReady = false;
  bool _whisperAvailable = false;

  bool _ttsServiceReady = false;
  bool _ttsEnabled = true;

  String _lastResponse = '';
  String _lastTranscription = '';
  double? _lastConfidence;
  double? _lastProcessingTime;

  static const int SERVER_PORT = 8000;

  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  // ÍNDICE DE NAVEGACIÓN INFERIOR
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _setupWebSocketCallbacks();
    _initializeServices();
    _autoDiscoverAndConnect();

    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(parent: _fadeController, curve: Curves.easeInOut);
    _fadeController.forward();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      SemanticsService.announce(
        'Aplicación COMPAS iniciada. Pantalla actual: Control de Voz. Use la navegación inferior para cambiar entre Control de Voz y Reconocimiento de Entorno',
        TextDirection.ltr,
      );
    });
  }

  void _setupWebSocketCallbacks() {
    _webSocketService.onConnectionStatus = (status) {
      setState(() {
        _connectionStatus = status['status'] ?? 'Desconocido';
        _whisperAvailable = status['whisper_available'] ?? false;
      });

      if (status['status'] == 'connected') {
        SemanticsService.announce('Conectado al servidor', TextDirection.ltr);
      }
    };

    _webSocketService.onCommandResult = (result) {
      setState(() {
        _lastResponse = result.aiResponse ?? '';
        if (result.transcription != null) {
          _lastTranscription = result.transcription!;
        }
      });

      if (result.success) {
        HapticFeedback.lightImpact();
      }
    };

    _webSocketService.onTranscriptionResult = (result) {
      setState(() {
        if (result.success && result.transcription != null) {
          _lastTranscription = result.transcription!;
          _lastConfidence = result.confidence;
          _lastProcessingTime = result.processingTime;
        }
      });
    };
  }

  Future<void> _initializeServices() async {
    try {
      await _audioService.initialize();
      setState(() => _audioServiceReady = true);
    } catch (e) {
      setState(() => _audioServiceReady = false);
      _showSnackBar('Error de micrófono', isError: true);
    }

    try {
      await _ttsService.initialize();
      setState(() => _ttsServiceReady = true);
    } catch (e) {
      setState(() {
        _ttsServiceReady = false;
        _ttsEnabled = false;
      });
    }
  }

  Future<void> _autoDiscoverAndConnect() async {
    setState(() {
      _isSearchingServer = true;
      _connectionStatus = 'Buscando servidor...';
    });

    SemanticsService.announce('Detectando servidor en la red', TextDirection.ltr);

    try {
      final detectedIP = await DynamicIPDetector.detectWhisperServerIP();

      if (detectedIP != null) {
        await _connectToServer(detectedIP);
        if (_isConnected) {
          _showSnackBar('Conectado correctamente');
        }
      } else {
        setState(() => _connectionStatus = 'Servidor no encontrado');
        _showSnackBar('Servidor no encontrado en la red', isError: true);
      }
    } catch (e) {
      setState(() => _connectionStatus = 'Error de conexión');
      _showSnackBar('Error de red', isError: true);
    } finally {
      setState(() => _isSearchingServer = false);
    }
  }

  Future<void> _connectToServer(String serverIP) async {
    setState(() {
      _isConnecting = true;
      _connectionStatus = 'Conectando...';
    });

    try {
      await _webSocketService.connect(serverIP, SERVER_PORT);
      setState(() {
        _isConnected = true;
        _isConnecting = false;
        _connectionStatus = 'Conectado';
        _discoveredIP = serverIP;
        _whisperAvailable = _webSocketService.whisperAvailable;
      });
    } catch (e) {
      setState(() {
        _isConnected = false;
        _isConnecting = false;
        _connectionStatus = 'Error de conexión';
      });
      rethrow;
    }
  }

  Future<void> _startRecording() async {
    if (!_audioServiceReady || !_isConnected || !_whisperAvailable) {
      _showSnackBar('Servicio no disponible', isError: true);
      return;
    }

    try {
      await _audioService.startRecording();
      setState(() => _isRecording = true);
      HapticFeedback.mediumImpact();
      SemanticsService.announce('Grabando audio', TextDirection.ltr);
    } catch (e) {
      _showSnackBar('Error de grabación', isError: true);
    }
  }

  Future<void> _stopRecording() async {
    if (!_isRecording) return;

    try {
      final audioPath = await _audioService.stopRecording();
      setState(() => _isRecording = false);
      HapticFeedback.lightImpact();
      SemanticsService.announce('Procesando comando de voz', TextDirection.ltr);

      if (audioPath != null) {
        await _processAudioFile(audioPath);
      }
    } catch (e) {
      setState(() => _isRecording = false);
      _showSnackBar('Error al detener grabación', isError: true);
    }
  }

  Future<void> _processAudioFile(String audioPath) async {
    setState(() {
      _isProcessingAudio = true;
      _lastResponse = '';
      _lastTranscription = '';
    });

    try {
      final result = await _webSocketService.processAudioCommand(audioPath);
      setState(() {
        _lastResponse = result.aiResponse ?? '';
        _lastTranscription = result.transcription ?? '';
        _isProcessingAudio = false;
      });

      if (result.success) {
        _showSnackBar('Comando procesado correctamente');
        if (_ttsEnabled && _ttsServiceReady && _lastResponse.isNotEmpty) {
          await _ttsService.speakSystemResponse(_lastResponse);
        }
      } else {
        _showSnackBar('Error de procesamiento', isError: true);
      }
    } catch (e) {
      setState(() {
        _isProcessingAudio = false;
        _lastResponse = 'Error: $e';
      });
      _showSnackBar('Error crítico', isError: true);
    }
  }

  Future<void> _sendTextCommand() async {
    final command = _textController.text.trim();
    if (command.isEmpty) {
      _showSnackBar('Campo vacío', isError: true);
      _textFieldFocusNode.requestFocus();
      return;
    }

    if (!_isConnected) {
      _showSnackBar('Sin conexión al servidor', isError: true);
      return;
    }

    try {
      setState(() => _lastResponse = 'Procesando...');
      SemanticsService.announce('Enviando comando de texto', TextDirection.ltr);

      final result = await _webSocketService.sendTextCommand(command);
      setState(() {
        _lastResponse = result.aiResponse ?? '';
        _lastTranscription = command;
      });

      _textController.clear();

      if (result.success) {
        _showSnackBar('Comando enviado correctamente');
        if (_ttsEnabled && _ttsServiceReady && _lastResponse.isNotEmpty) {
          await Future.delayed(const Duration(milliseconds: 500));
          await _ttsService.speakSystemResponse(_lastResponse);
        }
        HapticFeedback.lightImpact();
      } else {
        _showSnackBar('Error al enviar comando', isError: true);
      }
    } catch (e) {
      _showSnackBar('Error de conexión', isError: true);
      setState(() => _lastResponse = 'Error: $e');
    }
  }

  void _toggleTTS() {
    setState(() => _ttsEnabled = !_ttsEnabled);
    final message = _ttsEnabled ? 'Síntesis de voz activada' : 'Síntesis de voz desactivada';
    _showSnackBar(message);
    if (!_ttsEnabled) _ttsService.stop();
    _ttsService.setEnabled(_ttsEnabled);
    SemanticsService.announce(message, TextDirection.ltr);
  }

  void _onNavigationTap(int index) {
    if (index == _currentIndex) return;

    setState(() => _currentIndex = index);
    HapticFeedback.mediumImpact();

    final screenName = index == 0 ? 'Control de Voz' : 'Reconocimiento de Entorno';
    SemanticsService.announce('Navegando a: $screenName', TextDirection.ltr);
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
    _webSocketService.disconnect();
    _audioService.dispose();
    _ttsService.dispose();
    _textController.dispose();
    _textFieldFocusNode.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Column(
            children: [
              // HEADER LIMPIO Y SEPARADO
              _buildCleanHeader(theme),

              // CONTENIDO DE LAS PANTALLAS
              Expanded(
                child: IndexedStack(
                  index: _currentIndex,
                  children: [
                    // PANTALLA 1: CONTROL DE VOZ
                    _buildVoiceControlTab(theme),

                    // PANTALLA 2: RECONOCIMIENTO DE ENTORNO
                    EnvironmentRecognitionScreen(
                      isConnected: _isConnected,
                      webSocketService: _webSocketService,
                      onReconnect: _autoDiscoverAndConnect,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),

      // NAVEGACIÓN INFERIOR ACCESIBLE
      bottomNavigationBar: _buildAccessibleBottomNav(theme),

      // BOTÓN DE ESTADO FLOTANTE (solo en pantalla de voz)
      floatingActionButton: _currentIndex == 0 ? _buildStatusFAB(theme) : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  // HEADER LIMPIO: Solo logo + título + control de voz
  Widget _buildCleanHeader(ThemeData theme) {
    return Semantics(
      label: 'Encabezado de la aplicación',
      container: true,
      child: Container(
        decoration: BoxDecoration(
          color: _isConnected ? theme.colorScheme.primary : theme.colorScheme.surface,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: Row(
          children: [
            // ICONO
            Semantics(
              label: 'Icono de robot',
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: _isConnected
                      ? Colors.white.withOpacity(0.2)
                      : theme.colorScheme.primary.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.smart_toy_outlined,
                  size: 32,
                  color: _isConnected ? Colors.white : theme.colorScheme.primary,
                ),
              ),
            ),

            const SizedBox(width: 16),

            // TÍTULO
            Expanded(
              child: Semantics(
                header: true,
                label: 'COMPAS - Control de Robot',
                child: Text(
                  'COMPAS',
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: _isConnected ? Colors.white : theme.colorScheme.onSurface,
                    fontWeight: FontWeight.bold,
                    fontSize: 26,
                  ),
                ),
              ),
            ),

            // BOTÓN DE SÍNTESIS DE VOZ (solo en pantalla de voz)
            if (_currentIndex == 0)
              Semantics(
                label: _ttsEnabled
                    ? 'Desactivar síntesis de voz'
                    : 'Activar síntesis de voz',
                hint: _ttsEnabled
                    ? 'Las respuestas se reproducirán con voz'
                    : 'Las respuestas no se reproducirán',
                button: true,
                child: Container(
                  decoration: BoxDecoration(
                    color: _isConnected
                        ? Colors.white.withOpacity(0.2)
                        : theme.colorScheme.primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: IconButton(
                    icon: Icon(
                      _ttsEnabled ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                      size: 28,
                      color: _isConnected ? Colors.white : theme.colorScheme.primary,
                    ),
                    onPressed: _ttsServiceReady ? _toggleTTS : null,
                    padding: const EdgeInsets.all(12),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // NAVEGACIÓN INFERIOR CON SEPARACIÓN CLARA
  Widget _buildAccessibleBottomNav(ThemeData theme) {
    return Semantics(
      label: 'Barra de navegación principal con dos opciones',
      container: true,
      child: Container(
        height: 100,
        decoration: BoxDecoration(
          color: theme.cardColor,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.12),
              blurRadius: 24,
              offset: const Offset(0, -8),
            ),
          ],
          border: Border(
            top: BorderSide(
              color: theme.colorScheme.primary.withOpacity(0.2),
              width: 2,
            ),
          ),
        ),
        child: SafeArea(
          top: false,
          child: Row(
            children: [
              // BOTÓN 1: CONTROL DE VOZ
              Expanded(
                child: _buildNavButton(
                  theme: theme,
                  icon: Icons.mic_rounded,
                  label: 'Control de Voz',
                  index: 0,
                ),
              ),

              // SEPARADOR VISUAL
              Container(
                width: 2,
                height: 50,
                color: theme.colorScheme.onSurface.withOpacity(0.1),
              ),

              // BOTÓN 2: RECONOCIMIENTO DE ENTORNO
              Expanded(
                child: _buildNavButton(
                  theme: theme,
                  icon: Icons.videocam_rounded,
                  label: 'Reconocimiento de Entorno',
                  index: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavButton({
    required ThemeData theme,
    required IconData icon,
    required String label,
    required int index,
  }) {
    final isSelected = _currentIndex == index;
    final baseColor = _isConnected ? theme.colorScheme.primary : theme.colorScheme.secondary;

    return Semantics(
      label: label,
      hint: isSelected ? 'Pantalla actual' : 'Toque dos veces para navegar',
      button: true,
      selected: isSelected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _onNavigationTap(index),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // ICONO CON FONDO
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? baseColor.withOpacity(0.2)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(16),
                    border: isSelected
                        ? Border.all(color: baseColor, width: 2)
                        : null,
                  ),
                  child: Icon(
                    icon,
                    size: 32,
                    color: isSelected
                        ? baseColor
                        : theme.colorScheme.onSurface.withOpacity(0.4),
                  ),
                ),

                const SizedBox(height: 4),

                // INDICADOR DE SELECCIÓN
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: isSelected ? 8 : 4,
                  height: isSelected ? 8 : 4,
                  decoration: BoxDecoration(
                    color: isSelected ? baseColor : Colors.transparent,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVoiceControlTab(ThemeData theme) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          const SizedBox(height: 32),

          // BOTÓN DE VOZ GIGANTE
          if (_isConnected) ...[
            AccessibleEnhancedVoiceButton(
              isRecording: _isRecording,
              isProcessing: _isProcessingAudio,
              whisperAvailable: _whisperAvailable && _audioServiceReady,
              onStartRecording: _startRecording,
              onStopRecording: _stopRecording,
            ),
            const SizedBox(height: 48),
          ],

          // CAMPO DE TEXTO
          _buildTextInput(theme),
          const SizedBox(height: 24),

          // COMANDOS RÁPIDOS
          if (_isConnected) _buildQuickCommands(theme),

          const SizedBox(height: 24),

          // RESPUESTA DEL ROBOT
          if (_lastResponse.isNotEmpty || _lastTranscription.isNotEmpty)
            AccessibleTranscriptionCard(
              transcription: _lastTranscription,
              aiResponse: _lastResponse,
              confidence: _lastConfidence,
              processingTime: _lastProcessingTime,
              publishedToRos: true,
              autoSpeak: _ttsEnabled && _ttsServiceReady,
            ),

          const SizedBox(height: 140),
        ],
      ),
    );
  }

  Widget _buildTextInput(ThemeData theme) {
    return Semantics(
      label: 'Campo de texto para ingresar comando manualmente',
      textField: true,
      hint: 'Escriba su comando y presione el botón enviar',
      child: Container(
        decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _isConnected
                ? theme.colorScheme.primary.withOpacity(0.3)
                : theme.colorScheme.onSurface.withOpacity(0.1),
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: TextField(
          controller: _textController,
          focusNode: _textFieldFocusNode,
          enabled: _isConnected,
          style: theme.textTheme.bodyLarge,
          decoration: InputDecoration(
            hintText: 'Escribe tu comando aquí',
            hintStyle: TextStyle(
              color: theme.colorScheme.onSurface.withOpacity(0.4),
              fontSize: 18,
            ),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.all(20),
            suffixIcon: Semantics(
              label: 'Enviar comando de texto',
              hint: 'Toque dos veces para enviar el comando escrito',
              button: true,
              child: IconButton(
                icon: Icon(
                  Icons.send_rounded,
                  color: _isConnected ? theme.colorScheme.primary : Colors.grey,
                  size: 28,
                ),
                onPressed: _isConnected ? _sendTextCommand : null,
                padding: const EdgeInsets.all(12),
              ),
            ),
          ),
          onSubmitted: _isConnected ? (_) => _sendTextCommand() : null,
          textInputAction: TextInputAction.send,
          maxLines: null,
          minLines: 1,
        ),
      ),
    );
  }

  Widget _buildQuickCommands(ThemeData theme) {
    final commands = ['Hola', 'Avanzar', 'Parar', 'Estado'];

    return Semantics(
      label: 'Botones de comandos rápidos. ${commands.length} opciones disponibles',
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        alignment: WrapAlignment.center,
        children: commands.map((cmd) => Semantics(
          label: 'Comando rápido: $cmd',
          hint: 'Toque dos veces para enviar este comando',
          button: true,
          child: Material(
            color: theme.colorScheme.primary.withOpacity(0.15),
            borderRadius: BorderRadius.circular(24),
            child: InkWell(
              onTap: () {
                _textController.text = cmd;
                _sendTextCommand();
              },
              borderRadius: BorderRadius.circular(24),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                child: Text(
                  cmd,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
        )).toList(),
      ),
    );
  }

  Widget _buildStatusFAB(ThemeData theme) {
    if (_isSearchingServer || _isConnecting) {
      return Semantics(
        label: _isSearchingServer
            ? 'Buscando servidor en la red'
            : 'Conectando al servidor',
        child: FloatingActionButton.extended(
          onPressed: null,
          backgroundColor: theme.colorScheme.surface,
          elevation: 4,
          label: Row(
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  valueColor: AlwaysStoppedAnimation(theme.colorScheme.primary),
                ),
              ),
              const SizedBox(width: 16),
              Text(
                _isSearchingServer ? 'Buscando...' : 'Conectando...',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (!_isConnected) {
      return Semantics(
        label: 'Reconectar al servidor',
        hint: 'Toque dos veces para intentar conectar al servidor nuevamente',
        button: true,
        child: FloatingActionButton.extended(
          onPressed: _autoDiscoverAndConnect,
          backgroundColor: theme.colorScheme.error,
          elevation: 6,
          icon: const Icon(Icons.refresh_rounded, color: Colors.white, size: 28),
          label: const Text(
            'Reconectar',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }
}