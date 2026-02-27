// lib/screens/voice_navigation_screen.dart
// ✅ PANTALLA MODERNA Y MEJORADA DE COMANDOS DE VOZ

import 'package:flutter/material.dart' hide NavigationMode;
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';

import '../models/shared_models.dart';
import '../services/AI/navigation_coordinator.dart';
import '../services/AI/ai_mode_controller.dart';

class VoiceNavigationScreen extends StatefulWidget {
  const VoiceNavigationScreen({super.key});

  @override
  State<VoiceNavigationScreen> createState() => _VoiceNavigationScreenState();
}

class _VoiceNavigationScreenState extends State<VoiceNavigationScreen>
    with TickerProviderStateMixin {
  final NavigationCoordinator _coordinator = NavigationCoordinator();
  final AIModeController _aiModeController = AIModeController();
  final Logger _logger = Logger();

  bool _isInitialized = false;
  bool _isActive = false;
  String _statusMessage = 'Inicializando...';
  NavigationMode _currentMode = NavigationMode.eventBased;
  AIMode _aiMode = AIMode.auto;

  NavigationIntent? _currentIntent;
  bool _wakeWordAvailable = false;
  double _wakeWordSensitivity = 0.7;

  // Historial de comandos
  final List<CommandHistoryItem> _commandHistory = [];
  final int _maxHistory = 10;

  // Animaciones
  late AnimationController _pulseController;
  late AnimationController _waveController;
  late Animation<double> _pulseAnimation;
  late Animation<double> _waveAnimation;

  @override
  void initState() {
    super.initState();
    _setupAnimations();
    _initializeSystem();
  }

  void _setupAnimations() {
    // Animación de pulso para el botón principal
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.1).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Animación de ondas para cuando está escuchando
    _waveController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    );

    _waveAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _waveController, curve: Curves.easeInOut),
    );
  }

  Future<void> _initializeSystem() async {
    try {
      setState(() => _statusMessage = 'Inicializando servicios...');

      // Inicializar AI Mode Controller
      await _aiModeController.initialize();
      _aiMode = _aiModeController.currentMode;

      // Inicializar Coordinator
      await _coordinator.initialize();
      _wakeWordAvailable = _coordinator.wakeWordAvailable;

      // Configurar callbacks
      _coordinator.onStatusUpdate = _handleStatusUpdate;
      _coordinator.onIntentDetected = _handleIntentDetected;
      _coordinator.onCommandExecuted = _handleCommandExecuted;
      _coordinator.onCommandRejected = _handleCommandRejected;

      _aiModeController.onModeChanged = (mode) {
        if (mounted) {
          setState(() => _aiMode = mode);
          _showSnackBar(
            'Modo IA: ${mode == AIMode.online ? "🌐 Online (Groq)" : "📴 Offline (TFLite)"}',
          );
        }
      };

      setState(() {
        _isInitialized = true;
        _statusMessage = _buildInitialStatusMessage();
      });

      SemanticsService.announce(
        'Sistema de comandos de voz inicializado',
        TextDirection.ltr,
      );

      _logger.i('✅ Pantalla inicializada');

    } catch (e) {
      _logger.e('❌ Error inicializando: $e');
      setState(() {
        _statusMessage = 'Error: $e';
        _isInitialized = false;
      });
      _showSnackBar('Error de inicialización: $e', isError: true);
    }
  }

  String _buildInitialStatusMessage() {
    if (_wakeWordAvailable) {
      return '✅ Sistema listo - Di "Oye COMPAS"';
    } else {
      return '✅ Sistema listo - Presiona para hablar';
    }
  }

  Future<void> _toggleSystem() async {
    if (!_isInitialized) {
      _showSnackBar('Sistema no inicializado', isError: true);
      return;
    }

    try {
      if (_isActive) {
        await _coordinator.stop();
        _pulseController.stop();
        _waveController.stop();
        setState(() {
          _isActive = false;
          _statusMessage = 'Sistema detenido';
        });
        SemanticsService.announce('Sistema detenido', TextDirection.ltr);
      } else {
        await _coordinator.start(mode: _currentMode);
        _pulseController.repeat(reverse: true);
        _waveController.repeat();
        setState(() {
          _isActive = true;
          _statusMessage = _wakeWordAvailable
              ? 'Esperando "Oye COMPAS"...'
              : 'Escuchando comandos...';
        });
        SemanticsService.announce('Sistema iniciado', TextDirection.ltr);
      }

      HapticFeedback.mediumImpact();

    } catch (e) {
      _logger.e('Error toggle: $e');
      _showSnackBar('Error: $e', isError: true);
    }
  }

  void _toggleMode() {
    if (!_isInitialized) return;

    final newMode = _currentMode == NavigationMode.eventBased
        ? NavigationMode.continuous
        : NavigationMode.eventBased;

    _coordinator.setMode(newMode);
    setState(() => _currentMode = newMode);

    final modeName = newMode == NavigationMode.eventBased
        ? 'Modo Ahorro de Batería'
        : 'Modo Continuo';

    SemanticsService.announce(modeName, TextDirection.ltr);
    _showSnackBar(modeName);
  }

  void _cycleAIMode() {
    if (!_isInitialized) return;

    final modes = [AIMode.auto, AIMode.online, AIMode.offline];
    final currentIndex = modes.indexOf(_aiModeController.currentMode);
    final nextMode = modes[(currentIndex + 1) % modes.length];

    _aiModeController.setMode(nextMode);
    setState(() => _aiMode = nextMode);

    final modeNames = {
      AIMode.auto: 'Auto (Inteligente)',
      AIMode.online: 'Online (Groq)',
      AIMode.offline: 'Offline (Local)',
    };

    _showSnackBar('Modo IA: ${modeNames[nextMode]}');
  }

  void _resetSystem() {
    _coordinator.reset();
    setState(() {
      _currentIntent = null;
      _commandHistory.clear();
    });
    _showSnackBar('Sistema reiniciado');
  }

  void _showSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _buildSettingsSheet(),
    );
  }

  void _showStatistics() {
    final stats = _coordinator.getStatistics();
    final aiStats = _aiModeController.getStatistics();

    showDialog(
      context: context,
      builder: (context) => _buildStatsDialog(stats, aiStats),
    );
  }

  // Callbacks
  void _handleStatusUpdate(String status) {
    if (mounted) {
      setState(() => _statusMessage = status);
    }
  }

  void _handleIntentDetected(NavigationIntent intent) {
    if (mounted) {
      setState(() => _currentIntent = intent);

      SemanticsService.announce(
        'Comando detectado: ${intent.suggestedResponse}',
        TextDirection.ltr,
      );

      _logger.i('🎯 Comando: ${intent.type}');

      // Auto-limpiar después de 3 segundos
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted && _currentIntent?.type == intent.type) {
          setState(() => _currentIntent = null);
        }
      });
    }
  }

  void _handleCommandExecuted(NavigationIntent intent) {
    if (mounted) {
      _addToHistory(intent);
      _showSnackBar('✅ ${intent.suggestedResponse}');
      HapticFeedback.lightImpact();
    }
  }

  void _handleCommandRejected(String reason) {
    if (mounted) {
      _showSnackBar('⛔ $reason', isError: true);
      HapticFeedback.heavyImpact();
    }
  }

  void _addToHistory(NavigationIntent intent) {
    setState(() {
      _commandHistory.insert(
        0,
        CommandHistoryItem(
          intent: intent,
          timestamp: DateTime.now(),
        ),
      );

      if (_commandHistory.length > _maxHistory) {
        _commandHistory.removeLast();
      }
    });
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;

    SemanticsService.announce(message, TextDirection.ltr);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.check_circle_outline,
              color: Colors.white,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: isError
            ? const Color(0xFFE53935)
            : const Color(0xFF43A047),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        duration: Duration(seconds: isError ? 4 : 2),
        elevation: 6,
      ),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _waveController.dispose();
    _coordinator.dispose();
    _aiModeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.of(context).size;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.primary.withOpacity(0.05),
              theme.colorScheme.secondary.withOpacity(0.05),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildModernHeader(theme),

              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    children: [
                      const SizedBox(height: 24),

                      // Estado del sistema
                      _buildModernStatusCard(theme),

                      const SizedBox(height: 32),

                      // Botón principal animado
                      _buildAnimatedMainButton(theme, size),

                      const SizedBox(height: 32),

                      // Indicador de modo IA
                      _buildAIModeIndicator(theme),

                      const SizedBox(height: 24),

                      // Comando actual
                      if (_currentIntent != null)
                        _buildModernCurrentCommand(theme),

                      const SizedBox(height: 24),

                      // Historial mejorado
                      if (_commandHistory.isNotEmpty)
                        _buildModernCommandHistory(theme),
                    ],
                  ),
                ),
              ),

              // Controles modernos
              _buildModernControls(theme),

              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModernHeader(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  theme.colorScheme.primary,
                  theme.colorScheme.secondary,
                ],
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.primary.withOpacity(0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(
              _wakeWordAvailable ? Icons.waving_hand : Icons.mic,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'COMPAS',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Asistente Inteligente de Voz',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.6),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.analytics_outlined,
                color: theme.colorScheme.primary,
              ),
            ),
            onPressed: _showStatistics,
            tooltip: 'Estadísticas',
          ),
        ],
      ),
    );
  }

  Widget _buildModernStatusCard(ThemeData theme) {
    final stateColor = _isActive
        ? theme.colorScheme.secondary
        : theme.colorScheme.onSurface.withOpacity(0.3);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: stateColor.withOpacity(0.3),
          width: 2,
        ),
        boxShadow: _isActive
            ? [
          BoxShadow(
            color: stateColor.withOpacity(0.2),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ]
            : [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: stateColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              _coordinator.state == CoordinatorState.listeningCommand
                  ? Icons.mic
                  : Icons.mic_off,
              color: stateColor,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _isActive ? Colors.green : Colors.grey,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isActive ? 'ACTIVO' : 'INACTIVO',
                      style: TextStyle(
                        color: stateColor,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _statusMessage,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnimatedMainButton(ThemeData theme, Size size) {
    return GestureDetector(
      onTap: _isInitialized ? _toggleSystem : null,
      child: AnimatedBuilder(
        animation: _pulseAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: _isActive ? _pulseAnimation.value : 1.0,
            child: Container(
              width: 160,
              height: 160,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: !_isInitialized
                      ? [Colors.grey, Colors.grey.shade400]
                      : (_isActive
                      ? [
                    const Color(0xFFE53935),
                    const Color(0xFFD32F2F),
                  ]
                      : [
                    theme.colorScheme.secondary,
                    theme.colorScheme.secondary.withOpacity(0.8),
                  ]),
                ),
                boxShadow: _isInitialized && _isActive
                    ? [
                  BoxShadow(
                    color: const Color(0xFFE53935).withOpacity(0.4),
                    blurRadius: 30,
                    spreadRadius: 5,
                  ),
                ]
                    : [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 20,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Ondas de audio animadas
                  if (_isActive)
                    AnimatedBuilder(
                      animation: _waveAnimation,
                      builder: (context, child) {
                        return Container(
                          width: 160 + (40 * _waveAnimation.value),
                          height: 160 + (40 * _waveAnimation.value),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withOpacity(
                                0.3 * (1 - _waveAnimation.value),
                              ),
                              width: 2,
                            ),
                          ),
                        );
                      },
                    ),
                  // Icono
                  Icon(
                    _isActive ? Icons.stop_rounded : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 72,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildAIModeIndicator(ThemeData theme) {
    final effectiveMode = _aiModeController.effectiveMode;
    final modeInfo = _getModeInfo(effectiveMode);

    return GestureDetector(
      onTap: _cycleAIMode,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: modeInfo.color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: modeInfo.color.withOpacity(0.3),
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(modeInfo.icon, color: modeInfo.color, size: 20),
            const SizedBox(width: 8),
            Text(
              modeInfo.label,
              style: TextStyle(
                color: modeInfo.color,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.sync, color: modeInfo.color.withOpacity(0.5), size: 16),
          ],
        ),
      ),
    );
  }

  AIModeInfo _getModeInfo(AIMode mode) {
    switch (mode) {
      case AIMode.online:
        return AIModeInfo(
          icon: Icons.cloud,
          label: 'Online (Groq)',
          color: const Color(0xFF4CAF50),
        );
      case AIMode.offline:
        return AIModeInfo(
          icon: Icons.offline_bolt,
          label: 'Offline (Local)',
          color: const Color(0xFFFF9800),
        );
      case AIMode.auto:
        return AIModeInfo(
          icon: Icons.auto_awesome,
          label: 'Auto',
          color: const Color(0xFF2196F3),
        );
    }
  }

  Widget _buildModernCurrentCommand(ThemeData theme) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutBack,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.scale(
            scale: 0.8 + (0.2 * value),
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    theme.colorScheme.primary.withOpacity(0.15),
                    theme.colorScheme.secondary.withOpacity(0.15),
                  ],
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: theme.colorScheme.primary.withOpacity(0.3),
                  width: 2,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      _getIntentIcon(_currentIntent!.type),
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Comando Actual',
                          style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.primary.withOpacity(0.7),
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _currentIntent!.suggestedResponse,
                          style: TextStyle(
                            color: theme.colorScheme.primary,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildModernCommandHistory(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              Icon(
                Icons.history_rounded,
                color: theme.colorScheme.onSurface.withOpacity(0.6),
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                'Historial Reciente',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.6),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _commandHistory.length,
            separatorBuilder: (context, index) => Divider(
              height: 1,
              indent: 56,
              color: theme.colorScheme.onSurface.withOpacity(0.1),
            ),
            itemBuilder: (context, index) {
              final item = _commandHistory[index];
              return _buildHistoryItem(theme, item);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildHistoryItem(ThemeData theme, CommandHistoryItem item) {
    final timeDiff = DateTime.now().difference(item.timestamp);
    final timeStr = _formatTimeDifference(timeDiff);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              _getIntentIcon(item.intent.type),
              color: theme.colorScheme.secondary,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.intent.suggestedResponse,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  timeStr,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.check_circle,
            color: theme.colorScheme.secondary.withOpacity(0.5),
            size: 18,
          ),
        ],
      ),
    );
  }

  String _formatTimeDifference(Duration diff) {
    if (diff.inSeconds < 60) {
      return 'Hace ${diff.inSeconds}s';
    } else if (diff.inMinutes < 60) {
      return 'Hace ${diff.inMinutes}m';
    } else {
      return 'Hace ${diff.inHours}h';
    }
  }

  Widget _buildModernControls(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildModernControlButton(
            icon: _currentMode == NavigationMode.eventBased
                ? Icons.battery_saver_rounded
                : Icons.all_inclusive_rounded,
            label: _currentMode == NavigationMode.eventBased ? 'Ahorro' : 'Continuo',
            onTap: _toggleMode,
            color: theme.colorScheme.primary,
            enabled: _isInitialized,
          ),
          _buildModernControlButton(
            icon: Icons.refresh_rounded,
            label: 'Reset',
            onTap: _resetSystem,
            color: const Color(0xFFE53935),
            enabled: _isInitialized,
          ),
          _buildModernControlButton(
            icon: Icons.settings_rounded,
            label: 'Config',
            onTap: _showSettings,
            color: theme.colorScheme.secondary,
            enabled: _isInitialized,
          ),
        ],
      ),
    );
  }

  Widget _buildModernControlButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required Color color,
    bool enabled = true,
  }) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.5,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: color.withOpacity(enabled ? 0.3 : 0.2),
              width: 1.5,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 24),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsSheet() {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(28),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      theme.colorScheme.primary,
                      theme.colorScheme.secondary,
                    ],
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.settings_rounded,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),
              const Text(
                'Configuración',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),

          if (_wakeWordAvailable) ...[
            const Text(
              'Sensibilidad "Oye COMPAS"',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: theme.colorScheme.primary,
                inactiveTrackColor: theme.colorScheme.primary.withOpacity(0.2),
                thumbColor: theme.colorScheme.primary,
                overlayColor: theme.colorScheme.primary.withOpacity(0.2),
                valueIndicatorColor: theme.colorScheme.primary,
              ),
              child: Slider(
                value: _wakeWordSensitivity,
                min: 0.3,
                max: 1.0,
                divisions: 7,
                label: '${(_wakeWordSensitivity * 100).toInt()}%',
                onChanged: (value) async {
                  setState(() => _wakeWordSensitivity = value);
                  await _coordinator.setWakeWordSensitivity(value);
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Baja (30%)',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
                Text(
                  'Alta (100%)',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Actual: ${(_wakeWordSensitivity * 100).toInt()}%',
                      style: TextStyle(
                        fontSize: 13,
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }

  Widget _buildStatsDialog(
      Map<String, dynamic> stats,
      Map<String, dynamic> aiStats,
      ) {
    final theme = Theme.of(context);
    final voiceStats = stats['voice_service'] as Map<String, dynamic>? ?? {};
    final wakeStats = stats['wake_word'] as Map<String, dynamic>? ?? {};
    final systemStats = stats['system'] as Map<String, dynamic>? ?? {};

    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      child: Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.analytics_rounded,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                const Text(
                  'Estadísticas',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            _buildStatsSection(
              theme,
              '🌐 Modo IA',
              [
                _buildStatRow(
                  theme,
                  'Modo actual:',
                  aiStats['current_mode'].toString().toUpperCase(),
                ),
                _buildStatRow(
                  theme,
                  'Internet:',
                  aiStats['has_internet'] == true ? '✅ Disponible' : '❌ No disponible',
                ),
                _buildStatRow(
                  theme,
                  'Groq API:',
                  aiStats['groq_available'] == true ? '✅ Activo' : '❌ Inactivo',
                ),
              ],
            ),

            const Divider(height: 32),

            _buildStatsSection(
              theme,
              '🎤 Sistema',
              [
                _buildStatRow(
                  theme,
                  'Estado:',
                  systemStats['state'].toString(),
                ),
                _buildStatRow(
                  theme,
                  'Modo:',
                  systemStats['mode'].toString(),
                ),
                if (_wakeWordAvailable)
                  _buildStatRow(
                    theme,
                    'Detecciones:',
                    wakeStats['detection_count'].toString(),
                  ),
              ],
            ),

            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'Cerrar',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsSection(
      ThemeData theme,
      String title,
      List<Widget> children,
      ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 12),
        ...children,
      ],
    );
  }

  Widget _buildStatRow(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: theme.colorScheme.onSurface.withOpacity(0.7),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  IconData _getIntentIcon(IntentType type) {
    switch (type) {
      case IntentType.navigate:
        return Icons.navigation_rounded;
      case IntentType.stop:
        return Icons.stop_circle_rounded;
      case IntentType.describe:
        return Icons.description_rounded;
      case IntentType.help:
        return Icons.help_rounded;
      default:
        return Icons.question_mark_rounded;
    }
  }
}

// ========== CLASES DE DATOS ==========

class CommandHistoryItem {
  final NavigationIntent intent;
  final DateTime timestamp;

  CommandHistoryItem({
    required this.intent,
    required this.timestamp,
  });
}

class AIModeInfo {
  final IconData icon;
  final String label;
  final Color color;

  AIModeInfo({
    required this.icon,
    required this.label,
    required this.color,
  });
}