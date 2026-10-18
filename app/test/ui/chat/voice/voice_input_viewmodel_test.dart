// Plan 29 — VoiceInputViewModel state machine: recording / transcribe / cancel
// / cap / permission, against a fake SpeechService.

import 'dart:async';

import 'package:app/data/voice/speech_service.dart';
import 'package:app/ui/chat/voice/states/voice_input_state.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

class _FakeSpeechService implements SpeechService {
  SpeechAvailability availability = const SpeechReady('en_US');
  String transcript = 'hello world';
  bool failListen = false;
  bool endOnListen = false;
  Completer<void>? initGate;
  Completer<void>? startGate;
  Completer<String>? stopGate;
  void Function(String)? live;
  void Function()? ended;
  void Function()? error;

  int startCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;
  String? startedLocale;
  Duration? startedMax;

  @override
  Future<SpeechAvailability> init({String? preferredLocaleId}) async {
    if (initGate != null) await initGate!.future;
    return availability;
  }

  @override
  Future<void> start({
    required String localeId,
    required Duration maxDuration,
    void Function(String text)? onTranscript,
    void Function()? onEnded,
    void Function()? onError,
  }) async {
    startCalls++;
    startedLocale = localeId;
    startedMax = maxDuration;
    live = onTranscript;
    ended = onEnded;
    error = onError;
    if (failListen) throw PlatformException(code: 'synthetic_unavailable');
    if (endOnListen) onEnded?.call();
    if (startGate != null) await startGate!.future;
  }

  @override
  Future<String> stop() async {
    stopCalls++;
    return stopGate == null ? transcript : stopGate!.future;
  }

  @override
  Future<void> cancel() async => cancelCalls++;

  @override
  void dispose() {}
}

void main() {
  test(
    'normal native segment end keeps the user dictation session active',
    () async {
      final svc = _FakeSpeechService();
      final vm = VoiceInputViewModel(svc);
      await vm.startRecording();
      svc.ended!();
      await Future<void>.delayed(Duration.zero);
      expect(vm.active, isTrue);
      vm.dispose();
    },
  );

  group('serial native segments', () {
    test(
      'partial corrections and finals append once across three segments',
      () {
        fakeAsync((clock) {
          final svc = _FakeSpeechService();
          final vm = VoiceInputViewModel(svc);
          final got = <String>[];
          vm.transcripts.listen(got.add);
          unawaited(vm.startRecording());
          clock.flushMicrotasks();
          final old = svc.live!;
          svc.live!('synthetic one');
          svc.live!('synthetic won');
          svc.transcript = 'synthetic won final';
          svc.ended!();
          svc.ended!();
          clock.flushMicrotasks();
          expect(vm.state, isA<VoiceReconnecting>());
          expect(svc.stopCalls, 1);
          clock.elapse(vm.restartDelay);
          expect(vm.state, isA<VoiceRecording>());
          old('stale replacement');
          svc.live!('second partial');
          expect(got.last, 'synthetic won final second partial');
          svc.transcript = 'second final';
          svc.ended!();
          clock.flushMicrotasks();
          clock.elapse(vm.restartDelay);
          svc.live!('third partial');
          svc.transcript = 'third final';
          unawaited(vm.stopAndTranscribe());
          clock.flushMicrotasks();
          expect(got.last, 'synthetic won final second final third final');
          expect(vm.state, isA<VoiceIdle>());
          clock.elapse(const Duration(seconds: 5));
          expect(svc.startCalls, 3);
          vm.dispose();
        });
      },
    );

    for (final teardown in ['stop', 'cancel', 'dispose']) {
      test(
        '$teardown cancels restart gap and fences old segment callbacks',
        () {
          fakeAsync((clock) {
            final svc = _FakeSpeechService();
            final vm = VoiceInputViewModel(svc);
            final got = <String>[];
            vm.transcripts.listen(got.add);
            unawaited(vm.startRecording());
            clock.flushMicrotasks();
            final oldLive = svc.live!;
            final oldError = svc.error!;
            svc.ended!();
            clock.flushMicrotasks();
            if (teardown == 'stop') unawaited(vm.stopAndTranscribe());
            if (teardown == 'cancel') unawaited(vm.cancel());
            if (teardown == 'dispose') vm.dispose();
            clock.flushMicrotasks();
            final before = got.toList();
            oldLive('stale words');
            oldError();
            clock.elapse(const Duration(seconds: 5));
            expect(svc.startCalls, 1);
            expect(got, before);
            if (teardown != 'dispose') vm.dispose();
          });
        },
      );
    }

    test(
      'Stop during segment finalization retains final and suppresses restart',
      () async {
        final svc = _FakeSpeechService()..stopGate = Completer<String>();
        final vm = VoiceInputViewModel(svc);
        final got = <String>[];
        vm.transcripts.listen(got.add);
        await vm.startRecording();
        svc.live!('synthetic partial');
        svc.ended!();
        final stopping = vm.stopAndTranscribe();
        expect(vm.state, isA<VoiceTranscribing>());
        svc.live!('synthetic complete');
        svc.stopGate!.complete('synthetic complete');
        expect(await stopping, 'synthetic complete');
        expect(svc.stopCalls, 1);
        expect(got.last, 'synthetic complete');
        expect(vm.state, isA<VoiceIdle>());
        vm.dispose();
      },
    );

    test(
      'failed restart stops with visible error, retaining earlier segments',
      () {
        fakeAsync((clock) {
          final svc = _FakeSpeechService()..transcript = 'synthetic retained';
          final vm = VoiceInputViewModel(svc);
          final got = <String>[];
          vm.transcripts.listen(got.add);
          unawaited(vm.startRecording());
          clock.flushMicrotasks();
          svc.ended!();
          clock.flushMicrotasks();
          svc.failListen = true;
          svc.transcript = '';
          clock.elapse(vm.restartDelay);
          clock.flushMicrotasks();
          expect(vm.state, isA<VoiceFailed>());
          expect(got.last, 'synthetic retained');
          clock.elapse(const Duration(seconds: 10));
          expect(svc.startCalls, 2);
          vm.dispose();
        });
      },
    );

    test(
      'immediate native ends are paced, never a synchronous restart loop',
      () {
        fakeAsync((clock) {
          final svc = _FakeSpeechService()..endOnListen = true;
          final vm = VoiceInputViewModel(svc, restartDelay: Duration.zero);
          unawaited(vm.startRecording());
          clock.flushMicrotasks();
          expect(svc.startCalls, 1);
          expect(vm.state, isA<VoiceReconnecting>());
          clock.elapse(const Duration(seconds: 1));
          expect(svc.startCalls, 4);
          vm.dispose();
          clock.elapse(const Duration(seconds: 1));
          expect(svc.startCalls, 4);
        });
      },
    );
  });

  group('generation and capture lifecycle', () {
    test(
      'rapid taps cancel pending permission without starting microphone',
      () async {
        final svc = _FakeSpeechService()..initGate = Completer<void>();
        final vm = VoiceInputViewModel(svc);
        final starting = vm.startRecording();
        expect(vm.state, isA<VoiceStarting>());
        final stopping = vm.stopAndTranscribe();
        svc.initGate!.complete();
        await starting;
        await stopping;
        expect(vm.state, isA<VoiceIdle>());
        expect(svc.startCalls, 0);
        vm.dispose();
      },
    );

    test(
      'dispose during permission never starts or emits into another room',
      () async {
        final svc = _FakeSpeechService()..initGate = Completer<void>();
        final vm = VoiceInputViewModel(svc);
        final starting = vm.startRecording();
        vm.dispose();
        svc.initGate!.complete();
        await starting;
        expect(svc.startCalls, 0);
        expect(svc.cancelCalls, 0);
      },
    );

    test(
      'cancel/dispose during pending native startup releases microphone',
      () async {
        for (final dispose in [false, true]) {
          final svc = _FakeSpeechService()..startGate = Completer<void>();
          final vm = VoiceInputViewModel(svc);
          final starting = vm.startRecording();
          await Future<void>.delayed(Duration.zero);
          Future<void>? cancelled;
          if (dispose) {
            vm.dispose();
          } else {
            cancelled = vm.cancel();
          }
          svc.startGate!.complete();
          await starting;
          await cancelled;
          expect(svc.cancelCalls, 1);
          if (!dispose) {
            expect(vm.state, isA<VoiceIdle>());
            vm.dispose();
          }
        }
      },
    );

    test(
      'cancel while finalizing rejects transcript and old generation callbacks',
      () async {
        final svc = _FakeSpeechService()..stopGate = Completer<String>();
        final vm = VoiceInputViewModel(svc);
        final got = <String>[];
        vm.transcripts.listen(got.add);
        await vm.startRecording();
        final oldLive = svc.live!;
        final finishing = vm.stopAndTranscribe();
        await vm.cancel();
        svc.stopGate!.complete('cancelled final');
        await finishing;
        oldLive('old late words');
        expect(got, isEmpty);
        await vm.startRecording();
        oldLive('old callback in new capture');
        svc.live!('new correction');
        expect(got, ['new correction']);
        vm.dispose();
      },
    );

    test(
      'native end during startup reconnects without claiming Listening',
      () async {
        final svc = _FakeSpeechService()
          ..startGate = Completer<void>()
          ..stopGate = Completer<String>();
        final vm = VoiceInputViewModel(svc);
        final starting = vm.startRecording();
        await Future<void>.delayed(Duration.zero);
        svc.ended!();
        expect(vm.state, isA<VoiceReconnecting>());
        svc.startGate!.complete();
        await starting;
        expect(vm.state, isA<VoiceReconnecting>());
        svc.stopGate!.complete('early final');
        await Future<void>.delayed(Duration.zero);
        expect(vm.state, isA<VoiceReconnecting>());
        vm.dispose();
      },
    );

    test(
      'native errors stop honestly and retain valid partial/final words',
      () async {
        final svc = _FakeSpeechService();
        final vm = VoiceInputViewModel(svc);
        final got = <String>[];
        vm.transcripts.listen(got.add);
        await vm.startRecording();
        svc.live!('valid partial');
        svc.error!();
        svc.ended!();
        await Future<void>.delayed(Duration.zero);
        expect(vm.state, isA<VoiceFailed>());
        expect(got, ['valid partial', 'hello world']);
        expect(svc.stopCalls, 1);
        vm.dispose();
      },
    );

    test(
      'stop/cap race finalizes once, blocks restart and releases on dispose',
      () async {
        final svc = _FakeSpeechService()..stopGate = Completer<String>();
        final vm = VoiceInputViewModel(svc);
        await vm.startRecording();
        final stopping = vm.stopAndTranscribe();
        expect(await vm.stopAndTranscribe(), isEmpty);
        await vm.startRecording();
        expect(svc.startCalls, 1);
        vm.dispose();
        svc.stopGate!.complete('late final');
        expect(await stopping, isEmpty);
        expect(svc.stopCalls, 1);
        expect(svc.cancelCalls, 1);
      },
    );
  });

  group('startRecording', () {
    test('start → VoiceRecording, with the resolved locale + cap', () async {
      final svc = _FakeSpeechService();
      final vm = VoiceInputViewModel(
        svc,
        maxDuration: const Duration(seconds: 30),
      );
      await vm.startRecording();
      expect(vm.state, isA<VoiceRecording>());
      expect(svc.startCalls, 1);
      expect(svc.startedLocale, 'en_US');
      expect(svc.startedMax, const Duration(seconds: 30));
      vm.dispose();
    });

    test('recording stays stable without waveform-driven UI updates', () async {
      final svc = _FakeSpeechService();
      final vm = VoiceInputViewModel(svc);
      await vm.startRecording();
      var updates = 0;
      vm.addListener(() => updates++);
      await Future<void>.delayed(Duration.zero);
      expect(vm.state, const VoiceRecording());
      expect(updates, 0);
      vm.dispose();
    });

    test(
      'permission denied → VoiceUnavailable(permissionDenied), no capture',
      () async {
        final svc = _FakeSpeechService()
          ..availability = const SpeechPermissionDenied();
        final vm = VoiceInputViewModel(svc);
        await vm.startRecording();
        expect(
          vm.state,
          const VoiceUnavailable(VoiceUnavailableReason.permissionDenied),
        );
        expect(svc.startCalls, 0);
        vm.dispose();
      },
    );

    test('unsupported → VoiceUnavailable(unsupported)', () async {
      final svc = _FakeSpeechService()
        ..availability = const SpeechUnsupported();
      final vm = VoiceInputViewModel(svc);
      await vm.startRecording();
      expect(
        vm.state,
        const VoiceUnavailable(VoiceUnavailableReason.unsupported),
      );
      vm.dispose();
    });
  });

  group('stop / cancel', () {
    test(
      'stop → VoiceTranscribing → idle, transcript on stream + returned',
      () async {
        final svc = _FakeSpeechService()..transcript = 'ship it';
        final vm = VoiceInputViewModel(svc);
        final transitions = <VoiceInputState>[];
        vm.addListener(() => transitions.add(vm.state));
        final got = <String>[];
        final sub = vm.transcripts.listen(got.add);

        await vm.startRecording();
        final text = await vm.stopAndTranscribe();
        await Future<void>.delayed(Duration.zero);

        expect(text, 'ship it');
        expect(got, ['ship it']);
        expect(transitions.whereType<VoiceTranscribing>(), isNotEmpty);
        expect(vm.state, isA<VoiceIdle>());
        expect(svc.stopCalls, 1);
        await sub.cancel();
        vm.dispose();
      },
    );

    test('cancel → idle, no transcript, no stop', () async {
      final svc = _FakeSpeechService();
      final vm = VoiceInputViewModel(svc);
      final got = <String>[];
      final sub = vm.transcripts.listen(got.add);

      await vm.startRecording();
      await vm.cancel();
      await Future<void>.delayed(Duration.zero);

      expect(vm.state, isA<VoiceIdle>());
      expect(svc.cancelCalls, 1);
      expect(svc.stopCalls, 0);
      expect(got, isEmpty);
      await sub.cancel();
      vm.dispose();
    });

    test('stopAndTranscribe is a no-op when not recording', () async {
      final svc = _FakeSpeechService();
      final vm = VoiceInputViewModel(svc);
      expect(await vm.stopAndTranscribe(), isEmpty);
      expect(svc.stopCalls, 0);
      vm.dispose();
    });
  });

  group('continuous session (former 60s cap)', () {
    test('native segment duration never caps the user session', () {
      fakeAsync((async) {
        final svc = _FakeSpeechService()..transcript = 'capped text';
        final vm = VoiceInputViewModel(
          svc,
          maxDuration: const Duration(milliseconds: 600),
        );
        final got = <String>[];
        vm.transcripts.listen(got.add);

        // ignore: discarded_futures
        vm.startRecording();
        async.flushMicrotasks();
        expect(vm.state, isA<VoiceRecording>());

        // Waiting does not schedule elapsed-time UI updates.
        async.elapse(const Duration(milliseconds: 400));
        expect(vm.state, isA<VoiceRecording>());
        expect(async.periodicTimerCount, 0);

        // More than the former cap: only explicit Stop ends the session.
        async.elapse(const Duration(seconds: 120));
        async.flushMicrotasks();
        expect(svc.stopCalls, 0);
        expect(got, isEmpty);
        expect(vm.state, isA<VoiceRecording>());
        vm.dispose();
      });
    });
  });
}
