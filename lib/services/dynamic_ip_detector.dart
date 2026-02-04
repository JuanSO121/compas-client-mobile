// lib/services/dynamic_ip_detector.dart - VERSIÓN CORREGIDA PARA ANDROID
import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'dart:convert';

class DynamicIPDetector {
  static const int WHISPER_PORT = 8000;
  static const Duration SCAN_TIMEOUT = Duration(seconds: 5); // Aumentado para Android

  /// Detectar automáticamente la IP del servidor Whisper DESDE ANDROID
  static Future<String?> detectWhisperServerIP() async {
    print('🔍 Iniciando detección desde dispositivo Android...');

    // PASO 1: Probar la IP de Windows (host) primero - MÁS PROBABLE
    final String? windowsIP = await _detectWindowsHostIP();
    if (windowsIP != null) {
      print('🎯 Probando IP de Windows host: $windowsIP');
      if (await _testWhisperService(windowsIP, WHISPER_PORT)) {
        print('✅ Conectado a Windows host: $windowsIP');
        return windowsIP;
      }
    }

    // PASO 2: Obtener todas las IPs candidatas
    final candidateIPs = await _getAllCandidateIPsForAndroid();

    print('📋 IPs candidatas encontradas: ${candidateIPs.length}');
    for (String ip in candidateIPs) {
      print('  - $ip');
    }

    // PASO 3: Probar IPs en lotes pequeños
    return await _testIPsInBatches(candidateIPs, WHISPER_PORT);
  }

  /// Detectar IP del host Windows (donde está WSL2)
  static Future<String?> _detectWindowsHostIP() async {
    try {
      // En Android, necesitamos la IP del host Windows, no de WSL2
      // Obtener gateway (que debería ser el router)
      final List<NetworkInterface> interfaces = await NetworkInterface.list();

      for (NetworkInterface interface in interfaces) {
        for (InternetAddress addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            // Desde la IP del celular, calcular posibles IPs del host
            final parts = addr.address.split('.');
            if (parts.length == 4) {
              // Generar IPs probables del host Windows en la misma red
              final baseNetwork = '${parts[0]}.${parts[1]}.${parts[2]}';

              // IPs comunes para hosts Windows
              final List<String> hostCandidates = [
                '$baseNetwork.1',   // Router/Gateway
                '$baseNetwork.100', // IP común de PC
                '$baseNetwork.101',
                '$baseNetwork.102',
                '$baseNetwork.10',  // Otra IP común
                '$baseNetwork.2',   // Segunda IP común
              ];

              // Probar cada candidato
              for (String hostIP in hostCandidates) {
                print('🔍 Probando host candidato: $hostIP');
                if (await _quickPingTest(hostIP)) {
                  return hostIP;
                }
              }
            }
          }
        }
      }
    } catch (e) {
      print('⚠️ Error detectando Windows host: $e');
    }

    return null;
  }

  /// Test rápido de ping a una IP
  static Future<bool> _quickPingTest(String ip) async {
    try {
      final socket = await Socket.connect(ip, WHISPER_PORT, timeout: Duration(seconds: 2));
      await socket.close();
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Obtener todas las IPs candidatas PARA ANDROID
  static Future<List<String>> _getAllCandidateIPsForAndroid() async {
    final Set<String> allIPs = <String>{};

    // 1. PRIORIDAD: IPs de la red local del celular
    try {
      final localNetworkIPs = await _getLocalNetworkIPs();
      allIPs.addAll(localNetworkIPs);
    } catch (e) {
      print('⚠️ Error obteniendo IPs de red local: $e');
    }

    // 2. IPs del gateway y rangos relacionados
    try {
      final gatewayIPs = await _getGatewayRelatedIPs();
      allIPs.addAll(gatewayIPs);
    } catch (e) {
      print('⚠️ Error obteniendo IPs de gateway: $e');
    }

    // 3. IPs específicas que pueden funcionar con port forwarding
    allIPs.addAll([
      '172.16.206.94',
      '172.16.203.38',
      '192.168.1.2',
      '192.168.1.3',
      '192.168.1.8',
      '192.168.1.100',  // IP común de PC Windows
      '192.168.1.101',
      '192.168.1.102',
      '192.168.1.10',
      '192.168.0.100',
      '192.168.0.101',
      '10.0.0.100',
      '172.17.192.179', // Tu WSL2 IP específica (por si acaso)
    ]);

    return allIPs.toList();
  }

  /// Obtener IPs de la red local del dispositivo Android
  static Future<List<String>> _getLocalNetworkIPs() async {
    final List<String> networkIPs = [];

    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length == 4) {
            final base = '${parts[0]}.${parts[1]}.${parts[2]}';

            // Generar rango de IPs probables para PCs en la red
            for (int i = 1; i <= 254; i += 10) { // Cada 10 para ser más eficiente
              if (i != int.tryParse(parts[3])) { // Evitar la IP del propio celular
                networkIPs.add('$base.$i');
              }
            }
          }
        }
      }
    } catch (e) {
      print('❌ Error listando interfaces de red: $e');
    }

    return networkIPs;
  }

  /// Obtener IPs relacionadas con el gateway
  static Future<List<String>> _getGatewayRelatedIPs() async {
    final List<String> gatewayIPs = [];

    // Rangos comunes de redes domésticas
    final commonRanges = [
      '192.168.1',
      '192.168.0',
      '192.168.100',
      '10.0.0',
      '172.16.0',
    ];

    for (String range in commonRanges) {
      // IPs comunes para el host Windows
      gatewayIPs.addAll([
        '$range.1',
        '$range.100',
        '$range.101',
        '$range.102',
        '$range.10',
        '$range.2',
      ]);
    }

    return gatewayIPs;
  }

  /// Probar IPs en lotes para Android
  static Future<String?> _testIPsInBatches(List<String> ips, int port) async {
    const int batchSize = 3; // Lotes pequeños para Android

    // Priorizar IPs más probables para Android
    final orderedIPs = _prioritizeIPsForAndroid(ips);

    for (int i = 0; i < orderedIPs.length; i += batchSize) {
      final batch = orderedIPs.skip(i).take(batchSize).toList();
      print('🔍 Probando lote ${(i ~/ batchSize) + 1}: ${batch.join(", ")}');

      final futures = batch.map((ip) => _testWhisperService(ip, port)).toList();
      final results = await Future.wait(futures);

      for (int j = 0; j < results.length; j++) {
        if (results[j]) {
          final foundIP = batch[j];
          print('✅ Servidor Whisper encontrado en: $foundIP');
          return foundIP;
        }
      }

      // Pausa entre lotes
      if (i + batchSize < orderedIPs.length) {
        await Future.delayed(Duration(milliseconds: 500));
      }
    }

    print('❌ No se encontró servidor Whisper en ninguna IP');
    return null;
  }

  /// Priorizar IPs más probables para Android
  static List<String> _prioritizeIPsForAndroid(List<String> ips) {
    final priorityOrder = <String>[];
    final remaining = <String>[];

    // Prioridades para conexión desde Android
    final highPriority = [
      '192.168.1.8',
      '172.16.203.38',
      '192.168.1.2',
      '192.168.1.1',
      '192.168.1.3',
      '192.168.1.100',  // IP muy común de PC Windows
      '192.168.1.101',
      '192.168.1.102',
      '192.168.0.100',
      '10.0.0.100',
    ];

    for (String ip in ips) {
      if (highPriority.contains(ip)) {
        priorityOrder.add(ip);
      } else {
        remaining.add(ip);
      }
    }

    // Ordenar prioridades
    priorityOrder.sort((a, b) {
      return highPriority.indexOf(a).compareTo(highPriority.indexOf(b));
    });

    priorityOrder.addAll(remaining);
    return priorityOrder;
  }

  /// Probar servicio Whisper - OPTIMIZADO PARA ANDROID
  static Future<bool> _testWhisperService(String ip, int port) async {
    try {
      print('🔍 Probando Whisper en $ip:$port desde Android');

      final client = http.Client();

      try {
        final response = await client.get(
          Uri.parse('http://$ip:$port/health'),
          headers: {
            'Accept': 'application/json',
            'User-Agent': 'FlutterAndroid/2.0',
            'Connection': 'close',
          },
        ).timeout(SCAN_TIMEOUT);

        if (response.statusCode == 200) {
          try {
            final data = jsonDecode(response.body);

            final isWhisper = data['status'] == 'healthy' &&
                (data['whisper_available'] == true ||
                    data['services']?['whisper'] == true);

            if (isWhisper) {
              print('✅ Whisper confirmado en $ip:$port');
              final model = data['whisper_model'] ?? 'unknown';
              final ros2Status = data['ros2_connected'] ?? data['services']?['ros2'] ?? false;
              print('📦 Modelo: $model, ROS2: $ros2Status');
              return true;
            } else {
              print('❌ $ip:$port responde pero no es nuestro servicio Whisper');
            }
          } catch (jsonError) {
            print('❌ $ip:$port - Error parseando JSON: $jsonError');
          }
        } else {
          print('❌ $ip:$port - HTTP ${response.statusCode}');
        }
      } finally {
        client.close();
      }

      return false;

    } catch (e) {
      // Solo mostrar errores importantes, filtrar timeouts comunes en Android
      if (!e.toString().toLowerCase().contains('timeout') &&
          !e.toString().toLowerCase().contains('refused') &&
          !e.toString().toLowerCase().contains('unreachable')) {
        print('❌ $ip:$port - Error: $e');
      }
      return false;
    }
  }

  /// Verificar si una IP específica tiene Whisper disponible
  static Future<bool> verifyWhisperService(String ip, int port) async {
    return await _testWhisperService(ip, port);
  }

  /// Obtener información completa de red para debugging DESDE ANDROID
  static Future<Map<String, dynamic>> getNetworkDiagnostics() async {
    final diagnostics = <String, dynamic>{};

    try {
      // Interfaces de red del dispositivo Android
      final interfaces = await NetworkInterface.list(includeLoopback: true);
      diagnostics['network_interfaces'] = interfaces.map((interface) => {
        'name': interface.name,
        'addresses': interface.addresses.map((addr) => {
          'address': addr.address,
          'type': addr.type.name,
        }).toList(),
      }).toList();

      // IP del dispositivo Android
      diagnostics['android_device_ip'] = await _getAndroidDeviceIP();

      // Información de gateway estimado
      diagnostics['estimated_gateway'] = await _estimateGatewayIP();

      // Todas las IPs candidatas para Android
      diagnostics['all_candidates'] = await _getAllCandidateIPsForAndroid();

      // Test específico de IPs comunes para Windows host
      diagnostics['windows_host_tests'] = {
        '192.168.1.2:8000': await verifyWhisperService('192.168.1.2', 8000),
        '192.168.1.3:8000': await verifyWhisperService('192.168.1.3', 8000),
        '192.168.1.101:8000': await verifyWhisperService('192.168.1.101', 8000),
        '192.168.0.100:8000': await verifyWhisperService('192.168.0.100', 8000),
      };

    } catch (e) {
      diagnostics['error'] = e.toString();
    }

    return diagnostics;
  }

  /// Obtener IP del dispositivo Android
  static Future<String?> _getAndroidDeviceIP() async {
    try {
      final interfaces = await NetworkInterface.list();
      for (var interface in interfaces) {
        if (interface.name.contains('wlan') || interface.name.contains('wifi')) {
          for (var addr in interface.addresses) {
            if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
              return addr.address;
            }
          }
        }
      }
    } catch (e) {
      print('Error obteniendo IP de Android: $e');
    }
    return null;
  }

  /// Estimar IP del gateway desde Android
  static Future<String?> _estimateGatewayIP() async {
    try {
      final androidIP = await _getAndroidDeviceIP();
      if (androidIP != null) {
        final parts = androidIP.split('.');
        if (parts.length == 4) {
          return '${parts[0]}.${parts[1]}.${parts[2]}.1';
        }
      }
    } catch (e) {
      print('Error estimando gateway: $e');
    }
    return null;
  }

  // Método legacy mantenido por compatibilidad
  static Future<String?> detectWSL2IP() async {
    // En Android, este método no es aplicable, retornamos null
    return null;
  }
}