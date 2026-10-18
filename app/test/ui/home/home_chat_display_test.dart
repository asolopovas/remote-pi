import 'dart:async';
import 'dart:convert';
import 'package:app/ui/agents/agents_page.dart';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/local/boxes.dart';
import 'package:app/data/local/records/message_record.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/repositories/session_read_repository.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/voice/speech_service.dart';
import 'package:app/domain/contracts/update_checker.dart';
import 'package:app/domain/contracts/session_control_repository.dart';
import 'package:app/domain/contracts/dismissed_update_store.dart';
import 'package:app/domain/contracts/url_opener.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/ui/chat/states/chat_state.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/home/home_page.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/home/widgets/session_tile.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:app/data/local/records/runtime_record.dart';
import 'package:app/domain/session_state.dart';
import 'package:provider/provider.dart';

import '../../transport/connection_manager_display_test.dart' as data;
import 'session_display_name_test.dart' show fixtureDisplay;

class _Storage extends data.Storage {
  bool failSave = false;
  @override
  Future<void> saveRooms(String epk, List<PersistedRoom> rooms) async {
    if (failSave) throw Exception('synthetic storage failure');
    await super.saveRooms(epk, rooms);
  }

  @override
  Future<PeerRecord?> loadPeer(String epk) async => data.peer;
  @override
  Future<void> savePeer(PeerRecord peer) async {}
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

class _Checker implements UpdateChecker {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Dismissed implements DismissedUpdateStore {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Opener implements UrlOpener {
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

class _SessionControls extends SessionControlRepository {
  int stops = 0;
  @override
  Future<SessionStopCapability> inspect(String peer, String room) async =>
      SessionStopCapability(
        peer: peer,
        room: room,
        canStop: true,
        token: 'opaque',
      );
  @override
  Future<SessionStopOutcome> stop(SessionStopCapability capability) async {
    stops++;
    return SessionStopOutcome.requested;
  }

  @override
  void dispose() {}
}

// Same room/name/cwd deliberately; only paired keys and startedAt identify it.
const _peerB = PeerRecord(
  remoteEpk: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  sessionName: 'project',
  relayUrl: 'ws://synthetic',
  pairedAt: '2026-01-02',
  roomId: 'r1',
);

class _ControlsStorage extends _Storage {
  Completer<void>? gate;
  int revision = 0;
  bool parked = false;
  Completer<void>? chatGate;
  @override
  int get peerRevision => revision;
  @override
  Future<List<PeerRecord>> listPeers() async {
    if (gate != null) parked = true;
    await gate?.future;
    return [data.peer, _peerB];
  }

  @override
  Future<PeerRecord?> loadPeer(String epk) async {
    await chatGate?.future;
    return epk == _peerB.remoteEpk ? _peerB : data.peer;
  }
}

class _ControlsSecure extends _Secure {
  Completer<void>? gate;
  bool parked = false;
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
  }) async {
    if (gate != null) parked = true;
    await gate?.future;
  }
}

class _ControlsChannel extends data.Channel {
  Completer<void>? closeGate;
  int closes = 0;
  @override
  Future<void> close() async {
    closes++;
    await closeGate?.future;
  }
}

// Only this fixture's exact read-only display protocol may cross an event
// assertion. Everything else stays in the strict ordered control-frame equality.
({List<Map<String, dynamic>> other, List<Map<String, dynamic>> polls})
_classifyControls(
  Iterable<Map<String, dynamic>> frames,
  Set<String> liveRooms,
) {
  final other = <Map<String, dynamic>>[];
  final polls = <Map<String, dynamic>>[];
  final nonces = <String>{};
  for (final frame in frames) {
    Object? inner;
    final ct = frame['ct'];
    if (ct is String) {
      try {
        inner = jsonDecode(utf8.decode(base64.decode(ct)));
      } on FormatException {
        // Not an exempt display read: retain it for strict equality below.
      }
    }
    if (inner is! Map || inner['type'] != 'room_display_request') {
      other.add(frame);
      continue;
    }
    expect(frame.keys.toSet(), {'peer', 'room', 'ct'});
    expect(frame['peer'], data.wirePeer);
    expect(liveRooms, contains(frame['room']));
    expect(inner.keys.toSet(), {'type', 'id', 'room_id'});
    expect(inner['room_id'], frame['room']);
    expect(ct, base64.encode(utf8.encode(jsonEncode(inner))));
    final id = inner['id'];
    expect(id, isA<String>());
    expect(
      id,
      matches(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ),
    );
    expect(nonces.add(id as String), isTrue, reason: 'display nonce reused');
    polls.add(frame);
  }
  return (other: other, polls: polls);
}

void main() {
  test('display-read exemption rejects malformed/mutating control traffic', () {
    Map<String, dynamic> envelope({
      String room = 'r1',
      Map<String, dynamic>? body,
    }) => {
      'peer': data.wirePeer,
      'room': room,
      'ct': base64.encode(
        utf8.encode(
          jsonEncode(
            body ??
                {
                  'type': 'room_display_request',
                  'id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
                  'room_id': room,
                },
          ),
        ),
      ),
    };
    final valid = envelope();
    final body =
        jsonDecode(utf8.decode(base64.decode(valid['ct'] as String)))
            as Map<String, dynamic>;
    expect(_classifyControls([valid], {'r1'}).polls, [valid]);
    for (final invalid in [
      {...valid, 'peer': 'other-peer'},
      {...valid, 'room': 'r2'},
      {...valid, 'extra': true},
      envelope(room: 'not-live'),
      envelope(body: {...body, 'room_id': 'r2'}),
      envelope(body: {...body, 'extra': true}),
      envelope(body: {...body, 'id': 'not-a-nonce'}),
      envelope(body: {...body}..remove('id')),
    ]) {
      expect(
        () => _classifyControls([invalid], {'r1'}),
        throwsA(isA<TestFailure>()),
      );
    }
    expect(
      () => _classifyControls([valid, valid], {'r1'}),
      throwsA(isA<TestFailure>()),
    );
    final baseline = <Map<String, dynamic>>[
      {'type': 'rooms_subscribe'},
    ];
    void unchanged(List<Map<String, dynamic>> frames) =>
        expect(_classifyControls(frames, {'r1'}).other, baseline);
    unchanged([...baseline, valid]);
    for (final unexpected in [
      {'type': 'rooms_subscribe', 'extra': true},
      {'type': 'switch_room', 'room': 'r2'},
      {'type': 'stop_session'},
      {'ct': 'invalid base64!'},
      envelope(body: {...body, 'type': 'sync_request'}),
    ]) {
      // Added AND substituted non-display frames must still fail equality.
      expect(
        () => unchanged([...baseline, unexpected]),
        throwsA(isA<TestFailure>()),
      );
      expect(() => unchanged([unexpected]), throwsA(isA<TestFailure>()));
    }
  });

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

  for (final scenario in [
    'success',
    for (final phase in [
      'storage',
      'preferences',
      'close',
      'connect',
      'discovery',
    ])
      for (final change in [
        'selection-ABA',
        'peer-ABA',
        'room-ABA',
        'pairing',
        'dispose',
      ])
        '$phase-$change',
    for (final phase in ['storage', 'preferences', 'discovery'])
      for (final loss in ['snapshot-loss', 'ended-loss']) '$phase-$loss',
    'success-duplicates',
    'storage-duplicates',
    'preferences-duplicates',
    'preferences-pref-ABA',
    'storage-replacement-ABA',
    'preferences-replacement-ABA',
    'discovery-replacement-ABA',
    'handoff-selection-ABA',
    for (final phase in ['storage', 'preferences', 'close', 'connect'])
      '$phase-error',
    for (final phase in [
      'storage',
      'preferences',
      'close',
      'connect',
      'discovery',
    ])
      '$phase-timeout',
  ]) {
    testWidgets('two-machine controls $scenario', (tester) async {
      final successful =
          scenario == 'success' || scenario.endsWith('-duplicates');
      tester.view.physicalSize = const Size(420, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = _ControlsStorage();
      final secure = _ControlsSecure();
      final prefs = Preferences(secure);
      await prefs.setSelectedRoom(epk: data.peer.remoteEpk, roomId: 'r1');
      final a = _ControlsChannel(), b = _ControlsChannel();
      Completer<void>? connectGate;
      var connects = 0;
      final cm = ConnectionManager(
        storage: storage,
        emitDebounce: Duration.zero,
        factory: (peer, token) async {
          connects++;
          expect(peer.remoteEpk, _peerB.remoteEpk);
          await connectGate?.future;
          return b;
        },
      );
      cm.adopt(a, data.peer);
      cm.subscribeToPeers([data.peer.remoteEpk, _peerB.remoteEpk]);
      Map<String, dynamic> announcement(String peer, {int startedAt = 1}) => {
        ...data.announced(),
        'peer': peer,
        'started_at': startedAt,
      };
      a.push(announcement(data.wirePeer));
      a.push(announcement('${_peerB.remoteEpk}='));
      await tester.runAsync(data.settle);
      await tester.pump();
      final home = HomeViewModel(storage, prefs, cm);
      final selection = SessionSelection()
        ..select(data.peer.remoteEpk, 'r1', 'A');
      final shell = ShellLayout();
      final update = UpdateBannerViewModel(
        _Checker(),
        _Dismissed(),
        _Opener(),
        currentVersion: '0.0.0',
        enabled: false,
      );
      final boxes = LocalBoxes();
      final sync = _Sync(cm, boxes);
      final voice = VoiceInputViewModel(_Speech());
      final actions = _Actions(cm);
      final attach = AttachmentViewModel(_Picker(), actions);
      final controls = _SessionControls();
      ChatViewModel? chat;
      var routed = false, homeDisposed = false, managerDisposed = false;
      final router = GoRouter(
        initialLocation: '/home',
        routes: [
          GoRoute(path: '/home', builder: (_, _) => const HomePage()),
          GoRoute(
            path: '/chat',
            builder: (_, state) {
              routed = true;
              final extra = state.extra! as Map<String, dynamic>;
              chat ??= ChatViewModel(
                _Read(boxes),
                sync,
                cm,
                prefs,
                storage,
                sessionControls: controls,
              );
              return ChangeNotifierProvider<ChatViewModel>.value(
                value: chat!,
                child: ChatPage(
                  controlsRequest: extra['controls'] as SessionControlsRequest?,
                ),
              );
            },
          ),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        chat?.dispose();
        if (!homeDisposed) home.dispose();
        voice.dispose();
        attach.dispose();
        prefs.dispose();
        selection.dispose();
        shell.dispose();
        update.dispose();
        router.dispose();
        sync.dispose();
        actions.dispose();
        if (!managerDisposed) cm.dispose();
        await a.controls.close();
        await a.messages.close();
        await b.controls.close();
        await b.messages.close();
      });
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<HomeViewModel>.value(value: home),
            ChangeNotifierProvider<Preferences>.value(value: prefs),
            ChangeNotifierProvider<SessionSelection>.value(value: selection),
            ChangeNotifierProvider<ShellLayout>.value(value: shell),
            ChangeNotifierProvider<UpdateBannerViewModel>.value(value: update),
            ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
            ChangeNotifierProvider<AttachmentViewModel>.value(value: attach),
          ],
          child: MaterialApp.router(
            theme: buildDarkTheme(),
            routerConfig: router,
            builder: (_, child) => MediaQuery(
              data: const MediaQueryData(
                disableAnimations: true,
                size: Size(420, 1000),
              ),
              child: child!,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      home.setFilter(HomeFilter.all);
      await tester.pumpAndSettle();
      final tile = find.byWidgetPredicate(
        (w) => w is SessionTile && w.peer.remoteEpk == _peerB.remoteEpk,
      );
      expect(tile, findsOneWidget);
      await tester.longPress(tile);
      await tester.pumpAndSettle();
      if (scenario.startsWith('storage')) storage.gate = Completer<void>();
      if (scenario.startsWith('preferences')) secure.gate = Completer<void>();
      if (scenario.startsWith('close')) a.closeGate = Completer<void>();
      if (scenario.startsWith('connect')) connectGate = Completer<void>();
      if (scenario.startsWith('handoff')) storage.chatGate = Completer<void>();
      await tester.tap(find.text('Agent controls…'));
      await tester.runAsync(data.settle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      if (scenario.contains('selection-ABA') &&
          !scenario.startsWith('discovery') &&
          !scenario.startsWith('handoff')) {
        selection.select(_peerB.remoteEpk, 'r1', 'B');
        selection.select(data.peer.remoteEpk, 'r1', 'A');
      }
      if (scenario.contains('peer-ABA') && !scenario.startsWith('discovery')) {
        cm.adopt(_ControlsChannel(), _peerB);
        cm.adopt(a, data.peer);
      }
      if (scenario.contains('room-ABA') && !scenario.startsWith('discovery')) {
        cm.switchRoom('elsewhere');
        cm.switchRoom('r1');
      }
      if (!scenario.startsWith('discovery') && scenario.endsWith('pairing')) {
        storage.revision++;
      }
      if (!scenario.startsWith('discovery') && scenario.endsWith('dispose')) {
        home.dispose();
        homeDisposed = true;
      }
      if (scenario.endsWith('pref-ABA')) {
        // Preference revisions change synchronously even while writes are parked.
        unawaited(
          prefs.setSelectedRoom(epk: data.peer.remoteEpk, roomId: 'r1'),
        );
        unawaited(prefs.setSelectedRoom(epk: _peerB.remoteEpk, roomId: 'r1'));
      }
      if (scenario.endsWith('replacement-ABA') &&
          !scenario.startsWith('discovery')) {
        a.push(announcement('${_peerB.remoteEpk}=', startedAt: 2));
        a.push(announcement('${_peerB.remoteEpk}='));
        await tester.pump();
      }
      void loseAndRestore(_ControlsChannel ch) {
        // Same peer/room/name/startedAt: only authoritative liveness changes.
        ch.push(
          scenario.endsWith('snapshot-loss')
              ? {'type': 'rooms', 'peer': '${_peerB.remoteEpk}=', 'rooms': []}
              : {
                  'type': 'room_ended',
                  'peer': '${_peerB.remoteEpk}=',
                  'room_id': 'r1',
                  'since_ts': 2,
                },
        );
        ch.push(announcement('${_peerB.remoteEpk}='));
      }

      void duplicateDiscovery(_ControlsChannel ch) {
        final snapshot = {
          'type': 'rooms',
          'peer': '${_peerB.remoteEpk}=',
          'rooms': [announcement('${_peerB.remoteEpk}=')],
        };
        ch.push(snapshot);
        ch.push(snapshot);
        ch.push(
          data.patch({'model': 'updated'}, target: '${_peerB.remoteEpk}='),
        );
        ch.push(announcement('${_peerB.remoteEpk}='));
      }

      if (scenario == 'storage-duplicates' ||
          scenario == 'preferences-duplicates') {
        expect(
          scenario.startsWith('storage') ? storage.parked : secure.parked,
          isTrue,
        );
        duplicateDiscovery(a);
        await tester.runAsync(data.settle);
        await tester.pump();
      }
      if (!scenario.startsWith('discovery') && scenario.endsWith('-loss')) {
        expect(
          scenario.startsWith('storage') ? storage.gate : secure.gate,
          isNotNull,
        );
        expect(
          scenario.startsWith('storage') ? storage.parked : secure.parked,
          isTrue,
        );
        expect(connects, 0);
        loseAndRestore(a);
        await tester.runAsync(data.settle);
        await tester.pump();
      }
      if (scenario.endsWith('timeout')) {
        await tester.pump(const Duration(milliseconds: 5100));
        await tester.runAsync(data.settle);
        await tester.pump();
      }
      for (final gate in [
        storage.gate,
        secure.gate,
        a.closeGate,
        connectGate,
      ]) {
        if (scenario.endsWith('error')) {
          gate?.completeError(Exception('synthetic handoff IO failure'));
        } else {
          gate?.complete();
        }
      }
      await tester.runAsync(data.settle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Frames from the discarded socket can never supply B's fresh discovery.
      a.push(announcement('${_peerB.remoteEpk}='));
      await tester.runAsync(data.settle);
      await tester.pump();
      if (scenario == 'discovery-selection-ABA') {
        selection.select(_peerB.remoteEpk, 'r1', 'B');
        selection.select(data.peer.remoteEpk, 'r1', 'A');
      } else if (scenario == 'discovery-peer-ABA') {
        cm.adopt(_ControlsChannel(), _peerB);
        cm.adopt(a, data.peer);
      } else if (scenario == 'discovery-room-ABA') {
        cm.switchRoom('elsewhere');
        cm.switchRoom('r1');
      }
      if (scenario.startsWith('discovery') && scenario.endsWith('-loss')) {
        expect(connects, 1);
        expect(cm.channel, same(b));
        expect(cm.isRoomLive(_peerB.remoteEpk, 'r1'), isFalse);
        expect(routed, isFalse);
        // First authoritative snapshot after the owned socket reset loses B.
        // Socket-local liveness is empty, but the original online intent must
        // still be revoked before same-incarnation fresh discovery restores B.
        loseAndRestore(b);
      } else if (scenario == 'discovery-replacement-ABA') {
        b.push(announcement('${_peerB.remoteEpk}=', startedAt: 2));
        b.push(announcement('${_peerB.remoteEpk}='));
      } else if (scenario == 'discovery-pairing') {
        storage.revision++;
        b.push(announcement('${_peerB.remoteEpk}='));
      } else if (scenario == 'discovery-dispose') {
        home.dispose();
        homeDisposed = true;
      } else if (successful || scenario.startsWith('handoff')) {
        expect(routed, isFalse);
        b.push(announcement('${_peerB.remoteEpk}='));
        if (scenario.endsWith('-duplicates')) duplicateDiscovery(b);
      }
      await tester.runAsync(data.settle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      await tester.runAsync(data.settle);
      await tester.pumpAndSettle();
      await tester.runAsync(data.settle);
      await tester.pumpAndSettle();
      if (scenario.startsWith('handoff')) {
        expect(routed, isTrue);
        selection.select(_peerB.remoteEpk, 'r1', 'B');
        selection.select(data.peer.remoteEpk, 'r1', 'A');
        cm.adopt(a, data.peer);
        storage.chatGate!.complete();
        await tester.runAsync(data.settle);
        await tester.pumpAndSettle();
      }
      expect(controls.stops, 0);
      if (successful) {
        expect(connects, 1);
        expect(cm.activePeer?.remoteEpk, _peerB.remoteEpk);
        expect(chat?.activePeer?.remoteEpk, _peerB.remoteEpk);
        expect(chat?.activeRoom?.startedAt, 1);
        expect(find.text('Session info'), findsOneWidget);
        await tester.tap(find.byKey(const Key('stop-session-agent')));
        await tester.pumpAndSettle();
        expect(find.text('Stop agent?'), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pumpAndSettle();
        expect(controls.stops, 0);
      } else {
        if (scenario.endsWith('-loss')) {
          expect(chat, isNull);
          expect(selection.current?.epk, data.peer.remoteEpk);
          if (scenario.startsWith('discovery')) {
            expect(cm.channel, isNull);
            expect(cm.activePeer, isNull);
          }
        }
        expect(routed, scenario.startsWith('handoff'));
        expect(find.text('Session info'), findsNothing);
        expect(
          find.text('Could not open agent controls. Try again.'),
          findsOneWidget,
        );
        if (!scenario.startsWith('discovery')) {
          expect(
            cm.activePeer?.remoteEpk,
            scenario.startsWith('connect') && !scenario.contains('peer-ABA')
                ? isNull
                : data.peer.remoteEpk,
          );
          if (!scenario.startsWith('connect') &&
              !scenario.startsWith('handoff')) {
            expect(connects, 0);
          }
        }
      }
      if (scenario == 'connect-timeout') {
        expect(b.closes, greaterThan(0));
        expect(cm.channel, isNull);
      }
      // The fake channels record every production transport send, not only
      // repository calls. No Stop/unlock/mutation is permitted on this path.
      expect([...a.sends, ...b.sends], isEmpty);
      for (final frame in [...a.checks, ...b.checks]) {
        final ct = frame['ct'];
        if (ct is String) {
          final body = jsonDecode(utf8.decode(base64.decode(ct))) as Map;
          expect(body['type'], 'room_display_request');
        }
      }
      expect(tester.takeException(), isNull);
      cm.dispose();
      managerDisposed = true;
    });
  }

  for (final dark in [true, false]) {
    testWidgets(
      'Home navigation, alias control and actual roomsStream refresh chat (${dark ? 'dark' : 'light'})',
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
        final home = HomeViewModel(h.storage, prefs, h.cm);
        final selection = SessionSelection();
        final shell = ShellLayout();
        final update = UpdateBannerViewModel(
          _Checker(),
          _Dismissed(),
          _Opener(),
          currentVersion: '0.0.0',
          enabled: false,
        );
        final boxes = LocalBoxes();
        final sync = _Sync(h.cm, boxes);
        final voice = VoiceInputViewModel(_Speech());
        final actions = _Actions(h.cm);
        final attach = AttachmentViewModel(_Picker(), actions);
        ChatViewModel? chat;
        final sessionControls = _SessionControls();
        Map<String, dynamic>? navigation;
        AgentsTarget? launchTarget;
        final router = GoRouter(
          initialLocation: '/home',
          routes: [
            GoRoute(path: '/home', builder: (_, _) => const HomePage()),
            GoRoute(
              path: '/agents',
              builder: (_, state) {
                launchTarget = state.extra! as AgentsTarget;
                return const Scaffold(body: Text('Agent creation form'));
              },
            ),
            GoRoute(
              path: '/chat',
              builder: (_, state) {
                navigation = state.extra as Map<String, dynamic>;
                chat ??= ChatViewModel(
                  _Read(boxes),
                  sync,
                  h.cm,
                  prefs,
                  h.storage,
                  sessionControls: sessionControls,
                );
                return ChangeNotifierProvider<ChatViewModel>.value(
                  value: chat!,
                  child: ChatPage(
                    initialTitle: navigation!['title'] as String,
                    initialDevice: navigation!['device'] as String,
                    initialOnline: navigation!['online'] as bool,
                    controlsRequest:
                        navigation!['controls'] as SessionControlsRequest?,
                  ),
                );
              },
            ),
          ],
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          chat?.dispose();
          home.dispose();
          voice.dispose();
          attach.dispose();
          prefs.dispose();
          selection.dispose();
          shell.dispose();
          update.dispose();
          router.dispose();
          sync.dispose();
          actions.dispose();
        });
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<HomeViewModel>.value(value: home),
              ChangeNotifierProvider<Preferences>.value(value: prefs),
              ChangeNotifierProvider<SessionSelection>.value(value: selection),
              ChangeNotifierProvider<ShellLayout>.value(value: shell),
              ChangeNotifierProvider<UpdateBannerViewModel>.value(
                value: update,
              ),
              ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
              ChangeNotifierProvider<AttachmentViewModel>.value(value: attach),
            ],
            child: MaterialApp.router(
              theme: dark ? buildDarkTheme() : buildLightTheme(),
              routerConfig: router,
              builder: (_, child) => MediaQuery(
                data: const MediaQueryData(
                  // Navigation fixtures settle; rotation has dedicated coverage.
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
        home.setFilter(HomeFilter.all);
        await tester.pumpAndSettle();
        expect(find.text('Pi · system'), findsNWidgets(2));
        // Two ordinary sessions on one paired machine skip the machine picker.
        await tester.tap(find.byTooltip('Start agent'));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNothing);
        expect(find.text('Choose launch host'), findsNothing);
        expect(launchTarget!.freshStart, isTrue);
        expect(launchTarget!.preferredRoom, isNull);
        expect(find.text('Agent creation form'), findsOneWidget);
        expect(launchTarget!.room, 'r1');
        router.pop();
        await tester.pumpAndSettle();
        expect(
          tester.getSemantics(find.text('Connected').first).label,
          contains('Connected'),
        );
        Finder tile(String id) => find.byWidgetPredicate(
          (w) => w is SessionTile && w.room?.roomId == id,
        );
        await tester.longPress(tile('r1'));
        await tester.pumpAndSettle();
        final controlsEntry = find.widgetWithText(ListTile, 'Agent controls…');
        expect(tester.widget<ListTile>(controlsEntry).enabled, isTrue);
        expect(find.text('Delete session (local only)'), findsNothing);
        await tester.tap(controlsEntry);
        await tester.pumpAndSettle();
        // Handoff cleanup cancels broadcast subscriptions before routing.
        await tester.runAsync(data.settle);
        await tester.pumpAndSettle();
        await tester.runAsync(data.settle);
        await tester.pumpAndSettle();
        expect(find.text('Session info'), findsOneWidget);
        expect(sessionControls.stops, 0);
        expect(navigation!['controls'], isA<SessionControlsRequest>());
        await tester.tap(find.byKey(const Key('stop-session-agent')));
        await tester.pumpAndSettle();
        expect(find.text('Stop agent?'), findsOneWidget);
        expect(sessionControls.stops, 0);
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pumpAndSettle();
        expect(sessionControls.stops, 0);
        // External selection while confirmation is open revokes this request.
        await tester.tap(find.byKey(const Key('stop-session-agent')));
        await tester.pumpAndSettle();
        selection.select(data.peer.remoteEpk, 'r2', 'Other session');
        await tester.tap(find.widgetWithText(FilledButton, 'Stop'));
        await tester.pumpAndSettle();
        expect(sessionControls.stops, 0);
        expect(find.text('Session unavailable'), findsOneWidget);
        await tester.tap(find.byKey(const Key('close-session-info')));
        await tester.pumpAndSettle();
        router.pop();
        await tester.pumpAndSettle();
        chat!.dispose();
        chat = null;
        await tester.longPress(tile('r1'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Mobile alias'));
        await tester.pumpAndSettle();
        final aliasField = tester.widget<TextField>(find.byType(TextField));
        expect(
          aliasField.controller!.text,
          isEmpty,
        ); // routing name is NOT a saved override
        expect(
          find.text('Saved fallback when no desktop name is available'),
          findsOneWidget,
        );
        await tester.enterText(find.byType(TextField), 'Mobile <plain>');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(h.room().localName, 'Mobile <plain>');
        expect(h.room().name, 'routing-agent');
        expect(find.text('Pi · system'), findsNWidgets(2));
        expect(find.text('Mobile <plain>'), findsNothing);
        await tester.longPress(tile('r1'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Mobile alias'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'Mobile <plain>',
        );
        await tester.enterText(find.byType(TextField), '');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(h.room().localName, isNull);
        expect(find.text('Pi · system'), findsNWidgets(2));
        await tester.tap(tile('r1'));
        await tester.pumpAndSettle();
        expect(navigation!['title'], 'Pi · system');
        expect(selection.current!.roomId, 'r1');
        expect(prefs.selectedRoomId, 'r1');
        expect(chat!.activeRoom!.roomId, 'r1');
        expect(find.text('Pi · system'), findsOneWidget);
        expect(
          tester.widget<Text>(find.byKey(const Key('chat-session-title'))).data,
          'Pi · system',
        );
        await tester.enterText(
          find.descendant(
            of: find.byType(InputBar),
            matching: find.byType(TextField),
          ),
          'synthetic unsent draft',
        );
        await tester.pump();
        final before = chat!.state as ChatReady;
        final inputState = tester.state(find.byType(InputBar));
        Set<String> liveRooms() => h.cm
            .roomsFor(data.wirePeer)
            .where((r) => h.cm.isRoomLive(data.wirePeer, r.roomId))
            .map((r) => r.roomId)
            .toSet();
        final checks = jsonDecode(
          jsonEncode(_classifyControls(h.ch.checks, liveRooms()).other),
        );
        final sends = h.ch.sends.length;
        final reloads = sync.requests;
        var notices = 0;
        var forcePollBoundary = true;
        chat!.addListener(() => notices++);
        Future<void> patch(
          Map<String, dynamic> meta,
          String title, {
          String room = 'r1',
        }) async {
          if (forcePollBoundary) {
            forcePollBoundary = false;
            // Harness.create runs in runAsync, so the production two-second
            // Timer is real. Wait for its actual next send, not a fake pump or
            // an assumed sleep; drain and prove the exact r1/r2 delta.
            final start = h.ch.checks.length;
            await tester.runAsync(() async {
              final deadline = DateTime.now().add(const Duration(seconds: 5));
              while (h.ch.checks.length == start &&
                  DateTime.now().isBefore(deadline)) {
                await Future<void>.delayed(const Duration(milliseconds: 10));
              }
              await data.settle();
            });
            final delta = _classifyControls(
              h.ch.checks.skip(start),
              liveRooms(),
            );
            expect(delta.other, isEmpty);
            expect(
              delta.polls.map((f) => f['room']),
              unorderedEquals(['r1', 'r2']),
            );
          }
          await tester.runAsync(() => h.push(data.patch(meta, room: room)));
          await tester.pumpAndSettle();
          expect(find.text(title), findsOneWidget);
          expect(
            identical((chat!.state as ChatReady).messages, before.messages),
            isTrue,
          );
          expect(
            (chat!.state as ChatReady).queuedMessages,
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
          expect(_classifyControls(h.ch.checks, liveRooms()).other, checks);
          expect(h.ch.sends.length, sends);
          expect(sync.requests, reloads);
        }

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
        await tester.tap(find.byTooltip('Session info'));
        await tester.pumpAndSettle();
        expect(find.text('model-only'), findsOneWidget);
        expect(find.text('r1'), findsOneWidget);
        expect(find.text('/synthetic/duplicate'), findsOneWidget);
        expect(find.text('Renamed <plain>'), findsNWidgets(2));
        await tester.tap(find.byTooltip('Close info'));
        await tester.pumpAndSettle();
        await h.cm.setRoomLocalName(
          data.peer.remoteEpk,
          'r1',
          'Saved fallback',
        );
        await tester.pumpAndSettle();
        expect(find.text('Renamed <plain>'), findsOneWidget);
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
        await h.cm.setRoomLocalName(data.peer.remoteEpk, 'r1', null);
        await tester.pumpAndSettle();
        expect(find.text('duplicate'), findsOneWidget);
        final priorNotices = notices;
        await patch({'working': false}, 'duplicate');
        expect(notices, priorNotices + 1); // State emit must not double-notify.
        expect(find.text('synthetic retained message'), findsOneWidget);
        // The info X only dismisses info; actual Stop is a separate confirmed action.
        await tester.tap(find.byTooltip('Session info'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('close-session-info')));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(ChatPage), findsOneWidget);
        expect(selection.current?.roomId, 'r1');
        expect(h.cm.isRoomLive(data.peer.remoteEpk, 'r1'), isTrue);
        expect(h.storage.rooms.any((r) => r.roomId == 'r1'), isTrue);
        await tester.tap(find.byTooltip('Session info'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('stop-session-agent')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Stop'));
        await tester.pumpAndSettle();
        expect(sessionControls.stops, 1);
        expect(find.byType(ChatPage), findsNothing);
        expect(selection.current, isNull);
        expect(h.storage.rooms.any((r) => r.roomId == 'r1'), isTrue);
        await tester.tap(tile('r1'));
        await tester.pumpAndSettle();
        // The open chat launches directly against its exact peer/room.
        await tester.tap(find.byTooltip('Start agent'));
        await tester.pumpAndSettle();
        expect(find.text('Agent creation form'), findsOneWidget);
        expect(launchTarget!.room, 'r1');
        expect(launchTarget!.peer, data.peer.remoteEpk);
        router.pop();
        await tester.pumpAndSettle();
        router.pop();
        await tester.pumpAndSettle();
        // Home carries a preference, not an unvalidated launcher endpoint.
        await tester.tap(find.byTooltip('Start agent'));
        await tester.pumpAndSettle();
        expect(find.text('Agent creation form'), findsOneWidget);
        expect(find.text('Choose launch host'), findsNothing);
        expect(find.byType(BottomSheet), findsNothing);
        expect(launchTarget!.room, 'r1');
        router.pop();
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => h.push({
            'type': 'room_ended',
            'peer': data.wirePeer,
            'room_id': 'r2',
            'since_ts': 99,
          }),
        );
        await tester.pumpAndSettle();
        await tester.longPress(tile('r2'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Remove from list…'));
        await tester.pumpAndSettle();
        expect(find.text('Remove from list?'), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, 'Remove'));
        await tester.pumpAndSettle();
        expect(tile('r2'), findsNothing);
        expect(find.text('Removed from list.'), findsOneWidget);
        expect(h.storage.rooms.any((r) => r.roomId == 'r2'), isFalse);
        expect(sessionControls.stops, 1); // Only the explicit earlier Stop.
        expect(tester.takeException(), isNull);
        semantics.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  for (final size in [const Size(400, 900), const Size(900, 900)]) {
    testWidgets(
      'Home metadata and full relay status at default scale ${size.width}',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final h = (await tester.runAsync(
          () => data.Harness.create(_Storage()),
        ))!;
        await tester.runAsync(
          () =>
              h.push(data.announced(value: fixtureDisplay('rename').toJson())),
        );
        final prefs = Preferences(_Secure());
        final home = HomeViewModel(h.storage, prefs, h.cm);
        final selection = SessionSelection();
        final shell = ShellLayout();
        final update = UpdateBannerViewModel(
          _Checker(),
          _Dismissed(),
          _Opener(),
          currentVersion: '0.0.0',
          enabled: false,
        );
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<HomeViewModel>.value(value: home),
              ChangeNotifierProvider<SessionSelection>.value(value: selection),
              ChangeNotifierProvider<ShellLayout>.value(value: shell),
              ChangeNotifierProvider<UpdateBannerViewModel>.value(
                value: update,
              ),
            ],
            child: MaterialApp(
              theme: buildDarkTheme(),
              builder: (context, child) => MediaQuery(
                // Preserve viewport/text scale while settling metadata fixtures.
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: child!,
              ),
              home: const HomePage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Pi · system'), findsOneWidget);
        expect(find.text('Connected'), findsOneWidget);
        await tester.runAsync(
          () =>
              h.push(data.patch({'display': data.display(2, 'Home renamed')})),
        );
        await tester.pumpAndSettle();
        expect(find.text('Home renamed'), findsOneWidget);
        await h.cm.setRoomLocalName(data.peer.remoteEpk, 'r1', 'Home fallback');
        await tester.runAsync(
          () => h.push(
            data.announced(
              room: 'r2',
              value: data.display(
                1,
                'Other desktop',
                native: '11111111-1111-4111-8111-111111111111',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(h.room().cwd, h.room('r2').cwd);
        expect(find.text('Home renamed'), findsOneWidget);
        expect(find.text('Other desktop'), findsOneWidget);
        Set<String> liveRooms() => h.cm
            .roomsFor(data.wirePeer)
            .where((r) => h.cm.isRoomLive(data.wirePeer, r.roomId))
            .map((r) => r.roomId)
            .toSet();
        final checks = jsonDecode(
          jsonEncode(_classifyControls(h.ch.checks, liveRooms()).other),
        );
        final sends = h.ch.sends.length;
        await tester.runAsync(
          () => h.push(
            data.patch({'display': data.display(3, 'Latest desktop')}),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Latest desktop'), findsOneWidget);
        expect(find.text('Other desktop'), findsOneWidget);
        expect(h.room().localName, 'Home fallback');
        expect(_classifyControls(h.ch.checks, liveRooms()).other, checks);
        expect(h.ch.sends.length, sends);
        expect(
          h.storage.rooms.singleWhere((r) => r.roomId == 'r1').localName,
          'Home fallback',
        );
        home.setFilter(HomeFilter.all);
        await tester.runAsync(
          () => h.push({
            'type': 'room_ended',
            'peer': data.peer.remoteEpk,
            'room_id': 'r2',
            'since_ts': 3,
          }),
        );
        await tester.pumpAndSettle();
        Finder roomTile(String id) => find.byWidgetPredicate(
          (w) => w is SessionTile && w.room?.roomId == id,
        );
        Future<void> removeDialog() async {
          await tester.longPress(roomTile('r2'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Remove from list…'));
          await tester.pumpAndSettle();
        }

        await removeDialog();
        selection.select(data.peer.remoteEpk, 'r1', 'Other selection');
        await tester.tap(find.widgetWithText(TextButton, 'Remove'));
        await tester.pumpAndSettle();
        expect(
          find.text('Session changed. Open the menu again.'),
          findsOneWidget,
        );
        expect(home.counts.all, 2);
        await removeDialog();
        (h.storage as _Storage).failSave = true;
        await tester.tap(find.widgetWithText(TextButton, 'Remove'));
        await tester.pumpAndSettle();
        expect(
          find.text('Could not remove session. Try again.'),
          findsOneWidget,
        );
        expect(home.counts.all, 2);
        (h.storage as _Storage).failSave = false;
        await removeDialog();
        await tester.runAsync(() => h.push(data.announced(room: 'r2')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'Remove'));
        await tester.pumpAndSettle();
        expect(
          find.text('Session changed. Open the menu again.'),
          findsOneWidget,
        );
        expect(h.cm.isRoomLive(data.peer.remoteEpk, 'r2'), isTrue);
        await tester.runAsync(
          () => h.push({
            'type': 'room_ended',
            'peer': data.peer.remoteEpk,
            'room_id': 'r2',
            'since_ts': 4,
          }),
        );
        await tester.pumpAndSettle();
        final clear = find.byKey(const Key('clear-inactive-sessions'));
        expect(tester.widget<TextButton>(clear).onPressed, isNotNull);
        await tester.tap(clear);
        await tester.pumpAndSettle();
        expect(
          find.text('Removes offline entries from this device only.'),
          findsOneWidget,
        );
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(home.counts.all, 2);
        await tester.tap(clear);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
        await tester.pumpAndSettle();
        expect(home.counts, (all: 1, online: 1, offline: 0));
        expect(h.cm.isRoomLive(data.peer.remoteEpk, 'r1'), isTrue);
        // A new live announcement may return a previously cleared cache row.
        await tester.runAsync(() => h.push(data.announced(room: 'r2')));
        await tester.pumpAndSettle();
        expect(home.counts.all, 2);
        await h.cm.disconnect();
        await tester.pumpAndSettle();
        expect(find.text('Home fallback'), findsOneWidget);
        expect(find.text('duplicate'), findsOneWidget);
        expect(find.textContaining('Reconnecting'), findsNWidgets(2));
        expect(h.room().display, isNull);
        expect(tester.widget<TextButton>(clear).onPressed, isNull);
        await tester.longPress(roomTile('r2'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Remove from list…'));
        await tester.pumpAndSettle();
        expect(
          find.text('Status unknown. Reconnect before removing.'),
          findsOneWidget,
        );
        expect(find.text('Remove from list?'), findsNothing);
        expect(home.counts.all, 2);

        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        home.dispose();
        prefs.dispose();
        selection.dispose();
        shell.dispose();
        update.dispose();
      },
    );
  }
}
