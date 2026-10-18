// Plan/71: exercise the production ChatPage list, not isolated static cards.
import 'dart:async';
import 'dart:convert';
import 'package:app/ui/chat/widgets/codemode_preview.dart';
import 'dart:io';

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/states/chat_state.dart';
import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/local/boxes.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/repositories/session_read_repository.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/voice/speech_service.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:app/ui/chat/widgets/tool_request_card.dart';
import 'package:app/ui/chat/widgets/subagent_panel.dart';
import 'package:app/ui/chat/widgets/accordion_viewport.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/chat/voice/states/voice_input_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui' show Tristate;
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';

class _FakeChannel implements IChannel {
  final _ctrl = StreamController<ServerMessage>.broadcast();
  @override
  Stream<ServerMessage> get serverMessages => _ctrl.stream;
  @override
  Future<void> send(ClientMessage msg) async {}
  @override
  Future<void> close() => _ctrl.close();
}

// Keep transport inert; drive the real ViewModel state as DB/stream updates do.
class _FakeStorage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => const [];
  @override
  Future<PeerRecord?> loadPeer(String epk) async => null;
}

class _FakeSecureStorage implements FlutterSecureStorage {
  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {}

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => null;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeSpeech implements SpeechService {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakePicker implements IImagePickerService {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _SessionVM extends ChatViewModel {
  _SessionVM(super.read, super.sync, super.conn, super.prefs, super.storage);
  PeerRecord? testPeer;
  bool? testWorking;
  @override
  bool get isWorking => testWorking ?? super.isWorking;
  @override
  PeerRecord? get activePeer => testPeer;
}

void main() {
  late Directory dir;
  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('rp_rendering_');
    await LocalBoxes.initForTest(dir.path);
    if (const bool.fromEnvironment('CAPTURE86')) {
      Directory(
        'build/86-compact-chat/${const String.fromEnvironment('CAPTURE_PHASE', defaultValue: 'followup')}',
      ).createSync(recursive: true);
      final loader = FontLoader(kMonoFamily);
      loader.addFont(
        rootBundle.load('assets/fonts/fira_mono/FiraMonoNerdFont-Regular.otf'),
      );
      await loader.load();
      for (final (family, asset) in [
        ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
        (
          'packages/lucide_icons_flutter/Lucide',
          'packages/lucide_icons_flutter/assets/lucide.ttf',
        ),
        (
          'packages/lucide_icons_flutter/Lucide600',
          'packages/lucide_icons_flutter/assets/build_font/LucideVariable-w600.ttf',
        ),
      ]) {
        final icons = FontLoader(family)..addFont(rootBundle.load(asset));
        await icons.load();
      }
    }
  });
  tearDownAll(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  for (final dark in [false, true]) {
    testWidgets(
      '${dark ? 'dark' : 'light'} compact fixed control retains reverse disclosure and nested shared code at 320px/2x without child composer or stale room header',
      (tester) async {
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        tester.view.physicalSize = const Size(320, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final semantics = tester.ensureSemantics();
        final conn = ConnectionManager(
          factory: (_, _) async => _FakeChannel(),
          storage: _FakeStorage(),
        );
        final boxes = LocalBoxes();
        final sync = SyncService(conn, boxes);
        final prefs = Preferences(_FakeSecureStorage());
        final actions = ActionsRepository(conn);
        final vm = _SessionVM(
          SessionReadRepository(boxes),
          sync,
          conn,
          prefs,
          _FakeStorage(),
        );
        final voice = VoiceInputViewModel(_FakeSpeech());
        final attach = AttachmentViewModel(_FakePicker(), actions);
        final sel = SessionSelection();
        final capture = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? buildDarkTheme() : buildLightTheme(),
            home: MultiProvider(
              providers: [
                ChangeNotifierProvider<ChatViewModel>.value(value: vm),
                ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
                ChangeNotifierProvider<AttachmentViewModel>.value(
                  value: attach,
                ),
                ChangeNotifierProvider<Preferences>.value(value: prefs),
                ChangeNotifierProvider<SessionSelection>.value(value: sel),
              ],
              child: Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: const TextScaler.linear(2)),
                  child: RepaintBoundary(
                    key: capture,
                    child: const ChatPage(initialOnline: true),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        vm.emit(const ChatReady(messages: []));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final toggle = find.byKey(const Key('thread-toggle'));
        expect(toggle, findsNothing);
        expect(find.byType(InputBar), findsOneWidget);
        expect(tester.getRect(find.byType(InputBar)).bottom, 1000);
        const initialAgent = ToolEvent(
          id: 'initial-agent',
          toolCallId: 'initial-agent',
          tool: 'subagent',
          args: {'agent': 'scout', 'task': 'Inspect'},
          status: ToolEventStatus.pending,
        );
        vm.emit(const ChatReady(messages: [initialAgent]));
        await tester.pumpAndSettle();
        expect(tester.getSize(toggle).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(toggle).width, lessThan(300));
        expect(tester.getRect(toggle).left, 8);
        expect(find.text('Sub-agents'), findsOneWidget);
        await prefs.setHideToolCalls(true);
        await tester.pumpAndSettle();
        expect(toggle, findsOneWidget);
        await prefs.setHideToolCalls(false);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextField).first,
          'retained main draft',
        );
        voice.emit(const VoiceStarting());
        await tester.pump();
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(voice.state, isA<VoiceIdle>());
        final hiddenInput = tester.widget<InputBar>(
          find.byType(InputBar, skipOffstage: false),
        );
        expect(hiddenInput.disabled, isTrue);
        expect(
          tester
              .widget<EditableText>(
                find.byType(EditableText, skipOffstage: false).first,
              )
              .focusNode
              .hasFocus,
          isFalse,
        );
        expect(find.text('Main'), findsOneWidget);
        expect(find.byType(InputBar), findsNothing);
        await tester.tap(find.text('Main'));
        await tester.pumpAndSettle();
        expect(find.byType(InputBar), findsOneWidget);
        expect(find.text('retained main draft'), findsOneWidget);
        await tester.tap(find.text('Sub-agents'));
        await tester.pumpAndSettle();
        vm.emit(const ChatReady(messages: []));
        await tester.pumpAndSettle();
        expect(toggle, findsNothing);
        expect(find.byType(InputBar), findsOneWidget);
        expect(find.text('retained main draft'), findsOneWidget);
        expect(tester.takeException(), isNull);
        final lines = List.generate(100, (i) => 'nested line $i').join('\n');
        final tool = ToolEvent(
          id: 'tool',
          toolCallId: 'tool',
          tool: 'bash',
          args: const {
            'command': 'if true; then\n  printf "hello\\n"\nfi\n',
            'timeout': 120,
          },
          status: ToolEventStatus.completed,
          result: lines,
        );
        final agent = ToolEvent(
          id: 'agent',
          toolCallId: 'agent',
          tool: 'subagent',
          args: const {'agent': 'scout', 'task': 'Inspect'},
          status: ToolEventStatus.completed,
          result: 'Actual output\n```dart\n$lines\n```\nEnd of output',
        );
        final history = <ChatMessage>[tool, agent];
        vm.emit(ChatReady(messages: history));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(
          find.byKey(const Key('tool-disclosure')).hitTestable(),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final mainList = find.byWidgetPredicate(
          (w) => w is ListView && w.reverse,
        );
        final mainScroll = tester.widget<ListView>(mainList).controller!;
        expect(
          tester.getRect(mainList).top,
          tester.getRect(find.byKey(const Key('chat-toolbar'))).bottom,
        );
        final toolAlignedOffset = mainScroll.offset;
        if (const bool.fromEnvironment('CAPTURE86') && dark) {
          await tester.runAsync(() async {
            final image =
                await (capture.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              'build/86-compact-chat/${const String.fromEnvironment('CAPTURE_PHASE', defaultValue: 'followup')}/chat-aligned-320-2x.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        final fixedControlRect = tester.getRect(toggle);
        mainScroll.jumpTo(mainScroll.offset - 200);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.getRect(toggle), fixedControlRect);
        var readingOffset = mainScroll.offset;
        final latest = find.byKey(const Key('scroll-to-latest'));
        expect(tester.getSize(latest).height, greaterThanOrEqualTo(48));
        expect(
          tester
              .widget<Icon>(
                find.descendant(of: latest, matching: find.byType(Icon)),
              )
              .size,
          24,
        );
        expect(
          tester.getRect(latest).bottom,
          lessThan(tester.getRect(toggle).top),
        );
        expect(find.byTooltip('Scroll to latest message'), findsOneWidget);
        expect(
          find.bySemanticsLabel(RegExp('Scroll to latest message')),
          findsOneWidget,
        );
        tester.view.viewInsets = const FakeViewPadding(bottom: 220);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        expect(tester.getRect(toggle).bottom, lessThanOrEqualTo(780));
        expect(
          tester.getRect(toggle).bottom,
          lessThanOrEqualTo(tester.getRect(find.byType(InputBar)).top),
        );
        tester.view.padding = const FakeViewPadding(bottom: 24);
        addTearDown(tester.view.resetPadding);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester.getRect(latest).bottom,
          lessThan(tester.getRect(toggle).top),
        );
        expect(find.byTooltip('Scroll to latest message'), findsOneWidget);
        expect(tester.takeException(), isNull);
        tester.view.resetPadding();
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
        await tester.tap(latest);
        await tester.pumpAndSettle();
        expect(mainScroll.offset, 0);
        expect(latest, findsNothing);
        mainScroll.jumpTo(readingOffset);
        await tester.pumpAndSettle();
        final failed = ToolEvent(
          id: 'tool',
          toolCallId: 'tool',
          tool: 'bash',
          args: tool.args,
          status: ToolEventStatus.failed,
          result: lines,
        );
        vm.emit(ChatReady(messages: [failed, agent]));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('accordion-pinned-heading')), findsNothing);
        expect(
          find.byKey(const Key('tool-disclosure')).hitTestable(),
          findsNothing,
        );
        expect(mainScroll.offset, closeTo(readingOffset, 1));
        mainScroll.jumpTo(toolAlignedOffset);
        await tester.pumpAndSettle();
        expect(find.byTooltip('FAILED'), findsOneWidget);
        await tester.tap(find.byTooltip('Copy command').hitTestable());
        await tester.pump();
        expect(copied, (tool.args as Map)['command']);
        mainScroll.jumpTo(readingOffset);
        await tester.pumpAndSettle();
        final readingTop = tester.getTopLeft(find.byType(ToolRequestCard)).dy;
        vm.emit(
          ChatReady(
            messages: [failed, agent],
            streaming: const StreamingMessage(
              inReplyTo: 'update',
              buffer: 'New output',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester.getTopLeft(find.byType(ToolRequestCard)).dy,
          closeTo(readingTop, 0.5),
        );
        readingOffset = mainScroll.offset;
        await tester.tap(find.text('Sub-agents'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(InputBar), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey('subagent-agent')).hitTestable(),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byTooltip('Call returned'), findsWidgets);
        expect(find.textContaining('not live child telemetry'), findsNothing);
        await tester.tap(
          find.byKey(const Key('code-disclosure')).hitTestable(),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final codeHeader = find
            .byKey(const Key('code-disclosure'))
            .hitTestable();
        final agentList = find.byWidgetPredicate(
          (w) => w is ListView && !w.reverse,
        );
        expect(codeHeader, findsOneWidget);
        expect(
          tester.getRect(codeHeader).top,
          closeTo(tester.getRect(agentList).top + kAccordionGutter, 1),
        );
        final agentScroll = tester.widget<ListView>(agentList).controller!;
        if (const bool.fromEnvironment('CAPTURE86') && dark) {
          await tester.runAsync(() async {
            final image =
                await (capture.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              'build/86-compact-chat/${const String.fromEnvironment('CAPTURE_PHASE', defaultValue: 'followup')}/chat-children-320-2x.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        final agentAlignedOffset = agentScroll.offset;
        agentScroll.jumpTo(agentScroll.offset + 300);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(codeHeader, findsNothing);
        expect(find.byKey(const Key('accordion-pinned-heading')), findsNothing);
        final agentReadingOffset = agentScroll.offset;
        await tester.tap(find.text('Main'));
        await tester.pumpAndSettle();
        expect(
          tester.getTopLeft(find.byType(ToolRequestCard)).dy,
          closeTo(readingTop, 0.5),
        );
        await tester.tap(find.text('Sub-agents'));
        await tester.pumpAndSettle();
        expect(agentScroll.offset, closeTo(agentReadingOffset, 1));
        agentScroll.jumpTo(agentAlignedOffset);
        await tester.pumpAndSettle();
        expect(codeHeader, findsOneWidget);
        expect(
          tester.getSemantics(codeHeader).flagsCollection.isExpanded,
          Tristate.isTrue,
        );
        await tester.tap(codeHeader);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('nested line 99'), findsNothing);
        await tester.tap(find.text('Main'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(InputBar), findsOneWidget);
        expect(mainScroll.offset, closeTo(readingOffset, 1));
        expect(
          find.byKey(const Key('tool-disclosure')).hitTestable(),
          findsNothing,
        );
        // Plan75: real recovered static source owns one nested viewport heading,
        // not an inferred child-tool event. Its independent controls/state persist.
        final recovered =
            jsonDecode(
                  File(
                    'test/ui/chat/fixtures/75/75-reported-tool.json',
                  ).readAsStringSync(),
                )
                as Map;
        final recoveredScript =
            (recovered['arguments'] as Map)['code'] as String;
        final preview = embeddedCodemodeSource(recoveredScript).first;
        final nestedTool = ToolEvent(
          id: 'nested',
          toolCallId: 'nested',
          tool: 'codemode',
          args: recovered['arguments'],
        );
        vm.emit(ChatReady(messages: [nestedTool, agent, initialAgent]));
        await tester.pumpAndSettle();
        mainScroll.jumpTo(0);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('tool-disclosure')).hitTestable(),
        );
        await tester.pumpAndSettle();
        // The composite outer Scroll must not unbound nested frames or headings.
        await tester.tap(find.byKey(const Key('code-wrap')).hitTestable());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final embeddedViewport = find.byKey(
          ValueKey('tool-embedded-nested-${preview.offset}'),
        );
        await tester.tap(
          find
              .descendant(
                of: embeddedViewport,
                matching: find.byKey(const Key('code-disclosure')),
              )
              .hitTestable(),
        );
        await tester.pumpAndSettle();
        final nestedHeading = find
            .byKey(const Key('code-disclosure'))
            .hitTestable();
        expect(
          tester.getRect(nestedHeading).top,
          closeTo(tester.getRect(mainList).top + kAccordionGutter, 1),
        );
        final nestedAlignedOffset = mainScroll.offset;
        mainScroll.jumpTo(
          (mainScroll.offset - 300).clamp(
            0,
            mainScroll.position.maxScrollExtent,
          ),
        );
        await tester.pumpAndSettle();
        expect(nestedHeading, findsNothing);
        expect(find.byKey(const Key('accordion-pinned-heading')), findsNothing);
        mainScroll.jumpTo(nestedAlignedOffset);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byTooltip('Copy decoded embedded string').hitTestable(),
        );
        await tester.pump();
        expect(copied, preview.text);
        await tester.tap(
          find
              .descendant(
                of: embeddedViewport,
                matching: find.byKey(const Key('code-wrap')),
              )
              .hitTestable(),
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: embeddedViewport,
            matching: find.byTooltip('Wrap code'),
          ),
          findsOneWidget,
        );
        vm.emit(
          ChatReady(
            messages: [
              nestedTool.copyWith(status: ToolEventStatus.completed),
              agent,
              initialAgent,
            ],
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sub-agents'));
        await tester.pumpAndSettle();
        expect(
          find.byTooltip('Copy decoded embedded string').hitTestable(),
          findsNothing,
        );
        expect(
          tester
              .widget<SubagentPanel>(find.byType(SubagentPanel))
              .invocations
              .length,
          2,
        );
        await tester.tap(find.text('Main'));
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: embeddedViewport,
            matching: find.byTooltip('Wrap code'),
          ),
          findsOneWidget,
        );
        await tester.ensureVisible(
          find.descendant(
            of: embeddedViewport,
            matching: find.byKey(const Key('code-disclosure')),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(nestedHeading);
        await tester.pumpAndSettle();
        expect(find.text(preview.text), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        vm.testPeer = const PeerRecord(
          remoteEpk: 'another-peer',
          roomId: 'other-room',
          sessionName: 'Other',
          relayUrl: 'ws://example',
          pairedAt: 'today',
        );
        vm.emit(
          const ChatReady(
            messages: [UserMsg(id: 'other', text: 'Other room')],
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const Key('tool-disclosure')).hitTestable(),
          findsNothing,
        );
        expect(find.byType(InputBar), findsOneWidget);
        expect(find.text('Other room'), findsWidgets);
        expect(find.text('retained main draft'), findsNothing);
        expect(toggle, findsNothing);
        expect(find.byType(AccordionAnchor), findsNothing);
        vm.emit(const ChatReady(messages: [initialAgent]));
        await tester.pumpAndSettle();
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(find.byType(InputBar), findsNothing);
        vm.testPeer = const PeerRecord(
          remoteEpk: 'another-peer',
          roomId: 'same-peer-new-room',
          sessionName: 'Next room',
          relayUrl: 'ws://example',
          pairedAt: 'today',
        );
        vm.emit(
          const ChatReady(
            messages: [UserMsg(id: 'next', text: 'Same peer next room')],
          ),
        );
        await tester.pumpAndSettle();
        expect(toggle, findsNothing);
        expect(find.byType(InputBar), findsOneWidget);
        expect(find.text('Same peer next room'), findsWidgets);
        expect(tester.takeException(), isNull);
        semantics.dispose();
        await tester.pumpWidget(const SizedBox());
        vm.dispose();
        attach.dispose();
        voice.dispose();
        actions.dispose();
        sync.dispose();
        sel.dispose();
        conn.dispose();
      },
    );
  }

  testWidgets(
    'last reverse tool aligns once and its original heading scrolls away',
    (tester) async {
      tester.view.physicalSize = const Size(360, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final capture = GlobalKey();
      final conn = ConnectionManager(
        factory: (_, _) async => _FakeChannel(),
        storage: _FakeStorage(),
      );
      final boxes = LocalBoxes();
      final sync = SyncService(conn, boxes);
      final prefs = Preferences(_FakeSecureStorage());
      final actions = ActionsRepository(conn);
      final vm = ChatViewModel(
        SessionReadRepository(boxes),
        sync,
        conn,
        prefs,
        _FakeStorage(),
      );
      final voice = VoiceInputViewModel(_FakeSpeech());
      final attach = AttachmentViewModel(_FakePicker(), actions);
      final sel = SessionSelection();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildDarkTheme(),
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<ChatViewModel>.value(value: vm),
              ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
              ChangeNotifierProvider<AttachmentViewModel>.value(value: attach),
              ChangeNotifierProvider<Preferences>.value(value: prefs),
              ChangeNotifierProvider<SessionSelection>.value(value: sel),
            ],
            child: RepaintBoundary(
              key: capture,
              child: const ChatPage(initialOnline: true),
            ),
          ),
        ),
      );
      await tester.pump();

      vm.emit(
        ChatReady(
          messages: [
            const UserMsg(id: 'p', text: 'Parent'),
            ToolEvent(
              id: 'long',
              toolCallId: 'long',
              tool: 'bash',
              args: const {'command': 'long output'},
              status: ToolEventStatus.completed,
              result: List.generate(150, (i) => 'Line $i').join('\n'),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final list = find.byWidgetPredicate((w) => w is ListView && w.reverse);
      await tester.tap(find.byKey(const Key('tool-disclosure')).hitTestable());
      await tester.pumpAndSettle();
      final heading = find.byKey(const Key('tool-disclosure')).hitTestable();
      expect(heading, findsOneWidget);
      expect(
        tester.getRect(heading).top,
        closeTo(tester.getRect(list).top + kAccordionGutter, 1),
      );
      expect(tester.getSize(heading).height, 48);
      for (final action in [
        find.byTooltip('Copy output'),
        find.byTooltip('Copy command'),
        find.byTooltip('Scroll horizontally'),
      ]) {
        expect(tester.getRect(action).top, tester.getRect(heading).top);
        expect(tester.getSize(action), const Size(48, 48));
        expect(
          tester.getRect(action).overlaps(tester.getRect(heading)),
          isFalse,
        );
      }
      expect(find.text('DONE'), findsNothing);
      expect(find.byTooltip('DONE'), findsOneWidget);
      if (const bool.fromEnvironment('CAPTURE86')) {
        await tester.runAsync(() async {
          final image =
              await (capture.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'build/86-compact-chat/${const String.fromEnvironment('CAPTURE_PHASE', defaultValue: 'followup')}/chat-ordinary-360-1x.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      final scroll = tester.widget<ListView>(list).controller!;
      final alignedOffset = scroll.offset;
      scroll.jumpTo(
        (scroll.offset - 300).clamp(0, scroll.position.maxScrollExtent),
      );
      await tester.pumpAndSettle();
      expect(heading, findsNothing);
      expect(find.byKey(const Key('accordion-pinned-heading')), findsNothing);
      final readingTop = tester.getTopLeft(find.byType(ToolRequestCard)).dy;
      tester.view.viewInsets = const FakeViewPadding(bottom: 180);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(heading, findsNothing);
      expect(
        tester.getTopLeft(find.byType(ToolRequestCard)).dy,
        closeTo(readingTop, 0.5),
      );
      scroll.jumpTo(alignedOffset);
      await tester.ensureVisible(find.byKey(const Key('tool-disclosure')));
      await tester.pumpAndSettle();
      expect(heading, findsOneWidget);
      await tester.tap(heading);
      await tester.pumpAndSettle();
      expect(find.textContaining('Line 149'), findsNothing);
      expect(find.byKey(const Key('accordion-pinned-heading')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      vm.dispose();
      attach.dispose();
      voice.dispose();
      actions.dispose();
      sync.dispose();
      sel.dispose();
      conn.dispose();
    },
  );

  testWidgets(
    'reverse assistant code aligns independently and scrolls its heading away',
    (tester) async {
      final conn = ConnectionManager(
        factory: (_, _) async => _FakeChannel(),
        storage: _FakeStorage(),
      );
      final boxes = LocalBoxes();
      final sync = SyncService(conn, boxes);
      final prefs = Preferences(_FakeSecureStorage());
      final actions = ActionsRepository(conn);
      final vm = ChatViewModel(
        SessionReadRepository(boxes),
        sync,
        conn,
        prefs,
        _FakeStorage(),
      );
      final voice = VoiceInputViewModel(_FakeSpeech());
      final attach = AttachmentViewModel(_FakePicker(), actions);
      final sel = SessionSelection();
      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<ChatViewModel>.value(value: vm),
              ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
              ChangeNotifierProvider<AttachmentViewModel>.value(value: attach),
              ChangeNotifierProvider<Preferences>.value(value: prefs),
              ChangeNotifierProvider<SessionSelection>.value(value: sel),
            ],
            child: const ChatPage(initialOnline: true),
          ),
        ),
      );
      await tester.pump();

      final lines = List.generate(80, (i) => 'output $i').join('\n');
      vm.emit(
        ChatReady(
          messages: [
            AssistantMsg(id: 'code', text: 'Example\n```dart\n$lines\n```'),
            ToolEvent(
              id: 'cmd',
              toolCallId: 'cmd',
              tool: 'bash',
              args: const {'command': 'command'},
              result: lines,
              status: ToolEventStatus.completed,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tool-disclosure')).hitTestable());
      await tester.pumpAndSettle();
      final list = find.byWidgetPredicate((w) => w is ListView && w.reverse);
      final scroll = tester.widget<ListView>(list).controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('accordion-pinned-heading')),
          matching: find.byKey(const Key('tool-disclosure')),
        ),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('code-disclosure')).hitTestable());
      await tester.pumpAndSettle();
      final heading = find.byKey(const Key('code-disclosure')).hitTestable();
      expect(heading, findsOneWidget);
      expect(
        tester.getRect(heading).top,
        closeTo(tester.getRect(list).top + kAccordionGutter, 1),
      );
      expect(
        tester
            .widgetList<AccordionAnchor>(
              find.byType(AccordionAnchor, skipOffstage: false),
            )
            .where((a) => a.expanded)
            .length,
        2,
      );
      final codeAlignedOffset = scroll.offset;
      scroll.jumpTo(scroll.offset - 200);
      await tester.pumpAndSettle();
      expect(heading, findsNothing);
      scroll.jumpTo(codeAlignedOffset);
      await tester.pumpAndSettle();
      expect(heading, findsOneWidget);
      await tester.tap(heading);
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<AccordionAnchor>(
              find.byType(AccordionAnchor, skipOffstage: false),
            )
            .where((a) => a.expanded)
            .length,
        1,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      vm.dispose();
      attach.dispose();
      voice.dispose();
      actions.dispose();
      sync.dispose();
      sel.dispose();
      conn.dispose();
    },
  );

  testWidgets(
    'header toggles tools, nested code and subagents together without pinning or changing preferences',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final conn = ConnectionManager(
        factory: (_, _) async => _FakeChannel(),
        storage: _FakeStorage(),
      );
      final boxes = LocalBoxes();
      final sync = SyncService(conn, boxes);
      final prefs = Preferences(_FakeSecureStorage());
      final actions = ActionsRepository(conn);
      final vm = _SessionVM(
        SessionReadRepository(boxes),
        sync,
        conn,
        prefs,
        _FakeStorage(),
      );
      final voice = VoiceInputViewModel(_FakeSpeech());
      final attach = AttachmentViewModel(_FakePicker(), actions);
      final sel = SessionSelection();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildDarkTheme(),
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<ChatViewModel>.value(value: vm),
              ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
              ChangeNotifierProvider<AttachmentViewModel>.value(value: attach),
              ChangeNotifierProvider<Preferences>.value(value: prefs),
              ChangeNotifierProvider<SessionSelection>.value(value: sel),
            ],
            child: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: const ChatPage(initialOnline: true),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final messages = <ChatMessage>[
        const ToolEvent(
          id: 'agent-bulk',
          toolCallId: 'agent-bulk',
          tool: 'subagent',
          args: {'agent': 'scout', 'task': 'Synthetic task'},
          result: '```python\nprint("synthetic child")\n```',
        ),
        const AssistantMsg(
          id: 'code-bulk',
          text: '```python\nprint("synthetic code")\n```',
        ),
        const ToolEvent(
          id: 'tool-bulk',
          toolCallId: 'tool-bulk',
          tool: 'read_symbol',
          args: {'path': 'example.py', 'symbol': 'example'},
          result: 'def example():\n    return 42\n',
        ),
      ];
      vm.emit(ChatReady(messages: messages));
      await tester.pumpAndSettle();
      final button = find.byKey(const Key('toggle-all-accordions'));
      expect(tester.getSize(button).shortestSide, greaterThanOrEqualTo(48));
      expect(find.byTooltip('Expand all accordions'), findsOneWidget);
      final list = find.byWidgetPredicate((w) => w is ListView && w.reverse);
      final scroll = tester.widget<ListView>(list).controller!;
      final initialOffset = scroll.offset;
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Collapse all accordions'), findsOneWidget);
      expect(
        tester.widgetList<AccordionAnchor>(
          find.byType(AccordionAnchor, skipOffstage: false),
        ),
        everyElement(
          isA<AccordionAnchor>().having((w) => w.expanded, 'expanded', true),
        ),
      );
      expect(scroll.offset, closeTo(initialOffset, 1));
      messages.add(
        const ToolEvent(
          id: 'new-bulk',
          toolCallId: 'new-bulk',
          tool: 'read',
          args: {'path': 'new.py'},
          result: 'print("new row")',
        ),
      );
      vm.testWorking = true;
      vm.emit(ChatReady(messages: messages.toList()));
      await tester.pump();
      expect(find.text('Reading new.py…'), findsOneWidget);
      expect(find.text('print("new row")'), findsNothing);
      expect(find.textContaining('Read 1 file'), findsNothing);
      vm.testWorking = false;
      messages[messages.length - 1] = const ToolEvent(
        id: 'new-bulk',
        toolCallId: 'new-bulk',
        tool: 'read',
        args: {'path': 'new.py'},
        status: ToolEventStatus.completed,
        result: 'print("new row")',
      );
      vm.emit(ChatReady(messages: messages.toList()));
      await tester.pumpAndSettle();
      expect(find.text('Reading new.py…'), findsNothing);
      expect(find.text('print("new row")'), findsNothing);
      const supervisor = ToolEvent(
        id: 'supervisor',
        toolCallId: 'supervisor',
        tool: 'functions.subagent_supervisor',
        args: {'action': 'reply'},
        result: 'Internal coordination payload',
      );
      messages.add(supervisor);
      vm.testWorking = true;
      vm.emit(ChatReady(messages: messages.toList()));
      await tester.pump();
      expect(find.text('Coordinating agents…'), findsOneWidget);
      expect(find.text('Internal coordination payload'), findsNothing);
      expect(find.byType(ToolRequestCard), findsNothing);
      messages[messages.length - 1] = supervisor.copyWith(
        status: ToolEventStatus.failed,
        error: 'Worker unavailable',
      );
      vm.testWorking = false;
      vm.emit(ChatReady(messages: messages.toList()));
      await tester.pumpAndSettle();
      expect(find.text('Agent coordination failed'), findsOneWidget);
      expect(find.text('Worker unavailable'), findsOneWidget);
      expect(find.byType(ToolRequestCard), findsNothing);
      messages[messages.length - 1] = supervisor.copyWith(
        status: ToolEventStatus.completed,
      );
      vm.emit(ChatReady(messages: messages.toList()));
      await tester.pumpAndSettle();
      expect(find.text('Agent coordination failed'), findsNothing);
      await tester.tap(find.byKey(const Key('thread-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('Synthetic task'), findsOneWidget);
      expect(
        find.text('Collapse all'),
        findsNothing,
      ); // header owns the bulk action
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('Synthetic task'), findsNothing);
      expect(
        tester.widgetList<AccordionAnchor>(
          find.byType(AccordionAnchor, skipOffstage: false),
        ),
        everyElement(
          isA<AccordionAnchor>().having((w) => w.expanded, 'expanded', false),
        ),
      );
      expect(prefs.collapseSubagents, isTrue);
      await tester.tap(find.byKey(const Key('thread-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('code-disclosure')).hitTestable().first,
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<AccordionAnchor>(find.byType(AccordionAnchor))
            .any((w) => w.expanded),
        isTrue,
      );
      await tester.tap(
        button,
      ); // expand again overrides local choices and includes nested rows
      await tester.pumpAndSettle();
      vm.testPeer = const PeerRecord(
        remoteEpk: 'new-peer',
        roomId: 'new-room',
        sessionName: 'New',
        relayUrl: 'ws://example',
        pairedAt: 'today',
      );
      vm.emit(ChatReady(messages: messages.toList()));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Expand all accordions'), findsOneWidget);
      expect(
        tester.widgetList<AccordionAnchor>(
          find.byType(AccordionAnchor, skipOffstage: false),
        ),
        everyElement(
          isA<AccordionAnchor>().having((w) => w.expanded, 'expanded', false),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      vm.dispose();
      attach.dispose();
      voice.dispose();
      actions.dispose();
      sync.dispose();
      sel.dispose();
      conn.dispose();
    },
  );

  testWidgets(
    'reverse separated history with retained tool survives streaming and reload',
    (tester) async {
      final conn = ConnectionManager(
        factory: (_, _) async => _FakeChannel(),
        storage: _FakeStorage(),
      );
      final boxes = LocalBoxes();
      final sync = SyncService(conn, boxes);
      final prefs = Preferences(_FakeSecureStorage());
      final actions = ActionsRepository(conn);
      final vm = ChatViewModel(
        SessionReadRepository(boxes),
        sync,
        conn,
        prefs,
        _FakeStorage(),
      );
      final voice = VoiceInputViewModel(_FakeSpeech());
      final attach = AttachmentViewModel(_FakePicker(), actions);
      final sel = SessionSelection();
      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<ChatViewModel>.value(value: vm),
              ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
              ChangeNotifierProvider<AttachmentViewModel>.value(value: attach),
              ChangeNotifierProvider<Preferences>.value(value: prefs),
              ChangeNotifierProvider<SessionSelection>.value(value: sel),
            ],
            child: const ChatPage(initialOnline: true),
          ),
        ),
      );
      await tester.pump();
      final history = <ChatMessage>[
        for (var i = 0; i < 30; i++) ...[
          UserMsg(id: 'a$i', text: 'Prompt $i'),
          AssistantMsg(id: 'a$i', text: 'History $i\n' * 4),
          AssistantMsg(id: 'a$i', text: 'Segment $i'),
        ],
        const UserMsg(
          id: 'streaming',
          text: 'A valid ID, not a reserved row key',
        ),
        const ToolEvent(
          id: 'tool',
          toolCallId: 'tool',
          tool: 'bash',
          args: {'command': 'pwd'},
          status: ToolEventStatus.completed,
          result: 'directory',
        ),
        const ToolEvent(
          id: 'tool-two',
          toolCallId: 'tool-two',
          tool: 'bash',
          args: {'command': 'ls'},
          status: ToolEventStatus.completed,
          result: 'second directory',
        ),
      ];
      Future<void> show(
        List<ChatMessage> messages, [
        StreamingMessage? streaming,
      ]) async {
        vm.emit(ChatReady(messages: messages, streaming: streaming));
        await tester.pump();
        expect(tester.takeException(), isNull);
      }

      await show(history);
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ToolRequestCard, 'BASH · ls'),
          matching: find.byKey(const Key('tool-disclosure')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('BASH · pwd'),
        150,
        scrollable: find
            .descendant(
              of: find.byWidgetPredicate((w) => w is ListView && w.reverse),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ToolRequestCard, 'BASH · pwd'),
          matching: find.byKey(const Key('tool-disclosure')),
        ),
      );
      await tester.pumpAndSettle();
      final list = find.byWidgetPredicate((w) => w is ListView && w.reverse);
      final scroll = tester.widget<ListView>(list).controller!;
      await tester.pumpAndSettle();
      scroll.jumpTo(1400);
      await tester.pumpAndSettle();
      final reading = find
          .descendant(
            of: list,
            matching: find.byWidgetPredicate(
              (w) =>
                  w is SelectableText &&
                  (w.data?.startsWith('Prompt ') ?? false),
            ),
          )
          .hitTestable()
          .first;
      final readingText = tester.widget<SelectableText>(reading).data!;
      final readingY = tester.getTopLeft(reading).dy;
      final readingRow = find.descendant(
        of: list,
        matching: find.byWidgetPredicate(
          (w) => w is SelectableText && w.data == readingText,
        ),
      );
      await show([
        ...history,
        const ToolEvent(
          id: 'quiet-read',
          toolCallId: 'quiet-read',
          tool: 'read',
          args: {'path': 'context.dart'},
          status: ToolEventStatus.pending,
        ),
      ]);
      expect(tester.getTopLeft(readingRow).dy, closeTo(readingY, 0.5));
      expect(find.text('New activity'), findsNothing);
      expect(find.textContaining('context.dart'), findsNothing);
      for (var i = 0; i < 5; i++) {
        await show([
          ...history,
          ToolEvent(
            id: 'new-$i',
            toolCallId: 'new-$i',
            tool: 'edit',
            args: {
              'path': 'file-$i.dart',
              'edits': [
                {'oldText': 'before', 'newText': 'after'},
              ],
            },
            status: ToolEventStatus.completed,
          ),
        ]);
        expect(tester.getTopLeft(readingRow).dy, closeTo(readingY, 0.5));
        expect(find.text('New activity'), findsOneWidget);
        await show(
          history,
          StreamingMessage(
            inReplyTo: 'streaming',
            buffer: 'Streaming $i\n' * 8,
          ),
        );
        expect(tester.getTopLeft(readingRow).dy, closeTo(readingY, 0.5));
        await show([
          ...history,
          AssistantMsg(id: 'streaming', text: 'Persisted $i'),
        ]);
        expect(tester.getTopLeft(readingRow).dy, closeTo(readingY, 0.5));
        await show(history.toList());
        expect(tester.getTopLeft(readingRow).dy, closeTo(readingY, 0.5));
      }
      // Explicit navigation respects reduced motion; arriving updates alone
      // must never leave the reading position above.
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('scroll-to-latest')));
      await tester.pump();
      expect(scroll.offset, 0);
      expect(find.text('New activity'), findsNothing);
      await show([
        ...history,
        const AssistantMsg(id: 'bottom-update', text: 'Arrived at bottom'),
      ]);
      expect(scroll.offset, 0);
      expect(find.text('New activity'), findsNothing);
      await show(history);
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.text('second directory'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('directory'),
        150,
        scrollable: find
            .descendant(of: list, matching: find.byType(Scrollable))
            .first,
      );
      await tester.pumpAndSettle();
      expect(find.text('directory'), findsOneWidget);
      history.removeLast();
      await show(history.toList());
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      // Explicit collapse and wrap choices survive offscreen keepalive/remapping.
      await tester.tap(find.byKey(const Key('code-wrap')).hitTestable().first);
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('tool-disclosure')).hitTestable().first,
      );
      await tester.pump();
      scroll.jumpTo(1400);
      await tester.pump();
      await show(
        history,
        const StreamingMessage(inReplyTo: 'streaming', buffer: 'Next'),
      );
      await show(history);
      // Settle any anchor correction after the retained rows move, then
      // return to the actual bottom before hitting their controls.
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.text('directory'), findsNothing);
      await tester.tap(
        find.byKey(const Key('tool-disclosure')).hitTestable().first,
      );
      await tester.pump();
      expect(find.byTooltip('Wrap code').hitTestable(), findsOneWidget);

      // Tool classification can remove a retained row from the main thread.
      await show([
        ...history.take(history.length - 1),
        const ToolEvent(
          id: 'tool',
          toolCallId: 'tool',
          tool: 'subagent',
          args: {'agent': 'scout', 'task': 'Inspect'},
        ),
      ]);
      expect(
        find.byKey(const Key('tool-disclosure')).hitTestable(),
        findsNothing,
      );
      await show(history);
      expect(
        find.text('directory'),
        findsNothing,
      ); // removed rows start collapsed

      // A short reversed list naturally paints at the bottom, not at the top.
      await show(const [UserMsg(id: 'short', text: 'Short history')]);
      expect(
        tester
            .getRect(
              find.descendant(of: list, matching: find.text('Short history')),
            )
            .bottom,
        greaterThan(tester.getRect(list).center.dy),
      );
      // This branch is not a painting failure: there really are no messages in
      // state. Presence does not imply history, and no sliver is built here.
      await show(const []);
      expect(find.text('No messages available'), findsOneWidget);
      expect(find.text('online'), findsOneWidget);
      expect(list, findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      vm.dispose();
      attach.dispose();
      voice.dispose();
      actions.dispose();
      sync.dispose();
      sel.dispose();
      conn.dispose();
    },
  );
}
