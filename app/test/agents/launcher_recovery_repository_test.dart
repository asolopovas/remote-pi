import 'package:app/domain/contracts/agent_repository.dart';
import 'agents_viewmodel_test.dart' show agent;
import 'package:app/data/agents/agent_repository_impl.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/ui/agents/viewmodels/agents_viewmodel.dart';
import 'package:app/protocol/protocol.dart';
import 'dart:async';
import 'package:app/data/agents/launcher_recovery_repository_impl.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/contracts/session_control_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'session_control_repository_test.dart' as f;

class Controls extends SessionControlRepository {
  LaunchingHost? origin = const LaunchingHost('parent', 'launcher-parent');
  final inspections = <(String, String)>[];
  bool permitted = false;
  Completer<void>? pending;
  int stops = 0;
  @override
  Future<SessionStopCapability> inspect(String peer, String room) async {
    inspections.add((peer, room));
    if (pending != null) await pending!.future;
    return SessionStopCapability(
      peer: peer,
      room: room,
      canStop: permitted,
      token: permitted ? 'fresh-${inspections.length}' : null,
      launchingHost: origin,
    );
  }

  @override
  Future<SessionStopOutcome> stop(SessionStopCapability capability) async {
    ++stops;
    return SessionStopOutcome.stopped;
  }

  @override
  void dispose() {}
}

class ParkedStorage extends f.Storage {
  final entered = Completer<void>();
  final release = Completer<List<PeerRecord>>();
  @override
  Future<List<PeerRecord>> listPeers() {
    entered.complete();
    return release.future;
  }
}

void main() {
  late f.Channel channel;
  late ConnectionManager conn;
  late Controls controls;
  late LauncherRecoveryRepositoryImpl recovery;
  setUp(() async {
    channel = f.Channel();
    conn = ConnectionManager(
      factory: (_, _) async => channel,
      storage: f.Storage(),
      emitDebounce: Duration.zero,
    );
    await conn.connectTo(f.peer);
    for (final room in ['one', 'parent', 'other-root']) {
      channel.controls.add(
        RoomAnnounced(peer: f.peer.remoteEpk, roomId: room, startedAt: 1),
      );
    }
    await f.settle();
    controls = Controls();
    recovery = LauncherRecoveryRepositoryImpl(conn, f.Storage(), controls);
  });
  tearDown(() async {
    recovery.dispose();
    await conn.disconnect();
    conn.dispose();
  });
  test(
    'authoritative exact parent then exact child with a fresh read-only inspect; no Stop',
    () async {
      final host = await recovery.resolve(f.peer.remoteEpk, 'one');
      expect(host!.roomId, 'parent');
      await recovery.selectParent(host.roomId);
      expect(conn.activeRoomId, 'parent');
      controls.permitted = true;
      final status = await recovery.returnToChild();
      expect(conn.activeRoomId, 'one');
      expect(status.canStop, isTrue);
      expect(status.token, 'fresh-2');
      expect(controls.inspections, [
        (f.peer.remoteEpk, 'one'),
        (f.peer.remoteEpk, 'one'),
      ]);
      expect(controls.stops, 0);
      expect(channel.sent.whereType<SessionStop>(), isEmpty);
    },
  );
  test(
    'unknown legacy origin never auto-guesses or auto-switches; explicit same-peer choice',
    () async {
      controls.origin = null;
      expect(await recovery.resolve(f.peer.remoteEpk, 'one'), isNull);
      expect(conn.activeRoomId, 'one');
      expect(
        recovery.choices.map((c) => c.room),
        containsAll(['parent', 'other-root']),
      );
      expect(conn.activeRoomId, 'one');
      await recovery.selectParent('other-root');
      final status = await recovery.returnToChild();
      expect(
        status.canStop,
        isFalse,
      ); // Wrong-host unlock cannot claim child access.
      expect(status.token, isNull);
      expect(conn.activeRoomId, 'one');
      expect(controls.stops, 0);
    },
  );
  test(
    'authoritative parent missing fails without switching to another root',
    () async {
      controls.origin = const LaunchingHost('not-live', 'missing');
      final host = await recovery.resolve(f.peer.remoteEpk, 'one');
      await expectLater(
        recovery.selectParent(host!.roomId),
        throwsA(isA<SessionControlFailure>()),
      );
      expect(conn.activeRoomId, 'one');
    },
  );
  test(
    'changed manual candidate incarnation fails before selecting it',
    () async {
      controls.origin = null;
      await recovery.resolve(f.peer.remoteEpk, 'one');
      expect(recovery.choices, isNotEmpty);
      channel.controls.add(
        RoomAnnounced(peer: f.peer.remoteEpk, roomId: 'parent', startedAt: 2),
      );
      await f.settle();
      await expectLater(
        recovery.selectParent('parent'),
        throwsA(isA<SessionControlFailure>()),
      );
      expect(conn.activeRoomId, 'one');
    },
  );
  test(
    'parent or child changed after selection cannot return or reuse previous token',
    () async {
      await recovery.resolve(f.peer.remoteEpk, 'one');
      await recovery.selectParent('parent');
      channel.controls.add(
        RoomAnnounced(peer: f.peer.remoteEpk, roomId: 'one', startedAt: 2),
      );
      await f.settle();
      await expectLater(
        recovery.returnToChild(),
        throwsA(isA<SessionControlFailure>()),
      );
      expect(conn.activeRoomId, 'parent');
      expect(controls.inspections.length, 1);
      expect(controls.stops, 0);
    },
  );
  test(
    'external target change, background invalidation and disconnect never silently renew lease',
    () async {
      await recovery.resolve(f.peer.remoteEpk, 'one');
      await recovery.selectParent('parent');
      recovery.invalidate();
      await expectLater(
        recovery.returnToChild(),
        throwsA(isA<SessionControlFailure>()),
      );
      expect(controls.inspections.length, 1);
    },
  );
  test(
    'late child inspect rejected after current selection authority changes',
    () async {
      await recovery.resolve(f.peer.remoteEpk, 'one');
      await recovery.selectParent('parent');
      controls.pending = Completer<void>();
      final pending = recovery.returnToChild();
      final assertion = expectLater(
        pending,
        throwsA(isA<SessionControlFailure>()),
      );
      await f.settle();
      conn.switchRoom('other-root');
      controls.pending!.complete();
      await assertion;
      expect(conn.activeRoomId, 'other-root');
    },
  );
  for (final change in [
    'selection',
    'epoch',
    'channel',
    'parent incarnation',
    'invalidate',
    'dispose',
  ]) {
    test(
      'parked recovery bind rejects $change without hopping back or leasing',
      () async {
        final storage = ParkedStorage();
        final agents = AgentRepositoryImpl(
          conn,
          storage,
          AgentMutationJournal(),
          Preferences(),
          timeout: const Duration(milliseconds: 10),
        );
        final vm = AgentsViewModel(agents, recovery: recovery);
        final pending = vm.resolveHost(
          f.peer.remoteEpk,
          'one',
          returnToChild: true,
        );
        await storage.entered.future;
        expect(conn.activeRoomId, 'parent');
        switch (change) {
          case 'selection':
            conn.switchRoom('other-root');
          case 'epoch':
            conn.switchRoom('other-root');
            conn.switchRoom('parent');
          case 'channel':
            conn.adopt(f.Channel(), f.peer.copyWith(roomId: 'other-root'));
          case 'parent incarnation':
            channel.controls.add(
              RoomAnnounced(
                peer: f.peer.remoteEpk,
                roomId: 'parent',
                startedAt: 2,
              ),
            );
          case 'invalidate':
            recovery.invalidate();
          case 'dispose':
            vm.dispose();
        }
        await f.settle();
        if (change != 'dispose') expect(vm.state.invalid, isTrue);
        final target = conn.activeRoomId;
        storage.release.complete([f.peer]);
        await pending;
        expect(conn.activeRoomId, target);
        expect(channel.sent.whereType<LauncherRequest>(), isEmpty);
        expect(agents.launcherStatus, isNull);
        if (change != 'dispose') {
          expect(vm.state.invalid, isTrue);
          await vm.initializePin('654321');
          await vm.unlock('654321');
          await vm.lock(shutdown: true);
          await vm.launch('project', null, confirmed: true);
          await vm.stop('agent', confirmed: true);
          await vm.refresh();
          expect(await vm.openAgent(agent), isFalse);
          expect(await vm.cancelRecovery(), isFalse);
          expect(await vm.finishRecovery(), isNull);
          expect(conn.activeRoomId, target);
          expect(channel.sent.whereType<LauncherRequest>(), isEmpty);
          vm.dispose();
        }
      },
    );
  }
  test(
    'same parent stays valid; a new explicit flow can bind after an old invalidation',
    () async {
      await recovery.resolve(f.peer.remoteEpk, 'one');
      await recovery.selectParent('parent');
      final old = recovery;
      old.invalidate();
      // No automatic return: only a newly opened explicit flow gets new authority.
      recovery = LauncherRecoveryRepositoryImpl(conn, f.Storage(), controls);
      await recovery.resolve(f.peer.remoteEpk, 'parent');
      await recovery.selectParent('parent');
      final epoch = conn.roomSelectionEpoch;
      final storage = ParkedStorage();
      final repo = AgentRepositoryImpl(
        conn,
        storage,
        AgentMutationJournal(),
        Preferences(),
      );
      bool current() {
        recovery.checkCurrent();
        return true;
      }

      final pending = repo.bind(f.peer.remoteEpk, 'parent', isCurrent: current);
      await storage.entered.future;
      conn.switchRoom('parent'); // A no-op selection is not a new epoch.
      storage.release.complete([f.peer]);
      await pending;
      expect(conn.roomSelectionEpoch, epoch);
      final status = repo.status();
      final request = channel.sent.last as LauncherRequest;
      channel.messages.add(
        LauncherStatusResult(
          'launcher_status_result',
          request.id,
          const LauncherStatus(
            launcherId: 'launcher-parent',
            epoch: 'fresh',
            configured: true,
            unlocked: false,
            expiresAt: null,
            cooldownUntil: 0,
          ),
          null,
        ),
      );
      await status;
      expect(repo.launcherStatus?.launcherId, 'launcher-parent');
      expect(conn.activeRoomId, 'parent');
      repo.dispose();
      old.dispose();
    },
  );
}
