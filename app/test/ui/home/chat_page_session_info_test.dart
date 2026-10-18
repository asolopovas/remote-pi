import 'dart:async';
import 'package:app/domain/contracts/session_control_repository.dart';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/local/boxes.dart';
import 'package:app/data/local/records/message_record.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/repositories/session_read_repository.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/voice/speech_service.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/ui/chat/states/chat_state.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:app/data/local/records/runtime_record.dart';
import 'package:app/domain/session_state.dart';
import 'package:provider/provider.dart';

import '../../transport/connection_manager_display_test.dart' as data;
import 'session_display_name_test.dart' show fixtureDisplay;

class _Storage extends data.Storage {
  @override
  Future<PeerRecord?> loadPeer(String epk) async => data.peer;
  @override
  Future<void> savePeer(PeerRecord peer) async {}
}

class _DeferredRoomStorage extends _Storage {
  Completer<List<PersistedRoom>>? pendingRooms;
  @override
  Future<List<PersistedRoom>> loadRooms(String epk) =>
      pendingRooms?.future ?? super.loadRooms(epk);
}

class _Secure implements FlutterSecureStorage {
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
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Actions extends ActionsRepository {
  _Actions(super.conn);
  @override
  Future<ModelsCatalogue> listModels({bool forceRefresh = false}) async =>
      const ModelsCatalogue(models: []);
}

class _Speech implements SpeechService {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Picker implements IImagePickerService {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Read extends SessionReadRepository {
  _Read(super.boxes);
  @override
  Stream<List<MessageRecord>> watchMessages(String epk, String roomId) =>
      Stream.value([
        MessageRecord(
          id: 'synthetic-message',
          seq: 1,
          role: MsgRole.user,
          text: 'synthetic retained message',
          ts: DateTime(2026),
        ),
      ]);
  @override
  Stream<RuntimeRecord> watchRuntime(String epk, String roomId) => Stream.value(
    const RuntimeRecord(
      connection: RuntimeConnection.online,
      presence: RuntimePresence.alive,
    ),
  );
}

class _Sync extends SyncService {
  _Sync(super.conn, super.boxes);
  int requests = 0;
  @override
  Future<void> activate(String epk, String roomId) async {}
  @override
  void requestSync() {
    requests++;
  }

  @override
  List<QueuedMsg> get queuedMessages => [
    QueuedMsg(
      id: 'synthetic-queue',
      text: 'retained follow-up',
      editable: true,
      createdAt: DateTime(2026),
    ),
  ];
}

// Deliberately controlled presentation scope for lifecycle cases only; the
// mounted metadata test below uses the real roomsStream and production VM.
class _ScopeChat extends ChatViewModel {
  _ScopeChat(
    super.read,
    super.sync,
    super.conn,
    super.prefs,
    super.storage, {
    super.sessionControls,
  });
  PeerRecord? peer = data.peer.copyWith(roomId: 'r1');
  RoomInfo? room = const RoomInfo(
    startedAt: 1,
    roomId: 'r1',
    localName: 'Scoped name',
    cwd: '/scope',
  );
  final Set<VoidCallback> listeners = {};
  @override
  PeerRecord? get activePeer => peer;
  @override
  RoomInfo? get activeRoom => room;
  @override
  ChatState get state => const ChatReady(messages: []);
  @override
  void addListener(VoidCallback listener) {
    listeners.add(listener);
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners.remove(listener);
    super.removeListener(listener);
  }

  void changed() => notifyListeners();
}

class _StopControls extends SessionControlRepository {
  int inspections = 0, stops = 0;
  Completer<SessionStopCapability>? pending;
  bool unknown = false;
  bool allowed = true;
  SessionAccess? access;
  LaunchingHost? origin;
  @override
  Future<SessionStopCapability> inspect(String peer, String room) async {
    inspections++;
    return pending?.future ??
        SessionStopCapability(
          peer: peer,
          room: room,
          canStop: allowed,
          token: allowed ? 'opaque' : null,
          access: access,
          launchingHost: origin,
        );
  }

  @override
  Future<SessionStopOutcome> stop(SessionStopCapability capability) async {
    stops++;
    if (unknown) {
      throw const SessionControlFailure('Lost reply', outcomeUnknown: true);
    }
    return SessionStopOutcome.requested;
  }

  @override
  void dispose() {}
}

class _PushFailingNavigator extends Navigator {
  _PushFailingNavigator({required Widget page})
    : super(
        onGenerateRoute: (settings) =>
            MaterialPageRoute<void>(settings: settings, builder: (_) => page),
      );
  @override
  NavigatorState createState() => _PushFailingNavigatorState();
}

class _PushFailingNavigatorState extends NavigatorState {
  @override
  Future<T?> push<T extends Object?>(Route<T> route) {
    throw StateError('Synthetic dialog push failure');
  }
}

class _DialogObserver extends NavigatorObserver {
  DialogRoute<dynamic>? dialog;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is DialogRoute) dialog = route;
  }
}

class _DialogLifecycleHarness {
  _DialogLifecycleHarness(this.dataHarness, this.prefs, this.sync, this.vm)
    : current = vm;
  final data.Harness dataHarness;
  final Preferences prefs;
  final _Sync sync;
  final ChatViewModel vm;
  ChatViewModel current;
  final rebuild = ValueNotifier(0);
  final additionalVms = <ChatViewModel>[];
  final voice = VoiceInputViewModel(_Speech());
  late final actions = _Actions(dataHarness.cm);
  late final attach = AttachmentViewModel(_Picker(), actions);
  bool showPage = true;
  bool dark = true;
  double scale = 1;
  final observer = _DialogObserver();
  Widget get page => ChangeNotifierProvider<ChatViewModel>.value(
    value: current,
    child: showPage ? const ChatPage(showBack: false) : const SizedBox(),
  );

  static Future<_DialogLifecycleHarness> create(
    WidgetTester tester, {
    _Storage? storage,
    bool realVm = false,
    SessionControlRepository? sessionControls,
  }) async {
    final h = (await tester.runAsync(
      () => data.Harness.create(storage ?? _Storage()),
    ))!;
    final prefs = Preferences(_Secure());
    if (realVm) {
      await tester.runAsync(() => h.push(data.announced(value: null)));
      await prefs.setSelectedRoom(epk: data.peer.remoteEpk, roomId: 'r1');
    }
    final boxes = LocalBoxes();
    final sync = _Sync(h.cm, boxes);
    final vm = realVm
        ? ChatViewModel(
            _Read(boxes),
            sync,
            h.cm,
            prefs,
            h.storage,
            sessionControls: sessionControls,
          )
        : _ScopeChat(
            _Read(boxes),
            sync,
            h.cm,
            prefs,
            h.storage,
            sessionControls: sessionControls,
          );
    return _DialogLifecycleHarness(h, prefs, sync, vm);
  }

  Future<void> mount(WidgetTester tester, {bool failPush = false}) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<Preferences>.value(value: prefs),
          ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
          ChangeNotifierProvider<AttachmentViewModel>.value(value: attach),
        ],
        child: ValueListenableBuilder(
          valueListenable: rebuild,
          builder: (_, _, _) => MaterialApp(
            theme: dark ? buildDarkTheme() : buildLightTheme(),
            navigatorObservers: [observer],
            builder: (_, child) => MediaQuery(
              // Lifecycle tests settle with reduced motion; rotation is tested separately.
              data: MediaQueryData(
                disableAnimations: true,
                textScaler: TextScaler.linear(scale),
              ),
              child: failPush ? _PushFailingNavigator(page: page) : child!,
            ),
            home: ValueListenableBuilder(
              valueListenable: rebuild,
              builder: (_, _, _) => page,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    for (final chat in [vm, ...additionalVms]) {
      if (chat is _ScopeChat) expect(chat.listeners, isEmpty);
      chat.dispose();
    }
    voice.dispose();
    attach.dispose();
    actions.dispose();
    sync.dispose();
    prefs.dispose();
    rebuild.dispose();
  }
}

void main() {
  for (final state in ['unlocked', 'locked', 'expired', 'unavailable']) {
    testWidgets(
      'Session info own launching-host access $state is scoped, fresh and never automatic Stop',
      (tester) async {
        final timed = state == 'unlocked' || state == 'expired';
        final controls = _StopControls()
          ..allowed = state == 'unlocked'
          ..origin = const LaunchingHost('actual-root', 'actual-launcher')
          ..access = SessionAccess(
            state,
            timed
                ? DateTime.now().millisecondsSinceEpoch +
                      (state == 'unlocked' ? 60000 : -1)
                : null,
          );
        final h = await _DialogLifecycleHarness.create(
          tester,
          sessionControls: controls,
        );
        await h.mount(tester);
        await tester.tap(find.byTooltip('Session info'));
        await tester.pumpAndSettle();
        expect(find.text('actual-root · actual-launcher'), findsOneWidget);
        expect(
          find.text(
            state == 'locked' || state == 'expired'
                ? 'Unlock launching host'
                : 'Check access',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            state == 'expired'
                ? 'access expired'
                : state == 'unavailable'
                ? 'host unavailable'
                : 'host $state',
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('stop-session-agent')),
          state == 'unlocked' ? findsOneWidget : findsNothing,
        );
        expect(controls.stops, 0);
        await tester.pump(const Duration(seconds: 31));
        await tester.pumpAndSettle();
        expect(find.text('Access unknown · Check access'), findsOneWidget);
        expect(find.byKey(const Key('stop-session-agent')), findsNothing);
        expect(controls.stops, 0);
        await tester.tap(find.byTooltip('Close info'));
        await tester.pumpAndSettle();
        await h.dispose(tester);
      },
    );
  }
  testWidgets(
    'same child room replaced cannot retain old access snapshot or Stop',
    (tester) async {
      final controls = _StopControls()
        ..access = SessionAccess(
          'unlocked',
          DateTime.now().millisecondsSinceEpoch + 60000,
        );
      final h = await _DialogLifecycleHarness.create(
        tester,
        sessionControls: controls,
      );
      await h.mount(tester);
      await tester.tap(find.byTooltip('Session info'));
      await tester.pumpAndSettle();
      expect(find.textContaining('host unlocked until'), findsOneWidget);
      final scope = h.vm as _ScopeChat;
      scope.room = RoomInfo(
        roomId: scope.room!.roomId,
        startedAt: scope.room!.startedAt + 1,
      );
      scope.changed();
      await tester.pumpAndSettle();
      expect(find.textContaining('host unlocked until'), findsNothing);
      expect(find.byKey(const Key('stop-session-agent')), findsNothing);
      expect(controls.stops, 0);
      await tester.tap(find.byTooltip('Close info'));
      await tester.pumpAndSettle();
      await h.dispose(tester);
    },
  );
  for (final outcome in ['cancel', 'confirm', 'switch', 'unknown']) {
    testWidgets('Stop agent is explicit, exact and non-replayed: $outcome', (
      tester,
    ) async {
      final controls = _StopControls()..unknown = outcome == 'unknown';
      final h = await _DialogLifecycleHarness.create(
        tester,
        sessionControls: controls,
      );
      await h.mount(tester);
      await tester.tap(find.byTooltip('Session info'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('stop-session-agent')), findsOneWidget);
      await tester.tap(find.byKey(const Key('stop-session-agent')));
      await tester.pumpAndSettle();
      expect(find.text('Stop agent?'), findsOneWidget);
      expect(find.textContaining('History is kept'), findsOneWidget);
      expect(controls.stops, 0);
      if (outcome == 'switch') {
        (h.vm as _ScopeChat).room = const RoomInfo(
          roomId: 'other-room',
          startedAt: 2,
        );
        (h.vm as _ScopeChat).changed();
        await tester.pump();
      }
      await tester.tap(
        outcome == 'cancel'
            ? find.text('Cancel')
            : find.widgetWithText(FilledButton, 'Stop'),
      );
      await tester.pumpAndSettle();
      expect(
        controls.stops,
        outcome == 'cancel' || outcome == 'switch' ? 0 : 1,
      );
      expect(controls.inspections, 2); // Fresh authority before confirmation.
      if (outcome == 'confirm') expect(find.byType(AlertDialog), findsNothing);
      if (outcome == 'unknown') {
        expect(
          find.text('Stop result unknown. Refresh sessions.'),
          findsOneWidget,
        );
        expect(find.byKey(const Key('stop-session-agent')), findsNothing);
        await tester.tap(find.widgetWithText(TextButton, 'Check status'));
        await tester.pumpAndSettle();
        expect(
          controls.stops,
          1,
        ); // Read-only reconciliation never retries Stop.
        expect(find.byKey(const Key('stop-session-agent')), findsOneWidget);
      }
      if (outcome != 'confirm') {
        await tester.tap(find.byTooltip('Close info'));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      await h.dispose(tester);
    });
  }
  testWidgets(
    'late stop capability cannot enable controls for a replaced room',
    (tester) async {
      final controls = _StopControls()
        ..pending = Completer<SessionStopCapability>();
      final h = await _DialogLifecycleHarness.create(
        tester,
        sessionControls: controls,
      );
      await h.mount(tester);
      await tester.tap(find.byTooltip('Session info'));
      await tester.pump();
      (h.vm as _ScopeChat).room = const RoomInfo(
        roomId: 'other-room',
        startedAt: 2,
      );
      (h.vm as _ScopeChat).changed();
      controls.pending!.complete(
        SessionStopCapability(
          peer: data.peer.remoteEpk,
          room: 'r1',
          canStop: true,
          token: 'late',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('stop-session-agent')), findsNothing);
      expect(controls.stops, 0);
      await tester.tap(find.byTooltip('Close info'));
      await tester.pumpAndSettle();
      await h.dispose(tester);
    },
  );
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    GoogleFonts.config.allowRuntimeFetching = false;
    // No HTTP or downloaded fonts. Only the brand face is substituted in this
    // widget harness; naming/layout uses the production theme and mono assets.
    final font = await rootBundle.load(
      'assets/fonts/fira_mono/FiraMonoNerdFont-Regular.otf',
    );
    final manifest = const StandardMessageCodec().encodeMessage({
      for (final name in ['Inter-Bold.ttf', 'Inter-SemiBold.ttf'])
        name: [
          {'asset': name},
        ],
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
          final name = String.fromCharCodes(message!.buffer.asUint8List());
          if (name == 'AssetManifest.bin') return manifest;
          if (name.startsWith('Inter-')) return font;
          return null;
        });
  });
  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
    GoogleFonts.config.allowRuntimeFetching = true;
  });

  for (final dark in [true, false]) {
    testWidgets(
      'ChatPage SAME mounted Session info live metadata and scroll (${dark ? 'dark' : 'light'})',
      (tester) async {
        tester.view.physicalSize = const Size(320, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final semantics = tester.ensureSemantics();
        final h = (await tester.runAsync(
          () => data.Harness.create(_Storage()),
        ))!;
        await tester.runAsync(
          () =>
              h.push(data.announced(value: fixtureDisplay('rename').toJson())),
        );
        await tester.runAsync(
          () => h.push(
            data.announced(
              value: fixtureDisplay('rename').toJson(),
              room: 'r2',
            ),
          ),
        );
        final prefs = Preferences(_Secure());
        await prefs.setSelectedRoom(epk: data.peer.remoteEpk, roomId: 'r1');
        final boxes = LocalBoxes();
        final sync = _Sync(h.cm, boxes);
        final voice = VoiceInputViewModel(_Speech());
        final actions = _Actions(h.cm);
        final attach = AttachmentViewModel(_Picker(), actions);
        final chat = ChatViewModel(_Read(boxes), sync, h.cm, prefs, h.storage);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          chat.dispose();
          voice.dispose();
          attach.dispose();
          prefs.dispose();
          sync.dispose();
          actions.dispose();
        });
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<ChatViewModel>.value(value: chat),
              ChangeNotifierProvider<Preferences>.value(value: prefs),
              ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
              ChangeNotifierProvider<AttachmentViewModel>.value(value: attach),
            ],
            child: MaterialApp(
              theme: dark ? buildDarkTheme() : buildLightTheme(),
              home: const ChatPage(showBack: false),
              builder: (_, child) => MediaQuery(
                data: const MediaQueryData(
                  disableAnimations: true,
                  size: Size(320, 1100),
                  textScaler: TextScaler.linear(2),
                ),
                child: child!,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
        expect(chat.activeRoom!.roomId, 'r1');
        expect(find.text('Pi · system'), findsOneWidget);
        await tester.enterText(
          find.descendant(
            of: find.byType(InputBar),
            matching: find.byType(TextField),
          ),
          'synthetic unsent draft',
        );
        await tester.pump();
        final before = chat.state as ChatReady;
        final inputState = tester.state(find.byType(InputBar));
        final checks = h.ch.checks.length;
        final sends = h.ch.sends.length;
        final reloads = sync.requests;
        var notices = 0;
        chat.addListener(() => notices++);
        Future<void> patch(
          Map<String, dynamic> meta,
          String title, {
          String room = 'r1',
        }) async {
          await tester.runAsync(() => h.push(data.patch(meta, room: room)));
          await tester.pumpAndSettle();
          expect(find.text(title), findsNWidgets(2));
          expect(
            identical((chat.state as ChatReady).messages, before.messages),
            isTrue,
          );
          expect(
            (chat.state as ChatReady).queuedMessages,
            before.queuedMessages,
          );
          expect(
            identical(tester.state(find.byType(InputBar)), inputState),
            isTrue,
          );
          expect(
            tester
                .widget<TextField>(
                  find.descendant(
                    of: find.byType(InputBar),
                    matching: find.byType(TextField),
                  ),
                )
                .controller!
                .text,
            'synthetic unsent draft',
          );
          expect(prefs.selectedRoomId, 'r1');
          expect(h.cm.activeRoomId, 'r1');
          expect(h.ch.checks.length, checks);
          expect(h.ch.sends.length, sends);
          expect(sync.requests, reloads);
        }

        await tester.tap(find.byTooltip('Session info'));
        await tester.pumpAndSettle();
        final mountedDialog = tester.element(find.byType(AlertDialog));
        await patch({
          'display': data.display(2, 'Renamed <plain>'),
        }, 'Renamed <plain>');
        expect(notices, 1);
        await patch({
          'display': data.display(2, 'Renamed <plain>'),
        }, 'Renamed <plain>');
        expect(notices, 1);
        await patch(
          {'display': data.display(2, 'Other room')},
          'Renamed <plain>',
          room: 'r2',
        );
        expect(notices, 1);
        await patch({'model': 'model-only'}, 'Renamed <plain>');
        expect(notices, 2);
        expect(
          identical(tester.element(find.byType(AlertDialog)), mountedDialog),
          isTrue,
        );
        expect(find.text('model-only'), findsOneWidget);
        expect(find.text('r1'), findsOneWidget);
        expect(find.text('/synthetic/duplicate'), findsOneWidget);
        expect(find.text('Renamed <plain>'), findsNWidgets(2));
        await h.cm.setRoomLocalName(
          data.peer.remoteEpk,
          'r1',
          'Saved fallback',
        );
        await tester.pumpAndSettle();
        expect(find.text('Renamed <plain>'), findsNWidgets(2));
        expect(h.room().localName, 'Saved fallback');
        await patch({
          'display': data.display(3, 'Desktop changed'),
        }, 'Desktop changed');
        expect(h.room().localName, 'Saved fallback');
        expect(
          h.storage.rooms.singleWhere((r) => r.roomId == 'r1').localName,
          'Saved fallback',
        );
        await patch({'display': data.display(4, null)}, 'Saved fallback');
        await patch({
          'display': data.display(5, 'Verified again'),
        }, 'Verified again');
        await patch({'display': null}, 'Saved fallback');
        await patch({
          'display': data.display(6, 'Unverified late'),
        }, 'Saved fallback');
        expect(h.room().localName, 'Saved fallback');
        expect(
          identical(tester.element(find.byType(AlertDialog)), mountedDialog),
          isTrue,
        );
        expect(
          h.storage.rooms.singleWhere((r) => r.roomId == 'r1').localName,
          'Saved fallback',
        );
        await h.cm.setRoomLocalName(data.peer.remoteEpk, 'r1', null);
        await tester.pumpAndSettle();
        expect(find.text('duplicate'), findsNWidgets(2));
        final priorNotices = notices;
        await patch({'working': false}, 'duplicate');
        expect(notices, priorNotices + 1); // State emit must not double-notify.
        expect(find.text('synthetic retained message'), findsOneWidget);
        final longName = ('Literal <plain> **not markdown** ' * 3).trim();
        final longPath = '/synthetic/long-literal-path' * 14;
        final longModel = 'synthetic-long-model' * 12;
        await tester.runAsync(
          () => h.push({
            ...data.announced(value: data.display(8, longName)),
            'cwd': longPath,
            'model': longModel,
          }),
        );
        await tester.pumpAndSettle();
        expect(
          identical(tester.element(find.byType(AlertDialog)), mountedDialog),
          isTrue,
        );
        expect(find.text(longName), findsNWidgets(2));
        expect(find.text(longPath), findsOneWidget);
        expect(find.text(longModel), findsOneWidget);
        final paired = find.text('PAIRED');
        final scroll = find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          paired,
          180,
          scrollable: scroll,
          maxScrolls: 100,
        );
        await tester.pumpAndSettle();
        final dialogRect = tester.getRect(find.byType(AlertDialog));
        expect(dialogRect.contains(tester.getCenter(paired)), isTrue);
        expect(find.byTooltip('Close info').hitTestable(), findsOneWidget);
        await tester.tap(find.byTooltip('Close info'));
        await tester.pumpAndSettle();
        final noticesAfterClose = notices;
        await tester.runAsync(
          () => h.push(data.patch({'model': 'after-close'})),
        );
        await tester.pumpAndSettle();
        expect(notices, noticesAfterClose + 1);
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
        semantics.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  for (final scenario in [
    'peer switch',
    'room switch',
    'room disappears',
    'page teardown',
    'VM replacement',
    'in-flight page teardown',
    'independent VM disposal',
  ]) {
    testWidgets('ChatPage Session info exact lease: $scenario', (tester) async {
      final h = (await tester.runAsync(() => data.Harness.create(_Storage())))!;
      final prefs = Preferences(_Secure());
      final boxes = LocalBoxes();
      final sync = _Sync(h.cm, boxes);
      final vm = _ScopeChat(_Read(boxes), sync, h.cm, prefs, h.storage);
      final replacement = _ScopeChat(
        _Read(boxes),
        sync,
        h.cm,
        prefs,
        h.storage,
      );
      final voice = VoiceInputViewModel(_Speech());
      final actions = _Actions(h.cm);
      final attach = AttachmentViewModel(_Picker(), actions);
      final rebuild = ValueNotifier(0);
      var showPage = true;
      var current = vm;
      var vmDisposed = false;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<Preferences>.value(value: prefs),
            ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
            ChangeNotifierProvider<AttachmentViewModel>.value(value: attach),
          ],
          child: MaterialApp(
            theme: buildDarkTheme(),
            home: ValueListenableBuilder(
              valueListenable: rebuild,
              builder: (_, _, _) => ChangeNotifierProvider<ChatViewModel>.value(
                value: current,
                child: showPage
                    ? const ChatPage(showBack: false)
                    : const SizedBox(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final baselineListeners = vm.listeners.length;
      await tester.tap(find.byTooltip('Session info'));
      if (scenario == 'in-flight page teardown') {
        showPage = false;
        rebuild.value++;
      }
      await tester.pumpAndSettle();
      final mountedDialog = tester.element(find.byType(AlertDialog));
      if (scenario != 'in-flight page teardown') {
        expect(find.text('Scoped name'), findsNWidgets(2));
        expect(vm.listeners.length, baselineListeners + 1);
      }
      switch (scenario) {
        case 'peer switch':
          vm.peer = const PeerRecord(
            remoteEpk: 'synthetic-other-peer',
            sessionName: 'Other',
            relayUrl: 'ws://127.0.0.1',
            pairedAt: '2026-01-01',
            roomId: 'r1',
          );
          vm.changed();
        case 'room switch':
          vm.peer = data.peer.copyWith(roomId: 'r2');
          vm.room = const RoomInfo(
            startedAt: 1,
            roomId: 'r2',
            name: 'Other room',
          );
          vm.changed();
        case 'room disappears':
          vm.room = null;
          vm.changed();
        case 'page teardown':
          showPage = false;
          rebuild.value++;
        case 'VM replacement':
          current = replacement;
          rebuild.value++;
        case 'independent VM disposal':
          vm.dispose();
          vmDisposed = true;
          await tester.runAsync(
            () => h.push(data.patch({'model': 'late-after-dispose'})),
          );
        case 'in-flight page teardown':
          break;
      }
      await tester.pumpAndSettle();
      expect(
        identical(tester.element(find.byType(AlertDialog)), mountedDialog),
        isTrue,
      );
      if (!vmDisposed) {
        expect(find.text('Session unavailable'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Scoped name'),
          ),
          findsNothing,
        );
        // Restoring the identity never revives an invalidated lease.
        vm.peer = data.peer.copyWith(roomId: 'r1');
        vm.room = const RoomInfo(
          startedAt: 1,
          roomId: 'r1',
          name: 'Restored name',
        );
        vm.changed();
        await tester.pumpAndSettle();
        expect(find.text('Session unavailable'), findsOneWidget);
      }
      await tester.tap(find.byTooltip('Close info'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(vm.listeners, isEmpty);
      expect(replacement.listeners, isEmpty);
      if (!vmDisposed) vm.dispose();
      replacement.dispose();
      voice.dispose();
      attach.dispose();
      prefs.dispose();
      actions.dispose();
      sync.dispose();
      rebuild.dispose();
      expect(tester.takeException(), isNull);
    });
  }
  for (final scenario in [
    'closing room loss',
    'closing room switch',
    'closing page teardown',
    'closing VM replacement',
    'unnotified peer switch',
    'unnotified room switch',
    'initial room absence',
    'closing root teardown',
  ]) {
    testWidgets('ChatPage Session info revision2: $scenario', (tester) async {
      final h = await _DialogLifecycleHarness.create(tester);
      final vm = h.vm as _ScopeChat;
      if (scenario == 'initial room absence') vm.room = null;
      await h.mount(tester);
      final listenersBefore = vm.listeners.length;
      await tester.tap(find.byTooltip('Session info'));
      await tester.pumpAndSettle();
      final dialog = tester.element(find.byType(AlertDialog));
      final route = ModalRoute.of(dialog)!;
      var popped = false;
      route.popped.then((_) => popped = true);
      final closing = scenario.startsWith('closing');
      if (closing) {
        await tester.tap(find.byTooltip('Close info'));
        // Process the pop-result Future but NOT the reverse animation/unmount.
        await tester.pump();
        expect(popped, isTrue);
        expect(dialog.mounted, isTrue);
        expect(route.animation!.isDismissed, isFalse);
      }
      switch (scenario) {
        case 'closing room loss':
          vm.room = null;
          vm.changed();
        case 'closing room switch':
        case 'unnotified room switch':
          vm.room = const RoomInfo(
            startedAt: 1,
            roomId: 'r2',
            localName: 'Wrong scope',
          );
          if (closing) vm.changed();
        case 'closing page teardown':
          h.showPage = false;
        case 'closing VM replacement':
          final other = _ScopeChat(
            _Read(LocalBoxes()),
            h.sync,
            h.dataHarness.cm,
            h.prefs,
            h.dataHarness.storage,
          );
          other.room = const RoomInfo(
            startedAt: 1,
            roomId: 'r1',
            localName: 'Wrong VM',
          );
          h.additionalVms.add(other);
          h.current = other;
        case 'unnotified peer switch':
          vm.peer = const PeerRecord(
            remoteEpk: 'other-synthetic-peer',
            sessionName: 'Wrong peer',
            relayUrl: 'ws://127.0.0.1',
            pairedAt: '2026-01-01',
            roomId: 'r1',
          );
        case 'closing root teardown':
          h.showPage = false;
        case 'initial room absence':
          break;
      }
      h.dark = false;
      h.scale = 1.2;
      h.rebuild.value++;
      await tester.pump(const Duration(milliseconds: 10));
      // Page finalization/provider replacement may occur after the overlay's
      // build. Process its redraw, still without advancing/settling the exit.
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(dialog.mounted, isTrue);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Session unavailable'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Wrong scope'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Wrong VM'),
        ),
        findsNothing,
      );
      if (closing) {
        expect(vm.listeners.length, lessThanOrEqualTo(listenersBefore));
      }
      // Loss observed in a build is a permanent tombstone, even without a VM
      // notification at the moment it was observed.
      vm.peer = data.peer.copyWith(roomId: 'r1');
      vm.room = const RoomInfo(
        startedAt: 1,
        roomId: 'r1',
        localName: 'Restored name',
      );
      vm.changed();
      h.dark = true;
      h.rebuild.value++;
      await tester.pump(const Duration(milliseconds: 10));
      expect(find.text('Session unavailable'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (scenario != 'closing root teardown') {
        if (!closing) await tester.tap(find.byTooltip('Close info'));
        await tester.pumpAndSettle();
        expect(dialog.mounted, isFalse);
        expect(find.byType(AlertDialog), findsNothing);
      }
      await h.dispose(
        tester,
      ); // Also exercises queued invalidation/root unmount.
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'ChatPage Session info revision2: CM removal before storage publication',
    (tester) async {
      final storage = _DeferredRoomStorage();
      final h = await _DialogLifecycleHarness.create(
        tester,
        storage: storage,
        realVm: true,
      );
      await h.mount(tester);
      await tester.tap(find.byTooltip('Session info'));
      await tester.pumpAndSettle();
      final dialog = tester.element(find.byType(AlertDialog));
      expect(find.text('duplicate'), findsNWidgets(2));
      var notices = 0;
      h.vm.addListener(() => notices++);
      final gate = Completer<List<PersistedRoom>>();
      storage.pendingRooms = gate;
      final deletion = h.dataHarness.cm.deleteCachedRoom(
        data.peer.remoteEpk,
        'r1',
      );
      expect(h.vm.activeRoom, isNull);
      expect(
        notices,
        0,
      ); // Removal is visible to getters before roomsStream emits.
      h.dark = false;
      h.scale = 1.2;
      h.rebuild.value++;
      await tester.pump(const Duration(milliseconds: 10));
      expect(notices, 0);
      expect(tester.takeException(), isNull);
      expect(
        identical(tester.element(find.byType(AlertDialog)), dialog),
        isTrue,
      );
      expect(find.text('Session unavailable'), findsOneWidget);
      // Restore the exact room while the deletion's storage await is held. The
      // already-observed loss cannot revive the dialog, even on a notification.
      await tester.runAsync(
        () => h.dataHarness.push(
          data.announced(value: data.display(2, 'Restored desktop')),
        ),
      );
      await tester.pump();
      expect(h.vm.activeRoom, isNotNull);
      expect(find.text('Session unavailable'), findsOneWidget);
      gate.complete([]);
      await tester.runAsync(() => deletion);
      storage.pendingRooms = null;
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close info'));
      await tester.pumpAndSettle();
      await h.dispose(tester);
      expect(tester.takeException(), isNull);
    },
  );
  for (final remove in [false, true]) {
    testWidgets(
      'ChatPage Session info revision2: never-built ${remove ? 'removed' : 'popped'} route',
      (tester) async {
        final h = await _DialogLifecycleHarness.create(tester);
        await h.mount(tester);
        final vm = h.vm as _ScopeChat;
        final listenersBefore = vm.listeners.length;
        final info = tester.widget<IconButton>(
          find.byWidgetPredicate(
            (w) => w is IconButton && w.tooltip == 'Session info',
          ),
        );
        final pageContext = tester.element(find.byType(ChatPage));
        info.onPressed!(); // No pump: the dialog builder has never run.
        final route = h.observer.dialog!;
        var completed = false;
        route.completed.then((_) => completed = true);
        expect(vm.listeners.length, listenersBefore + 1);
        final navigator = Navigator.of(pageContext, rootNavigator: true);
        if (remove) {
          navigator.removeRoute(route);
        } else {
          navigator.pop();
        }
        await tester.pumpAndSettle();
        expect(completed, isTrue);
        expect(find.byType(AlertDialog), findsNothing);
        expect(vm.listeners.length, listenersBefore);
        await h.dispose(tester);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'ChatPage Session info revision2: synchronous push failure cleans lease',
    (tester) async {
      final h = await _DialogLifecycleHarness.create(tester);
      await h.mount(tester, failPush: true);
      final vm = h.vm as _ScopeChat;
      final listenersBefore = vm.listeners.length;
      final info = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (w) => w is IconButton && w.tooltip == 'Session info',
        ),
      );
      final failed = Completer<Object>();
      runZonedGuarded(
        info.onPressed!,
        (error, stack) => failed.complete(error),
      );
      await tester.pump();
      expect(await failed.future, isA<StateError>());
      expect(vm.listeners.length, listenersBefore);
      expect(find.byType(AlertDialog), findsNothing);
      await h.dispose(tester);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'ChatPage Session info revision2: in-flight VM replacement before opening settles',
    (tester) async {
      final h = await _DialogLifecycleHarness.create(tester);
      await h.mount(tester);
      final other = _ScopeChat(
        _Read(LocalBoxes()),
        h.sync,
        h.dataHarness.cm,
        h.prefs,
        h.dataHarness.storage,
      );
      other.room = const RoomInfo(
        startedAt: 1,
        roomId: 'r1',
        localName: 'Wrong VM',
      );
      h.additionalVms.add(other);
      final info = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (w) => w is IconButton && w.tooltip == 'Session info',
        ),
      );
      info.onPressed!();
      h.current = other;
      h.rebuild.value++;
      await tester.pump();
      // Overlay and page builds can be ordered independently in this frame.
      // Process the invalidation redraw without settling the opening route.
      expect(
        Provider.of<ChatViewModel>(
          tester.element(find.byType(ChatPage)),
          listen: false,
        ),
        same(other),
      );
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Session unavailable'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      h.current = h.vm;
      h.rebuild.value++;
      await tester.pump();
      expect(find.text('Session unavailable'), findsOneWidget);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close info'));
      await tester.pumpAndSettle();
      await h.dispose(tester);
      expect(tester.takeException(), isNull);
    },
  );
}
