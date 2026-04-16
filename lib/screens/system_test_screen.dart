// lib/screens/system_test_screen.dart
// ✅ v2.0 — Pantalla de pruebas del sistema COMPAS (CORREGIDA)
//
// CORRECCIONES v1.0 → v2.0
// ─────────────────────────────────────────────────────────────────────────
//
//  BUG 1 — Pantalla trabada en pruebas "automáticas":
//    Las pruebas P-01, P-06 y P-09 llamaban _measureNavigateTo() y
//    _measureCreateWaypoint() que hacen await sobre un Completer que
//    solo se resuelve cuando llega una respuesta del bridge de Unity.
//    Si el bridge no está ready (o la escena AR no está activa), el
//    Future nunca completa → UI congelada hasta el timeout de 8-10s,
//    y aun así registraba un fallo inútil.
//
//    FIX: Todas las pruebas son MANUALES. El evaluador ejecuta la acción
//    en la app y registra el resultado (éxito/fallo + nota + valor medido).
//    No hay ningún await pendiente de Unity.
//
//  BUG 2 — isAutomatic = true generaba un botón "Ejecutar" que llamaba
//    _runAutoAttempt(), el cual dependía del bridge. Eliminado por completo.
//
//  BUG 3 — _responseSubscription nunca se cancelaba correctamente en
//    caso de timeout porque estaba fuera del finally.
//
//  BUG 4 — setState() se llamaba tras dispose() si el usuario salía
//    durante una prueba automática en curso. Añadido guard mounted.
//
//  BUG 5 — El campo de nota (_noteCtrl) era compartido entre pruebas,
//    causando que la nota de una prueba apareciera en la siguiente.
//    Ahora cada prueba tiene su propio TextEditingController local
//    creado con StatefulBuilder.
//
//  MEJORA: P-04 ahora muestra contadores acumulados de TP/FP/FN en
//    tiempo real para facilitar la toma de decisión durante la prueba.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ─── Enums ────────────────────────────────────────────────────────────────

enum TestStatus { pending, running, passed, failed, skipped }

enum TestCategory { navigation, obstacle, voice }

// ─── Modelo de intento ────────────────────────────────────────────────────

class TestAttempt {
  final int number;
  final bool success;
  final String? note;
  final DateTime timestamp;
  final double? measuredValue;

  TestAttempt({
    required this.number,
    required this.success,
    this.note,
    this.measuredValue,
  }) : timestamp = DateTime.now();
}

// ─── Modelo de prueba ─────────────────────────────────────────────────────

class SystemTest {
  final String id;
  final String name;
  final String condition;
  final String expectedResult;
  final TestCategory category;
  final int totalAttempts;
  final String? unit;

  // Instrucciones paso a paso para el evaluador
  final List<String> steps;

  TestStatus status = TestStatus.pending;
  final List<TestAttempt> attempts = [];

  SystemTest({
    required this.id,
    required this.name,
    required this.condition,
    required this.expectedResult,
    required this.category,
    required this.steps,
    this.totalAttempts = 5,
    this.unit,
  });

  int get successCount => attempts.where((a) => a.success).length;
  int get failCount => attempts.where((a) => !a.success).length;
  double get successRate =>
      attempts.isEmpty ? 0 : successCount / attempts.length * 100;
  double? get avgMeasuredValue {
    final vals = attempts
        .where((a) => a.measuredValue != null)
        .map((a) => a.measuredValue!)
        .toList();
    if (vals.isEmpty) return null;
    return vals.reduce((a, b) => a + b) / vals.length;
  }

  bool get isComplete => attempts.length >= totalAttempts;

  String get summaryLine {
    switch (category) {
      case TestCategory.navigation:
        return '$successCount/$totalAttempts exitosas';
      case TestCategory.obstacle:
        if (id == 'P-04') {
          final fp = attempts.where((a) => a.note == 'FP').length;
          final fn = attempts.where((a) => a.note == 'FN').length;
          return 'FP=$fp  FN=$fn  (lím. <3)';
        }
        return '$successCount/$totalAttempts avisos correctos';
      case TestCategory.voice:
        return '${successRate.toStringAsFixed(0)}% éxito ($successCount/${attempts.length})';
    }
  }
}

// ─── Pantalla principal ───────────────────────────────────────────────────

class SystemTestScreen extends StatefulWidget {
  const SystemTestScreen({super.key});

  @override
  State<SystemTestScreen> createState() => _SystemTestScreenState();
}

class _SystemTestScreenState extends State<SystemTestScreen> {
  late final List<SystemTest> _tests;
  int _activeIndex = 0;
  bool _sessionFinished = false;
  String? _exportText;

  @override
  void initState() {
    super.initState();
    _buildTests();
  }

  // ─── Definición de pruebas ─────────────────────────────────────────────

  void _buildTests() {
    _tests = [
      // ── NAVEGACIÓN ────────────────────────────────────────────────────
      SystemTest(
        id: 'P-01',
        name: 'Generación de ruta',
        condition: 'Petición del usuario (waypoint existente)',
        expectedResult: 'Sistema calcula la ruta y comienza la navegación',
        category: TestCategory.navigation,
        totalAttempts: 5,
        steps: [
          'Asegúrate de tener al menos un waypoint guardado en la escena AR.',
          'Di: "Oye COMPAS, llévame a [nombre del waypoint]".',
          'Observa si el agente AR inicia el recorrido hacia el destino.',
          'Registra si la navegación comenzó (éxito) o no (fallo).',
        ],
      ),
      SystemTest(
        id: 'P-02',
        name: 'Recalcular ruta',
        condition: 'Obstáculo detectado durante navegación activa',
        expectedResult: 'Sistema recalcula la ruta y retoma la navegación',
        category: TestCategory.navigation,
        totalAttempts: 3,
        steps: [
          'Inicia una navegación con P-01.',
          'Coloca un objeto físico en el camino del agente.',
          'Observa si el sistema detecta el obstáculo y anuncia una nueva ruta.',
          'Confirma que el agente continúa hacia el destino por la nueva ruta.',
        ],
      ),
      SystemTest(
        id: 'P-03',
        name: 'Precisión de la guía',
        condition: 'Finalización de navegación',
        expectedResult: 'Usuario a ≤ 0.5 m del destino al finalizar',
        category: TestCategory.navigation,
        totalAttempts: 5,
        unit: 'm',
        steps: [
          'Completa una navegación hasta que el sistema anuncie llegada.',
          'Mide con una cinta métrica o app de AR la distancia real al waypoint.',
          'Ingresa la distancia medida en el campo de valor.',
          'Se marca como éxito automáticamente si la distancia es ≤ 0.5 m.',
        ],
      ),
      // ── OBSTÁCULOS ────────────────────────────────────────────────────
      SystemTest(
        id: 'P-04',
        name: 'Detección de obstáculos',
        condition: 'Modo navegación activo con cámara recibiendo imágenes',
        expectedResult: 'Registrar FP y FN. Tolerancia máxima: 3 de cada tipo.',
        category: TestCategory.obstacle,
        totalAttempts: 10,
        steps: [
          'Inicia una navegación activa.',
          'Coloca y quita obstáculos reales en el campo de visión de la cámara.',
          'Por cada evento de detección registra su tipo usando los botones.',
          'TP = obstáculo real detectado correctamente.',
          'FP = alerta de obstáculo sin obstáculo real presente.',
          'FN = obstáculo real presente pero NO detectado (ninguna alerta).',
        ],
      ),
      SystemTest(
        id: 'P-05',
        name: 'Aviso auditivo de obstáculos',
        condition: 'Sistema detecta un obstáculo durante navegación',
        expectedResult: 'Sistema alerta mediante audio la presencia del obstáculo',
        category: TestCategory.obstacle,
        totalAttempts: 5,
        steps: [
          'Inicia navegación activa.',
          'Coloca un obstáculo real frente a la cámara.',
          'Espera la respuesta del sistema (máx. 3 segundos).',
          'Registra si el aviso de voz se reprodujo correctamente.',
        ],
      ),
      // ── COMANDOS DE VOZ ───────────────────────────────────────────────
      SystemTest(
        id: 'P-06',
        name: 'Iniciar navegación por voz',
        condition: 'Usuario pide ser guiado a un punto mediante voz',
        expectedResult: 'Sistema inicia la navegación hacia la ubicación solicitada',
        category: TestCategory.voice,
        totalAttempts: 5,
        steps: [
          'Di: "Oye COMPAS" y espera el tono de activación.',
          'Cuando el micrófono esté listo, di: "llévame a [nombre]".',
          'Verifica que el agente AR inicie el recorrido.',
          'Si el sistema respondió y navegó: éxito. Si no: fallo.',
        ],
      ),
      SystemTest(
        id: 'P-07',
        name: 'Detener navegación por voz',
        condition: 'Usuario pide detener el sistema guía',
        expectedResult: 'Sistema detiene la navegación',
        category: TestCategory.voice,
        totalAttempts: 5,
        steps: [
          'Con navegación activa, di: "Oye COMPAS" y espera el tono.',
          'Di: "para" o "detente" o "cancelar navegación".',
          'Verifica que el agente AR se detiene y el sistema confirma.',
        ],
      ),
      SystemTest(
        id: 'P-08',
        name: 'Listar waypoints disponibles',
        condition: 'Usuario pregunta cuáles son los destinos disponibles',
        expectedResult: 'Sistema responde mediante audio con los waypoints existentes',
        category: TestCategory.voice,
        totalAttempts: 3,
        steps: [
          'Di: "Oye COMPAS" y espera el tono.',
          'Di: "¿a dónde puedo ir?" o "lista de destinos".',
          'Verifica que el sistema responde enumerando los waypoints por voz.',
        ],
      ),
      SystemTest(
        id: 'P-09',
        name: 'Crear waypoint por voz',
        condition: 'Usuario pide crear un nuevo punto de destino en su ubicación',
        expectedResult: 'Sistema crea y guarda el nuevo waypoint',
        category: TestCategory.voice,
        totalAttempts: 3,
        steps: [
          'Sitúate físicamente en la ubicación donde quieres crear el waypoint.',
          'Di: "Oye COMPAS" y espera el tono.',
          'Di: "crea un punto aquí" o "guarda esta ubicación como [nombre]".',
          'Verifica en el panel de debugging que el waypoint aparece en la lista.',
        ],
      ),
      SystemTest(
        id: 'P-10',
        name: 'Eliminar un waypoint por voz',
        condition: 'Usuario pide eliminar un punto de destino existente',
        expectedResult: 'Sistema elimina el waypoint indicado',
        category: TestCategory.voice,
        totalAttempts: 3,
        steps: [
          'Asegúrate de tener al menos 2 waypoints guardados.',
          'Di: "Oye COMPAS" y espera el tono.',
          'Di: "elimina el punto [nombre]".',
          'Verifica que el waypoint desaparece de la lista.',
        ],
      ),
      SystemTest(
        id: 'P-11',
        name: 'Eliminar todos los waypoints',
        condition: 'Usuario pide eliminar todos los destinos guardados',
        expectedResult: 'Sistema elimina todos los waypoints',
        category: TestCategory.voice,
        totalAttempts: 3,
        steps: [
          'Asegúrate de tener varios waypoints guardados.',
          'Di: "Oye COMPAS" y espera el tono.',
          'Di: "elimina todos los puntos" o "borrar todo".',
          'Verifica que la lista de waypoints queda vacía.',
        ],
      ),
    ];
  }

  // ─── Lógica de registro ────────────────────────────────────────────────

  void _recordAttempt(SystemTest test, bool success,
      {double? value, String? note}) {
    if (!mounted) return;
    setState(() {
      test.attempts.add(TestAttempt(
        number: test.attempts.length + 1,
        success: success,
        measuredValue: value,
        note: note,
      ));
      if (test.isComplete) {
        // Criterio de aprobación por categoría
        if (test.id == 'P-04') {
          final fp = test.attempts.where((a) => a.note == 'FP').length;
          final fn = test.attempts.where((a) => a.note == 'FN').length;
          test.status =
          (fp < 3 && fn < 3) ? TestStatus.passed : TestStatus.failed;
        } else {
          test.status = test.successCount >= (test.totalAttempts * 0.6).ceil()
              ? TestStatus.passed
              : TestStatus.failed;
        }
      }
    });
    HapticFeedback.lightImpact();
  }

  // ─── Navegación entre pruebas ──────────────────────────────────────────

  void _nextTest() {
    if (_activeIndex < _tests.length - 1) {
      setState(() => _activeIndex++);
    } else {
      _finishSession();
    }
  }

  void _prevTest() {
    if (_activeIndex > 0) setState(() => _activeIndex--);
  }

  // ─── Finalizar ────────────────────────────────────────────────────────

  void _finishSession() {
    if (!mounted) return;
    setState(() {
      _sessionFinished = true;
      _exportText = _buildExportText();
    });
  }

  String _buildExportText() {
    final buf = StringBuffer();
    final now = DateTime.now();
    final dateStr =
        '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}'
        '  ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    buf.writeln('═══════════════════════════════════════════════════');
    buf.writeln('  RESULTADOS DE PRUEBAS — SISTEMA COMPAS');
    buf.writeln('  Fecha: $dateStr');
    buf.writeln('═══════════════════════════════════════════════════');
    buf.writeln();

    void writeSection(String title, String metric, TestCategory cat) {
      buf.writeln('─── $title');
      buf.writeln('Métrica: $metric');
      buf.writeln();
      for (final t in _tests.where((t) => t.category == cat)) {
        buf.writeln('[${t.id}] ${t.name}');
        buf.writeln('  Resultado: ${t.summaryLine}');
        if (t.unit != null && t.avgMeasuredValue != null) {
          buf.writeln(
              '  Promedio medido: ${t.avgMeasuredValue!.toStringAsFixed(2)} ${t.unit}');
        }
        for (final a in t.attempts) {
          final sym = a.success ? '✓' : '✗';
          final val = a.measuredValue != null
              ? ' ${a.measuredValue!.toStringAsFixed(2)} ${t.unit ?? ''}'
              : '';
          final note = a.note != null && a.note!.isNotEmpty ? '  [${a.note}]' : '';
          buf.writeln('  Intento ${a.number}: $sym$val$note');
        }
        buf.writeln();
      }
    }

    writeSection('PRUEBAS DE NAVEGACIÓN (P-01 a P-03)',
        'pruebas exitosas / total de pruebas', TestCategory.navigation);
    writeSection('PRUEBAS DE DETECCIÓN DE OBSTÁCULOS (P-04 a P-05)',
        'FP y FN < 3', TestCategory.obstacle);
    writeSection('PRUEBAS DE COMANDOS DE VOZ (P-06 a P-11)',
        '(solicitudes correctas / total) × 100', TestCategory.voice);

    // Totales voz
    final vTests = _tests.where((t) => t.category == TestCategory.voice);
    int vTotal = vTests.fold(0, (s, t) => s + t.attempts.length);
    int vOk = vTests.fold(0, (s, t) => s + t.successCount);
    final vPct = vTotal > 0 ? (vOk / vTotal * 100).toStringAsFixed(1) : '--';

    buf.writeln('  TOTAL VOZ: $vOk/$vTotal solicitudes = $vPct%');
    buf.writeln();

    int passed = _tests.where((t) => t.status == TestStatus.passed).length;
    int failed = _tests.where((t) => t.status == TestStatus.failed).length;
    int pending = _tests
        .where((t) =>
    t.status != TestStatus.passed && t.status != TestStatus.failed)
        .length;

    buf.writeln('═══════════════════════════════════════════════════');
    buf.writeln('  RESUMEN GLOBAL');
    buf.writeln('  Superadas: $passed/${_tests.length}');
    buf.writeln('  Fallidas:  $failed/${_tests.length}');
    buf.writeln('  Pendientes: $pending/${_tests.length}');
    buf.writeln('  Tasa voz:  $vPct%');
    buf.writeln('═══════════════════════════════════════════════════');
    buf.writeln('  — COMPAS System Test v2.0 —');

    return buf.toString();
  }

  void _copyToClipboard() {
    if (_exportText == null) return;
    Clipboard.setData(ClipboardData(text: _exportText!));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('✅ Resultados copiados al portapapeles'),
        backgroundColor: Color(0xFF2E7D32),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ─── Colores ──────────────────────────────────────────────────────────

  static Color _catColor(TestCategory c) => switch (c) {
    TestCategory.navigation => const Color(0xFF1565C0),
    TestCategory.obstacle => const Color(0xFFB71C1C),
    TestCategory.voice => const Color(0xFF4A148C),
  };

  static Color _catAccent(TestCategory c) => switch (c) {
    TestCategory.navigation => const Color(0xFF90CAF9),
    TestCategory.obstacle => const Color(0xFFEF9A9A),
    TestCategory.voice => const Color(0xFFCE93D8),
  };

  static String _catLabel(TestCategory c) => switch (c) {
    TestCategory.navigation => 'NAVEGACIÓN',
    TestCategory.obstacle => 'OBSTÁCULOS',
    TestCategory.voice => 'VOZ',
  };

  static Color _statusColor(TestStatus s) => switch (s) {
    TestStatus.pending => const Color(0xFF616161),
    TestStatus.running => const Color(0xFFF9A825),
    TestStatus.passed => const Color(0xFF2E7D32),
    TestStatus.failed => const Color(0xFFC62828),
    TestStatus.skipped => const Color(0xFF37474F),
  };

  static String _statusLabel(TestStatus s) => switch (s) {
    TestStatus.pending => 'Pendiente',
    TestStatus.running => 'En curso',
    TestStatus.passed => '✅ Superada',
    TestStatus.failed => '❌ Fallida',
    TestStatus.skipped => '⏭ Omitida',
  };

  // ═════════════════════════════════════════════════════════════════════════
  //  BUILD
  // ═════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF060914),
      appBar: _buildAppBar(),
      body: _sessionFinished ? _buildResultsView() : _buildTestingView(),
    );
  }

  // ─── AppBar ───────────────────────────────────────────────────────────

  PreferredSizeWidget _buildAppBar() {
    final done = _tests.where((t) => t.isComplete).length;
    return AppBar(
      backgroundColor: const Color(0xFF0A0D1E),
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios_new_rounded,
            color: Colors.white70, size: 18),
        onPressed: () => Navigator.of(context).pop(),
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Pruebas del Sistema',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700)),
          Text('$done / ${_tests.length} completadas',
              style: const TextStyle(
                  color: Color(0xFF90CAF9), fontSize: 11)),
        ],
      ),
      actions: [
        if (!_sessionFinished)
          TextButton(
            onPressed: _finishSession,
            child: const Text('Finalizar',
                style: TextStyle(
                    color: Color(0xFF80CBC4), fontSize: 12)),
          ),
        if (_sessionFinished)
          IconButton(
            onPressed: _copyToClipboard,
            icon: const Icon(Icons.copy_rounded,
                color: Color(0xFF80CBC4), size: 20),
            tooltip: 'Copiar resultados',
          ),
        const SizedBox(width: 4),
      ],
    );
  }

  // ─── Vista principal de testing ───────────────────────────────────────

  Widget _buildTestingView() {
    return Column(
      children: [
        _buildProgressBar(),
        Expanded(
          child: Row(
            children: [
              _buildSidebar(),
              Expanded(child: _buildActivePanel()),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildProgressBar() {
    final done = _tests.where((t) => t.isComplete).length;
    return Container(
      height: 4,
      color: const Color(0xFF0A0D1E),
      child: LinearProgressIndicator(
        value: done / _tests.length,
        backgroundColor: Colors.white12,
        valueColor: const AlwaysStoppedAnimation(Color(0xFF1976D2)),
        minHeight: 4,
      ),
    );
  }

  Widget _buildSidebar() {
    return Container(
      width: 52,
      color: const Color(0xFF080B18),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _tests.length,
        itemBuilder: (_, i) {
          final t = _tests[i];
          final isActive = i == _activeIndex;
          return GestureDetector(
            onTap: () => setState(() => _activeIndex = i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              margin: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: isActive
                    ? _catColor(t.category).withOpacity(0.65)
                    : Colors.white.withOpacity(0.04),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                  color: isActive
                      ? _catAccent(t.category)
                      : Colors.white.withOpacity(0.08),
                  width: isActive ? 1.5 : 0.5,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    t.id.replaceAll('P-', ''),
                    style: TextStyle(
                      color: isActive ? Colors.white : Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  _statusDot(t),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _statusDot(SystemTest t) {
    Color c;
    if (t.status == TestStatus.passed) {
      c = Colors.greenAccent;
    } else if (t.status == TestStatus.failed) {
      c = Colors.redAccent;
    } else if (t.attempts.isNotEmpty) {
      c = Colors.amberAccent;
    } else {
      c = Colors.white24;
    }
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(color: c, shape: BoxShape.circle),
    );
  }

  Widget _buildActivePanel() {
    final test = _tests[_activeIndex];
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTestHeader(test),
          const SizedBox(height: 14),
          _buildStepsCard(test),
          const SizedBox(height: 14),
          if (test.attempts.isNotEmpty) ...[
            _buildAttemptsSection(test),
            const SizedBox(height: 14),
          ],
          if (!test.isComplete) _buildActionSection(test),
          if (test.isComplete) _buildCompletedBanner(test),
          const SizedBox(height: 20),
          _buildNavButtons(test),
        ],
      ),
    );
  }

  Widget _buildTestHeader(SystemTest test) {
    return Row(children: [
      _pill(_catLabel(test.category), _catColor(test.category),
          _catAccent(test.category)),
      const SizedBox(width: 8),
      _pill(test.id, const Color(0xFF1A237E), const Color(0xFF90CAF9)),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          test.name,
          style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w700),
        ),
      ),
      Text(
        '${test.attempts.length}/${test.totalAttempts}',
        style: const TextStyle(color: Colors.white38, fontSize: 11),
      ),
    ]);
  }

  Widget _pill(String label, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg.withOpacity(0.4),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: fg.withOpacity(0.5)),
      ),
      child: Text(label,
          style: TextStyle(
              color: fg,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8)),
    );
  }

  Widget _buildStepsCard(SystemTest test) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.checklist_rounded,
                color: Color(0xFF90CAF9), size: 14),
            const SizedBox(width: 6),
            const Text('Pasos para el evaluador',
                style: TextStyle(
                    color: Color(0xFF90CAF9),
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 10),
          ...test.steps.asMap().entries.map((e) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 18,
                  height: 18,
                  margin: const EdgeInsets.only(right: 8, top: 1),
                  decoration: BoxDecoration(
                    color: _catColor(test.category).withOpacity(0.5),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Center(
                    child: Text(
                      '${e.key + 1}',
                      style: TextStyle(
                          color: _catAccent(test.category),
                          fontSize: 9,
                          fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
                Expanded(
                  child: Text(e.value,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 12, height: 1.4)),
                ),
              ],
            ),
          )),
          const SizedBox(height: 4),
          Text(
            'Resultado esperado: ${test.expectedResult}',
            style: const TextStyle(
                color: Colors.white38,
                fontSize: 11,
                fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }

  // ─── Sección de intentos registrados ─────────────────────────────────

  Widget _buildAttemptsSection(SystemTest test) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Intentos registrados',
            style: TextStyle(
                color: Colors.white54,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.8)),
        const SizedBox(height: 8),
        ...test.attempts.map((a) => _attemptTile(a, test)),
        if (test.unit != null && test.avgMeasuredValue != null)
          _avgBadge(test),
        if (test.id == 'P-04') _p04Counters(test),
      ],
    );
  }

  Widget _avgBadge(SystemTest test) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1E3A),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.analytics_outlined,
            size: 13, color: Color(0xFF90CAF9)),
        const SizedBox(width: 6),
        Text(
          'Promedio: ${test.avgMeasuredValue!.toStringAsFixed(2)} ${test.unit}',
          style:
          const TextStyle(color: Color(0xFF90CAF9), fontSize: 11),
        ),
      ]),
    );
  }

  Widget _p04Counters(SystemTest test) {
    final tp = test.attempts.where((a) => a.note == 'TP').length;
    final fp = test.attempts.where((a) => a.note == 'FP').length;
    final fn = test.attempts.where((a) => a.note == 'FN').length;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: (fp >= 3 || fn >= 3) ? Colors.redAccent : Colors.white12,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _counterBadge('TP', tp, Colors.greenAccent),
          _counterBadge('FP', fp, fp >= 3 ? Colors.redAccent : Colors.orange),
          _counterBadge('FN', fn, fn >= 3 ? Colors.redAccent : Colors.orange),
          Text(
            (fp < 3 && fn < 3) ? '✓ Dentro del límite' : '✗ Límite superado',
            style: TextStyle(
              color: (fp < 3 && fn < 3)
                  ? Colors.greenAccent
                  : Colors.redAccent,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _counterBadge(String label, int val, Color c) {
    return Column(children: [
      Text(val.toString(),
          style:
          TextStyle(color: c, fontSize: 20, fontWeight: FontWeight.w800)),
      Text(label, style: const TextStyle(color: Colors.white38, fontSize: 10)),
    ]);
  }

  Widget _attemptTile(TestAttempt a, SystemTest test) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: a.success
            ? Colors.green.withOpacity(0.08)
            : Colors.red.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: a.success
              ? Colors.greenAccent.withOpacity(0.25)
              : Colors.redAccent.withOpacity(0.25),
        ),
      ),
      child: Row(children: [
        Icon(
          a.success ? Icons.check_circle : Icons.cancel,
          size: 14,
          color: a.success ? Colors.greenAccent : Colors.redAccent,
        ),
        const SizedBox(width: 8),
        Text('Intento ${a.number}',
            style: const TextStyle(color: Colors.white70, fontSize: 12)),
        if (a.measuredValue != null) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '${a.measuredValue!.toStringAsFixed(2)} ${test.unit ?? ''}',
              style: const TextStyle(
                  color: Color(0xFF90CAF9), fontSize: 10),
            ),
          ),
        ],
        if (a.note != null && a.note!.isNotEmpty) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Text(a.note!,
                style:
                const TextStyle(color: Colors.white38, fontSize: 10),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ]),
    );
  }

  // ─── Sección de acción según tipo de prueba ───────────────────────────

  Widget _buildActionSection(SystemTest test) {
    if (test.id == 'P-03') return _buildP03Panel(test);
    if (test.id == 'P-04') return _buildP04Panel(test);
    return _buildDefaultPanel(test);
  }

  // ── P-03: Ingresa distancia medida ────────────────────────────────────

  Widget _buildP03Panel(SystemTest test) {
    final distCtrl = TextEditingController();
    return StatefulBuilder(builder: (_, setLocal) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Ingresa la distancia real medida al destino al finalizar:',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: TextField(
                controller: distCtrl,
                keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: _inputDeco('Distancia en metros (ej: 0.35)'),
                onChanged: (_) => setLocal(() {}),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: distCtrl.text.trim().isEmpty
                  ? null
                  : () {
                final v = double.tryParse(
                    distCtrl.text.trim().replaceAll(',', '.'));
                if (v == null) return;
                _recordAttempt(test, v <= 0.5,
                    value: v,
                    note:
                    '${v.toStringAsFixed(2)} m${v <= 0.5 ? '' : ' — supera 0.5 m'}');
                distCtrl.clear();
                setLocal(() {});
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1565C0),
                disabledBackgroundColor: Colors.white12,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(
                    vertical: 14, horizontal: 16),
              ),
              child: const Text('Registrar',
                  style: TextStyle(color: Colors.white, fontSize: 12)),
            ),
          ]),
          const SizedBox(height: 4),
          const Text('✓ Éxito automático si ≤ 0.5 m',
              style: TextStyle(color: Colors.white38, fontSize: 10)),
        ],
      );
    });
  }

  // ── P-04: Botones TP / FP / FN ────────────────────────────────────────

  Widget _buildP04Panel(SystemTest test) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Durante la navegación registra cada evento de detección:',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: _bigBtn(
              'Correcto (TP)',
              'Obstáculo real detectado',
              const Color(0xFF1B5E20),
              const Color(0xFFA5D6A7),
              Icons.check_circle_rounded,
                  () => _recordAttempt(test, true, note: 'TP'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _bigBtn(
              'Falso Positivo (FP)',
              'Alerta sin obstáculo real',
              const Color(0xFFE65100),
              const Color(0xFFFFCC80),
              Icons.warning_amber_rounded,
                  () => _recordAttempt(test, false, note: 'FP'),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        _bigBtn(
          'Falso Negativo (FN)',
          'Obstáculo real NO detectado (sin alerta)',
          const Color(0xFFB71C1C),
          const Color(0xFFEF9A9A),
          Icons.visibility_off_rounded,
              () => _recordAttempt(test, false, note: 'FN'),
        ),
      ],
    );
  }

  // ── Panel manual genérico con campo de nota ───────────────────────────

  Widget _buildDefaultPanel(SystemTest test) {
    // StatefulBuilder para que el controller sea local a esta prueba
    return StatefulBuilder(builder: (_, setLocal) {
      final noteCtrl = TextEditingController();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: noteCtrl,
            style: const TextStyle(color: Colors.white, fontSize: 12),
            maxLines: 2,
            decoration: _inputDeco(
                'Nota opcional (ej: comando reconocido, error observado)'),
            onChanged: (_) => setLocal(() {}),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: _bigBtn(
                'Éxito',
                'Sistema respondió correctamente',
                const Color(0xFF1B5E20),
                const Color(0xFFA5D6A7),
                Icons.check_circle_rounded,
                    () {
                  final note = noteCtrl.text.trim();
                  _recordAttempt(test, true,
                      note: note.isEmpty ? null : note);
                  noteCtrl.clear();
                  setLocal(() {});
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _bigBtn(
                'Fallo',
                'Sistema no respondió o error',
                const Color(0xFFB71C1C),
                const Color(0xFFEF9A9A),
                Icons.cancel_rounded,
                    () {
                  final note = noteCtrl.text.trim();
                  _recordAttempt(test, false,
                      note: note.isEmpty ? null : note);
                  noteCtrl.clear();
                  setLocal(() {});
                },
              ),
            ),
          ]),
        ],
      );
    });
  }

  Widget _buildCompletedBanner(SystemTest test) {
    final ok = test.status == TestStatus.passed;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ok
            ? Colors.green.withOpacity(0.08)
            : Colors.red.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: ok
              ? Colors.greenAccent.withOpacity(0.3)
              : Colors.redAccent.withOpacity(0.3),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            ok ? Icons.task_alt_rounded : Icons.error_outline_rounded,
            color: ok ? Colors.greenAccent : Colors.redAccent,
            size: 16,
          ),
          const SizedBox(width: 8),
          Text(
            '${_statusLabel(test.status)} — ${test.summaryLine}',
            style: TextStyle(
              color: ok ? Colors.greenAccent : Colors.redAccent,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Botones de navegación ─────────────────────────────────────────────

  Widget _buildNavButtons(SystemTest test) {
    return Row(children: [
      if (_activeIndex > 0)
        TextButton.icon(
          onPressed: _prevTest,
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              size: 13, color: Colors.white54),
          label: const Text('Anterior',
              style: TextStyle(color: Colors.white54, fontSize: 12)),
        ),
      const Spacer(),
      if (!test.isComplete)
        TextButton(
          onPressed: () {
            setState(() {
              test.status = TestStatus.skipped;
            });
            _nextTest();
          },
          child: const Text('Omitir',
              style: TextStyle(color: Colors.white38, fontSize: 12)),
        ),
      const SizedBox(width: 8),
      ElevatedButton.icon(
        onPressed: _nextTest,
        icon: Icon(
          _activeIndex == _tests.length - 1
              ? Icons.flag_rounded
              : Icons.arrow_forward_ios_rounded,
          size: 14,
        ),
        label: Text(
          _activeIndex == _tests.length - 1
              ? 'Ver resultados'
              : 'Siguiente',
          style: const TextStyle(fontSize: 12),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF1565C0),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
          padding:
          const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
        ),
      ),
    ]);
  }

  // ─── Vista de resultados ───────────────────────────────────────────────

  Widget _buildResultsView() {
    int passed = _tests.where((t) => t.status == TestStatus.passed).length;
    int failed = _tests.where((t) => t.status == TestStatus.failed).length;
    int pending = _tests
        .where((t) =>
    t.status != TestStatus.passed &&
        t.status != TestStatus.failed &&
        t.status != TestStatus.skipped)
        .length;

    final vTests = _tests.where((t) => t.category == TestCategory.voice);
    int vTotal = vTests.fold(0, (s, t) => s + t.attempts.length);
    int vOk = vTests.fold(0, (s, t) => s + t.successCount);
    final vPct = vTotal > 0 ? (vOk / vTotal * 100).toStringAsFixed(1) : '--';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _buildGlobalChips(passed, failed, pending, vPct),
          const SizedBox(height: 16),
          _buildResultsCategory(TestCategory.navigation),
          const SizedBox(height: 10),
          _buildResultsCategory(TestCategory.obstacle),
          const SizedBox(height: 10),
          _buildResultsCategory(TestCategory.voice),
          const SizedBox(height: 16),
          if (_exportText != null) _buildExportCard(),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => setState(() {
              _sessionFinished = false;
              _activeIndex = 0;
            }),
            child: const Text('← Volver a las pruebas',
                style: TextStyle(color: Colors.white38, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _buildGlobalChips(
      int passed, int failed, int pending, String vPct) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1730),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        children: [
          const Text('RESUMEN GLOBAL',
              style: TextStyle(
                  color: Color(0xFF90CAF9),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2)),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _chip('Superadas', passed.toString(), Colors.greenAccent),
              _chip('Fallidas', failed.toString(), Colors.redAccent),
              _chip('Pendientes', pending.toString(), Colors.white38),
              _chip('Voz', '$vPct%', const Color(0xFFCE93D8)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, String value, Color color) {
    return Column(children: [
      Text(value,
          style: TextStyle(
              color: color,
              fontSize: 22,
              fontWeight: FontWeight.w800)),
      Text(label,
          style: const TextStyle(color: Colors.white38, fontSize: 10)),
    ]);
  }

  Widget _buildResultsCategory(TestCategory cat) {
    final tests = _tests.where((t) => t.category == cat).toList();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _catColor(cat).withOpacity(0.07),
        borderRadius: BorderRadius.circular(12),
        border:
        Border.all(color: _catAccent(cat).withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _pill(_catLabel(cat), _catColor(cat), _catAccent(cat)),
          const SizedBox(height: 10),
          ...tests.map((t) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Text(t.id,
                  style: TextStyle(
                      color: _catAccent(cat),
                      fontSize: 11,
                      fontWeight: FontWeight.w700)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(t.name,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12)),
              ),
              Text(
                t.attempts.isEmpty ? '—' : t.summaryLine,
                style: TextStyle(
                  color: t.status == TestStatus.passed
                      ? Colors.greenAccent
                      : t.status == TestStatus.failed
                      ? Colors.redAccent
                      : Colors.white38,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ]),
          )),
        ],
      ),
    );
  }

  Widget _buildExportCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(children: [
                Icon(Icons.article_outlined,
                    color: Color(0xFF90CAF9), size: 14),
                SizedBox(width: 6),
                Text('Texto exportable',
                    style: TextStyle(
                        color: Color(0xFF90CAF9),
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
              ]),
              GestureDetector(
                onTap: _copyToClipboard,
                child: const Row(children: [
                  Icon(Icons.copy_rounded,
                      color: Color(0xFF80CBC4), size: 13),
                  SizedBox(width: 4),
                  Text('Copiar',
                      style: TextStyle(
                          color: Color(0xFF80CBC4), fontSize: 11)),
                ]),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            _exportText!,
            style: const TextStyle(
              color: Colors.white60,
              fontSize: 10,
              fontFamily: 'monospace',
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Widgets de utilidad ──────────────────────────────────────────────

  Widget _bigBtn(String label, String sub, Color bg, Color accent,
      IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding:
        const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: bg.withOpacity(0.75),
          borderRadius: BorderRadius.circular(12),
          border:
          Border.all(color: accent.withOpacity(0.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: accent, size: 18),
            const SizedBox(height: 4),
            Text(label,
                style: TextStyle(
                    color: accent,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
            Text(sub,
                style: TextStyle(
                    color: accent.withOpacity(0.7),
                    fontSize: 10)),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDeco(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(
          color: Colors.white.withOpacity(0.3), fontSize: 11),
      filled: true,
      fillColor: Colors.white.withOpacity(0.05),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide:
        BorderSide(color: Colors.white.withOpacity(0.12)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide:
        BorderSide(color: Colors.white.withOpacity(0.12)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFF1976D2)),
      ),
      contentPadding:
      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      isDense: true,
    );
  }
}