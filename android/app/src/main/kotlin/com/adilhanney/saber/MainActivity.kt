package com.adilhanney.saber

import android.os.Bundle
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import android.content.Intent.FLAG_ACTIVITY_NEW_TASK
import android.util.Log
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.common.model.RemoteModelManager
import com.google.mlkit.vision.digitalink.recognition.DigitalInkRecognition
import com.google.mlkit.vision.digitalink.recognition.DigitalInkRecognitionModel
import com.google.mlkit.vision.digitalink.recognition.DigitalInkRecognitionModelIdentifier
import com.google.mlkit.vision.digitalink.recognition.DigitalInkRecognizerOptions
import com.google.mlkit.vision.digitalink.recognition.Ink
import com.google.mlkit.vision.digitalink.recognition.RecognitionContext
import com.google.mlkit.vision.digitalink.recognition.WritingArea
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    companion object {
        private const val digitalInkLogTag = "SaberDigitalInk"
    }

    private val digitalInkChannel = "saber/digital_ink"
    override fun onCreate(savedInstanceState: Bundle?) {
        if (intent.getIntExtra("org.chromium.chrome.extra.TASK_ID", -1) == this.taskId) {
            this.finish()
            intent.addFlags(FLAG_ACTIVITY_NEW_TASK);
            startActivity(intent);
        }
        super.onCreate(savedInstanceState)

        WindowCompat.setDecorFitsSystemWindows(window, false)

        val windowInsetsController = WindowCompat.getInsetsController(window, window.decorView)
        windowInsetsController.isAppearanceLightNavigationBars = true

        MethodChannel(flutterEngine!!.dartExecutor.binaryMessenger, digitalInkChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "recognizeChinese") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val strokes = call.argument<List<List<Map<String, Number>>>>("strokes")
                if (strokes.isNullOrEmpty()) {
                    result.success(mapOf("status" to "invalid_ink"))
                    return@setMethodCallHandler
                }
                val identifier = DigitalInkRecognitionModelIdentifier.fromLanguageTag("zh-Hani-CN")
                if (identifier == null) {
                    result.success(mapOf("status" to "unsupported_language"))
                    return@setMethodCallHandler
                }
                val model = DigitalInkRecognitionModel.builder(identifier).build()
                val writingArea = call.argument<Map<String, Number>>("writingArea")
                val writingWidth = writingArea?.get("width")?.toFloat()
                val writingHeight = writingArea?.get("height")?.toFloat()
                val inkBuilder = Ink.builder()
                strokes.forEach { rawStroke ->
                    val builder = Ink.Stroke.builder()
                    rawStroke.forEach { point ->
                        val x = point["x"]?.toFloat()
                        val y = point["y"]?.toFloat()
                        if (x != null && y != null) builder.addPoint(Ink.Point.create(x, y))
                    }
                    inkBuilder.addStroke(builder.build())
                }
                val recognize = {
                    val recognizer = DigitalInkRecognition.getClient(DigitalInkRecognizerOptions.builder(model).build())
                    val ink = inkBuilder.build()
                    val context = if (writingWidth != null && writingHeight != null && writingWidth > 0f && writingHeight > 0f) {
                        RecognitionContext.builder()
                            .setPreContext("")
                            .setWritingArea(WritingArea(writingWidth, writingHeight))
                            .build()
                    } else {
                        null
                    }
                    (if (context == null) recognizer.recognize(ink) else recognizer.recognize(ink, context))
                        .addOnSuccessListener { value -> result.success(mapOf("status" to "ok", "candidates" to value.candidates.map { it.text }.filter { it.isNotBlank() }.take(3))) }
                        .addOnFailureListener { error ->
                            Log.w(digitalInkLogTag, "Chinese ink recognition failed", error)
                            result.success(mapOf("status" to "unavailable"))
                        }
                }
                val manager = RemoteModelManager.getInstance()
                manager.isModelDownloaded(model).addOnSuccessListener { downloaded ->
                    if (downloaded) {
                        Log.i(digitalInkLogTag, "Chinese ink model already available")
                        recognize()
                    } else {
                        Log.i(digitalInkLogTag, "Downloading Chinese ink model")
                        manager.download(model, DownloadConditions.Builder().build())
                            .addOnSuccessListener {
                                Log.i(digitalInkLogTag, "Chinese ink model download completed")
                                recognize()
                            }
                            .addOnFailureListener { error ->
                                Log.w(digitalInkLogTag, "Chinese ink model download failed", error)
                                result.success(mapOf("status" to "model_download_failed"))
                            }
                    }
                }.addOnFailureListener { error ->
                    Log.w(digitalInkLogTag, "Chinese ink model is unavailable", error)
                    result.success(mapOf("status" to "model_unavailable"))
                }
            }
    }
}
