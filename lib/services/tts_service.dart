// ═══════════════════════════════════════════════════════════════════
// ARCHIVO 1: lib/services/AI/tts_service.dart
// ═══════════════════════════════════════════════════════════════════

import 'package:flutter_tts/flutter_tts.dart';
import 'package:logger/logger.dart';
import 'dart:async';
import 'dart:io';

class TTSService {
  static final TTSService _instance = TTSService._internal();
  factory TTSService() => _instance;
  TTSService._internal();

  final Logger _logger = Logger();
  final FlutterTts _tts = FlutterTts();

  bool _isInitialized = false;
  bool _isSpeaking = false;

  final _completionController = StreamController<void>.broadcast();
  Stream<void> get onComplete => _completionController.stream;

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      _tts.setStartHandler(() {
        _isSpeaking = true;
        _logger.d('🔊 TTS iniciado');
      });

      _tts.setCompletionHandler(() {
        _isSpeaking = false;
        _completionController.add(null);
        _logger.d('✅ TTS completado');
      });

      _tts.setErrorHandler((msg) {
        _isSpeaking = false;
        _logger.e('❌ TTS Error: $msg');
        _completionController.add(null);
      });

      await _tts.setLanguage('es-ES');
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);

      if (Platform.isAndroid) {
        await _tts.setQueueMode(1);
      }

      _isInitialized = true;
      _logger.i('✅ TTS inicializado');

    } catch (e) {
      _logger.e('Error inicializando TTS: $e');
      rethrow;
    }
  }

  Future<void> speak(String text, {bool interrupt = false}) async {
    if (!_isInitialized) throw StateError('TTS no inicializado');
    if (text.trim().isEmpty) return;

    if (_isSpeaking && interrupt) {
      await stop();
      await Future.delayed(const Duration(milliseconds: 100));
    }

    if (_isSpeaking && !interrupt) {
      _logger.w('TTS ocupado, esperando...');
      await waitForCompletion();
    }

    try {
      final cleanText = _cleanText(text);
      _logger.d('🔊 "$cleanText"');
      await _tts.speak(cleanText);
    } catch (e) {
      _logger.e('Error speak: $e');
      _isSpeaking = false;
    }
  }

  Future<void> stop() async {
    if (!_isSpeaking) return;
    try {
      await _tts.stop();
      _isSpeaking = false;
    } catch (e) {
      _logger.e('Error stop: $e');
    }
  }

  Future<void> waitForCompletion({Duration timeout = const Duration(seconds: 5)}) async {
    if (!_isSpeaking) return;
    try {
      await onComplete.first.timeout(timeout);
    } on TimeoutException {
      _logger.w('TTS timeout');
      _isSpeaking = false;
    }
  }

  String _cleanText(String text) {
    return text
        .replaceAll(RegExp(r'[^\w\s\.,!?;:()\-áéíóúñÁÉÍÓÚÑ]', unicode: true), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  bool get isInitialized => _isInitialized;
  bool get isSpeaking => _isSpeaking;

  void dispose() {
    _tts.stop();
    _completionController.close();
  }
}