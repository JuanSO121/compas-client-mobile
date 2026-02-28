import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/auth/welcome_screen.dart';
import 'screens/voice_navigation_screen.dart';
import 'screens/environment_recognition_screen.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'screens/ar_navigation_screen.dart';

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

      home: const WelcomeScreen(),

      routes: {
        '/ar': (context) => const ArNavigationScreen(),
        '/camera': (context) => const EnvironmentRecognitionScreen(),
      },
    );
  }
}

ThemeData _darkTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,

    colorScheme: const ColorScheme.dark(
      primary: Color(0xFFFF6B00),        // 🔥 Nuevo naranja
      onPrimary: Color(0xFFFFFFFF),

      secondary: Color(0xFFFFFFFF),
      onSecondary: Color(0xFF00162D),

      background: Color(0xFF00162D),     // Azul profundo
      surface: Color(0xFF00162D),

      onSurface: Color(0xFFFFFFFF),
      onBackground: Color(0xFFFFFFFF),

      error: Color(0xFFFF4D4F),
      onError: Color(0xFFFFFFFF),
    ),

    scaffoldBackgroundColor: const Color(0xFF00162D),

    textTheme: const TextTheme(
      bodyLarge: TextStyle(
        fontSize: 20,
        height: 1.6,
        fontWeight: FontWeight.w500,
      ),
      bodyMedium: TextStyle(
        fontSize: 18,
        height: 1.6,
      ),
      titleLarge: TextStyle(
        fontSize: 26,
        fontWeight: FontWeight.bold,
      ),
      titleMedium: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
      ),
    ),

    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: Color(0xFF00162D),
      selectedItemColor: Color(0xFFFF6B00),  // 🔥 Activo en naranja
      unselectedItemColor: Colors.white70,
      selectedLabelStyle: TextStyle(fontSize: 16),
      unselectedLabelStyle: TextStyle(fontSize: 14),
    ),

    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFFFF6B00), // 🔥 Botones naranja
        foregroundColor: const Color(0xFFFFFFFF),
        textStyle: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
        padding: const EdgeInsets.symmetric(
          vertical: 18,
          horizontal: 24,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    ),
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
      background: Color(0xFFF5F5F5),
      surface: Color(0xFFFFFFFF),
      onSurface: Color(0xFF00162D),
      onBackground: Color(0xFF00162D),
    ),
  );
}

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
