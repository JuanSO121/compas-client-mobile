// android/app/src/main/kotlin/com/example/flutter_voice_robot/AecPlugin.kt
// ✅ v1.1 — Dos fixes sobre la versión original:
//
//  FIX 1 — initAec(): AcousticEchoCanceler.isAvailable() puede ser false en
//    algunos dispositivos aunque SpeechRecognizer sí funcione. Cambiamos la
//    condición a: retornar true si STT está disponible, independientemente de
//    si hay AEC hardware. El filtro de eco por software en processText() cubre
//    el caso sin AEC.
//
//  FIX 2 — onPartialResults(): la clave "android.speech.extra.UNSTABLE_TEXT"
//    no existe en todos los dispositivos. Se unifica a leer solo
//    RESULTS_RECOGNITION para mayor compatibilidad.

package com.example.flutter_voice_robot

import android.content.Context
import android.content.Intent
import android.media.audiofx.AcousticEchoCanceler
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class AecPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {

    companion object {
        const val METHOD_CHANNEL = "com.example.flutter_voice_robot/aec"
        const val EVENT_CHANNEL  = "com.example.flutter_voice_robot/aec_results"

        val KEYWORDS = listOf(
            "oye compas", "oye compass", "oye comas",
            "ey compas", "hey compas", "hey compass",
            "oye com pas", "compas", "compass"
        )

        val CANCEL_WORDS = listOf(
            "para", "cancela", "cancelar", "detente", "stop", "detén"
        )

        const val RESTART_DELAY_MS = 300L
    }

    // ─── Flutter channels ─────────────────────────────────────────────────
    private var methodChannel: MethodChannel? = null
    private var eventChannel:  EventChannel?  = null
    private var eventSink:     EventChannel.EventSink? = null

    // ─── Android ──────────────────────────────────────────────────────────
    private var context:          Context?          = null
    private var speechRecognizer: SpeechRecognizer? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // ─── Estado ───────────────────────────────────────────────────────────
    private var isActive     = false
    private var isNavigating = false
    private var isTTSActive  = false
    private var isRestarting = false

    // ─── FlutterPlugin ────────────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel!!.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel!!.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                eventSink = sink
            }
            override fun onCancel(args: Any?) {
                eventSink = null
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopRecognizer()
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel  = null
        context       = null
    }

    // ─── ActivityAware ────────────────────────────────────────────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {}
    override fun onDetachedFromActivityForConfigChanges() {}
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {}
    override fun onDetachedFromActivity() {}

    // ─── MethodCallHandler ────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {

            "initAec" -> {
                // ✅ FIX 1: retornamos true si STT está disponible.
                // AEC hardware es opcional — el filtro de eco por software
                // en processText() cubre el caso sin AEC hardware.
                val sttAvailable = SpeechRecognizer.isRecognitionAvailable(context!!)
                // Intentar activar AEC hardware si está disponible (silencioso)
                if (AcousticEchoCanceler.isAvailable()) {
                    try {
                        AcousticEchoCanceler.create(0)?.apply { enabled = true }
                    } catch (_: Exception) {}
                }
                result.success(sttAvailable)
            }

            "startListening" -> {
                isNavigating = call.argument<Boolean>("isNavigating") ?: false
                isActive     = true
                startRecognizer()
                result.success(null)
            }

            "stopListening" -> {
                isActive = false
                stopRecognizer()
                result.success(null)
            }

            "setNavigationMode" -> {
                isNavigating = call.argument<Boolean>("active") ?: false
                result.success(null)
            }

            "setTTSActive" -> {
                isTTSActive = call.argument<Boolean>("active") ?: false
                result.success(null)
            }

            "setSensitivity" -> result.success(null) // no-op

            "dispose" -> {
                isActive = false
                stopRecognizer()
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    // ─── SpeechRecognizer ─────────────────────────────────────────────────

    private fun startRecognizer() {
        mainHandler.post {
            try {
                speechRecognizer?.destroy()
                speechRecognizer = null

                if (!isActive) return@post

                speechRecognizer = SpeechRecognizer.createSpeechRecognizer(context!!)
                speechRecognizer?.setRecognitionListener(buildListener())
                speechRecognizer?.startListening(buildRecognizerIntent())
            } catch (e: Exception) {
                scheduleRestart()
            }
        }
    }

    private fun stopRecognizer() {
        mainHandler.post {
            try {
                speechRecognizer?.stopListening()
                speechRecognizer?.destroy()
                speechRecognizer = null
            } catch (_: Exception) {}
        }
    }

    private fun scheduleRestart(delayMs: Long = RESTART_DELAY_MS) {
        if (!isActive || isRestarting) return
        isRestarting = true
        mainHandler.postDelayed({
            isRestarting = false
            if (isActive) startRecognizer()
        }, delayMs)
    }

    private fun buildRecognizerIntent() = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, "es-CO")
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 1500L)
        putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS, 300L)
        putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 1000L)
        putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
    }

    private fun buildListener(): RecognitionListener = object : RecognitionListener {

        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}

        override fun onPartialResults(partialResults: Bundle?) {
            // ✅ FIX 2: usar solo RESULTS_RECOGNITION — la clave UNSTABLE_TEXT
            // no existe en todos los dispositivos y causa NPE en algunos ROMs.
            val text = partialResults
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                ?.lowercase()
                ?.trim()
                ?: return

            processText(text, isFinal = false)
        }

        override fun onResults(results: Bundle?) {
            val candidates = results
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?: return

            for (text in candidates) {
                if (processText(text.lowercase().trim(), isFinal = true)) break
            }
            scheduleRestart()
        }

        override fun onError(error: Int) {
            val (shouldRestart, delayMs) = when (error) {
                SpeechRecognizer.ERROR_NO_MATCH       -> Pair(true,  RESTART_DELAY_MS)
                SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> Pair(true,  RESTART_DELAY_MS)
                SpeechRecognizer.ERROR_RECOGNIZER_BUSY-> Pair(false, 1000L)
                SpeechRecognizer.ERROR_AUDIO          -> Pair(true,  RESTART_DELAY_MS)
                SpeechRecognizer.ERROR_NETWORK        -> Pair(true,  2000L)
                SpeechRecognizer.ERROR_SERVER         -> Pair(true,  2000L)
                else                                  -> Pair(true,  RESTART_DELAY_MS)
            }
            if (shouldRestart) scheduleRestart(delayMs)
        }

        override fun onEvent(eventType: Int, params: Bundle?) {}
    }

    // ─── Detección ────────────────────────────────────────────────────────

    private fun processText(text: String, isFinal: Boolean): Boolean {
        if (text.isEmpty()) return false

        // Filtro de eco por software: texto muy corto mientras TTS habla
        if (isTTSActive && text.length < 4) return false

        // Cancelación durante navegación
        if (isNavigating && CANCEL_WORDS.any { text.contains(it) }) {
            sendDetection(text, isCancel = true, duringNavigation = true)
            return true
        }

        // Wake word
        if (KEYWORDS.any { text.contains(it) }) {
            sendDetection(text, isCancel = false, duringNavigation = isNavigating)
            return true
        }

        return false
    }

    private fun sendDetection(text: String, isCancel: Boolean, duringNavigation: Boolean) {
        mainHandler.post {
            eventSink?.success(mapOf(
                "text"             to text,
                "isCancel"         to isCancel,
                "duringNavigation" to duringNavigation,
            ))
        }
    }
}