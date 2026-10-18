import 'package:app/pairing/storage.dart';
import 'dart:async';
import 'package:app/data/agents/fresh_launcher_repository_impl.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/contracts/agent_repository.dart';
import 'package:app/domain/contracts/fresh_launcher_repository.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'session_control_repository_test.dart' as f;

LauncherStatus status(
  String id, {
  bool capable = true,
  bool configured = true,
  int api = 3,
}) => LauncherStatus(
  launcherId: id,
  epoch: 'epoch',
  configured: configured,
  unlocked: false,
  expiresAt: null,
  cooldownUntil: 0,
  launcherApi: capable ? api : null,
  pinSetup: configured ? PinSetup.configured : PinSetup.available,
);
typedef Reply = ({String peer, String room, LauncherStatus status});

class ProbeChannel extends f.Channel implements IRoomLauncherProbe {
  final probes = <String>[];
  final waiting = <Completer<Reply?>>[];
  final requested = StreamController<String>.broadcast();
  ConnectionManager? conn;
  final selectedDuringProbes = <String>[];
  @override
  Future<Reply?> probeLauncher(String room) {
    probes.add(room);
    selectedDuringProbes.add(conn!.activeRoomId);
    final c = Completer<Reply?>();
    waiting.add(c);
    requested.add(room);
    return c.future;
  }

  void reply(
    String room, {
    String? id,
    bool capable = true,
    String? peer,
    int api = 3,
  }) => waiting.removeAt(0).complete((
    peer: peer ?? f.peer.remoteEpk,
    room: room,
    status: status(id ?? room, capable: capable, api: api),
  ));
  @override
  void cancelLauncherProbes() {
    for (final c in waiting) {
      c.complete(null);
    }
    waiting.clear();
  }

  @override
  Future<void> close() async {
    cancelLauncherProbes();
    await requested.close();
    await super.close();
  }
}

class GuardedStorage extends f.Storage {
  Completer<List<PeerRecord>>? parked;
  int revision = 0;
  List<PeerRecord> records = [f.peer];
  @override
  int get peerRevision => revision;
  @override
  Future<List<PeerRecord>> listPeers() =>
      parked?.future ?? Future.value(records);
  void revoke() {
    revision++;
    notifyListeners();
  }
}

class ClosingChannel extends f.Channel {
  final closing = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> close() async {
    if (!closing.isCompleted) {
      closing.complete();
      await release.future;
    }
    await super.close();
  }
}

void main() {
  late ProbeChannel ch;
  late ConnectionManager conn;
  late GuardedStorage storage;
  late FreshLauncherRepositoryImpl repo;
  setUp(() async {
    storage = GuardedStorage();
    ch = ProbeChannel();
    conn = ConnectionManager(
      factory: (_, _) async => ch,
      storage: storage,
      emitDebounce: Duration.zero,
    );
    ch.conn = conn;
    await conn.connectTo(f.peer);
    for (final room in ['one', 'root-a', 'root-b']) {
      ch.controls.add(
        RoomAnnounced(peer: f.peer.remoteEpk, roomId: room, startedAt: 1),
      );
    }
    await f.settle();
    repo = FreshLauncherRepositoryImpl(conn, storage);
  });
  tearDown(() async {
    repo.dispose();
    await conn.disconnect();
    conn.dispose();
  });
  test(
    'child preference is not a launcher; deterministic root validated twice without scan selection changes',
    () async {
      final pending = repo.resolve(f.peer.remoteEpk, preferredRoom: 'one');
      await f.settle();
      expect(ch.probes, ['one']);
      ch.reply('one', capable: false);
      await f.settle();
      expect(ch.probes, ['one', 'root-a']);
      expect(conn.activeRoomId, 'one');
      ch.reply('root-a');
      await f.settle();
      expect(conn.activeRoomId, 'root-a');
      expect(ch.probes.last, 'root-a');
      ch.reply('root-a');
      final endpoint = await pending;
      expect(endpoint.room, 'root-a');
      expect(endpoint.launcherId, 'root-a');
      expect(ch.selectedDuringProbes, ['one', 'one', 'root-a']);
      expect(ch.sent.whereType<LauncherRequest>(), isEmpty);
      repo.checkCurrent();
    },
  );
  test('API 2 preference skipped for API 3 on the same machine', () async {
    final pending = repo.resolve(f.peer.remoteEpk, preferredRoom: 'root-a');
    await f.settle();
    ch.reply('root-a', api: 2);
    await f.settle();
    ch.reply('one', capable: false);
    await f.settle();
    expect(conn.activeRoomId, 'one');
    ch.reply('root-b', api: 3);
    await f.settle();
    ch.reply('root-b', api: 3);
    expect((await pending).room, 'root-b');
    expect(ch.probes, ['root-a', 'one', 'root-b', 'root-b']);
    expect(ch.sent.whereType<LauncherRequest>(), isEmpty);
  });
  test('only API 2 and explicit old session never bind or Start', () async {
    final pending = repo.resolve(f.peer.remoteEpk);
    final failed = expectLater(
      pending,
      throwsA(
        isA<FreshLauncherUnavailable>().having(
          (e) => e.message,
          'actionable',
          contains('after running jobs finish'),
        ),
      ),
    );
    for (final room in ['one', 'root-a', 'root-b']) {
      await f.settle();
      ch.reply(room, api: 2);
    }
    await failed;
    final selected = repo.selectSession('root-b');
    final old = expectLater(selected, throwsA(isA<FreshLauncherUnavailable>()));
    await f.settle();
    ch.reply('root-b', api: 2);
    await old;
    expect(conn.activeRoomId, 'one');
    expect(ch.sent.whereType<LauncherRequest>(), isEmpty);
  });
  test('same launcher ID downgraded on recheck fails closed', () async {
    final pending = repo.resolve(f.peer.remoteEpk, preferredRoom: 'root-a');
    final failed = expectLater(pending, throwsA(isA<AgentFailure>()));
    await f.settle();
    ch.reply('root-a', api: 3);
    await f.settle();
    ch.reply('root-a', api: 2);
    await failed;
    expect(ch.probes, ['root-a', 'root-a']);
    expect(ch.sent.whereType<LauncherRequest>(), isEmpty);
  });
  test('explicit eligible root preferred over sorted alternatives', () async {
    final pending = repo.resolve(f.peer.remoteEpk, preferredRoom: 'root-b');
    await f.settle();
    ch.reply('root-b');
    await f.settle();
    ch.reply('root-b');
    expect((await pending).room, 'root-b');
    expect(ch.probes, ['root-b', 'root-b']);
  });
  for (final failure in [
    'selection',
    'room-restart',
    'disconnect',
    'dispose',
    'wrong-peer',
    'wrong-room',
    'launcher-replaced',
    'socket-replaced',
  ]) {
    test('fail closed: $failure; no fallback hop or mutation', () async {
      final pending = repo.resolve(f.peer.remoteEpk, preferredRoom: 'root-a');
      final failed = expectLater(pending, throwsA(isA<AgentFailure>()));
      await f.settle();
      switch (failure) {
        case 'selection':
          conn.switchRoom('root-b');
          ch.reply('root-a');
        case 'room-restart':
          ch.controls.add(
            RoomAnnounced(
              peer: f.peer.remoteEpk,
              roomId: 'root-a',
              startedAt: 2,
            ),
          );
          await f.settle();
        case 'socket-replaced':
          conn.adopt(f.Channel(), f.peer);
          await f.settle();
        case 'disconnect':
          await conn.disconnect();
        case 'dispose':
          repo.dispose();
        case 'wrong-peer':
          ch.reply('root-a', peer: 'wrong');
          await f.settle();
          repo.invalidate();
        case 'wrong-room':
          ch.reply('root-b');
          await f.settle();
          repo.invalidate();
        case 'launcher-replaced':
          ch.reply('root-a', id: 'first');
          await f.settle();
          ch.reply('root-a', id: 'replacement');
      }
      await failed;
      expect(ch.sent.whereType<LauncherRequest>(), isEmpty);
      if (failure != 'selection' && failure != 'launcher-replaced') {
        expect(conn.activeRoomId, 'one');
      }
    });
  }
  test(
    'unavailable scan stays in chat; advanced explicit session validates before bind',
    () async {
      final pending = repo.resolve(f.peer.remoteEpk);
      final unavailable = expectLater(
        pending,
        throwsA(isA<FreshLauncherUnavailable>()),
      );
      for (final room in ['one', 'root-a', 'root-b']) {
        await f.settle();
        ch.reply(room, capable: false);
      }
      await unavailable;
      expect(conn.activeRoomId, 'one');
      expect(repo.sessions.map((s) => s.room), ['one', 'root-a', 'root-b']);
      final selected = repo.selectSession('root-b');
      await f.settle();
      ch.reply('root-b');
      await f.settle();
      ch.reply('root-b');
      expect((await selected).room, 'root-b');
      await expectLater(
        () => repo.selectSession('root-a'),
        throwsA(isA<AgentFailure>()),
      );
      expect(conn.activeRoomId, 'root-b');
    },
  );
  for (final change in ['selection', 'pairing', 'dispose']) {
    test(
      'parked pairing lookup rejects $change before any probe or selection',
      () async {
        storage.parked = Completer<List<PeerRecord>>();
        final pending = repo.resolve(f.peer.remoteEpk);
        final failed = expectLater(pending, throwsA(isA<AgentFailure>()));
        switch (change) {
          case 'selection':
            conn.switchRoom('root-b');
          case 'pairing':
            storage.revoke();
          case 'dispose':
            repo.dispose();
        }
        storage.parked!.complete([f.peer]);
        await failed;
        expect(ch.probes, isEmpty);
        expect(ch.sent.whereType<LauncherRequest>(), isEmpty);
      },
    );
  }
  for (final changed in [false, true]) {
    test(
      'explicit other machine connection waits for fresh discovery; connect changed=$changed',
      () async {
        const other = PeerRecord(
          remoteEpk: 'AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=',
          sessionName: 'PC',
          relayUrl: 'https://unused',
          pairedAt: '2026-01-01',
          roomId: 'root',
        );
        final storage2 = GuardedStorage()..records = [f.peer, other];
        final old = f.Channel(), next = ProbeChannel();
        final entered = Completer<void>(), release = Completer<void>();
        final conn2 = ConnectionManager(
          factory: (p, _) async {
            if (p.remoteEpk == f.peer.remoteEpk) return old;
            entered.complete();
            await release.future;
            return next;
          },
          storage: storage2,
          emitDebounce: Duration.zero,
        );
        next.conn = conn2;
        await conn2.connectTo(f.peer);
        old.controls.add(
          RoomAnnounced(peer: other.remoteEpk, roomId: 'root', startedAt: 1),
        );
        await f.settle();
        final resolver = FreshLauncherRepositoryImpl(conn2, storage2);
        final pending = resolver.resolve(other.remoteEpk);
        final failed = changed
            ? expectLater(pending, throwsA(isA<AgentFailure>()))
            : null;
        await entered.future;
        expect(next.probes, isEmpty);
        if (changed) conn2.switchRoom('one');
        release.complete();
        await f.settle();
        if (changed) {
          await failed;
          expect(next.probes, isEmpty);
          expect(conn2.activeRoomId, 'one');
        } else {
          expect(
            next.probes,
            isEmpty,
          ); // No stale pre-connect presence authority.
          next.controls.add(
            RoomAnnounced(peer: other.remoteEpk, roomId: 'root', startedAt: 1),
          );
          await f.settle();
          next.reply('root', peer: other.remoteEpk);
          await f.settle();
          next.reply('root', peer: other.remoteEpk);
          expect((await pending).peer, other.remoteEpk);
        }
        resolver.dispose();
        await conn2.disconnect();
        conn2.dispose();
      },
    );
  }
  test(
    'guarded connection does not overwrite selection parked across old socket close',
    () async {
      const other = PeerRecord(
        remoteEpk: 'AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=',
        sessionName: 'PC',
        relayUrl: 'https://unused',
        pairedAt: '2026-01-01',
        roomId: 'root',
      );
      final storage2 = GuardedStorage()..records = [f.peer, other];
      final old = ClosingChannel();
      int newConnections = 0;
      final conn2 = ConnectionManager(
        factory: (p, _) async {
          if (p.remoteEpk != f.peer.remoteEpk) newConnections++;
          return old;
        },
        storage: storage2,
        emitDebounce: Duration.zero,
      );
      await conn2.connectTo(f.peer);
      old.controls.add(
        RoomAnnounced(peer: other.remoteEpk, roomId: 'root', startedAt: 1),
      );
      await f.settle();
      final resolver = FreshLauncherRepositoryImpl(conn2, storage2);
      final pending = resolver.resolve(other.remoteEpk);
      final failed = expectLater(pending, throwsA(isA<AgentFailure>()));
      await old.closing.future;
      conn2.switchRoom('user-choice');
      old.release.complete();
      await failed;
      expect(newConnections, 0);
      expect(conn2.activeRoomId, 'user-choice');
      resolver.dispose();
      await conn2.disconnect();
      conn2.dispose();
    },
  );
  test(
    'eligibility includes PIN setup but not an old status without launcher API',
    () {
      expect(launcherEligible(status('setup', configured: false)), isTrue);
      expect(launcherEligible(status('old', capable: false)), isFalse);
      expect(launcherEligible(status('api2', api: 2)), isFalse);
    },
  );
}
