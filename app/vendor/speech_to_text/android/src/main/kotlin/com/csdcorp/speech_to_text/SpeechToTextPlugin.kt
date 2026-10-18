package com.csdcorp.speech_to_text

import android.Manifest
import android.annotation.TargetApi
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothHeadset
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.*
import android.speech.SpeechRecognizer.createOnDeviceSpeechRecognizer
import android.util.Log
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import org.json.JSONArray
import org.json.JSONObject
import java.util.*


enum class SpeechToTextErrors {
    multipleRequests,
    unimplemented,
    noLanguageIntent,
    recognizerNotAvailable,
    missingOrInvalidArg,
    missingContext,
    unknown
}

enum class SpeechToTextCallbackMethods {
    textRecognition,
    notifyStatus,
    notifyError,
    soundLevelChange,
}

enum class SpeechToTextStatus {
    listening,
    notListening,
    unavailable,
    available,
    done,
    doneNoResult,
}

enum class ListenMode {
    deviceDefault,
    dictation,
    search,
    confirmation,
}

enum class ResultType {
    partial,
    intermediate,
    finalResult,
}

fun ResultType.intValue(): Int {
    return when (this) {
        ResultType.partial -> 0
        ResultType.intermediate -> 1
        ResultType.finalResult -> 2
    }
}

const val pluginChannelName = "plugin.csdcorp.com/speech_to_text"

@TargetApi(8)
/** SpeechToTextPlugin */
public class SpeechToTextPlugin :
        MethodCallHandler,
        PluginRegistry.RequestPermissionsResultListener, FlutterPlugin,
        ActivityAware {
    private var pluginContext: Context? = null
    private var channel: MethodChannel? = null
    private val minSdkForSpeechSupport = 21
    private val minSdkForOnDeviceSpeechSupport = 33
    private val speechToTextPermissionCode = 28521
    private val missingConfidence: Double = -1.0
    private var speechThresholdRms = 9
    private val logTag = "SpeechToTextPlugin"
    private var currentActivity: Activity? = null
    private var activeResult: Result? = null
    private var initializedSuccessfully: Boolean = false
    private var permissionToRecordAudio: Boolean = false
    private var listening = false
    private var debugLogging: Boolean = false
    private var noBluetoothOpt: Boolean = false // user-defined option
    private var bluetoothDisabled = true // final bluetooth state (combines user-defined option and permissions)
    private var resultSent: Boolean = false
    // Each capture owns a fresh recognizer and listener. IDs also cross the
    // channel so already-enqueued messages cannot enter a newer Dart listen.
    private var captureId: Int? = null
    private var captureListener: CaptureListener? = null
    private var finalization: Runnable? = null
    private var captureStopping = false
    private var audioSource: ContinuousAudioSource? = null
    private var startReply: Result? = null
    private var supportTimeout: Runnable? = null
    private var committedText = ""
    private var latestText = ""
    private var speechRecognizer: SpeechRecognizer? = null
    private var recognizerIntent: Intent? = null
    private var bluetoothAdapter: android.bluetooth.BluetoothAdapter? = null
    private var pairedDevices: Set<android.bluetooth.BluetoothDevice>? = null
    private var activeBluetooth: android.bluetooth.BluetoothDevice? = null
    private var bluetoothHeadset: BluetoothHeadset? = null
    private var speechStartTime: Long = 0
    private var minRms: Float = 1000.0F
    private var maxRms: Float = -100.0F
    private val handler: Handler = Handler(Looper.getMainLooper())
    private val defaultLanguageTag: String = Locale.getDefault().toLanguageTag()

    override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {

        onAttachedToEngine(flutterPluginBinding.getApplicationContext(), flutterPluginBinding.getBinaryMessenger());
    }

    private fun onAttachedToEngine(applicationContext: Context, messenger: BinaryMessenger) {
        this.pluginContext = applicationContext;
        channel = MethodChannel(messenger, pluginChannelName)
        channel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        retireCapture()
        activeResult?.success(false)
        activeResult = null
        initializedSuccessfully = false
        this.pluginContext = null;
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onDetachedFromActivity() {
        retireCapture()
        currentActivity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        currentActivity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        currentActivity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        retireCapture()
        currentActivity = null
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull rawrResult: Result) {
        val result = ChannelResultWrapper(rawrResult)
        try {
            when (call.method) {
                "has_permission" -> hasPermission(result)
                "initialize" -> {
                    var dlog = call.argument<Boolean>("debugLogging")
                    if (null != dlog) {
                        debugLogging = dlog
                    }
                    var noBtOpt = call.argument<Boolean>("noBluetooth")
                    if (null != noBtOpt) {
                        noBluetoothOpt = noBtOpt == true
                    }
                    initialize(result)
                }
                "listen" -> {
                    var localeId = call.argument<String>("localeId")
                    if (null == localeId) {
                        localeId = defaultLanguageTag
                    }
                    localeId = localeId.replace( '_', '-')
                    var partialResults = call.argument<Boolean>("partialResults")
                    if (null == partialResults) {
                        partialResults = true
                    }
                    var onDevice = call.argument<Boolean>("onDevice")
                    if ( null == onDevice ) {
                        onDevice = false
                    }
                    val listenModeIndex = call.argument<Int>("listenMode")
                    if ( null == listenModeIndex ) {
                        result.error(SpeechToTextErrors.missingOrInvalidArg.name,
                                "listenMode is required", null)
                        return
                    }
                    startListening(result, localeId, partialResults, listenModeIndex, onDevice, call.argument<Int>("captureId"))
                }
                "stop" -> stopListening(result)
                "cancel" -> cancelListening(result)
                "locales" -> locales(result)
                else -> result.notImplemented()
            }
        } catch (exc: Exception) {
            Log.e(logTag, "Unexpected exception", exc)
            result.error(SpeechToTextErrors.unknown.name,
                    "Unexpected exception", exc.localizedMessage)
        }
    }

    private fun hasPermission(result: Result) {
        if (sdkVersionTooLow()) {
            result.success(false)
            return
        }
        debugLog("Start has_permission")
        val localContext = pluginContext
        if (localContext != null) {
            val hasPerm = ContextCompat.checkSelfPermission(localContext,
                    Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
            result.success(hasPerm)
        } else {
            result.success(false)
        }
    }

    private fun initialize(result: Result) {
        if (sdkVersionTooLow()) {
            result.success(false)
            return
        }
        debugLog("Start initialize")
        if (null != activeResult) {
            result.error(SpeechToTextErrors.multipleRequests.name,
                    "Only one initialize at a time", null)
            return
        }
        activeResult = result
        initializeIfPermitted(pluginContext)
    }

    private fun sdkVersionTooLow(): Boolean {
        if (Build.VERSION.SDK_INT < minSdkForSpeechSupport) {
            return true;
        }
        return false;
    }

    private fun isNotInitialized(): Boolean {
        return !initializedSuccessfully
    }

    private fun isListening(): Boolean {
        return listening
    }

    private fun isNotListening(): Boolean {
        return !listening
    }

    private fun localRecognitionAvailable(): Boolean {
        val context = pluginContext ?: return false
        return Build.VERSION.SDK_INT >= minSdkForOnDeviceSpeechSupport &&
            SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
    }

    private fun startListening(result: Result, languageTag: String, partialResults: Boolean,
                               listenModeIndex: Int, onDevice: Boolean, id: Int?) {
        if (isNotInitialized() || captureId != null || !onDevice || id == null ||
            listenModeIndex != ListenMode.dictation.ordinal) {
            result.success(false)
            return
        }
        retireCapture()
        captureId = id
        startReply = result
        resultSent = false
        captureStopping = false
        committedText = ""
        latestText = ""
        minRms = 1000.0F
        maxRms = -100.0F
        try {
            check(localRecognitionAvailable()) { "Local continuous recognition unavailable" }
            val recognizer = createOnDeviceSpeechRecognizer(pluginContext!!)
            speechRecognizer = recognizer
            val listener = CaptureListener(id)
            captureListener = listener
            recognizer.setRecognitionListener(listener)
            audioSource = ContinuousAudioSource()
            setupRecognizerIntent(languageTag, partialResults)
            val timeout = Runnable { if (captureListener === listener) failContinuousCapture() }
            supportTimeout = timeout
            handler.postDelayed(timeout, 2000)
            // Check the exact intent, including the pipe, before acquiring the mic.
            // Success is not proof that a provider honors optional extras.
            recognizer.checkRecognitionSupport(recognizerIntent!!,
                java.util.concurrent.Executor { command -> handler.post(command) },
                object : RecognitionSupportCallback {
                    override fun onSupportResult(support: RecognitionSupport) {
                        if (captureListener !== listener || supportTimeout !== timeout) return
                        handler.removeCallbacks(timeout)
                        supportTimeout = null
                        try {
                            audioSource!!.start {
                                handler.post { if (captureListener === listener) failContinuousCapture() }
                            }
                            speechStartTime = System.currentTimeMillis()
                            recognizer.startListening(recognizerIntent)
                            if (captureListener === listener && !captureStopping) {
                                // Disable Dart pause/cap timers immediately, even before words.
                                emit(SpeechToTextCallbackMethods.notifyStatus, "segmented")
                                notifyListening(true)
                                startReply?.success(true)
                                startReply = null
                            }
                        } catch (error: Exception) { failContinuousCapture() }
                    }
                    override fun onError(error: Int) {
                        if (captureListener === listener && supportTimeout === timeout) failContinuousCapture()
                    }
                })
        } catch (error: Exception) { failContinuousCapture() }
    }

    private fun failContinuousCapture() {
        if (captureId == null) return
        sendError("error_continuous_recognition_unavailable")
        finishCapture()
    }

    private inner class CaptureListener(private val id: Int) : RecognitionListener {
        private fun current() = captureId == id && captureListener === this
        override fun onPartialResults(results: Bundle?) { if (current()) updateResults(results, false) }
        override fun onResults(results: Bundle?) {
            if (!current()) return
            if (!captureStopping) {
                updateResults(results, false)
                failContinuousCapture() // ignored source/segmentation: never restart
            } else {
                updateResults(results, true)
                finishCapture()
            }
        }
        override fun onSegmentResults(results: Bundle) {
            if (!current()) return
            updateResults(results, false)
            val words = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
            if (!words.isNullOrBlank()) committedText = cumulative(words)
        }
        override fun onEndOfSegmentedSession() {
            if (!current()) return
            if (!captureStopping) {
                failContinuousCapture()
                return
            }
            // EOF after explicit Stop seals the cumulative transcript.
            if (latestText.isNotEmpty()) {
                val final = Bundle()
                final.putStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION, arrayListOf(latestText))
                updateResults(final, true, false)
            }
            finishCapture()
        }
        override fun onError(error: Int) { if (current()) this@SpeechToTextPlugin.onError(error) }
        override fun onEndOfSpeech() { if (current()) this@SpeechToTextPlugin.onEndOfSpeech() }
        override fun onBeginningOfSpeech() { if (current()) this@SpeechToTextPlugin.onBeginningOfSpeech() }
        override fun onRmsChanged(level: Float) { if (current()) this@SpeechToTextPlugin.onRmsChanged(level) }
        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEvent(event: Int, params: Bundle?) {}
    }

    private fun emit(method: SpeechToTextCallbackMethods, payload: Any) {
        val id = captureId ?: return
        channel?.invokeMethod(method.name, mapOf("captureId" to id, "payload" to payload))
    }

    private fun awaitFinal() {
        if (finalization != null) return
        val id = captureId ?: return
        val timeout = Runnable { if (captureId == id) finishCapture() }
        finalization = timeout
        handler.postDelayed(timeout, 2000)
    }

    private fun stopCapture() {
        if (captureId == null || captureStopping) return
        captureStopping = true // before status delivery can re-enter Stop
        awaitFinal()
        notifyListening(false)
        // AUDIO_SOURCE segmented sessions end by EOF, not stopListening().
        audioSource?.close()
        if (startReply != null) finishCapture() // Stop during support preflight
    }

    private fun finishCapture() {
        if (captureId == null) return
        notifyListening(false)
        emit(SpeechToTextCallbackMethods.notifyStatus,
            if (resultSent) SpeechToTextStatus.done.name else SpeechToTextStatus.doneNoResult.name)
        retireCapture()
    }

    private fun retireCapture() {
        captureId = null // invalidate before cancel/destroy can call back
        captureListener = null
        finalization?.let { handler.removeCallbacks(it) }
        supportTimeout?.let { handler.removeCallbacks(it) }
        finalization = null
        supportTimeout = null
        audioSource?.close()
        audioSource = null
        val reply = startReply
        startReply = null
        reply?.success(false)
        val recognizer = speechRecognizer
        speechRecognizer = null
        listening = false
        optionallyStopBluetooth()
        try { recognizer?.cancel() } catch (exc: Exception) { debugLog("Cancel failed: $exc") }
        try { recognizer?.destroy() } catch (exc: Exception) { debugLog("Destroy failed: $exc") }
    }

    private fun optionallyStartBluetooth() {
        if ( bluetoothDisabled ) return
        val context = pluginContext
        val lbt = bluetoothAdapter
        val lpaired = pairedDevices
        val lhead = bluetoothHeadset
        if (null != lbt && null!= lhead && null != lpaired && lbt.isEnabled) {
            for (tryDevice in lpaired) {
                //This loop tries to start VoiceRecognition mode on every paired device until it finds one that works(which will be the currently in use bluetooth headset)
                if (lhead.startVoiceRecognition(tryDevice)) {
                    debugLog("Starting bluetooth voice recognition")
                    activeBluetooth = tryDevice;
                    break
                }
            }
        }
    }

    private fun stopListening(result: Result) {
        stopCapture()
        result.success(true)
    }

    private fun cancelListening(result: Result) {
        retireCapture() // also release a stopped recognizer awaiting its final
        result.success(true)
    }

    private fun locales(result: Result) {
        if (!localRecognitionAvailable()) {
            result.success(emptyList<String>())
            return
        }
        var recognizer: SpeechRecognizer? = null
        var completed = false
        val timeout = Runnable {
            if (!completed) {
                completed = true
                recognizer?.destroy()
                result.success(emptyList<String>())
            }
        }
        fun complete(languages: List<String>) {
            if (completed) return
            completed = true
            handler.removeCallbacks(timeout)
            recognizer?.destroy()
            // Do not add a default locale that the local support query excluded.
            result.success(languages.map {
                val locale = Locale.forLanguageTag(it)
                "${locale.language}_${locale.country}:${locale.displayName.replace(':', ' ')}"
            })
        }
        try {
            recognizer = createOnDeviceSpeechRecognizer(pluginContext!!)
            handler.postDelayed(timeout, 2000)
            recognizer.checkRecognitionSupport(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH),
                java.util.concurrent.Executor { command -> handler.post(command) },
                object : RecognitionSupportCallback {
                    override fun onSupportResult(support: RecognitionSupport) {
                        complete(support.installedOnDeviceLanguages)
                    }
                    override fun onError(error: Int) { complete(emptyList()) }
                })
        } catch (exc: Exception) { complete(emptyList()) }
    }

    private fun notifyListening(isRecording: Boolean ) {
        if ( listening == isRecording ) return;
        listening = isRecording
        val status = when (isRecording) {
            true -> SpeechToTextStatus.listening.name
            false -> SpeechToTextStatus.notListening.name
        }
        debugLog("Notify status:" + status)
        emit(SpeechToTextCallbackMethods.notifyStatus, status)
        if (!isRecording) optionallyStopBluetooth()
    }

    private fun optionallyStopBluetooth() {
        if ( bluetoothDisabled ) return
        val lactive = activeBluetooth
        val lbt = bluetoothHeadset
        if (null != lactive && null != lbt ) {
            debugLog("Stopping bluetooth voice recognition")
            lbt.stopVoiceRecognition(lactive)
            activeBluetooth = null
        }
    }
    
    private fun cumulative(words: String): String =
        listOf(committedText, words.trim()).filter { it.isNotEmpty() }.joinToString(" ")

    private fun updateResults(speechBundle: Bundle?, isFinal: Boolean, includeCommitted: Boolean = true) {
        val userSaid = speechBundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
        if (null != userSaid && userSaid.isNotEmpty()) {
            latestText = if (includeCommitted) cumulative(userSaid[0]) else userSaid[0]
            val speechResult = JSONObject()
            val finalResult = speechBundle.getBoolean("final_result", false)
            val resultType = if (isFinal) {
                ResultType.finalResult
            } else if (finalResult) {
                ResultType.intermediate
            } else {
                ResultType.partial
            }
            speechResult.put("resultType", resultType.intValue())
            val confidence = speechBundle.getFloatArray(SpeechRecognizer.CONFIDENCE_SCORES)
            val alternates = JSONArray()
            for (resultIndex in 0..userSaid.size - 1) {
                val speechWords = JSONObject()
                speechWords.put("recognizedWords", if (includeCommitted) cumulative(userSaid[resultIndex]) else userSaid[resultIndex])
                if (null != confidence && confidence.size >= userSaid.size) {
                    speechWords.put("confidence", confidence[resultIndex])
                } else {
                    speechWords.put("confidence", missingConfidence)
                }
                alternates.put(speechWords)
            }
            speechResult.put("alternates", alternates)
            val jsonResult = speechResult.toString()
            debugLog("Calling results callback")
            resultSent = true
            emit(SpeechToTextCallbackMethods.textRecognition, jsonResult)
        } else {
            debugLog("Results null or empty")
        }
    }

    private fun initializeIfPermitted(context: Context?) {
        val localContext = context
        if (null == localContext) {
            completeInitialize()
            return
        }
        permissionToRecordAudio = ContextCompat.checkSelfPermission(localContext,
                Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        val permissionToEnableBluetooth = ContextCompat.checkSelfPermission(localContext,
                Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
        bluetoothDisabled = !permissionToEnableBluetooth || noBluetoothOpt
        debugLog("Checked permission")
        if (!permissionToRecordAudio) {
            val localActivity = currentActivity
            if (null != localActivity) {
                debugLog("Requesting permission")
                var requiredPermissions = arrayOf(Manifest.permission.RECORD_AUDIO)
                if ( !noBluetoothOpt ) {
                    requiredPermissions = requiredPermissions.plus(Manifest.permission.BLUETOOTH_CONNECT)
                }
                ActivityCompat.requestPermissions(localActivity, requiredPermissions, speechToTextPermissionCode)
            } else {
                debugLog("no permission, no activity, completing")
                completeInitialize()
            }
        } else {
            debugLog("has permission, completing")
            completeInitialize()
        }
        debugLog("leaving initializeIfPermitted")
    }

    private fun completeInitialize() {

        debugLog("completeInitialize")
        if (permissionToRecordAudio) {
            debugLog("Testing recognition availability")
            val localContext = pluginContext
            if (localContext != null) {
                if (!localRecognitionAvailable()) {
                    initializedSuccessfully = false
                    activeResult?.success(false)
                    activeResult = null
                    return
                }
                setupBluetooth()
            } else {
                debugLog("null context during initialization")
                activeResult?.success(false)
                activeResult = null
                return
            }
        }

        initializedSuccessfully = permissionToRecordAudio
        debugLog("sending result")
        activeResult?.success(permissionToRecordAudio)
        debugLog("leaving complete")
        activeResult = null
    }

    private fun setupBluetooth() {
        if ( bluetoothDisabled ) return
        bluetoothAdapter = BluetoothAdapter.getDefaultAdapter()
        pairedDevices = bluetoothAdapter?.getBondedDevices()

        val mProfileListener: BluetoothProfile.ServiceListener = object : BluetoothProfile.ServiceListener {
            override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
                if (profile == BluetoothProfile.HEADSET) {
                    bluetoothHeadset = proxy as BluetoothHeadset
                    debugLog("Found a headset: " + bluetoothHeadset.toString())
                }
            }

            override fun onServiceDisconnected(profile: Int) {
                if (profile == BluetoothProfile.HEADSET) {
                    debugLog("Clearing headset: ")
                    bluetoothHeadset = null
                }
            }
        }
        bluetoothAdapter?.getProfileProxy(pluginContext, mProfileListener, BluetoothProfile.HEADSET)
    }

    private fun setupRecognizerIntent(languageTag: String, partialResults: Boolean) {
        debugLog("setupRecognizerIntent")
        recognizerIntent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            debugLog("In RecognizerIntent apply")
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            debugLog("put model")
            val localContext = pluginContext
            if (null != localContext) {
                putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE,
                        localContext.applicationInfo.packageName)
            }
            debugLog("put package")
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, partialResults)
            debugLog("put partial")
            if (languageTag != Locale.getDefault().toLanguageTag()) {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, languageTag);
                debugLog("put languageTag")
            }
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS,10)

            putExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION, RecognizerIntent.EXTRA_AUDIO_SOURCE)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, audioSource!!.reader)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, android.media.AudioFormat.ENCODING_PCM_16BIT)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, 16000)
        }
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        when (requestCode) {
            speechToTextPermissionCode -> {
                permissionToRecordAudio = grantResults.isNotEmpty() &&
                        grantResults[0] == PackageManager.PERMISSION_GRANTED
                bluetoothDisabled = (grantResults.isEmpty() || grantResults.size == 1 ||
                        grantResults[1] != PackageManager.PERMISSION_GRANTED) ||
                        noBluetoothOpt
                completeInitialize()
                return true
            }
        }
        return false
    }


    private fun onBeginningOfSpeech() {}

    private fun onEndOfSpeech() {
        // A phrase boundary never closes the pipe, starts a watchdog, or ends
        // Listening. Only explicit Stop/cancel/lifecycle release owns EOF.
    }

    private fun onError(errorCode: Int) {
        val delta = System.currentTimeMillis() - speechStartTime
        var errorReturn = errorCode
        if ( SpeechRecognizer.ERROR_NO_MATCH == errorCode && maxRms < speechThresholdRms ) {
            errorReturn = SpeechRecognizer.ERROR_SPEECH_TIMEOUT
        }
        debugLog( "Error $errorCode after start at $delta $minRms / $maxRms")
        val errorMsg = when (errorReturn) {
            SpeechRecognizer.ERROR_AUDIO -> "error_audio_error"
            SpeechRecognizer.ERROR_CLIENT -> "error_client"
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "error_permission"
            SpeechRecognizer.ERROR_NETWORK -> "error_network"
            SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "error_network_timeout"
            SpeechRecognizer.ERROR_NO_MATCH -> "error_no_match"
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "error_busy"
            SpeechRecognizer.ERROR_SERVER -> "error_server"
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "error_speech_timeout"
            SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> "error_language_not_supported"
            SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "error_language_unavailable"
            SpeechRecognizer.ERROR_SERVER_DISCONNECTED -> "error_server_disconnected"
            SpeechRecognizer.ERROR_TOO_MANY_REQUESTS -> "error_too_many_requests"
            else -> "error_unknown ($errorCode)"
        }

        // Even no-match/timeout is a real continuous-engine failure, not an
        // invitation for the Dart owner to reopen a recognizer on every pause.
        if (!captureStopping) failContinuousCapture()
        else {
            sendError(errorMsg)
            finishCapture()
        }
    }

    private fun debugLog( msg: String ) {
        if ( debugLogging ) {
            Log.d( logTag, msg )
        }
    }

    private fun sendError(errorMsg: String) {
        val speechError = JSONObject()
        speechError.put("errorMsg", errorMsg)
        speechError.put("permanent", true)
        emit(SpeechToTextCallbackMethods.notifyError, speechError.toString())
    }

    private fun onRmsChanged(rmsdB: Float) {
        minRms = minOf(minRms, rmsdB)
        maxRms = maxOf(maxRms, rmsdB)
        emit(SpeechToTextCallbackMethods.soundLevelChange, rmsdB)
    }


}

// See https://stackoverflow.com/questions/10538791/how-to-set-the-language-in-speech-recognition-on-android/10548680#10548680
class LanguageDetailsChecker(flutterResult: Result, logging: Boolean ) : BroadcastReceiver() {
    private val logTag = "SpeechToTextPlugin"
    private val result: Result = flutterResult
    private val debugLogging: Boolean = logging
    private var supportedLanguages: List<String>? = null

    private var languagePreference: String? = null

    override fun onReceive(context: Context, intent: Intent) {
        debugLog( "Received extra language broadcast" )
        val results = getResultExtras(true)
        if (results.containsKey(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE)) {
            languagePreference = results.getString(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE)
        }
        if (results.containsKey(RecognizerIntent.EXTRA_SUPPORTED_LANGUAGES)) {
            debugLog( "Extra supported languages" )
            supportedLanguages = results.getStringArrayList(
                    RecognizerIntent.EXTRA_SUPPORTED_LANGUAGES)
            createResponse(supportedLanguages)
        }
        else {
            debugLog(  "No extra supported languages" )
            createResponse( ArrayList<String>())
        }
    }

    public fun createResponse(supportedLanguages: List<String>?) {
        val currentLocale = Locale.getDefault()
        val localeNames = ArrayList<String>()
        localeNames.add(buildIdNameForLocale(currentLocale))
        if (null != supportedLanguages) {
            for (lang in supportedLanguages) {
                if (currentLocale.toLanguageTag() == lang) {
                    continue
                }
                val locale = Locale.forLanguageTag(lang)
                localeNames.add(buildIdNameForLocale(locale))
            }
        }
        result.success(localeNames)

    }

    private fun buildIdNameForLocale(locale: Locale): String {
        val name = locale.displayName.replace(':', ' ')
        return "${locale.language}_${locale.country}:$name"
    }

    private fun debugLog( msg: String ) {
        if ( debugLogging ) {
            Log.d( logTag, msg )
        }
    }
}

private class ChannelResultWrapper(result: Result) : Result {
    // Caller handler
    val handler: Handler = Handler(Looper.getMainLooper())
    val result: Result = result

    // make sure to respond in the caller thread
    override fun success(results: Any?) {

        handler.post {
            run {
                result.success(results);
            }
        }
    }

    override fun error(errorCode: String, errorMessage: String?, data: Any?) {
        handler.post {
            run {
                result.error(errorCode, errorMessage, data);
            }
        }
    }

    override fun notImplemented() {
        handler.post {
            run {
                result.notImplemented();
            }
        }
    }
}