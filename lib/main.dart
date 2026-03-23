// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'screens/auth/welcome_screen.dart';
import 'screens/ar_navigation_screen.dart';
import 'services/auth_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
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
      },
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// AUTH GATE
// ════════════════════════════════════════════════════════════════════════════

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final AuthService _authService = AuthService();

  bool _isLoading       = true;
  bool _isAuthenticated = false;

  @override
  void initState() {
    super.initState();
    _initializeSession();
  }

  Future<void> _initializeSession() async {
    try {
      final hasSession = await _authService.isAuthenticated();
      if (!hasSession) {
        debugPrint('🔓 Sin tokens → ir a login');
        _goTo(authenticated: false);
        return;
      }

      final tokenValid = await _authService.isAccessTokenValid();
      if (tokenValid) {
        debugPrint('✅ Token vigente → sesión activa');
        _goTo(authenticated: true);
        return;
      }

      debugPrint('⏰ Token expirado → intentando renovar');
      final hasRefresh = await _authService.hasRefreshToken();
      if (!hasRefresh) {
        debugPrint('⚠️ Sin refresh token → login');
        await _authService.clearLocalSession();
        _goTo(authenticated: false);
        return;
      }

      final refreshResponse = await _authService.refreshToken();
      if (!mounted) return;

      if (refreshResponse.success) {
        debugPrint('✅ Token renovado → sesión activa');
        _goTo(authenticated: true);
      } else {
        debugPrint('❌ Refresh falló → login');
        await _authService.clearLocalSession();
        _goTo(authenticated: false);
      }
    } catch (e) {
      debugPrint('⚠️ Error en AuthGate: $e → conservando tokens');
      if (!mounted) return;
      final stillHasSession = await _authService.isAuthenticated();
      _goTo(authenticated: stillHasSession);
    }
  }

  void _goTo({required bool authenticated}) {
    if (!mounted) return;
    setState(() {
      _isAuthenticated = authenticated;
      _isLoading       = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 24),
              Text(
                'Verificando sesión...',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // ✅ Fix: sesión activa → ArNavigationScreen directamente
    return _isAuthenticated ? const ArNavigationScreen() : const WelcomeScreen();
  }
}

// ════════════════════════════════════════════════════════════════════════════
// THEMES
// ════════════════════════════════════════════════════════════════════════════

ThemeData _darkTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: const ColorScheme.dark(
      primary:     Color(0xFFFF6B00),
      onPrimary:   Color(0xFFFFFFFF),
      secondary:   Color(0xFFFFFFFF),
      onSecondary: Color(0xFF00162D),
      surface:     Color(0xFF00162D),
      onSurface:   Color(0xFFFFFFFF),
      error:       Color(0xFFFF4D4F),
      onError:     Color(0xFFFFFFFF),
    ),
    scaffoldBackgroundColor: const Color(0xFF00162D),
  );
}

ThemeData _lightTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: const ColorScheme.light(
      primary:     Color(0xFFFF6B00),
      onPrimary:   Color(0xFFFFFFFF),
      secondary:   Color(0xFF00162D),
      onSecondary: Color(0xFFFFFFFF),
      surface:     Color(0xFFFFFFFF),
      onSurface:   Color(0xFF00162D),
    ),
  );
}