// Standalone offline Android test app. Never used by the production entrypoint.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/local/boxes.dart';
import 'package:app/data/local/records/message_record.dart';
import 'package:app/data/local/records/runtime_record.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/repositories/session_read_repository.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/voice/speech_service.dart';
import 'package:app/domain/contracts/dismissed_update_store.dart';
import 'package:app/domain/contracts/update_checker.dart';
import 'package:app/domain/contracts/url_opener.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/ui/chat/states/chat_state.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:app/ui/core/session_label.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/home/home_page.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/home/widgets/session_tile.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

const peer = PeerRecord(
  remoteEpk: 'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO_oMQ6yyQE',
  sessionName: 'Synthetic owner',
  relayUrl: 'ws://127.0.0.1', // Never dialed: the channel factory is injected.
  pairedAt: '2026-01-01',
  roomId: 'r1',
);
const wirePeer = 'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO/oMQ6yyQE=';
const longLabel =
    'Pi <plain> **not markdown** · a very long synthetic desktop label';

class SyntheticStorage extends PairingStorage {
  List<PersistedRoom> rooms = [];
  @override
  Future<List<PeerRecord>> listPeers() async => [peer];
  @override
  Future<PeerRecord?> loadPeer(String epk) async => peer;
  @override
  Future<void> savePeer(PeerRecord peer) async {}
  @override
  Future<List<PersistedRoom>> loadRooms(String epk) async => List.of(rooms);
  @override
  Future<void> saveRooms(String epk, List<PersistedRoom> value) async {
    rooms = List.of(value);
  }
}

class SyntheticSecure implements FlutterSecureStorage {
  final values = <String, String>{};
  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];
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
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Transport boundary: parsed subscriber control frames, not Relay auth/WebSocket.
class SyntheticChannel implements IChannel, IControlLink {
  final controls = StreamController<ControlInbound>.broadcast();
  final messages = StreamController<ServerMessage>.broadcast();
  int sends = 0;
  int heartbeats = 0;
  int controlsSent = 0;
  @override
  Stream<ControlInbound> get controlFrames => controls.stream;
  @override
  Stream<ServerMessage> get serverMessages => messages.stream;
  @override
  Future<void> send(ClientMessage msg) async {
    if (msg is Ping) {
      heartbeats++;
      messages.add(Pong(inReplyTo: msg.id));
    } else {
      sends++;
    }
  }

  @override
  void sendControl(Map<String, dynamic> json) {
    controlsSent++;
  }

  @override
  Future<void> close() async {}
  void push(Map<String, dynamic> json) {
    controls.add(ControlInbound.tryFromJson(json)!);
  }
}

class SyntheticActions extends ActionsRepository {
  SyntheticActions(super.conn);
  @override
  Future<ModelsCatalogue> listModels({bool forceRefresh = false}) async =>
      const ModelsCatalogue(models: []);
}

class SyntheticSpeech implements SpeechService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Voice disabled in synthetic test');
}

class SyntheticPicker implements IImagePickerService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Images disabled in synthetic test');
}

class SyntheticChecker implements UpdateChecker {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Updates disabled in synthetic test');
}

class SyntheticDismissed implements DismissedUpdateStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class SyntheticOpener implements UrlOpener {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('External URLs disabled in synthetic test');
}

class SyntheticRead extends SessionReadRepository {
  SyntheticRead(super.boxes);
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

class SyntheticSync extends SyncService {
  SyntheticSync(super.conn, super.boxes);
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

final navigatorKey = GlobalKey<NavigatorState>();
final errors = <String>[];
late OfflineFixture fixture;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  FlutterError.onError = (details) {
    errors.add(details.toString());
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    errors.add('$error');
    return true;
  };
  fixture = await OfflineFixture.create();
  runApp(SyntheticApp(fixture: fixture));
  // Control surface is device-loopback only, ephemeral, read/whitelisted mutation.
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  debugPrint('SYNTHETIC_CONTROL_PORT=${server.port}');
  server.listen((request) async {
    try {
      if (request.uri.path == '/command') {
        await fixture.command(request.uri.queryParameters['name'] ?? '');
        await Future<void>.delayed(const Duration(milliseconds: 300));
      } else if (request.uri.path != '/status') {
        request.response.statusCode = 404;
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(fixture.status()));
    } on Object catch (error) {
      request.response.statusCode = 400;
      request.response.write(jsonEncode({'error': '$error'}));
    }
    await request.response.close();
  });
}

class OfflineFixture extends ChangeNotifier {
  OfflineFixture(this.storage, this.channel, this.cm, this.producerDisplay);
  final SyntheticStorage storage;
  final SyntheticChannel channel;
  final ConnectionManager cm;
  final Map<String, Map<String, dynamic>> producerDisplay;
  late final prefs = Preferences(SyntheticSecure());
  late final home = HomeViewModel(storage, prefs, cm);
  final selection = SessionSelection();
  final shell = ShellLayout();
  late final update = UpdateBannerViewModel(
    SyntheticChecker(),
    SyntheticDismissed(),
    SyntheticOpener(),
    currentVersion: '0.0.0',
    enabled: false,
  );
  final boxes = LocalBoxes();
  late final sync = SyntheticSync(cm, boxes);
  late final voice = VoiceInputViewModel(SyntheticSpeech());
  late final actions = SyntheticActions(cm);
  late final attach = AttachmentViewModel(SyntheticPicker(), actions);
  ChatViewModel? chat;
  bool dark = true;
  int revision = 2;
  Object? retainedMessages;
  Object? retainedInput;
  late final router = GoRouter(
    navigatorKey: navigatorKey,
    initialLocation: '/home',
    routes: [
      GoRoute(path: '/home', builder: (_, _) => const HomePage()),
      GoRoute(
        path: '/chat',
        builder: (_, state) {
          final navigation = state.extra! as Map<String, dynamic>;
          chat ??= ChatViewModel(
            SyntheticRead(boxes),
            sync,
            cm,
            prefs,
            storage,
          );
          return ChangeNotifierProvider<ChatViewModel>.value(
            value: chat!,
            child: ChatPage(
              initialTitle: navigation['title'] as String,
              initialDevice: navigation['device'] as String,
              initialOnline: navigation['online'] as bool,
            ),
          );
        },
      ),
    ],
  );
  static Future<OfflineFixture> create() async {
    final entries =
        jsonDecode(
              await rootBundle.loadString(
                'test/protocol/fixtures/81-display-serialization.json',
              ),
            )
            as List;
    final displays = <String, Map<String, dynamic>>{};
    for (final entry in entries) {
      final frame = entry['frame'] as Map<String, dynamic>;
      final meta = frame['meta'] as Map<String, dynamic>?;
      if (meta?['display'] != null) {
        displays[entry['case'] as String] = Map<String, dynamic>.from(
          meta!['display'] as Map,
        );
      }
    }
    final storage = SyntheticStorage();
    final channel = SyntheticChannel();
    final cm = ConnectionManager(
      factory: (_, _) async => channel,
      storage: storage,
      emitDebounce: Duration.zero,
    );
    await cm.boot();
    final result = OfflineFixture(storage, channel, cm, displays);
    for (final room in ['r1', 'r2']) {
      channel.push({
        'type': 'room_announced',
        'peer': wirePeer,
        'room_id': room,
        'name': 'routing-agent',
        'cwd': '/synthetic/duplicate',
        'started_at': 1,
        'model': 'model-a',
        'thinking': 'high',
        'working': true,
        'display': displays['rename'],
      });
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return result;
  }

  void patch(Map<String, dynamic> meta, {String room = 'r1'}) => channel.push({
    'type': 'room_meta_updated',
    'peer': wirePeer,
    'room_id': room,
    'meta': meta,
  });
  Map<String, dynamic> display(String? name) => {
    ...producerDisplay['rename']!,
    'revision': ++revision,
    'name': name,
  };
  Future<void> command(String name) async {
    switch (name) {
      case 'rename':
        patch({'display': display('Renamed <plain>')});
      case 'reset':
        patch({'display': producerDisplay['reset tombstone']});
      case 'reset-newer':
        patch({'display': display(null)});
      case 'invalidate':
        patch({'display': null});
      case 'late':
        patch({'display': display('Unverified late')});
      case 'model':
        patch({'model': 'model-only'});
      case 'other':
        patch({'display': display('Other room')}, room: 'r2');
      case 'local':
        await cm.setRoomLocalName(peer.remoteEpk, 'r1', 'Local wins');
      case 'clear':
        await cm.setRoomLocalName(peer.remoteEpk, 'r1', null);
      case 'long':
        patch({'display': display(longLabel)});
      case 'announce-long':
        channel.push({
          'type': 'room_announced',
          'peer': wirePeer,
          'room_id': 'r1',
          'name': 'routing-agent',
          'cwd': '/synthetic/duplicate',
          'model': 'model-only',
          'working': true,
          'display': display(longLabel),
        });
      case 'light':
        dark = false;
        notifyListeners();
      case 'dark':
        dark = true;
        notifyListeners();
      default:
        throw ArgumentError('Unknown synthetic command');
    }
  }

  Map<String, dynamic> status() {
    final widgets = <Map<String, dynamic>>[];
    final drafts = <String>[];
    Object? input;
    void visit(Element element) {
      final widget = element.widget;
      if (widget is Offstage && widget.offstage) return;
      String? label;
      if (widget is Text) label = widget.data;
      if (widget is IconButton) label = widget.tooltip;
      if (widget is TextField) {
        drafts.add(widget.controller?.text ?? '');
        label = 'TextField';
      }
      if (widget is InputBar && element is StatefulElement) {
        input = element.state;
      }
      if (widget is SessionTile) label = 'tile:${widget.room?.roomId}';
      if (label != null) {
        final render = element.findRenderObject();
        if (render is RenderBox && render.attached && render.hasSize) {
          final position = render.localToGlobal(Offset.zero);
          widgets.add({
            'label': label,
            'x': position.dx,
            'y': position.dy,
            'w': render.size.width,
            'h': render.size.height,
          });
        }
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    final state = chat?.state;
    if (state is ChatReady) retainedMessages ??= state.messages;
    retainedInput ??= input;
    return {
      'marker': 'Synthetic offline test',
      'transport': 'mocked IChannel; production ConnectionManager',
      'dark': dark,
      'route': router.routerDelegate.currentConfiguration.last.matchedLocation,
      'rooms': [
        for (final room in cm.roomsFor(wirePeer))
          {
            'id': room.roomId,
            'routingName': room.name,
            'localName': room.localName,
            'title': sessionDisplayName(room, peer),
            'display': room.display?.toJson(),
            'model': room.model,
          },
      ],
      'selectedRoom': selection.current?.roomId,
      'activeRoom': cm.activeRoomId,
      'preferenceRoom': prefs.selectedRoomId,
      'sendCount': channel.sends,
      'controlCount': channel.controlsSent,
      'syncRequests': sync.requests,
      'drafts': drafts,
      'widgets': widgets,
      'errors': errors,
      if (state is ChatReady)
        'messages': state.messages.map((m) => m.id).toList(),
      if (state is ChatReady)
        'queue': state.queuedMessages.map((m) => m.text).toList(),
      if (state is ChatReady)
        'sameMessages': identical(state.messages, retainedMessages),
      if (input != null) 'sameInput': identical(input, retainedInput),
    };
  }
}

class SyntheticApp extends StatelessWidget {
  const SyntheticApp({super.key, required this.fixture});
  final OfflineFixture fixture;
  @override
  Widget build(BuildContext context) => MultiProvider(
    providers: [
      ChangeNotifierProvider<HomeViewModel>.value(value: fixture.home),
      ChangeNotifierProvider<Preferences>.value(value: fixture.prefs),
      ChangeNotifierProvider<SessionSelection>.value(value: fixture.selection),
      ChangeNotifierProvider<ShellLayout>.value(value: fixture.shell),
      ChangeNotifierProvider<UpdateBannerViewModel>.value(
        value: fixture.update,
      ),
      ChangeNotifierProvider<VoiceInputViewModel>.value(value: fixture.voice),
      ChangeNotifierProvider<AttachmentViewModel>.value(value: fixture.attach),
    ],
    child: ListenableBuilder(
      listenable: fixture,
      builder: (_, _) => MaterialApp.router(
        theme: fixture.dark ? buildDarkTheme() : buildLightTheme(),
        routerConfig: fixture.router,
        builder: (context, child) => Stack(
          children: [
            Column(
              children: [
                SizedBox(height: MediaQuery.paddingOf(context).top + 28),
                Expanded(child: ClipRect(child: child!)),
              ],
            ),
            Positioned(
              top: MediaQuery.paddingOf(context).top,
              left: 0,
              right: 0,
              child: Material(
                color: Theme.of(context).colorScheme.surface,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Text(
                    'Synthetic offline test',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall!.copyWith(
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
