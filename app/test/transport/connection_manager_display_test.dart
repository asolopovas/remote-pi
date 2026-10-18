import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

const peer = PeerRecord(
  remoteEpk: 'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO_oMQ6yyQE',
  sessionName: 'project',
  relayUrl: 'ws://synthetic',
  pairedAt: '2026-01-01',
  roomId: 'r1',
);
const wirePeer = 'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO/oMQ6yyQE=';
const nativeA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const epochA = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
Map<String, dynamic> display(
  int revision,
  String? name, {
  String epoch = epochA,
  String native = nativeA,
}) => {
  'native_session_id': native,
  'epoch': epoch,
  'revision': revision,
  'name': name,
};
Map<String, dynamic> announced({
  Object? value,
  bool include = true,
  String room = 'r1',
  String remoteName = 'routing-agent',
}) => {
  'type': 'room_announced',
  'peer': wirePeer,
  'room_id': room,
  'name': remoteName,
  'cwd': '/synthetic/duplicate',
  'started_at': 1,
  'model': 'model-a',
  'thinking': 'high',
  'working': true,
  if (include) 'display': value,
};
Map<String, dynamic> patch(
  Map<String, dynamic> meta, {
  String room = 'r1',
  String target = wirePeer,
}) => {
  'type': 'room_meta_updated',
  'peer': target,
  'room_id': room,
  'meta': meta,
};

class Storage extends PairingStorage {
  List<PersistedRoom> rooms = [];
  @override
  Future<List<PeerRecord>> listPeers() async => [peer];
  @override
  Future<List<PersistedRoom>> loadRooms(String epk) async => List.of(rooms);
  @override
  Future<void> saveRooms(String epk, List<PersistedRoom> value) async {
    rooms = List.of(value);
  }
}

class RecordingStream<T> extends Stream<T> {
  final Stream<T> source;
  final callbacks = <void Function(T)?>[];
  final doneCallbacks = <void Function()?>[];
  final errorCallbacks = <Function?>[];
  RecordingStream(this.source);
  @override
  StreamSubscription<T> listen(
    void Function(T)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    callbacks.add(onData);
    doneCallbacks.add(onDone);
    errorCallbacks.add(onError);
    return source.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

class Channel implements IChannel, IControlLink {
  final controls = StreamController<ControlInbound>.broadcast();
  final messages = StreamController<ServerMessage>.broadcast();
  late final recordedControls = RecordingStream(controls.stream);
  late final recordedMessages = RecordingStream(messages.stream);
  final checks = <Map<String, dynamic>>[];
  final sends = <ClientMessage>[];
  @override
  Stream<ControlInbound> get controlFrames => recordedControls;
  @override
  Stream<ServerMessage> get serverMessages => recordedMessages;
  @override
  void sendControl(Map<String, dynamic> value) => checks.add(value);
  @override
  Future<void> send(ClientMessage value) async {
    sends.add(value);
  }

  @override
  Future<void> close() async {}
  void push(Map<String, dynamic> value) =>
      controls.add(ControlInbound.tryFromJson(value)!);
}

Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class Harness {
  final Channel ch;
  final Storage storage;
  final ConnectionManager cm;
  Harness(this.ch, this.storage, this.cm);
  static Future<Harness> create([Storage? storage]) async {
    final ch = Channel();
    final disk = storage ?? Storage();
    final cm = ConnectionManager(
      factory: (_, _) async => ch,
      storage: disk,
      emitDebounce: Duration.zero,
    );
    addTearDown(cm.dispose);
    await cm.boot();
    return Harness(ch, disk, cm);
  }

  RoomInfo room([String id = 'r1']) =>
      cm.roomsFor(wirePeer).singleWhere((r) => r.roomId == id);
  Future<void> push(Map<String, dynamic> frame) async {
    ch.push(frame);
    await settle();
  }

  Future<void> snapshot(Object? value, {bool include = true}) => push({
    'type': 'rooms',
    'peer': wirePeer,
    'rooms': [
      {
        'room_id': 'r1',
        'name': 'routing-agent',
        'cwd': '/synthetic/duplicate',
        'started_at': 1,
        'working': true,
        if (include) 'display': value,
      },
    ],
  });
}

void main() {
  test(
    'verified desktop rename remains separate from routing name and local override',
    () async {
      final ch = Channel();
      final storage = Storage();
      final cm = ConnectionManager(
        factory: (_, _) async => ch,
        storage: storage,
        emitDebounce: Duration.zero,
      );
      addTearDown(cm.dispose);
      await cm.boot();
      ch.push(announced(value: display(0, null)));
      await settle();
      ch.push(patch({'display': display(1, 'Pi · system')}));
      await settle();
      expect(
        cm.roomsFor(wirePeer).single.toJson()['display'],
        display(1, 'Pi · system'),
      );
      await cm.setRoomLocalName(peer.remoteEpk, 'r1', 'mobile');
      expect(cm.roomsFor(wirePeer).single.name, 'routing-agent');
      ch.push(
        announced(
          value: display(1, 'Pi · system'),
          remoteName: 'fresh-routing',
        ),
      );
      await settle();
      expect(storage.rooms.single.localName, 'mobile');
      await cm.setRoomLocalName(peer.remoteEpk, 'r1', null);
      expect(storage.rooms.single.localName, isNull);
      expect(cm.activeRoomId, 'r1');
    },
  );
  test(
    'rename/reset duplicates older/conflicting revisions do not rekey or send requests',
    () async {
      final h = await Harness.create();
      final emissions = <Map<String, List<RoomInfo>>>[];
      h.cm.roomsStream.listen(emissions.add);
      await h.push(announced(value: display(0, null)));
      final requests = h.ch.checks.length;
      expect(h.room().display?.name, isNull);
      expect(h.room().display, isNotNull);
      await h.push(patch({'display': display(1, 'Pi · system')}));
      final emitted = emissions.length;
      for (final value in [
        display(1, 'Pi · system'),
        display(1, 'conflict'),
        display(0, null),
      ]) {
        await h.push(patch({'display': value}));
        await h.snapshot(value);
        expect(h.room().display?.name, 'Pi · system');
      }
      expect(emissions.length, emitted);
      await h.push(patch({'display': display(2, null)}));
      expect(h.room().display, isNotNull);
      expect(h.room().display?.name, isNull);
      expect(h.room().name, 'routing-agent');
      expect(h.cm.activeRoomId, 'r1');
      expect(h.ch.checks.length, requests);
      expect(h.ch.sends, isEmpty);
    },
  );

  test(
    'invalidation retains highwater; only authoritative coherent snapshots recover',
    () async {
      final h = await Harness.create();
      await h.push(announced(value: display(4, 'current')));
      await h.push(patch({'display': null}));
      expect(h.room().display, isNull);
      for (final value in [
        display(3, 'older'),
        display(4, 'conflict'),
        display(4, 'current'),
        display(5, 'incremental-only'),
      ]) {
        await h.push(patch({'display': value}));
        expect(h.room().display, isNull);
      }
      await h.snapshot(display(3, 'older'));
      expect(h.room().display, isNull);
      await h.snapshot(display(4, 'conflict'));
      expect(h.room().display, isNull);
      await h.push(announced(value: display(4, 'current')));
      expect(h.room().display?.name, 'current');
      await h.snapshot(null, include: false);
      expect(h.room().display, isNull);
      await h.snapshot(display(4, 'current'));
      expect(h.room().display?.name, 'current');
    },
  );

  test(
    'new incarnation requires announcement; native A B A reload never resurrect retired epoch',
    () async {
      final h = await Harness.create();
      const epochB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
      const epochC = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
      const nativeB = '11111111-1111-4111-8111-111111111111';
      await h.push(announced(value: display(2, 'A')));
      await h.push(
        patch({'display': display(3, 'wrong-native', native: nativeB)}),
      );
      await h.push(
        patch({'display': display(0, 'B', epoch: epochB, native: nativeB)}),
      );
      expect(h.room().display?.name, 'A');
      await h.push(
        announced(
          value: display(0, 'B', epoch: epochB, native: nativeB),
        ),
      );
      expect(h.room().display?.name, 'B');
      await h.snapshot(display(10, 'old A'));
      expect(h.room().display?.name, 'B');
      await h.snapshot(display(0, 'new A', epoch: epochC));
      expect(h.room().display?.name, 'new A');
      await h.push(patch({'display': display(11, 'old A')}));
      await h.push(announced(value: display(11, 'old A')));
      expect(h.room().display?.name, 'new A');
    },
  );

  test(
    'legacy omission and invalid metadata preserve unrelated fields and local provenance',
    () async {
      final h = await Harness.create();
      await h.push(announced(value: display(1, 'desktop')));
      await h.cm.setRoomLocalName(peer.remoteEpk, 'r1', 'mobile');
      await h.push(patch({'working': false}));
      expect(h.room().display?.name, 'desktop');
      expect(h.room().thinking, ThinkingLevel.high);
      expect(h.room().model, 'model-a');
      await h.push(
        patch({
          'display': {'name': 'unbound'},
          'model': null,
          'thinking': null,
        }),
      );
      expect(h.room().display?.name, 'desktop');
      expect(h.room().model, isNull);
      expect(h.room().thinking, isNull);
      expect(h.room().working, isFalse);
      expect(h.room().localName, 'mobile');
      await h.push(announced(include: false));
      expect(h.room().display, isNull);
      expect(h.room().localName, 'mobile');
      // Malformed authority snapshot cannot become a title or routing name.
      await h.snapshot({'name': 'unverified instructions'});
      expect(h.room().display, isNull);
      expect(h.room().name, 'routing-agent');
    },
  );

  test(
    'identical cwd/name and unknown peers/rooms cannot cross display authorities',
    () async {
      final h = await Harness.create();
      await h.push(announced(value: display(1, 'same')));
      await h.push(announced(value: display(1, 'same'), room: 'r2'));
      await h.push(patch({'display': display(2, 'only r2')}, room: 'r2'));
      expect(h.room().display?.name, 'same');
      expect(h.room('r2').display?.name, 'only r2');
      await h.push(
        patch({'display': display(3, 'unknown room')}, room: 'unknown'),
      );
      await h.push(
        patch({'display': display(3, 'wrong peer')}, target: 'unpaired'),
      );
      await h.push({
        ...announced(value: display(1, 'unpaired')),
        'peer': 'unpaired',
      });
      expect(h.cm.roomsFor('unpaired').single.display, isNull);
      expect(h.room().display?.name, 'same');
      expect(h.cm.activeRoomId, 'r1');
    },
  );

  test(
    'explicit local override fresh snapshot clear and cold restart do not promote cached alias',
    () async {
      final storage = Storage()
        ..rooms = [
          const PersistedRoom(
            roomId: 'r1',
            startedAt: 1,
            name: 'route',
            localName: 'saved mobile',
            model: 'cached-model',
          ),
          const PersistedRoom(
            roomId: 'cached',
            startedAt: 1,
            name: 'project name',
          ),
        ];
      final h = await Harness.create(storage);
      expect(h.room().localName, 'saved mobile');
      expect(h.room().name, 'route');
      expect(h.room('cached').localName, isNull);
      expect(h.room().display, isNull);
      expect(h.cm.isRoomLive(peer.remoteEpk, 'r1'), isFalse);
      await h.snapshot(display(1, 'desktop'));
      expect(h.room().localName, 'saved mobile');
      expect(h.room().model, 'cached-model');
      await h.cm.setRoomLocalName(peer.remoteEpk, 'r1', null);
      expect(h.room().localName, isNull);
      expect(h.room().display?.name, 'desktop');
      expect(h.room().name, 'routing-agent');
      await h.cm.setRoomLocalName(peer.remoteEpk, 'r1', 'saved again');
      await h.cm.disconnect();
      expect(h.room().display, isNull);
      final restart = await Harness.create(storage);
      expect(restart.room().localName, 'saved again');
      expect(restart.room().name, 'routing-agent');
      expect(restart.room().display, isNull);
      expect(restart.cm.isRoomLive(peer.remoteEpk, 'r1'), isFalse);
      expect(
        storage.rooms
            .singleWhere((r) => r.roomId == 'r1')
            .toJson()
            .containsKey('display'),
        isFalse,
      );
    },
  );

  test(
    'socket replacement fences old queued frames even when same channel object is reused',
    () async {
      final h = await Harness.create();
      await h.push(announced(value: display(2, 'old')));
      // Queue old callback before replacing its subscription.
      h.ch.push(announced(value: display(3, 'obsolete')));
      final replacement = Channel();
      h.cm.adopt(replacement, peer);
      await settle();
      expect(h.room().display, isNull);
      expect(h.cm.isRoomLive(peer.remoteEpk, 'r1'), isFalse);
      replacement.push(announced(value: display(0, 'fresh')));
      await settle();
      expect(h.room().display?.name, 'fresh');
      h.ch.push(announced(value: display(99, 'late old')));
      await settle();
      expect(h.room().display?.name, 'fresh');
      // Queued event from a previous generation of the very same object.
      replacement.push(patch({'display': display(100, 'old generation')}));
      h.cm.adopt(replacement, peer);
      await settle();
      expect(h.room().display, isNull);
      replacement.push(announced(value: display(0, 'same object fresh')));
      await settle();
      expect(h.room().display?.name, 'same object fresh');
      // Invoke a captured obsolete callback explicitly; cancellation alone would
      // hide this race in a regular broadcast-controller fake.
      replacement.recordedControls.callbacks.first!(
        ControlInbound.tryFromJson(
          announced(value: display(200, 'obsolete same object callback')),
        )!,
      );
      await settle();
      expect(h.room().display?.name, 'same object fresh');
    },
  );

  test(
    'actual room teardown removes bounded retired state and cache stays offline',
    () async {
      final h = await Harness.create();
      await h.push(announced(value: display(1, 'desktop')));
      await h.push({
        'type': 'room_ended',
        'peer': wirePeer,
        'room_id': 'r1',
        'since_ts': 2,
      });
      expect(h.room().display, isNull);
      expect(h.cm.isRoomLive(peer.remoteEpk, 'r1'), isFalse);
      await h.push(patch({'display': display(2, 'late')}));
      expect(h.room().display, isNull);
      await h.snapshot(display(0, 'fresh room'));
      expect(h.room().display?.name, 'fresh room');
      await h.push({'type': 'rooms', 'peer': wirePeer, 'rooms': []});
      expect(h.room().display, isNull);
      expect(h.cm.isRoomLive(peer.remoteEpk, 'r1'), isFalse);
    },
  );

  test(
    'producer fixture rename/reset through actual Relay full-meta update retains selection',
    () async {
      final h = await Harness.create();
      final fixtures =
          jsonDecode(
                File(
                  'test/protocol/fixtures/81-display-serialization.json',
                ).readAsStringSync(),
              )
              as List<dynamic>;
      final hello = fixtures[1]['frame'] as Map<String, dynamic>;
      final meta = hello['room_meta'] as Map<String, dynamic>;
      final routing = hello['room_id'] as String;
      h.cm.switchRoom(routing);
      await h.push({
        ...meta,
        'room_id': routing,
        'started_at': 1,
        'working': false,
        'peer': wirePeer,
        'type': 'room_announced',
      });
      for (final index in [2, 3]) {
        final producer = fixtures[index]['frame'] as Map<String, dynamic>;
        await h.push({
          'type': 'room_meta_updated',
          'peer': wirePeer,
          'room_id': routing,
          'meta': {
            'working': false,
            ...producer['meta'] as Map<String, dynamic>,
          },
        });
        expect(h.room(routing).display?.toJson(), producer['meta']['display']);
        expect(h.cm.activeRoomId, routing);
        expect(h.room(routing).name, 'routing-agent');
      }
    },
  );
  test(
    'unsubscribed peer clears display and notifies without removing local cache',
    () async {
      final h = await Harness.create();
      const otherPeer = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
      h.cm.subscribeToPeers([peer.remoteEpk, otherPeer]);
      await h.push({
        ...announced(value: display(1, 'other desktop')),
        'peer': otherPeer,
      });
      final emissions = <Map<String, List<RoomInfo>>>[];
      h.cm.roomsStream.listen(emissions.add);
      h.cm.subscribeToPeers([peer.remoteEpk]);
      await settle();
      expect(h.cm.roomsFor(otherPeer).single.display, isNull);
      expect(emissions, isNotEmpty);
      await h.push(
        patch({'display': display(2, 'late other')}, target: otherPeer),
      );
      expect(h.cm.roomsFor(otherPeer).single.display, isNull);
      expect(h.cm.activeRoomId, 'r1');
    },
  );
}
