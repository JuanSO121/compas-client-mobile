package com.example.flutter_voice_robot

// ✅ Se deja una sola importación
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

class MainActivity: FlutterActivity() {
    private val CHANNEL = "google_ai_edge"
    private var llmInference: LlmInference? = null
    private val coroutineScope = CoroutineScope(Dispatchers.Main + Job())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getAndroidVersion" -> {
                    result.success(Build.VERSION.SDK_INT)
                }

                "checkPlayServices" -> {
                    val available = isGooglePlayServicesAvailable()
                    result.success(available)
                }

                "getTotalRAM" -> {
                    val ramGB = getTotalRAMInGB()
                    result.success(ramGB)
                }

                "initialize" -> {
                    coroutineScope.launch {
                        try {
                            initializeAIEdge()
                            result.success(mapOf(
                                "success" to true,
                                "modelPath" to "gemini-nano"
                            ))
                        } catch (e: Exception) {
                            result.error("INIT_ERROR", e.message, null)
                        }
                    }
                }

                "generateText" -> {
                    val prompt = call.argument<String>("prompt")
                    val maxTokens = call.argument<Int>("maxTokens") ?: 100
                    val temperature = call.argument<Double>("temperature") ?: 0.7

                    if (prompt == null) {
                        result.error("INVALID_ARGS", "Prompt requerido", null)
                        return@setMethodCallHandler
                    }

                    coroutineScope.launch {
                        try {
                            val generatedText = generateText(prompt, maxTokens, temperature)
                            result.success(mapOf("text" to generatedText))
                        } catch (e: Exception) {
                            result.error("GENERATION_ERROR", e.message, null)
                        }
                    }
                }

                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    /**
     * Inicializar Google AI Edge (MediaPipe LLM Inference)
     */
    private suspend fun initializeAIEdge() = withContext(Dispatchers.IO) {
        try {
            // Opciones de configuración
            val options = LlmInference.LlmInferenceOptions.builder()
                .setModelPath("/data/local/tmp/llm/model.bin") // Ruta del modelo
                .setMaxTokens(512)
                .setTemperature(0.7f)
                .setTopK(40)
                .setRandomSeed(42)
                .build()

            // Crear instancia
            llmInference = LlmInference.createFromOptions(applicationContext, options)

        } catch (e: Exception) {
            throw Exception("Error inicializando AI Edge: ${e.message}")
        }
    }

    /**
     * Generar texto con el modelo local
     */
    private suspend fun generateText(
        prompt: String,
        maxTokens: Int,
        temperature: Double
    ): String = withContext(Dispatchers.IO) {

        if (llmInference == null) {
            throw Exception("Modelo no inicializado")
        }

        try {
            // Generar texto de forma síncrona
            val response = llmInference!!.generateResponse(prompt)

            return@withContext response ?: ""

        } catch (e: Exception) {
            throw Exception("Error generando texto: ${e.message}")
        }
    }

    /**
     * Verificar si Google Play Services está disponible
     */
    private fun isGooglePlayServicesAvailable(): Boolean {
        val apiAvailability = GoogleApiAvailability.getInstance()
        val resultCode = apiAvailability.isGooglePlayServicesAvailable(this)
        return resultCode == ConnectionResult.SUCCESS
    }

    /**
     * Obtener RAM total del dispositivo en GB
     */
    private fun getTotalRAMInGB(): Int {
        val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val memoryInfo = ActivityManager.MemoryInfo()
        activityManager.getMemoryInfo(memoryInfo)

        val totalRAMBytes = memoryInfo.totalMem
        val totalRAMGB = (totalRAMBytes / (1024.0 * 1024.0 * 1024.0)).toInt()

        return totalRAMGB
    }

    override fun onDestroy() {
        super.onDestroy()
        coroutineScope.cancel()
        llmInference?.close()
    }
}