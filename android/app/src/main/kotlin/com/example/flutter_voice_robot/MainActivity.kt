// android/app/src/main/kotlin/com/example/flutter_voice_robot/MainActivity.kt
// ✅ v2.1 — Lifecycle fix para evitar pause de Unity + AEC + google_ai_edge

package com.example.flutter_voice_robot

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.os.Build
import android.content.Context
import android.app.ActivityManager
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.common.ConnectionResult
import kotlinx.coroutines.*
import com.google.mediapipe.tasks.genai.llminference.LlmInference

class MainActivity : FlutterActivity() {

    // ─── google_ai_edge ───────────────────────────────────────────────────
    private val CHANNEL = "google_ai_edge"
    private var llmInference: LlmInference? = null
    private val coroutineScope = CoroutineScope(Dispatchers.Main + Job())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ✅ Registrar plugin AEC (wake word)
        flutterEngine.plugins.add(AecPlugin())

        // ─── google_ai_edge ───────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    "getAndroidVersion" -> {
                        result.success(Build.VERSION.SDK_INT)
                    }

                    "checkPlayServices" -> {
                        result.success(isGooglePlayServicesAvailable())
                    }

                    "getTotalRAM" -> {
                        result.success(getTotalRAMInGB())
                    }

                    "initialize" -> {
                        coroutineScope.launch {
                            try {
                                initializeAIEdge()
                                result.success(mapOf(
                                    "success"   to true,
                                    "modelPath" to "gemini-nano"
                                ))
                            } catch (e: Exception) {
                                result.error("INIT_ERROR", e.message, null)
                            }
                        }
                    }

                    "generateText" -> {
                        val prompt      = call.argument<String>("prompt")
                        val maxTokens   = call.argument<Int>("maxTokens") ?: 100
                        val temperature = call.argument<Double>("temperature") ?: 0.7

                        if (prompt == null) {
                            result.error("INVALID_ARGS", "Prompt requerido", null)
                            return@setMethodCallHandler
                        }

                        coroutineScope.launch {
                            try {
                                result.success(mapOf(
                                    "text" to generateText(prompt, maxTokens, temperature)
                                ))
                            } catch (e: Exception) {
                                result.error("GENERATION_ERROR", e.message, null)
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    // ─── Lifecycle FIX (evita pause completo de Unity / AR) ───────────────

    override fun onPause() {
        super.onPause()
        // ⚠️ NO detener nada aquí
    }

    override fun onResume() {
        super.onResume()
    }

    override fun onStop() {
        super.onStop()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
    }

    // ─── AI Edge helpers ──────────────────────────────────────────────────

    private suspend fun initializeAIEdge() = withContext(Dispatchers.IO) {
        val options = LlmInference.LlmInferenceOptions.builder()
            .setModelPath("/data/local/tmp/llm/model.bin")
            .setMaxTokens(512)
            .setTemperature(0.7f)
            .setTopK(40)
            .setRandomSeed(42)
            .build()

        llmInference = LlmInference.createFromOptions(applicationContext, options)
    }

    private suspend fun generateText(
        prompt: String,
        maxTokens: Int,
        temperature: Double
    ): String = withContext(Dispatchers.IO) {
        llmInference?.generateResponse(prompt)
            ?: throw Exception("Modelo no inicializado")
    }

    private fun isGooglePlayServicesAvailable(): Boolean {
        val apiAvailability = GoogleApiAvailability.getInstance()
        return apiAvailability.isGooglePlayServicesAvailable(this) ==
                ConnectionResult.SUCCESS
    }

    private fun getTotalRAMInGB(): Int {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val mi = ActivityManager.MemoryInfo()
        am.getMemoryInfo(mi)
        return (mi.totalMem / (1024.0 * 1024.0 * 1024.0)).toInt()
    }

    override fun onDestroy() {
        super.onDestroy()
        coroutineScope.cancel()
        llmInference?.close()
    }
}