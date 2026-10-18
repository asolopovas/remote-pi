import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Source/configuration checks only, not proof that an OS/provider is silent.
void main() {
  test(
    'dictation disables plugin haptics and configures no feedback sounds',
    () {
      final service = File(
        'lib/data/voice/speech_service.dart',
      ).readAsStringSync();
      expect(service, contains('enableHapticFeedback: false'));
      expect(service, contains('stt.SpeechToText.androidNoBluetooth'));
      const feedbackFiles = [
        'speech_to_text_listening.m4r',
        'speech_to_text_stop.m4r',
        'speech_to_text_cancel.m4r',
      ];
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final assets = Directory('assets').listSync(recursive: true);
      for (final sound in feedbackFiles) {
        expect(pubspec, isNot(contains(sound)));
        expect(assets.where((asset) => asset.path.endsWith(sound)), isEmpty);
      }
    },
  );

  test('Android stays local without app tones or global audio muting', () {
    final native = File(
      'vendor/speech_to_text/android/src/main/kotlin/com/csdcorp/speech_to_text/SpeechToTextPlugin.kt',
    ).readAsStringSync();
    expect(native, contains('createOnDeviceSpeechRecognizer(pluginContext!!)'));
    expect(native, isNot(contains('createSpeechRecognizer(')));
    for (final audioControl in [
      'ToneGenerator',
      'MediaPlayer',
      'AudioManager',
      'setStreamVolume',
      'adjustStreamVolume',
      'setStreamMute',
    ]) {
      expect(native, isNot(contains(audioControl)));
    }
    expect(native, contains('override fun onSegmentResults('));
    expect(native, contains('override fun onEndOfSegmentedSession()'));
  });
}
