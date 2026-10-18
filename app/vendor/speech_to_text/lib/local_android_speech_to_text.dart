import 'package:flutter/services.dart';
import 'package:speech_to_text_platform_interface/method_channel_speech_to_text.dart';
import 'package:speech_to_text_platform_interface/speech_to_text_platform_interface.dart';

/// Android companion to the App-local native patch. Tokens fence messages
/// already queued on the channel, beyond the native per-recognizer listener.
class LocalAndroidSpeechToText extends MethodChannelSpeechToText {
  static const _channel = MethodChannel('plugin.csdcorp.com/speech_to_text');
  int _nextCaptureId = 0;
  int? _captureId;

  @override
  Future<bool> initialize({
    debugLogging = false,
    List<SpeechConfigOption>? options,
  }) async {
    _channel.setMethodCallHandler(processMethodCall);
    return await _channel.invokeMethod<bool>('initialize', {
          'debugLogging': debugLogging,
          for (final option in options ?? <SpeechConfigOption>[])
            option.name: option.value,
        }) ??
        false;
  }

  @override
  Future<bool> listen({
    String? localeId,
    partialResults = true,
    onDevice = false,
    int listenMode = 0,
    sampleRate = 0,
    SpeechListenOptions? options,
  }) async {
    final id = ++_nextCaptureId;
    _captureId = id;
    final started = await _channel.invokeMethod<bool>('listen', {
      'captureId': id,
      'localeId': localeId ?? options?.localeId,
      'partialResults': options?.partialResults ?? partialResults,
      'onDevice': options?.onDevice ?? onDevice,
      'listenMode': options?.listenMode.index ?? listenMode,
      'pauseFor': options?.pauseFor?.inMilliseconds,
      'listenFor': options?.listenFor?.inMilliseconds,
    });
    return started ?? false;
  }

  @override
  Future<void> cancel() {
    _captureId = null; // invalidate before native cancel acknowledgments
    return super.cancel();
  }

  @override
  Future processMethodCall(MethodCall call) async {
    final arguments = call.arguments;
    if (arguments is! Map ||
        _captureId == null ||
        arguments['captureId'] != _captureId) {
      return;
    }
    final payload = arguments['payload'];
    switch (call.method) {
      case MethodChannelSpeechToText.textRecognitionMethod:
        if (payload is String) onTextRecognition?.call(payload);
      case MethodChannelSpeechToText.notifyErrorMethod:
        if (payload is String) onError?.call(payload);
      case MethodChannelSpeechToText.notifyStatusMethod:
        if (payload is String) onStatus?.call(payload);
      case MethodChannelSpeechToText.soundLevelChangeMethod:
        if (payload is double) onSoundLevel?.call(payload);
    }
  }
}
