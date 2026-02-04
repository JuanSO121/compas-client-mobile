// lib/screens/voice_navigation_screen.dart
// ✅ PANTALLA SIMPLE DE COMANDOS DE VOZ (SIN ARCORE)

import 'package:flutter/material.dart' hide NavigationMode;
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';

import '../models/shared_models.dart';
import '../services/AI/navigation_coordinator.dart';

class VoiceNavigationScreen extends StatefulWidget {
  const VoiceNavigationScreen({super.key});

  @override
  State<VoiceNavigationScreen> createState() => _VoiceNavigationScreenState();
}

class _VoiceNavigationScreenState extends State<VoiceNavigationScreen> {
  final NavigationCoordinator _coordinator = NavigationCoordinator();
  final Logger _logger = Logger();

  bool _isInitialized = false;
  bool _isActive = false;
  String _statusMessage = 'Inicializando...';
  NavigationMode _currentMode = NavigationMode.eventBased;

  NavigationIntent? _currentIntent;
  bool _wakeWordAvailable = false;
  double _wakeWordSensitivity = 0.7;

  // Historial de comandos
  final List<String> _commandHistory = [];
  final int _maxHistory = 10;

  @override
  void initState() {
    super.initState();
    _initializeSystem();
  }

  Future<void> _initializeSystem() async {
    try {
      setState(() => _statusMessage = 'Inicializando servicios...');

      await _coordinator.initialize();

      _wakeWordAvailable = _coordinator.wakeWordAvailable;

      // Configurar callbacks
      _coordinator.onStatusUpdate = _handleStatusUpdate;
      _coordinator.onIntentDetected = _handleIntentDetected;
      _coordinator.onCommandExecuted = _handleCommandExecuted;
      _coordinator.onCommandRejected = _handleCommandRejected;

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
        setState(() {
          _isActive = false;
          _statusMessage = 'Sistema detenido';
        });
        SemanticsService.announce('Sistema detenido', TextDirection.ltr);
      } else {
        await _coordinator.start(mode: _currentMode);
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
      builder: (context) => _buildSettingsSheet(),
    );
  }

  void _showStatistics() {
    final stats = _coordinator.getStatistics();
    showDialog(
      context: context,
      builder: (context) => _buildStatsDialog(stats),
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
        if (mounted) {
          setState(() => _currentIntent = null);
        }
      });
    }
  }

  void _handleCommandExecuted(NavigationIntent intent) {
    if (mounted) {
      // Agregar al historial
      _addToHistory(intent.suggestedResponse);

      _showSnackBar('✅ ${intent.suggestedResponse}');
      HapticFeedback.lightImpact();
    }
  }

  void _handleCommandRejected(String reason) {
    if (mounted) {
      _showSnackBar('⛔ $reason', isError: true);
    }
  }

  void _addToHistory(String command) {
    setState(() {
      _commandHistory.insert(0, command);
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
        content: Text(
          message,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        backgroundColor: isError
            ? Theme.of(context).colorScheme.error
            : Theme.of(context).colorScheme.secondary,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        duration: Duration(seconds: isError ? 4 : 2),
      ),
    );
  }

  @override
  void dispose() {
    _coordinator.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(theme),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const SizedBox(height: 20),

                    // Estado visual
                    _buildStatusIndicator(theme),

                    const SizedBox(height: 40),

                    // Botón principal
                    _buildMainButton(theme),

                    const SizedBox(height: 40),

                    // Comando actual
                    if (_currentIntent != null)
                      _buildCurrentCommand(theme),

                    const SizedBox(height: 24),

                    // Historial
                    if (_commandHistory.isNotEmpty)
                      _buildCommandHistory(theme),
                  ],
                ),
              ),
            ),

            // Controles
            _buildControls(theme),

            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(
            _wakeWordAvailable ? Icons.waving_hand : Icons.mic,
            color: Colors.white,
            size: 32,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'COMPAS',
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Asistente de Voz',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.9),
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.analytics_outlined, color: Colors.white),
            onPressed: _showStatistics,
            tooltip: 'Estadísticas',
          ),
        ],
      ),
    );
  }

  Widget _buildStatusIndicator(ThemeData theme) {
    final stateColor = _isActive
        ? theme.colorScheme.secondary
        : theme.colorScheme.onSurface.withOpacity(0.3);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: stateColor, width: 2),
        boxShadow: _isActive
            ? [
          BoxShadow(
            color: stateColor.withOpacity(0.3),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ]
            : null,
      ),
      child: Row(
        children: [
          Icon(
            _coordinator.state == CoordinatorState.listeningCommand
                ? Icons.mic
                : Icons.mic_off,
            color: stateColor,
            size: 32,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isActive ? 'ACTIVO' : 'INACTIVO',
                  style: TextStyle(
                    color: stateColor,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _statusMessage,
                  style: theme.textTheme.bodyMedium,
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

  Widget _buildMainButton(ThemeData theme) {
    return GestureDetector(
      onTap: _isInitialized ? _toggleSystem : null,
      child: Container(
        width: 140,
        height: 140,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: !_isInitialized
              ? Colors.grey
              : (_isActive
              ? theme.colorScheme.error
              : theme.colorScheme.secondary),
          boxShadow: _isInitialized && _isActive
              ? [
            BoxShadow(
              color: theme.colorScheme.error.withOpacity(0.5),
              blurRadius: 30,
              spreadRadius: 5,
            ),
          ]
              : null,
        ),
        child: Icon(
          _isActive ? Icons.stop : Icons.play_arrow,
          color: Colors.white,
          size: 64,
        ),
      ),
    );
  }

  Widget _buildCurrentCommand(ThemeData theme) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 300),
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.scale(
            scale: 0.8 + (0.2 * value),
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.15),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: theme.colorScheme.primary,
                  width: 2,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _getIntentIcon(_currentIntent!.type),
                    color: theme.colorScheme.primary,
                    size: 28,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      _currentIntent!.suggestedResponse,
                      style: TextStyle(
                        color: theme.colorScheme.primary,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
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

  Widget _buildCommandHistory(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.history,
              color: theme.colorScheme.onSurface.withOpacity(0.6),
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              'Historial',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.cardColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: theme.colorScheme.onSurface.withOpacity(0.1),
            ),
          ),
          child: Column(
            children: _commandHistory.map((cmd) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.check_circle,
                      color: theme.colorScheme.secondary,
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        cmd,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildControls(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _buildControlButton(
            icon: _currentMode == NavigationMode.eventBased
                ? Icons.battery_saver
                : Icons.replay,
            label: _currentMode == NavigationMode.eventBased
                ? 'Ahorro'
                : 'Continuo',
            onTap: _toggleMode,
            color: theme.colorScheme.primary,
            enabled: _isInitialized,
          ),
          _buildControlButton(
            icon: Icons.refresh,
            label: 'Reset',
            onTap: _resetSystem,
            color: theme.colorScheme.error,
            enabled: _isInitialized,
          ),
          _buildControlButton(
            icon: Icons.settings,
            label: 'Config',
            onTap: _showSettings,
            color: theme.colorScheme.secondary,
            enabled: _isInitialized,
          ),
        ],
      ),
    );
  }

  Widget _buildControlButton({
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
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: color.withOpacity(enabled ? 0.5 : 0.3),
              width: 2,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 24),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsSheet() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '⚙️ Configuración',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 24),
          if (_wakeWordAvailable) ...[
            const Text(
              'Sensibilidad "Oye COMPAS"',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            Slider(
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
            Text(
              'Actual: ${(_wakeWordSensitivity * 100).toInt()}%',
              style: const TextStyle(fontSize: 14, color: Colors.grey),
            ),
          ],
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildStatsDialog(Map<String, dynamic> stats) {
    final voiceStats = stats['voice_service'] as Map<String, dynamic>? ?? {};
    final wakeStats = stats['wake_word'] as Map<String, dynamic>? ?? {};
    final systemStats = stats['system'] as Map<String, dynamic>? ?? {};

    return AlertDialog(
      title: const Text('📊 Estadísticas'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '🎤 Comandos de Voz',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            _buildStatRow('Estado:', systemStats['state'].toString()),
            _buildStatRow('Modo:', systemStats['mode'].toString()),
            const Divider(height: 24),
            if (_wakeWordAvailable) ...[
              const Text(
                '👋 Wake Word',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 8),
              _buildStatRow(
                'Detecciones:',
                wakeStats['detection_count'].toString(),
              ),
              const Divider(height: 24),
            ],
            const Text(
              '📱 Sistema',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            _buildStatRow(
              'Wake Word:',
              systemStats['wake_word_available'] == true ? 'Activo' : 'Inactivo',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cerrar'),
        ),
      ],
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  IconData _getIntentIcon(IntentType type) {
    switch (type) {
      case IntentType.navigate:
        return Icons.navigation;
      case IntentType.stop:
        return Icons.stop;
      case IntentType.describe:
        return Icons.description;
      case IntentType.help:
        return Icons.help;
      default:
        return Icons.question_mark;
    }
  }
}