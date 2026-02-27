// test/groq_api_test.dart
// ✅ TEST COMPLETO PARA VERIFICAR GROQ API

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

void main() {
  setUpAll(() async {
    // Cargar variables de entorno
    await dotenv.load(fileName: '.env');
  });

  group('Groq API Tests', () {

    test('1. ✅ API Key está configurada', () {
      final apiKey = dotenv.env['GROQ_API_KEY'] ?? '';

      expect(apiKey.isNotEmpty, true, reason: 'GROQ_API_KEY no encontrada en .env');
      expect(apiKey.length > 20, true, reason: 'API key parece inválida (muy corta)');
      expect(apiKey.contains('....'), false, reason: 'API key parece ser placeholder');
      expect(apiKey.startsWith('gsk_'), true, reason: 'API key debe empezar con "gsk_"');

      print('✅ API Key válida: ${apiKey.substring(0, 10)}...');
    });

    test('2. 🌐 Endpoint de Groq es alcanzable', () async {
      // ✅ USAR GET en lugar de HEAD (HEAD da 404 en algunos endpoints)
      final response = await http.get(
        Uri.parse('https://api.groq.com/openai/v1/models'),
        headers: {
          'Authorization': 'Bearer ${dotenv.env['GROQ_API_KEY']}',
        },
      ).timeout(const Duration(seconds: 10));

      expect(
        response.statusCode,
        200,
        reason: 'Endpoint de Groq no accesible (status: ${response.statusCode})',
      );

      print('✅ Endpoint alcanzable (status: ${response.statusCode})');
    });

    test('3. 🔑 API Key es válida (autenticación)', () async {
      final apiKey = dotenv.env['GROQ_API_KEY'] ?? '';

      final response = await http.get(
        Uri.parse('https://api.groq.com/openai/v1/models'),
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
      ).timeout(const Duration(seconds: 10));

      expect(
        response.statusCode,
        200,
        reason: 'Autenticación falló: ${response.statusCode} - ${response.body}',
      );

      print('✅ Autenticación exitosa');

      // Opcional: mostrar modelos disponibles
      final data = jsonDecode(response.body);
      if (data['data'] != null) {
        print('📋 Modelos disponibles:');
        for (var model in data['data']) {
          print('   - ${model['id']}');
        }
      }
    });

    test('4. 💬 Enviar request de prueba (clasificación de comando)', () async {
      final apiKey = dotenv.env['GROQ_API_KEY'] ?? '';

      final requestBody = {
        'model': 'llama-3.3-70b-versatile',
        'messages': [
          {
            'role': 'system',
            'content': '''Clasifica el siguiente comando en una de estas categorías: MOVE, STOP, TURN_LEFT, TURN_RIGHT, HELP, REPEAT.
Responde SOLO con JSON: {"label":"CATEGORIA","confidence":0.XX}'''
          },
          {
            'role': 'user',
            'content': 'avanza'
          }
        ],
        'temperature': 0.1,
        'max_tokens': 100,
      };

      final stopwatch = Stopwatch()..start();

      final response = await http.post(
        Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(requestBody),
      ).timeout(const Duration(seconds: 10));

      stopwatch.stop();

      expect(response.statusCode, 200, reason: 'Request falló: ${response.body}');

      final data = jsonDecode(response.body);
      final content = data['choices'][0]['message']['content'];
      final usage = data['usage'];

      print('✅ Request exitoso');
      print('   Respuesta: $content');
      print('   Tokens usados: ${usage['total_tokens']}');
      print('   Tiempo: ${stopwatch.elapsedMilliseconds}ms');

      // Verificar que la respuesta sea JSON válido
      final jsonResponse = jsonDecode(
          content.replaceAll('```json', '').replaceAll('```', '').trim()
      );

      expect(jsonResponse['label'], isNotEmpty);
      expect(jsonResponse['confidence'], isA<num>());

      print('   Label: ${jsonResponse['label']}');
      print('   Confidence: ${jsonResponse['confidence']}');
    });

    test('5. ⚡ Test de velocidad (múltiples requests)', () async {
      final apiKey = dotenv.env['GROQ_API_KEY'] ?? '';
      final commands = ['avanza', 'para', 'gira a la izquierda', 'ayuda'];
      final times = <int>[];

      for (var command in commands) {
        final stopwatch = Stopwatch()..start();

        final response = await http.post(
          Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': 'llama-3.3-70b-versatile',
            'messages': [
              {
                'role': 'system',
                'content': 'Clasifica: MOVE, STOP, TURN_LEFT, TURN_RIGHT, HELP, REPEAT. JSON: {"label":"X","confidence":0.XX}'
              },
              {'role': 'user', 'content': command}
            ],
            'temperature': 0.1,
            'max_tokens': 50,
          }),
        ).timeout(const Duration(seconds: 5));

        stopwatch.stop();
        times.add(stopwatch.elapsedMilliseconds);

        expect(response.statusCode, 200);
        print('   "$command": ${stopwatch.elapsedMilliseconds}ms');
      }

      final avgTime = times.reduce((a, b) => a + b) / times.length;
      print('✅ Tiempo promedio: ${avgTime.toStringAsFixed(0)}ms');

      // Groq debería ser muy rápido (< 1 segundo)
      expect(avgTime < 1000, true, reason: 'Groq es muy lento (promedio: ${avgTime}ms)');
    });

    test('6. 💰 Test de límite de rate (opcional)', () async {
      final apiKey = dotenv.env['GROQ_API_KEY'] ?? '';

      print('⚠️ Este test hará 35 requests para verificar rate limit...');
      print('   Plan gratuito: 30 RPM (requests por minuto)');

      var successCount = 0;
      var rateLimitHit = false;

      for (var i = 0; i < 35; i++) {
        try {
          final response = await http.post(
            Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'model': 'llama-3.3-70b-versatile',
              'messages': [
                {'role': 'user', 'content': 'test $i'}
              ],
              'max_tokens': 10,
            }),
          ).timeout(const Duration(seconds: 5));

          if (response.statusCode == 200) {
            successCount++;
          } else if (response.statusCode == 429) {
            rateLimitHit = true;
            print('   Rate limit alcanzado en request #${i + 1}');
            break;
          }

          // Pequeña pausa para no saturar
          await Future.delayed(const Duration(milliseconds: 100));

        } catch (e) {
          print('   Error en request #${i + 1}: $e');
        }
      }

      print('✅ Requests exitosos: $successCount/35');
      print('   Rate limit alcanzado: ${rateLimitHit ? "SI" : "NO"}');

      // Debería funcionar al menos 30 requests
      expect(successCount >= 30, true);
    }, skip: true); // Skip por defecto para no gastar cuota

  });
}