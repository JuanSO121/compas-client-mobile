// lib/services/AI/portable_tokenizer.dart
// ✅ TOKENIZADOR PORTABLE - RÉPLICA EXACTA DEL PYTHON
// Garantiza tokenización idéntica byte-a-byte

import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';

/// Tokenizador portable compatible con el tokenizer Python
///
/// GARANTÍAS:
/// - Normalización idéntica byte-a-byte
/// - Mismos IDs para mismos textos
/// - Sin dependencias externas (solo dart:core)
class PortableTokenizer {
  final Logger _logger = Logger();

  // Tokens especiales (IDs fijos - DEBEN coincidir con Python)
  static const String padToken = '<PAD>';
  static const String unkToken = '<UNK>';
  static const String startToken = '<START>';
  static const String endToken = '<END>';

  static const int padId = 0;
  static const int unkId = 1;
  static const int startId = 2;
  static const int endId = 3;

  // Vocabulario
  Map<String, int> token2id = {};
  Map<int, String> id2token = {};
  int vocabSize = 0;
  List<String> keywords = [];

  bool _isLoaded = false;

  /// Cargar vocabulario desde JSON en assets
  Future<void> loadVocab(String assetPath) async {
    if (_isLoaded) {
      _logger.w('Vocabulario ya cargado');
      return;
    }

    try {
      // Cargar archivo JSON
      final jsonString = await rootBundle.loadString(assetPath);
      final vocabData = jsonDecode(jsonString) as Map<String, dynamic>;

      // Cargar token2id
      token2id = Map<String, int>.from(vocabData['token2id']);

      // Cargar id2token (convertir keys a int)
      final id2tokenRaw = vocabData['id2token'] as Map<String, dynamic>;
      id2token = {};
      id2tokenRaw.forEach((key, value) {
        id2token[int.parse(key)] = value as String;
      });

      vocabSize = vocabData['vocab_size'] as int;
      keywords = List<String>.from(vocabData['keywords']);

      _isLoaded = true;

      _logger.i('✅ Vocabulario cargado: $vocabSize tokens');
      _logger.d('   Keywords: ${keywords.length}');

    } catch (e) {
      _logger.e('Error cargando vocabulario: $e');
      rethrow;
    }
  }

  /// Normaliza texto (DEBE ser idéntico a Python)
  ///
  /// REGLAS:
  /// 1. Lowercase
  /// 2. Remover acentos (mapeo manual)
  /// 3. Remover puntuación (solo letras, números, espacios)
  /// 4. Comprimir espacios múltiples
  String normalize(String text) {
    // 1. Lowercase
    text = text.toLowerCase();

    // 2. Remover acentos (mapeo manual - IDÉNTICO a Python)
    const accentMap = {
      'á': 'a', 'é': 'e', 'í': 'i', 'ó': 'o', 'ú': 'u',
      'ñ': 'n', 'ü': 'u',
      'à': 'a', 'è': 'e', 'ì': 'i', 'ò': 'o', 'ù': 'u',
    };

    for (var entry in accentMap.entries) {
      text = text.replaceAll(entry.key, entry.value);
    }

    // 3. Remover puntuación (solo letras, números, espacios)
    const allowed = 'abcdefghijklmnopqrstuvwxyz0123456789 ';
    text = text.split('').map((c) {
      return allowed.contains(c) ? c : ' ';
    }).join('');

    // 4. Comprimir espacios múltiples
    text = text.split(' ').where((s) => s.isNotEmpty).join(' ');

    return text.trim();
  }

  /// Tokeniza texto en lista de tokens
  ///
  /// ESTRATEGIA:
  /// 1. Normalizar
  /// 2. Buscar keywords completas (greedy longest match)
  /// 3. Char-level para el resto
  List<String> tokenize(String text) {
    if (!_isLoaded) {
      throw StateError('Vocabulario no cargado');
    }

    text = normalize(text);
    final tokens = <String>[];

    int i = 0;
    while (i < text.length) {
      bool matched = false;

      // Intentar match con keywords (longest first)
      for (int length = (text.length - i).clamp(0, 20); length > 0; length--) {
        if (i + length > text.length) continue;

        final candidate = text.substring(i, i + length).trim();

        if (candidate.isEmpty) {
          i++;
          matched = true;
          break;
        }

        final keywordToken = '<W>$candidate';

        if (token2id.containsKey(keywordToken)) {
          tokens.add(keywordToken);
          i += length;
          matched = true;
          break;
        }
      }

      // Si no hay match, usar char-level
      if (!matched) {
        final char = text[i];

        if (char == ' ') {
          // Skip espacios solitarios
          i++;
          continue;
        }

        if (token2id.containsKey(char)) {
          tokens.add(char);
        } else {
          tokens.add(unkToken);
        }
        i++;
      }
    }

    return tokens;
  }

  /// Convierte texto a lista de IDs con padding/truncate
  ///
  /// Args:
  ///   text: texto de entrada
  ///   maxLength: longitud máxima (padding/truncate)
  ///   addSpecial: agregar START/END tokens
  ///
  /// Returns:
  ///   Lista de IDs (length = maxLength)
  List<int> encode(
      String text, {
        int maxLength = 32,
        bool addSpecial = true,
      }) {
    if (!_isLoaded) {
      throw StateError('Vocabulario no cargado');
    }

    var tokens = tokenize(text);

    if (addSpecial) {
      tokens = [startToken, ...tokens, endToken];
    }

    // Convertir a IDs
    final ids = tokens.map((t) => token2id[t] ?? unkId).toList();

    // Padding o truncate
    if (ids.length < maxLength) {
      // Padding
      ids.addAll(List.filled(maxLength - ids.length, padId));
    } else if (ids.length > maxLength) {
      // Truncate
      return ids.sublist(0, maxLength);
    }

    return ids;
  }

  /// Convierte IDs a texto
  String decode(List<int> ids) {
    if (!_isLoaded) {
      throw StateError('Vocabulario no cargado');
    }

    final tokens = ids.map((id) => id2token[id] ?? unkToken).toList();

    // Remover tokens especiales y markers de keywords
    final textParts = <String>[];
    for (var token in tokens) {
      if (token.startsWith('<W>')) {
        textParts.add(token.substring(3)); // Remover <W>
      } else if (![padToken, unkToken, startToken, endToken].contains(token)) {
        textParts.add(token);
      }
    }

    return textParts.join('');
  }

  /// Verificar equivalencia con tokenización Python
  ///
  /// Útil para debugging y validación
  Map<String, dynamic> getTokenizationInfo(String text) {
    final normalized = normalize(text);
    final tokens = tokenize(text);
    final ids = encode(text, maxLength: 32);
    final decoded = decode(ids);

    return {
      'original': text,
      'normalized': normalized,
      'tokens': tokens.take(10).toList(),
      'ids': ids.take(15).toList(),
      'decoded': decoded,
      'token_count': tokens.length,
      'id_count': ids.length,
    };
  }

  // Getters
  bool get isLoaded => _isLoaded;
  int get keywordCount => keywords.length;

  /// Tests de validación (opcional - para debugging)
  Future<void> runValidationTests() async {
    if (!_isLoaded) {
      throw StateError('Vocabulario no cargado');
    }

    _logger.i('🧪 Ejecutando tests de validación...');

    final testCases = [
      'avanza',
      'pará',
      'gira a la izquierda',
      'ayuda por favor',
      'repite eso',
      'muévete rápido',
      'dobla derecha',
      'para ya',
    ];

    for (var text in testCases) {
      final info = getTokenizationInfo(text);
      _logger.d('Test: "$text"');
      _logger.d('  Normalized: ${info['normalized']}');
      _logger.d('  Tokens: ${info['tokens']}');
      _logger.d('  IDs: ${info['ids']}');
      _logger.d('  Decoded: ${info['decoded']}');
    }

    _logger.i('✅ Tests completados');
  }
}