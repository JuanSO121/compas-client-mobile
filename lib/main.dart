// lib/main.dart - VERSIÓN SIMPLIFICADA
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/auth/welcome_screen.dart';
import 'screens/voice_navigation_screen.dart';
import 'screens/environment_recognition_screen.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 🔑 Cargar variables de entorno
  await dotenv.load(fileName: ".env");

  // Bloquear orientación vertical
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
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: const ColorScheme.light(
          primary: Color(0xFFFFB300),
          secondary: Color(0xFF2E7D32),
          error: Color(0xFFC62828),
          surface: Colors.white,
          onSurface: Color(0xFF212121),
        ),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(fontSize: 18, height: 1.5),
          bodyMedium: TextStyle(fontSize: 16, height: 1.5),
          titleLarge: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          titleMedium: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
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
        ),
      ),
      themeMode: ThemeMode.system,
      home: const WelcomeScreen(),
      routes: {
        '/voice': (context) => const VoiceNavigationScreen(),
        '/camera': (context) => const EnvironmentRecognitionScreen(),
      },
      debugShowCheckedModeBanner: false,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// ✅ PANTALLA PRINCIPAL CON NAVEGACIÓN SIMPLIFICADA (2 TABS)
// ═══════════════════════════════════════════════════════════════════
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
            icon: Icon(Icons.mic),
            label: 'Comandos de Voz',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.videocam),
            label: 'Reconocimiento',
          ),
        ],
      ),
    );
  }
}