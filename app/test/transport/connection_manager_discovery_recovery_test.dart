import 'dart:async';
import 'dart:convert';

import 'package:app/config/dependencies.dart';
import 'package:app/data/mesh/mesh_sync_service.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/main.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _urlEpk = 'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO_oMQ6yyQE';
const _wireEpk = 'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO/oMQ6yyQE=';
const _peer = PeerRecord(
  remoteEpk: _urlEpk,
  sessionName: 'project',
  relayUrl: 'ws://localhost',
  pairedAt: '2026-01-01T00:00:00Z',
  roomId: 'project',
);
const _room = RoomInfo(roomId: 'project', cwd: '/project', startedAt: 1);

class _Storage extends PairingStorage {
  final List<PersistedRoom> cachedRooms;
  _Storage([this.cachedRooms = const []]);

  @override
  Future<List<PeerRecord>> listPeers() async => [_peer];
  @override
  Future<List<PersistedRoom>> loadRooms(String epk) async => cachedRooms;
  @override
  Future<void> saveRooms(String epk, List<PersistedRoom> rooms) async {}
}

class _Channel implements IChannel, IControlLink {
  final messages = StreamController<ServerMessage>.broadcast();
  final controls = StreamController<ControlInbound>.broadcast();
  final sent = <ClientMessage>[];
  final checks = <Map<String, dynamic>>[];
  bool closed = false;
  final List<RoomInfo>? registryRooms;
  String? _lastRoomsResponse;
  int roomsEmitted = 0;
  int roomsSuppressed = 0;

  _Channel({this.registryRooms});

  @override
  Stream<ServerMessage> get serverMessages => messages.stream;
  @override
  Stream<ControlInbound> get controlFrames => controls.stream;
  @override
  Future<void> send(ClientMessage msg) async => sent.add(msg);
  @override
  void sendControl(Map<String, dynamic> json) {
    checks.add(json);
    final rooms = registryRooms;
    if (json['type'] != 'rooms_check' || rooms == null) return;
    // relay/src/handlers/peer.rs:234-250 dedups each peer's unchanged
    // rooms response on this socket, even after local heartbeat degradation.
    final response = jsonEncode(rooms.map((r) => r.toJson()).toList());
    if (response == _lastRoomsResponse) {
      roomsSuppressed++;
      return;
    }
    _lastRoomsResponse = response;
    roomsEmitted++;
    controls.add(RoomsSnapshot(peer: _wireEpk, rooms: rooms));
  }

  @override
  Future<void> close() async {
    closed = true;
    await messages.close();
    await controls.close();
  }
}

class _MeshSync extends ChangeNotifier implements MeshSyncService {
  int starts = 0;
  int stops = 0;
  int pulls = 0;
  @override
  void startPolling({Duration interval = const Duration(seconds: 60)}) =>
      starts++;
  @override
  void stopPolling() => stops++;
  @override
  Future<bool> pullOnDemand() async {
    pulls++;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void _expectChecks(_Channel ch) {
  expect(ch.checks.where((frame) => frame.containsKey('type')).toList(), [
    {
      'type': 'presence_check',
      'peers': [_wireEpk],
    },
    {
      'type': 'rooms_check',
      'peers': [_wireEpk],
    },
  ]);
}

Future<ConnectionManager> _connected(WidgetTester tester, _Channel ch) async {
  final cm = ConnectionManager(
    factory: (_, _) async => ch,
    storage: _Storage(),
    emitDebounce: Duration.zero,
  );
  await cm.boot();
  if (ch.registryRooms == null) {
    ch.controls.add(const RoomsSnapshot(peer: _wireEpk, rooms: [_room]));
  }
  await tester.pump();
  expect(cm.isRoomLive(_urlEpk, 'project'), isTrue);
  ch.checks.clear();
  return cm;
}

void main() {
  for (final cachedOnly in [false, true]) {
    testWidgets(
      'current Pong cannot restore ${cachedOnly ? 'cache-only' : 'never-live'} room',
      (tester) async {
        final ch = _Channel();
        final cm = ConnectionManager(
          factory: (_, _) async => ch,
          storage: _Storage(
            cachedOnly
                ? [
                    const PersistedRoom(
                      roomId: 'project',
                      cwd: '/project',
                      startedAt: 1,
                    ),
                  ]
                : [],
          ),
          emitDebounce: Duration.zero,
        );
        await cm.boot();
        ch.checks.clear();
        await tester.pump(const Duration(seconds: 75));
        ch.messages.add(Pong(inReplyTo: ch.sent.whereType<Ping>().last.id));
        await tester.pump();
        expect(cm.isRoomLive(_urlEpk, 'project'), isFalse);
        expect(ch.checks, isEmpty);
        expect(cm.roomsFor(_urlEpk), hasLength(cachedOnly ? 1 : 0));
        cm.dispose();
      },
    );
  }

  testWidgets(
    'empty snapshot invalidates prior live recovery and overrides restoration',
    (tester) async {
      final ch = _Channel();
      final cm = await _connected(tester, ch);
      await tester.pump(const Duration(seconds: 75));
      final delayedPing = ch.sent.whereType<Ping>().last.id;
      ch.controls.add(const RoomsSnapshot(peer: _wireEpk, rooms: []));
      await tester.pump();
      ch.messages.add(Pong(inReplyTo: delayedPing));
      await tester.pump();
      expect(cm.isRoomLive(_urlEpk, 'project'), isFalse);
      expect(ch.checks, isEmpty);
      await tester.pump(const Duration(seconds: 25));
      ch.messages.add(Pong(inReplyTo: ch.sent.whereType<Ping>().last.id));
      await tester.pump();
      expect(cm.isRoomLive(_urlEpk, 'project'), isFalse);
      expect(ch.checks, isEmpty);

      ch.controls.add(const RoomsSnapshot(peer: _wireEpk, rooms: [_room]));
      await tester.pump();
      await tester.pump(const Duration(seconds: 75));
      final recoveryPing = ch.sent.whereType<Ping>().last.id;
      ch.messages.add(Pong(inReplyTo: recoveryPing));
      await tester.pump();
      expect(cm.isRoomLive(_urlEpk, 'project'), isTrue);
      ch.controls.add(const RoomsSnapshot(peer: _wireEpk, rooms: []));
      await tester.pump();
      ch.messages.add(Pong(inReplyTo: recoveryPing));
      await tester.pump();
      expect(cm.isRoomLive(_urlEpk, 'project'), isFalse);
      _expectChecks(ch);
      cm.dispose();
    },
  );

  testWidgets('deleted cached room cannot be restored by current Pong', (
    tester,
  ) async {
    final ch = _Channel();
    final cm = await _connected(tester, ch);
    await tester.pump(const Duration(seconds: 75));
    final probe = ch.sent.whereType<Ping>().last.id;
    await cm.deleteCachedRoom(_urlEpk, 'project');
    ch.messages.add(Pong(inReplyTo: probe));
    await tester.pump();
    expect(cm.roomsFor(_urlEpk), isEmpty);
    expect(cm.isRoomLive(_urlEpk, 'project'), isFalse);
    expect(ch.checks, isEmpty);
    cm.dispose();
  });

  testWidgets(
    'discovery refresh is read-only, normalized and safe offline/empty',
    (tester) async {
      final ch = _Channel();
      final cm = ConnectionManager(
        factory: (_, _) async => ch,
        storage: _Storage(),
      );
      cm.refreshDiscovery();
      cm.subscribeToPeers([_urlEpk]);
      cm.refreshDiscovery();
      expect(ch.checks, isEmpty);
      await cm.connectTo(_peer);
      ch.checks.clear();
      cm.refreshDiscovery();
      _expectChecks(ch);
      cm.refreshDiscovery();
      expect(ch.checks, hasLength(4));
      expect(cm.activePeer?.remoteEpk, _urlEpk);
      expect(cm.activeRoomId, 'project');
      expect(ch.sent, isEmpty);
      cm.subscribeToPeers([]);
      ch.checks.clear();
      cm.refreshDiscovery();
      expect(ch.checks, isEmpty);
      await cm.disconnect();
      cm.refreshDiscovery();
      expect(ch.checks, isEmpty);
      cm.dispose();
    },
  );

  testWidgets('normal traffic and unmatched Pong never request recovery', (
    tester,
  ) async {
    final ch = _Channel();
    final cm = await _connected(tester, ch);
    for (var i = 0; i < 5; i++) {
      ch.messages.add(AgentChunk(inReplyTo: 'turn', delta: 'text'));
      ch.messages.add(Pong(inReplyTo: 'unknown'));
    }
    await tester.pump();
    expect(ch.checks, isEmpty);
    await tester.pump(const Duration(seconds: 75));
    expect(cm.isRoomLive(_urlEpk, 'project'), isFalse);
    ch.messages.add(AgentChunk(inReplyTo: 'turn', delta: 'text'));
    ch.messages.add(Pong(inReplyTo: ch.sent.whereType<Ping>().first.id));
    await tester.pump();
    expect(ch.checks, isEmpty);
    expect(cm.isRoomLive(_urlEpk, 'project'), isFalse);
    // Arbitrary traffic resets misses but must not erase pending degradation.
    ch.messages.add(Pong(inReplyTo: ch.sent.whereType<Ping>().last.id));
    await tester.pump();
    _expectChecks(ch);
    expect(cm.isRoomLive(_urlEpk, 'project'), isTrue);
    cm.dispose();
  });

  testWidgets('room ended invalidates recovery; empty snapshot retains cache', (
    tester,
  ) async {
    final ch = _Channel();
    final cm = await _connected(tester, ch);
    await tester.pump(const Duration(seconds: 75));
    final oldPing = ch.sent.whereType<Ping>().last.id;
    ch.controls.add(
      const RoomEnded(peer: _wireEpk, roomId: 'project', sinceTs: 2),
    );
    await tester.pump();
    ch.messages.add(Pong(inReplyTo: oldPing));
    await tester.pump();
    expect(ch.checks, isEmpty);
    expect(cm.isRoomLive(_urlEpk, 'project'), isFalse);
    await tester.pump(const Duration(seconds: 25));
    ch.messages.add(Pong(inReplyTo: ch.sent.whereType<Ping>().last.id));
    await tester.pump();
    expect(cm.isRoomLive(_urlEpk, 'project'), isFalse);
    expect(ch.checks, isEmpty);
    cm.refreshDiscovery();
    _expectChecks(ch);
    ch.controls.add(const RoomsSnapshot(peer: _wireEpk, rooms: []));
    await tester.pump();
    expect(cm.isRoomLive(_urlEpk, 'project'), isFalse);
    expect(cm.roomsFor(_urlEpk), [_room]);
    ch.controls.add(
      const RoomAnnounced(
        peer: _wireEpk,
        roomId: 'project',
        cwd: '/project',
        startedAt: 1,
      ),
    );
    await tester.pump();
    expect(cm.isRoomLive(_urlEpk, 'project'), isTrue);
    cm.dispose();
  });

  testWidgets('stale room probe cannot refresh a different selection', (
    tester,
  ) async {
    final ch = _Channel();
    final cm = await _connected(tester, ch);
    await tester.pump(const Duration(seconds: 75));
    final oldPing = ch.sent.whereType<Ping>().last.id;
    cm.switchRoom('another');
    ch.messages.add(Pong(inReplyTo: oldPing));
    await tester.pump();
    expect(ch.checks, isEmpty);
    expect(cm.activeRoomId, 'another');
    expect(cm.isRoomLive(_urlEpk, 'project'), isFalse);
    expect(cm.isRoomLive(_urlEpk, 'another'), isFalse);
    cm.switchRoom('project');
    ch.messages.add(Pong(inReplyTo: oldPing));
    await tester.pump();
    expect(cm.isRoomLive(_urlEpk, 'project'), isFalse);
    expect(ch.checks, isEmpty);
    cm.dispose();
  });

  testWidgets('subscription change clears pending heartbeat recovery', (
    tester,
  ) async {
    final ch = _Channel();
    final cm = await _connected(tester, ch);
    await tester.pump(const Duration(seconds: 75));
    final oldPing = ch.sent.whereType<Ping>().last.id;
    cm.subscribeToPeers([]);
    cm.subscribeToPeers([_urlEpk]);
    ch.checks.clear();
    ch.messages.add(Pong(inReplyTo: oldPing));
    await tester.pump();
    expect(ch.checks, isEmpty);
    expect(cm.isRoomLive(_urlEpk, 'project'), isFalse);
    cm.dispose();
  });

  testWidgets('replaced socket rejects stale Pong and replays subscriptions', (
    tester,
  ) async {
    final ch = _Channel();
    final cm = await _connected(tester, ch);
    await tester.pump(const Duration(seconds: 75));
    final oldPing = ch.sent.whereType<Ping>().last.id;
    final next = _Channel();
    cm.adopt(next, _peer);
    ch.messages.add(Pong(inReplyTo: oldPing));
    ch.controls.add(const RoomsSnapshot(peer: _wireEpk, rooms: [_room]));
    await tester.pump(const Duration(milliseconds: 1));
    expect(next.checks.map((m) => m['type']), [
      'subscribe_presence',
      'presence_check',
      'subscribe_rooms',
      'rooms_check',
    ]);
    next.checks.clear();
    next.messages.add(Pong(inReplyTo: oldPing));
    await tester.pump();
    expect(next.checks, isEmpty);
    expect(cm.isRoomLive(_urlEpk, 'project'), isFalse);
    next.controls.add(const RoomsSnapshot(peer: _wireEpk, rooms: [_room]));
    await tester.pump();
    expect(cm.isRoomLive(_urlEpk, 'project'), isTrue);
    cm.dispose();
  });

  testWidgets(
    'heartbeat recovery survives unchanged same-socket rooms_check suppression',
    (tester) async {
      final ch = _Channel(registryRooms: [_room]);
      final cm = await _connected(tester, ch);
      final liveUpdates = <bool>[];
      final sub = cm.roomsStream.listen((_) {
        liveUpdates.add(cm.isRoomLive(_urlEpk, 'project'));
      });
      await tester.pump(const Duration(seconds: 75));
      expect(cm.status, isA<StatusOnline>());
      expect(ch.closed, isFalse);
      expect(cm.isRoomLive(_urlEpk, 'project'), isFalse);
      expect(ch.sent.whereType<Ping>(), hasLength(3));

      ch.messages.add(Pong(inReplyTo: ch.sent.whereType<Ping>().last.id));
      await tester.pump();
      _expectChecks(ch);
      expect(ch.roomsEmitted, 1);
      expect(ch.roomsSuppressed, 1);
      expect(
        cm.isRoomLive(_urlEpk, 'project'),
        isTrue,
        reason:
            'current Pong restores only the room locally removed as degraded',
      );
      await tester.pump(const Duration(milliseconds: 1));
      expect(liveUpdates, containsAllInOrder([false, true]));
      expect(cm.activeRoomId, 'project');
      expect(cm.activePeer?.remoteEpk, _urlEpk);

      for (var i = 0; i < 5; i++) {
        ch.messages.add(Pong(inReplyTo: ch.sent.whereType<Ping>().last.id));
      }
      await tester.pump();
      _expectChecks(ch);
      expect(ch.roomsEmitted, 1);
      expect(ch.roomsSuppressed, 1);
      ch.controls.add(
        const RoomEnded(peer: _wireEpk, roomId: 'project', sinceTs: 2),
      );
      await tester.pump();
      ch.messages.add(Pong(inReplyTo: ch.sent.whereType<Ping>().last.id));
      await tester.pump();
      expect(cm.isRoomLive(_urlEpk, 'project'), isFalse);
      _expectChecks(ch);
      unawaited(sub.cancel());
      cm.dispose();
    },
  );

  testWidgets('RemotePiApp foreground callback reconciles connected rooms', (
    tester,
  ) async {
    final ch = _Channel();
    final cm = await _connected(tester, ch);
    final mesh = _MeshSync();
    injector.addInstance<ConnectionManager>(cm);
    injector.addInstance<MeshSyncService>(mesh);
    injector.commit();
    addTearDown(injector.dispose);
    addTearDown(mesh.dispose);
    // Invoke the production observer without building the unrelated boot router.
    final observer =
        const RemotePiApp().createState() as WidgetsBindingObserver;
    observer.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(ch.checks, isEmpty);
    observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
    _expectChecks(ch);
    expect(mesh.starts, 1);
    expect(mesh.stops, 1);
    expect(mesh.pulls, 1);

    ch.controls.add(
      const RoomsSnapshot(
        peer: _wireEpk,
        rooms: [
          _room,
          RoomInfo(roomId: 'new-project', cwd: '/new-project', startedAt: 2),
        ],
      ),
    );
    await tester.pump();
    expect(cm.isRoomLive(_urlEpk, 'new-project'), isTrue);
    expect(cm.activeRoomId, 'project');
    cm.subscribeToPeers([]);
    ch.checks.clear();
    observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(ch.checks, isEmpty);
    await cm.disconnect();
    observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(ch.checks, isEmpty);
    cm.dispose();
  });
}
