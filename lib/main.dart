import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'screens/auth/welcome_screen.dart';
import 'screens/voice_navigation_screen.dart';
import 'screens/environment_recognition_screen.dart';
import 'screens/ar_navigation_screen.dart';
import 'services/auth_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await dotenv.load(fileName: ".env");

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'COMPAS - Asistente de Voz',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: _lightTheme(),
      darkTheme: _darkTheme(),
      home: const AuthGate(),
      routes: {
        '/ar': (context) => const ArNavigationScreen(),
        '/camera': (context) => const EnvironmentRecognitionScreen(),
      },
    );
  }
}

////////////////////////////////////////////////////////////
/// AUTH GATE - CORREGIDO
////////////////////////////////////////////////////////////

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final AuthService _authService = AuthService();

  bool _isLoading = true;
  bool _isAuthenticated = false;

  @override
  void initState() {
    super.initState();
    _initializeSession();
  }

  Future<void> _initializeSession() async {
    try {
      // 1️⃣ Verifica si existen tokens guardados
      final hasSession = await _authService.isAuthenticated();

      if (!hasSession) {
        // No hay tokens → ir a login directamente, sin llamar logout
        if (!mounted) return;
        setState(() {
          _isAuthenticated = false;
          _isLoading = false;
        });
        return;
      }

      // 2️⃣ Intenta renovar token automáticamente
      final refreshResponse = await _authService.refreshToken();

      if (!mounted) return;

      if (refreshResponse.success) {
        // ✅ Renovación exitosa → mantener sesión
        setState(() {
          _isAuthenticated = true;
          _isLoading = false;
        });
      } else {
        // ❌ FIX: El refresh falló → limpiar tokens localmente sin llamar
        // al endpoint /logout del servidor, porque ese endpoint requiere
        // un access token válido y además estaba causando que el servidor
        // registrara un logout, confundiendo el flujo de sesión.
        // Solo limpiamos el storage local.
        await _authService.clearLocalSession();

        if (!mounted) return;
        setState(() {
          _isAuthenticated = false;
          _isLoading = false;
        });
      }
    } catch (e) {
      // Error inesperado → limpiar solo localmente
      await _authService.clearLocalSession();

      if (!mounted) return;
      setState(() {
        _isAuthenticated = false;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return _isAuthenticated ? const MainScreen() : const WelcomeScreen();
  }
}

////////////////////////////////////////////////////////////
/// MAIN SCREEN
////////////////////////////////////////////////////////////

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  final List<Widget> _screens = const [
    VoiceNavigationScreen(),
    EnvironmentRecognitionScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() => _currentIndex = index);
          HapticFeedback.mediumImpact();
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.mic, size: 30),
            label: 'Comandos de Voz',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.videocam, size: 30),
            label: 'Reconocimiento',
          ),
        ],
      ),
    );
  }
}

////////////////////////////////////////////////////////////
/// THEMES
////////////////////////////////////////////////////////////

ThemeData _darkTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: const ColorScheme.dark(
      primary: Color(0xFFFF6B00),
      onPrimary: Color(0xFFFFFFFF),
      secondary: Color(0xFFFFFFFF),
      onSecondary: Color(0xFF00162D),
      surface: Color(0xFF00162D),
      onSurface: Color(0xFFFFFFFF),
      error: Color(0xFFFF4D4F),
      onError: Color(0xFFFFFFFF),
    ),
    scaffoldBackgroundColor: const Color(0xFF00162D),
  );
}

ThemeData _lightTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: const ColorScheme.light(
      primary: Color(0xFFFF6B00),
      onPrimary: Color(0xFFFFFFFF),
      secondary: Color(0xFF00162D),
      onSecondary: Color(0xFFFFFFFF),
      surface: Color(0xFFFFFFFF),
      onSurface: Color(0xFF00162D),
    ),
  );
}