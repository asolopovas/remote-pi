import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Source-level fences only: Linux host tests cannot compile Apple Speech or
// establish acoustic/runtime behavior of the Swift delegate and channel queue.
void main() {
  final source = File(
    'vendor/speech_to_text/darwin/speech_to_text/Sources/speech_to_text/SpeechToTextPlugin.swift',
  ).readAsStringSync();

  test('Darwin task callbacks serialize and reject a retired segment', () {
    final delegates = source.substring(
      source.indexOf(
        'extension SpeechToTextPlugin: SFSpeechRecognitionTaskDelegate',
      ),
      source.indexOf('extension SpeechToTextPlugin: AVAudioPlayerDelegate'),
    );
    expect(
      'guard task === callbackTask else { return }'.allMatches(delegates),
      hasLength(5),
    );
    expect('if !Thread.isMainThread'.allMatches(delegates), hasLength(5));
    expect(delegates, contains('if !stopping && task === currentTask'));
    expect(
      delegates,
      contains(
        'guard generation == self.captureGeneration, task === self.currentTask',
      ),
    );
  });

  test(
    'Darwin queued Flutter delivery and audio levels retain capture identity',
    () {
      expect(
        source,
        contains('let deliveryGeneration = generation ?? captureGeneration'),
      );
      expect(
        source,
        contains(
          'DispatchQueue.main.async {\n      guard deliveryGeneration == self.captureGeneration else { return }',
        ),
      );
      expect(
        source,
        contains(
          'self.updateSoundLevel(buffer: buffer, generation: generation)',
        ),
      );
      expect(source, contains('arguments: avgPower, generation: generation'));
    },
  );

  test(
    'Darwin Stop preserves final identity; cancel/new listen invalidate it',
    () {
      final cleanup = source.substring(
        source.indexOf('private func stopCurrentListen()'),
        source.indexOf('private func listenForSpeech('),
      );
      expect(cleanup, contains('currentTask = nil'));
      expect(cleanup, isNot(contains('callbackTask = nil')));
      final cancel = source.substring(
        source.indexOf('private func cancelSpeech('),
        source.indexOf('private func stopAllPlayers()'),
      );
      expect(
        cancel,
        contains('captureGeneration += 1\n    callbackTask = nil'),
      );
      final listen = source.substring(
        source.indexOf('private func listenForSpeech('),
        source.indexOf('private func updateSoundLevel('),
      );
      expect(
        listen,
        contains('captureGeneration += 1\n    callbackTask = nil'),
      );
      expect(listen, contains('self.callbackTask = self.currentTask'));
      expect(
        listen,
        contains('currentRequest.requiresOnDeviceRecognition = true'),
      );
    },
  );
}
