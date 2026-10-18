import 'dart:async';

import 'package:app/data/agents/session_control_repository_impl.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/contracts/session_control_repository.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

const peer = PeerRecord(
  remoteEpk: 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=',
  sessionName: 'PC',
  relayUrl: 'ws://fixture',
  pairedAt: '2026-01-01',
  roomId: 'one',
);

class Storage extends PairingStorage {
  List<PersistedRoom> rooms = [];
  @override
  Future<List<PeerRecord>> listPeers() async => [peer];
  @override
  Future<PeerRecord?> loadPeer(String key) async => peer;
  @override
  Future<void> savePeer(PeerRecord value) async {}
  @override
  Future<List<PersistedRoom>> loadRooms(String key) async => rooms;
  @override
  Future<void> saveRooms(String key, List<PersistedRoom> value) async {
    rooms = value;
  }
}

class Channel implements IChannel, IControlLink {
  final messages = StreamController<ServerMessage>.broadcast();
  final controls = StreamController<ControlInbound>.broadcast();
  final sent = <ClientMessage>[];
  @override
  Stream<ServerMessage> get serverMessages => messages.stream;
  @override
  Stream<ControlInbound> get controlFrames => controls.stream;
  @override
  Future<void> send(ClientMessage value) async {
    sent.add(value);
  }

  @override
  void sendControl(Map<String, dynamic> value) {}
  @override
  Future<void> close() async {
    await messages.close();
    await controls.close();
  }
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  late Channel channel;
  late ConnectionManager conn;
  late SessionControlRepositoryImpl repo;
  setUp(() async {
    channel = Channel();
    conn = ConnectionManager(
      factory: (_, _) async => channel,
      storage: Storage(),
      emitDebounce: Duration.zero,
    );
    await conn.connectTo(peer);
    channel.controls.add(
      RoomAnnounced(peer: peer.remoteEpk, roomId: 'one', startedAt: 1),
    );
    await settle();
    repo = SessionControlRepositoryImpl(
      conn,
      timeout: const Duration(milliseconds: 50),
      stopTimeout: const Duration(milliseconds: 50),
    );
  });
  tearDown(() async {
    repo.dispose();
    await conn.disconnect();
    conn.dispose();
  });
  Future<SessionStopCapability> inspect() async {
    final pending = repo.inspect(peer.remoteEpk, 'one');
    await settle();
    final id = (channel.sent.last as SessionControlStatus).id;
    channel.messages.add(
      SessionControlStatusResult(id, 'one', true, 'opaque-token', null),
    );
    return pending;
  }

  test(
    'status and Stop are exact-room, single-use and never auto-replayed',
    () async {
      final capability = await inspect();
      final pending = repo.stop(capability);
      await settle();
      final request = channel.sent.last as SessionStop;
      expect(request.roomId, 'one');
      expect(request.token, 'opaque-token');
      expect(
        request.toJson().keys,
        unorderedEquals(['type', 'id', 'room_id', 'token']),
      );
      channel.messages.add(SessionStopResult(request.id, 'one', 'requested'));
      expect(await pending, SessionStopOutcome.requested);
      final count = channel.sent.length;
      await expectLater(
        repo.stop(capability),
        throwsA(isA<SessionControlFailure>()),
      );
      expect(channel.sent.length, count);
    },
  );
  test(
    'same room new incarnation invalidates old Stop capability without sending',
    () async {
      final capability = await inspect();
      channel.controls.add(
        RoomAnnounced(peer: peer.remoteEpk, roomId: 'one', startedAt: 2),
      );
      await settle();
      final count = channel.sent.length;
      await expectLater(
        repo.stop(capability),
        throwsA(isA<SessionControlFailure>()),
      );
      expect(channel.sent.length, count);
    },
  );
  test(
    'same room new incarnation rejects a late access/status snapshot',
    () async {
      final pending = repo.inspect(peer.remoteEpk, 'one');
      final assertion = expectLater(
        pending,
        throwsA(isA<SessionControlFailure>()),
      );
      await settle();
      final id = (channel.sent.last as SessionControlStatus).id;
      channel.controls.add(
        RoomAnnounced(peer: peer.remoteEpk, roomId: 'one', startedAt: 2),
      );
      await settle();
      channel.messages.add(
        SessionControlStatusResult(id, 'one', true, 'stale', null),
      );
      await assertion;
    },
  );
  test('stopped response is distinct from requested', () async {
    final capability = await inspect();
    final pending = repo.stop(capability);
    await settle();
    final request = channel.sent.last as SessionStop;
    channel.messages.add(SessionStopResult(request.id, 'one', 'stopped'));
    expect(await pending, SessionStopOutcome.stopped);
  });
  test(
    'foreign room/type/nonce and unscoped errors cannot authorize controls',
    () async {
      final pending = repo.inspect(peer.remoteEpk, 'one');
      var done = false;
      pending.then((_) => done = true);
      await settle();
      final id = (channel.sent.last as SessionControlStatus).id;
      channel.messages.add(
        SessionControlStatusResult(id, 'foreign', true, 'foreign-token', null),
      );
      channel.messages.add(
        SessionControlStatusResult('wrong', 'one', true, 'foreign-token', null),
      );
      channel.messages.add(SessionStopResult(id, 'one', 'stopped'));
      channel.messages.add(
        ErrorMessage(
          inReplyTo: id,
          code: 'invalid_message',
          message: 'Unscoped',
        ),
      );
      channel.messages.add(
        ScopedPeerError(
          ErrorMessage(
            inReplyTo: id,
            code: 'invalid_message',
            message: 'Foreign',
          ),
          peer: peer.remoteEpk,
          room: 'foreign',
        ),
      );
      await settle();
      expect(done, isFalse);
      channel.messages.add(
        SessionControlStatusResult(id, 'one', true, 'correct-token', null),
      );
      expect((await pending).token, 'correct-token');
    },
  );
  test('scoped error rejects instead of enabling Stop', () async {
    final pending = repo.inspect(peer.remoteEpk, 'one');
    final assertion = expectLater(
      pending,
      throwsA(
        isA<SessionControlFailure>().having(
          (e) => e.message,
          'message',
          'Denied',
        ),
      ),
    );
    await settle();
    final id = (channel.sent.last as SessionControlStatus).id;
    channel.messages.add(
      ScopedPeerError(
        ErrorMessage(inReplyTo: id, code: 'invalid_message', message: 'Denied'),
        peer: peer.remoteEpk,
        room: 'one',
      ),
    );
    await assertion;
  });
  test(
    'selection switch and return does not revive old confirmation',
    () async {
      final capability = await inspect();
      final before = channel.sent.length;
      conn.switchRoom('other');
      conn.switchRoom('one');
      await expectLater(
        repo.stop(capability),
        throwsA(isA<SessionControlFailure>()),
      );
      expect(channel.sent.length, before);
    },
  );
  test('disconnect cannot redirect confirmation to a new channel', () async {
    final capability = await inspect();
    final before = channel.sent.length;
    await conn.disconnect();
    await expectLater(
      repo.stop(capability),
      throwsA(isA<SessionControlFailure>()),
    );
    expect(channel.sent.length, before);
  });
  test(
    'unsupported capability has no confirmation token or stop send',
    () async {
      final pending = repo.inspect(peer.remoteEpk, 'one');
      await settle();
      final id = (channel.sent.last as SessionControlStatus).id;
      channel.messages.add(
        SessionControlStatusResult(id, 'one', false, null, 'Update host.'),
      );
      final capability = await pending;
      expect(capability.canStop, isFalse);
      final before = channel.sent.length;
      await expectLater(
        repo.stop(capability),
        throwsA(isA<SessionControlFailure>()),
      );
      expect(channel.sent.length, before);
    },
  );
  test(
    'lost stop result is unknown and cannot be automatically retried',
    () async {
      final capability = await inspect();
      await expectLater(
        repo.stop(capability),
        throwsA(
          isA<SessionControlFailure>().having(
            (e) => e.outcomeUnknown,
            'unknown',
            true,
          ),
        ),
      );
      final before = channel.sent.length;
      await expectLater(
        repo.stop(capability),
        throwsA(isA<SessionControlFailure>()),
      );
      expect(channel.sent.length, before);
    },
  );
  test('closing controls cancels in-flight status', () async {
    final pending = repo.inspect(peer.remoteEpk, 'one');
    final assertion = expectLater(
      pending,
      throwsA(isA<SessionControlFailure>()),
    );
    await settle();
    repo.dispose();
    await assertion;
  });
}
