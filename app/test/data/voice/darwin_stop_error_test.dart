import 'dart:convert';

import 'package:app/data/voice/speech_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
// Existing transitive plugin seam; no additional dependency.
// ignore: depend_on_referenced_packages
import 'package:speech_to_text_platform_interface/method_channel_speech_to_text.dart';
// ignore: depend_on_referenced_packages
import 'package:speech_to_text_platform_interface/speech_to_text_platform_interface.dart';

class _Platform extends MethodChannelSpeechToText {
  @override
  Future<bool> initialize({
    debugLogging = false,
    List<SpeechConfigOption>? options,
  }) async => true;
  @override
  Future<bool> listen({
    String? localeId,
    partialResults = true,
    onDevice = false,
    int listenMode = 0,
    sampleRate = 0,
    SpeechListenOptions? options,
  }) async {
    onStatus?.call('listening');
    return true;
  }

  @override
  Future<void> stop() async => onStatus?.call('notListening');
  @override
  Future<void> cancel() async {}
  @override
  Future<List<String>> locales() async => ['en_US:English'];

  void error() => onError?.call(
    jsonEncode({'errorMsg': 'error_audio_error', 'permanent': true}),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final target in [
    TargetPlatform.iOS,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    test(
      '$target forwards current Darwin Stop errors but preserves other-platform filtering',
      () async {
        final previous = SpeechToTextPlatform.instance;
        final platform = _Platform();
        SpeechToTextPlatform.instance = platform;
        debugDefaultTargetPlatformOverride = target;
        try {
          final speech = stt.SpeechToText.withMethodChannel();
          final plugin = SttPluginImpl(speech);
          final errors = <SttError>[];
          await plugin.initialize(onError: errors.add);
          await plugin.listen(
            localeId: 'en_US',
            listenFor: const Duration(seconds: 60),
            onResult: (_, _) {},
          );
          await plugin.stop();
          platform.error();
          expect(
            errors,
            target == TargetPlatform.linux ? isEmpty : hasLength(1),
          );
          await plugin.cancel();
        } finally {
          debugDefaultTargetPlatformOverride = null;
          SpeechToTextPlatform.instance = previous;
        }
      },
    );
  }

  for (final teardown in ['cancel', 'dispose']) {
    test(
      'Darwin $teardown revokes service ownership before queued errors',
      () async {
        final previous = SpeechToTextPlatform.instance;
        final platform = _Platform();
        SpeechToTextPlatform.instance = platform;
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          final service = SpeechToTextService(
            SttPluginImpl(stt.SpeechToText.withMethodChannel()),
          );
          await service.init(preferredLocaleId: 'en_US');
          var errors = 0;
          await service.start(
            localeId: 'en_US',
            maxDuration: const Duration(seconds: 60),
            onError: () => errors++,
          );
          if (teardown == 'dispose') {
            service.dispose();
          } else {
            await service.cancel();
          }
          platform.error();
          expect(errors, 0);
          if (teardown != 'dispose') service.dispose();
          await Future<void>.delayed(Duration.zero);
        } finally {
          debugDefaultTargetPlatformOverride = null;
          SpeechToTextPlatform.instance = previous;
        }
      },
    );
  }
}
