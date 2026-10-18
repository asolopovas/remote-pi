import 'dart:async';

import 'package:app/data/voice/speech_service.dart';
import 'package:app/ui/chat/voice/states/voice_input_state.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// Synthetic callback tests prove ownership/lifecycle, not acoustic accuracy.
class _FakeSpeechService implements SpeechService {
  SpeechAvailability availability = const SpeechReady('en_US');
  String transcript = 'hello from voice';
  Completer<void>? initGate;
  Completer<String>? stopGate;
  void Function(String)? live;
  void Function()? ended;
  void Function()? error;
  int startCalls = 0;
  int cancelCalls = 0;
  int stopCalls = 0;

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
    live = onTranscript;
    ended = onEnded;
    error = onError;
  }

  @override
  Future<String> stop() async {
    stopCalls++;
    return stopGate == null ? transcript : stopGate!.future;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }

  @override
  void dispose() {}
}

void main() {
  late _FakeSpeechService svc;
  late VoiceInputViewModel vm;
  late List<VoiceHint> hints;
  late List<String> sent;
  setUp(() {
    svc = _FakeSpeechService();
    vm = VoiceInputViewModel(svc);
    hints = [];
    sent = [];
  });
  tearDown(() => vm.dispose());

  Future<void> pumpBar(
    WidgetTester tester, {
    Key? key,
    bool disabled = false,
    bool streaming = false,
    VoidCallback? onCancel,
    double scale = 1,
  }) => tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: InputBar(
              key: key,
              onSend: sent.add,
              voice: vm,
              onVoiceHint: hints.add,
              disabled: disabled,
              streaming: streaming,
              onCancel: onCancel,
            ),
          ),
        ),
      ),
    ),
  );
  Future<void> tapMic(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('input-bar-dictation')));
    await tester.pump();
  }

  String text(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  for (final failed in [false, true]) {
    testWidgets('terminal failure=$failed retains draft and never sends', (
      tester,
    ) async {
      svc.transcript = 'synthetic retained words';
      await pumpBar(tester);
      await tapMic(tester);
      svc.live!('synthetic partial');
      if (failed) svc.error!();
      svc.ended!();
      await tester.pump();
      expect(text(tester), 'synthetic retained words');
      expect(sent, isEmpty);
      expect(
        find.text('Dictation failed.'),
        failed ? findsOneWidget : findsNothing,
      );
      expect(vm.state, failed ? isA<VoiceFailed>() : isA<VoiceReconnecting>());
    });
  }

  testWidgets(
    'composer spans native segments and Stop during reconnect never sends',
    (tester) async {
      await pumpBar(tester);
      await tapMic(tester);
      svc.live!('synthetic first');
      svc.transcript = 'synthetic first final';
      svc.ended!();
      await tester.pump();
      expect(text(tester), 'synthetic first final');
      expect(find.byKey(const Key('dictation-feedback')), findsNothing);
      expect(find.textContaining('Listening'), findsNothing);
      expect(find.bySemanticsLabel('Stop dictation'), findsOneWidget);
      await tester.pump(vm.restartDelay);
      svc.live!('synthetic second');
      await tester.pump();
      expect(text(tester), 'synthetic first final synthetic second');
      svc.transcript = 'synthetic second final';
      svc.ended!();
      await tester.pump();
      await tapMic(tester);
      await tester.pump(const Duration(seconds: 5));
      expect(svc.startCalls, 2);
      expect(vm.state, isA<VoiceIdle>());
      expect(text(tester), 'synthetic first final synthetic second final');
      expect(sent, isEmpty);
      await tester.tap(find.byKey(const Key('input-bar-action')));
      expect(sent, ['synthetic first final synthetic second final']);
    },
  );

  for (final prefix in ['manual draft', 'manual draft\n']) {
    testWidgets('idle mic with draft "$prefix" appends live corrections', (
      tester,
    ) async {
      await pumpBar(tester);
      await tester.enterText(find.byType(TextField), prefix);
      await tester.pumpAndSettle();
      expect(find.byIcon(LucideIcons.mic600), findsOneWidget);
      expect(find.bySemanticsLabel('Start dictation'), findsOneWidget);
      expect(find.byIcon(LucideIcons.send600), findsOneWidget);
      await tapMic(tester);
      svc.live!('partial');
      final separator = prefix.endsWith('\n') ? '' : ' ';
      expect(text(tester), '$prefix${separator}partial');
      svc.live!('corrected words');
      await tester.pump();
      expect(text(tester), '$prefix${separator}corrected words');
      svc.transcript = 'final words';
      await tapMic(tester);
      expect(text(tester), '$prefix${separator}final words');
      expect(sent, isEmpty);
      expect(find.bySemanticsLabel('Start dictation'), findsOneWidget);
    });
  }

  testWidgets('one circular red mic throughout capture and silent restart', (
    tester,
  ) async {
    svc.transcript = '';
    await pumpBar(tester);
    final mic = find.byKey(const Key('input-bar-dictation'));
    BoxDecoration decoration() =>
        tester
                .widget<Container>(
                  find.descendant(of: mic, matching: find.byType(Container)),
                )
                .decoration!
            as BoxDecoration;
    final colors = tester.element(mic).colors;
    expect(decoration().color, colors.accent);
    await tapMic(tester);
    expect(decoration().color, colors.error);
    expect(decoration().shape, BoxShape.circle);
    expect(find.byIcon(LucideIcons.mic600), findsOneWidget);
    expect(find.bySemanticsLabel('Stop dictation'), findsOneWidget);
    expect(find.textContaining(RegExp(r'\d+s')), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(const Key('input-bar-action')), findsNothing);
    expect(find.byIcon(LucideIcons.square600), findsNothing);
    expect(find.byIcon(LucideIcons.x), findsNothing);
    svc.ended!(); // A silence-only segment must not revoke intent.
    await tester.pump();
    expect(vm.state, isA<VoiceReconnecting>());
    expect(decoration().color, colors.error);
    await tester.pump(vm.restartDelay);
    expect(svc.startCalls, 2);
    expect(vm.state, isA<VoiceRecording>());
    await tapMic(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(vm.state, isA<VoiceIdle>());
    expect(svc.startCalls, 2);
    expect(decoration().color, colors.accent);
    expect(sent, isEmpty);
  });

  testWidgets('unsupported mic stays actionable with an existing draft', (
    tester,
  ) async {
    svc.availability = const SpeechUnsupported();
    await pumpBar(tester);
    await tester.enterText(find.byType(TextField), 'keep this draft');
    await tapMic(tester);
    expect(find.bySemanticsLabel('Start dictation'), findsOneWidget);
    expect(find.text('Dictation unavailable.'), findsOneWidget);
    expect(text(tester), 'keep this draft');
    svc.availability = const SpeechReady('en_US');
    await tapMic(tester);
    expect(svc.startCalls, 1);
    svc.live!('more words');
    expect(text(tester), 'keep this draft more words');
  });

  testWidgets('tap immediately starts dictation without a hold hint', (
    tester,
  ) async {
    await pumpBar(tester);
    await tapMic(tester);
    expect(vm.state, isA<VoiceRecording>());
    expect(hints, isEmpty);
    expect(find.byKey(const Key('dictation-feedback')), findsNothing);
  });

  testWidgets(
    'live cumulative corrections replace text; second tap retains final and never sends',
    (tester) async {
      svc.stopGate = Completer<String>();
      await pumpBar(tester);
      await tapMic(tester);
      svc.live!('hello');
      await tester.pump();
      expect(text(tester), 'hello');
      svc.live!('yellow world');
      await tester.pump();
      expect(text(tester), 'yellow world');
      expect(find.byIcon(LucideIcons.send600), findsNothing);
      expect(find.bySemanticsLabel('Stop dictation'), findsOneWidget);
      expect(find.byKey(const Key('dictation-feedback')), findsNothing);
      await tapMic(tester);
      expect(find.textContaining('Listening'), findsNothing);
      expect(find.byKey(const Key('dictation-feedback')), findsNothing);
      svc.stopGate!.complete('yellow world complete');
      await tester.pump();
      expect(text(tester), 'yellow world complete');
      expect(sent, isEmpty);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byIcon(LucideIcons.send600), findsOneWidget);
      await tester.tap(find.byKey(const Key('input-bar-action')));
      expect(sent, ['yellow world complete']);
    },
  );

  testWidgets(
    'manual edits revoke ownership; late words do not overwrite draft',
    (tester) async {
      await pumpBar(tester);
      await tapMic(tester);
      final late = svc.live!;
      late('spoken');
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'my manual draft');
      late('spoken late correction');
      await tester.pump();
      expect(text(tester), 'my manual draft');
      expect(svc.cancelCalls, 1);
      expect(sent, isEmpty);
    },
  );

  testWidgets(
    'selection movement alone preserves voice ownership and bounded selection',
    (tester) async {
      await pumpBar(tester);
      await tapMic(tester);
      svc.live!('long hypothesis');
      final controller = tester
          .widget<TextField>(find.byType(TextField))
          .controller!;
      controller.selection = const TextSelection(
        baseOffset: 2,
        extentOffset: 9,
      );
      svc.live!('short');
      await tester.pump();
      expect(text(tester), 'short');
      expect(
        controller.selection,
        const TextSelection(baseOffset: 2, extentOffset: 5),
      );
      expect(svc.cancelCalls, 0);
    },
  );

  testWidgets(
    'permission prompt is honest; second tap cancels pending start intent',
    (tester) async {
      svc.initGate = Completer<void>();
      await pumpBar(tester);
      await tapMic(tester);
      expect(find.byKey(const Key('dictation-feedback')), findsNothing);
      expect(find.textContaining('Listening'), findsNothing);
      await tapMic(tester);
      svc.initGate!.complete();
      await tester.pump();
      expect(vm.state, isA<VoiceIdle>());
      expect(svc.startCalls, 0);
    },
  );

  testWidgets('permission allow starts after tap without holding', (
    tester,
  ) async {
    svc.initGate = Completer<void>();
    await pumpBar(tester);
    await tapMic(tester);
    svc.initGate!.complete();
    await tester.pump();
    expect(vm.state, isA<VoiceRecording>());
    expect(svc.startCalls, 1);
  });

  testWidgets(
    'permission denied keeps mic and guidance; unsupported is honest',
    (tester) async {
      svc.availability = const SpeechPermissionDenied();
      await pumpBar(tester);
      await tapMic(tester);
      expect(hints, [VoiceHint.permissionDenied]);
      expect(find.text('Microphone permission denied.'), findsOneWidget);
      expect(find.byIcon(LucideIcons.mic600), findsOneWidget);
      svc.availability = const SpeechUnsupported();
      await tapMic(tester);
      expect(find.byIcon(LucideIcons.mic600), findsOneWidget);
      expect(find.text('Dictation unavailable.'), findsOneWidget);
    },
  );

  testWidgets(
    'room key change releases capture and late results cannot enter new composer',
    (tester) async {
      await pumpBar(tester, key: const ValueKey('room1'));
      await tapMic(tester);
      final late = svc.live!;
      late('room one');
      await tester.pump();
      await pumpBar(tester, key: const ValueKey('room2'));
      await tester.pump();
      late('old room late');
      await tester.pump();
      expect(text(tester), isEmpty);
      expect(svc.cancelCalls, 1);
    },
  );

  testWidgets('background stops capture but retains visible words', (
    tester,
  ) async {
    await pumpBar(tester);
    await tapMic(tester);
    svc.live!('keep words');
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(svc.cancelCalls, 1);
    expect(text(tester), 'keep words');
    expect(find.textContaining('Listening'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('native end removes Listening and retains final without send', (
    tester,
  ) async {
    await pumpBar(tester);
    await tapMic(tester);
    svc.ended!();
    await tester.pump();
    expect(find.textContaining('Listening'), findsNothing);
    expect(text(tester), 'hello from voice');
    expect(sent, isEmpty);
  });

  testWidgets(
    'active mic survives agent working and hardware Enter does not send',
    (tester) async {
      var agentStops = 0;
      await pumpBar(tester);
      await tapMic(tester);
      svc.live!('voice words');
      await tester.pump();
      await pumpBar(tester, streaming: true, onCancel: () => agentStops++);
      expect(find.bySemanticsLabel('Stop dictation'), findsOneWidget);
      await tester.tap(find.byType(TextField));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(sent, isEmpty);
      await tapMic(tester);
      expect(agentStops, 0);
      expect(svc.stopCalls, 1);
    },
  );

  testWidgets('320px 2x keeps composer, feedback and stop reachable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpBar(tester, scale: 2);
    await tapMic(tester);
    svc.live!('long visible cumulative words for review');
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.bySemanticsLabel('Stop dictation'), findsOneWidget);
    expect(text(tester), 'long visible cumulative words for review');
    await tapMic(tester);
    expect(sent, isEmpty);
  });

  testWidgets(
    'offline transition cancels native capture without erasing text',
    (tester) async {
      await pumpBar(tester);
      await tapMic(tester);
      svc.live!('draft');
      await pumpBar(tester, disabled: true);
      await tester.pump();
      expect(svc.cancelCalls, 1);
      expect(text(tester), 'draft');
    },
  );
}
