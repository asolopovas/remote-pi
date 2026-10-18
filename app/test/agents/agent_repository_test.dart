import 'package:app/data/preferences/preferences.dart';
import 'dart:async';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'dart:io';
import 'package:app/data/agents/agent_repository_impl.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/contracts/agent_repository.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

const peer = PeerRecord(
  remoteEpk: 'paired-host',
  sessionName: 'Host',
  relayUrl: 'ws://unused',
  pairedAt: '2026-01-01',
);

class TestPreferences extends Preferences {
  String? peer, room;
  bool fail = false;
  @override
  Future<void> setSelectedRoom({String? epk, String? roomId}) async {
    if (fail) throw PlatformException(code: 'storage-unavailable');
    peer = epk;
    room = roomId;
  }
}

class Storage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => [peer];
}

class Channel implements IChannel {
  final messages = StreamController<ServerMessage>.broadcast();
  final sent = <ClientMessage>[];
  @override
  Stream<ServerMessage> get serverMessages => messages.stream;
  @override
  Future<void> send(ClientMessage message) async {
    sent.add(message);
  }

  @override
  Future<void> close() async {}
}

class Connection extends ConnectionManager {
  Connection(this.current)
    : super(factory: (_, _) async => current!, storage: Storage());
  IChannel? current;
  String room = 'launcher';
  Set<String>? liveRooms;
  int epoch = 0;
  PeerRecord selected = peer;
  final statuses = StreamController<ConnectionStatus>.broadcast();
  final rooms = StreamController<Map<String, List<RoomInfo>>>.broadcast();
  @override
  int get roomSelectionEpoch => epoch;
  @override
  IChannel? get channel => current;
  @override
  ConnectionStatus get status =>
      current == null ? const StatusNoPeer() : StatusOnline(current!);
  @override
  Stream<ConnectionStatus> get statusStream => statuses.stream;
  @override
  Stream<Map<String, List<RoomInfo>>> get roomsStream => rooms.stream;
  @override
  PeerRecord get activePeer => selected;
  @override
  String get activeRoomId => room;
  @override
  bool isRoomLive(String epk, String roomId) =>
      current != null && (liveRooms == null || liveRooms!.contains(roomId));
  @override
  Future<void> switchTo(PeerRecord p) async {
    selected = p;
  }

  @override
  void switchRoom(String r) {
    epoch++;
    room = r;
    rooms.add({});
  }

  @override
  void refreshDiscovery() {}
}

const available = AgentAvailability(
  available: true,
  launcherId: 'launcher-1',
  cwd: '/project',
  maxAgents: 4,
  agents: [],
);
const managed = ManagedAgent(
  agentId: 'agent',
  name: 'Agent',
  cwd: '/project',
  roomId: 'agent-room',
  state: 'running',
);
LauncherStatus security({
  bool unlocked = true,
  bool configured = true,
  String epoch = 'epoch-1',
  int? expiry,
  int cooldown = 0,
  int? api = 3,
}) => LauncherStatus(
  launcherId: 'launcher-1',
  launcherApi: api,
  epoch: epoch,
  configured: configured,
  unlocked: unlocked,
  expiresAt: unlocked
      ? expiry ?? DateTime.now().millisecondsSinceEpoch + 600000
      : null,
  cooldownUntil: cooldown,
);
Future<void> tick() => Future<void>.delayed(Duration.zero);
void main() {
  test('input boundaries match shared host validation fixture', () {
    final cases =
        jsonDecode(
              File(
                'test/protocol/fixtures/agent_input_validation.json',
              ).readAsStringSync(),
            )
            as List;
    for (final input in cases.cast<Map<String, dynamic>>()) {
      expect(
        validateAgentInput(input['cwd'] as String, input['name'] as String?) ==
            null,
        input['valid'],
      );
    }
  });
  test('legacy producer agent replies remain parseable', () {
    final fixture =
        jsonDecode(
              File(
                'test/protocol/fixtures/agent_management.json',
              ).readAsStringSync(),
            )
            as Map;
    final replies = (fixture['replies'] as List)
        .map((r) => ServerMessage.fromJson(Map<String, dynamic>.from(r as Map)))
        .toList();
    expect((replies[0] as AgentListResult).availability.cwd, '/projects/pi');
    expect((replies[1] as AgentListResult).availability.available, false);
    expect((replies[2] as AgentMutationResult).agent.roomId, 'room-agent-1');
    expect((replies[3] as AgentMutationResult).agent.state, 'stopped');
    expect((replies[4] as ErrorMessage).inReplyTo, 'launch-2');
  });
  group('PIN-protected pinned repository', () {
    late Channel channel;
    late Connection conn;
    late AgentRepositoryImpl repo;
    late AgentMutationJournal journal;
    late TestPreferences preferences;
    Future<void> replyStatus(LauncherStatus value) async {
      final request = channel.sent.last as LauncherRequest;
      channel.messages.add(
        LauncherStatusResult('launcher_status_result', request.id, value, null),
      );
      await tick();
    }

    Future<void> refresh({LauncherStatus? value}) async {
      final pending = repo.list();
      await replyStatus(value ?? security());
      final projectRequest = channel.sent.last as LauncherRequest;
      expect(projectRequest.type, 'project_list');
      channel.messages.add(
        ProjectListResult(projectRequest.id, const [
          LauncherProject('project', 'Project', '/project', [
            '/project',
            '/shared',
          ]),
        ]),
      );
      await tick();
      channel.messages.add(
        AgentListResult((channel.sent.last as AgentList).id, available),
      );
      await pending;
    }

    setUp(() async {
      channel = Channel();
      conn = Connection(channel);
      journal = AgentMutationJournal();
      preferences = TestPreferences();
      repo = AgentRepositoryImpl(
        conn,
        Storage(),
        journal,
        preferences,
        timeout: const Duration(milliseconds: 40),
        mutationTimeout: const Duration(milliseconds: 60),
      );
      await repo.bind(peer.remoteEpk, 'launcher');
    });
    tearDown(() async {
      repo.dispose();
      await tick();
      await channel.messages.close();
      await conn.statuses.close();
      await conn.rooms.close();
      conn.dispose();
    });
    test('delayed exact room discovery never selects another room', () async {
      await refresh();
      conn.liveRooms = {'launcher', 'unrelated'};
      final exact = ManagedAgent(
        agentId: 'new',
        name: 'New',
        cwd: '/project',
        roomId: 'exact-new-room',
        state: 'running',
      );
      var completed = false;
      final pending = repo.openAgent(exact).then((_) => completed = true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(completed, false);
      expect(conn.room, 'launcher');
      expect(preferences.room, null);
      conn.liveRooms!.add('exact-new-room');
      await pending;
      expect(conn.room, 'exact-new-room');
      expect(preferences.peer, peer.remoteEpk);
      expect(preferences.room, 'exact-new-room');
    });

    test(
      'undiscovered launched room fails without switching or replay',
      () async {
        await refresh();
        conn.liveRooms = {'launcher', 'unrelated'};
        await expectLater(
          repo.openAgent(
            const ManagedAgent(
              agentId: 'new',
              name: 'New',
              cwd: '/project',
              roomId: 'exact-new-room',
              state: 'running',
            ),
          ),
          throwsA(
            isA<AgentFailure>().having(
              (e) => e.message,
              'message',
              contains('do not start another'),
            ),
          ),
        );
        expect(conn.room, 'launcher');
        expect(preferences.room, null);
        expect(
          channel.sent.whereType<LauncherRequest>().where(
            (r) => r.type == 'project_launch',
          ),
          isEmpty,
        );
      },
    );

    test(
      'selection storage failure does not switch room or relaunch',
      () async {
        await refresh();
        preferences.fail = true;
        await expectLater(
          repo.openAgent(
            const ManagedAgent(
              agentId: 'new',
              name: 'New',
              cwd: '/project',
              roomId: 'new-room',
              state: 'running',
            ),
          ),
          throwsA(
            isA<AgentFailure>().having(
              (e) => e.message,
              'message',
              contains('do not start another'),
            ),
          ),
        );
        expect(conn.room, 'launcher');
        expect(
          channel.sent.whereType<LauncherRequest>().where(
            (r) => r.type == 'project_launch',
          ),
          isEmpty,
        );
      },
    );

    test('target change while connecting cannot hand off', () async {
      await refresh();
      conn.liveRooms = {'launcher'};
      final pending = repo.openAgent(
        const ManagedAgent(
          agentId: 'new',
          name: 'New',
          cwd: '/project',
          roomId: 'new-room',
          state: 'running',
        ),
      );
      final failed = expectLater(pending, throwsA(isA<AgentFailure>()));
      conn.switchRoom('other');
      conn.liveRooms!.add('new-room');
      await failed;
      expect(conn.room, 'other');
      expect(preferences.room, null);
    });

    const setup = LauncherStatus(
      launcherId: 'launcher-1',
      epoch: 'epoch-1',
      configured: false,
      unlocked: false,
      expiresAt: null,
      cooldownUntil: 0,
      pinSetup: PinSetup.available,
    );
    Future<void> setupStatus(LauncherStatus value) async {
      final pending = repo.status();
      await replyStatus(value);
      await pending;
    }

    test(
      'setup is create-only, strict PIN boundaries and never auto-unlocks',
      () async {
        await setupStatus(security(unlocked: false));
        await expectLater(
          repo.initializePin('123456'),
          throwsA(isA<AgentFailure>()),
        );
        await setupStatus(setup);
        for (final pin in ['12345', '1234567890123', 'abcdef', '12345 ']) {
          await expectLater(
            repo.initializePin(pin),
            throwsA(isA<AgentFailure>()),
          );
        }
        for (final pin in ['123456', '123456789012']) {
          final pending = repo.initializePin(pin);
          final request = channel.sent.last as LauncherRequest;
          expect(request.type, 'launcher_pin_initialize');
          expect(request.pin, pin);
          expect(request.status?.epoch, 'epoch-1');
          expect(repo.launcherStatus, null);
          await expectLater(
            repo.initializePin(pin),
            throwsA(isA<AgentFailure>()),
          );
          await replyStatus(security(epoch: 'setup-epoch', unlocked: false));
          await pending;
          expect(repo.launcherStatus?.permitsControl, false);
          expect(repo.projects, isEmpty);
          expect(repo.hasUnknownLaunch, false);
          await expectLater(
            repo.initializePin(pin),
            throwsA(isA<AgentFailure>()),
          );
          await setupStatus(setup);
        }
        expect(
          channel.sent.whereType<LauncherRequest>().where(
            (r) => r.type == 'launcher_unlock',
          ),
          isEmpty,
        );
      },
    );
    test('only current correlated setup result grants control', () async {
      await setupStatus(setup);
      final pending = repo.initializePin('123456');
      channel.messages.add(
        LauncherStatusResult(
          'launcher_status_result',
          'wrong-id',
          security(epoch: 'created'),
          null,
        ),
      );
      await tick();
      expect(repo.launcherStatus, null);
      await replyStatus(security(epoch: 'created'));
      await pending;
      expect(repo.launcherStatus?.permitsControl, true);
      expect(repo.projects, isEmpty);
      expect(
        channel.sent.whereType<LauncherRequest>().where(
          (r) => r.type == 'launcher_unlock',
        ),
        isEmpty,
      );
    });

    test('foreign launcher setup result stays unknown and locked', () async {
      await setupStatus(setup);
      final pending = repo.initializePin('123456');
      final failed = expectLater(
        pending,
        throwsA(
          isA<AgentFailure>().having((e) => e.outcomeUnknown, 'unknown', true),
        ),
      );
      await replyStatus(
        LauncherStatus(
          launcherId: 'different-launcher',
          epoch: 'created',
          configured: true,
          unlocked: true,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 60000,
          cooldownUntil: 0,
        ),
      );
      await failed;
      expect(repo.launcherStatus, null);
    });

    test(
      'lost setup response is unknown and refresh never replays PIN',
      () async {
        await setupStatus(setup);
        await expectLater(
          repo.initializePin('123456'),
          throwsA(
            isA<AgentFailure>().having(
              (e) => e.outcomeUnknown,
              'unknown',
              true,
            ),
          ),
        );
        expect(repo.launcherStatus, null);
        expect(repo.hasUnknownLaunch, false);
        await setupStatus(security(unlocked: false, epoch: 'configured'));
        expect(repo.launcherStatus?.permitsControl, false);
        expect(
          channel.sent.whereType<LauncherRequest>().where(
            (r) => r.type == 'launcher_pin_initialize',
          ),
          hasLength(1),
        );
        expect(
          channel.sent.whereType<LauncherRequest>().where(
            (r) => r.type == 'launcher_unlock',
          ),
          isEmpty,
        );
      },
    );
    test('setup disconnect outcome is unknown and revokes authority', () async {
      await setupStatus(setup);
      final pending = repo.initializePin('123456');
      final assertion = expectLater(
        pending,
        throwsA(
          isA<AgentFailure>().having((e) => e.outcomeUnknown, 'unknown', true),
        ),
      );
      conn.current = null;
      conn.statuses.add(const StatusNoPeer());
      await assertion;
      expect(repo.launcherStatus, null);
      expect(repo.hasUnknownLaunch, false);
    });
    for (final api in <int?>[null, 1, 2]) {
      test(
        'API $api denies new Start without send but retains exact Stop',
        () async {
          await refresh(value: security(api: api));
          final sent = channel.sent.length;
          await expectLater(
            repo.launch('project', null),
            throwsA(
              isA<AgentFailure>().having(
                (e) => e.message,
                'compatibility',
                contains('launcher API 3'),
              ),
            ),
          );
          expect(channel.sent.length, sent);
          expect(repo.hasUnknownLaunch, isFalse);
          final stopping = repo.stop('agent');
          await tick();
          final request = channel.sent.last as LauncherRequest;
          expect(request.type, 'launcher_agent_stop');
          channel.messages.add(
            AgentMutationResult(
              'agent_stop_result',
              request.id,
              const ManagedAgent(
                agentId: 'agent',
                name: 'Agent',
                cwd: '/project',
                roomId: 'agent-room',
                state: 'stopped',
              ),
            ),
          );
          expect((await stopping).state, 'stopped');
        },
      );
    }
    test('locked setup gates project list and arbitrary cwd launch', () async {
      final pending = repo.list();
      final assertion = expectLater(pending, throwsA(isA<AgentFailure>()));
      await replyStatus(security(unlocked: false));
      await assertion;
      expect(channel.sent.length, 1);
      await expectLater(
        repo.launch('/unregistered', null),
        throwsA(isA<AgentFailure>()),
      );
      await refresh();
      await expectLater(
        repo.launch('/project', null),
        throwsA(isA<AgentFailure>()),
      );
      expect(channel.sent.whereType<AgentLaunch>(), isEmpty);
    });
    test('setup missing, invalid PIN and cooldown never send unlock', () async {
      final status = repo.status();
      await replyStatus(security(configured: false, unlocked: false));
      await status;
      await expectLater(repo.unlock('123456'), throwsA(isA<AgentFailure>()));
      final status2 = repo.status();
      await replyStatus(
        security(
          unlocked: false,
          cooldown: DateTime.now().millisecondsSinceEpoch + 600000,
        ),
      );
      await status2;
      await expectLater(repo.unlock('123456'), throwsA(isA<AgentFailure>()));
      await expectLater(repo.unlock('bad'), throwsA(isA<AgentFailure>()));
      expect(
        channel.sent.whereType<LauncherRequest>().where(
          (r) => r.type == 'launcher_unlock',
        ),
        isEmpty,
      );
    });
    test(
      'wrong PIN error is correlated, no PIN journal or automatic replay',
      () async {
        final status = repo.status();
        await replyStatus(security(unlocked: false));
        await status;
        final unlock = repo.unlock('123456');
        final assertion = expectLater(
          unlock,
          throwsA(
            isA<AgentFailure>().having(
              (e) => e.message,
              'message',
              'Wrong PIN',
            ),
          ),
        );
        final request = channel.sent.last as LauncherRequest;
        channel.messages.add(
          ScopedPeerError(
            ErrorMessage(
              inReplyTo: request.id,
              code: 'invalid_message',
              message: 'Wrong PIN',
            ),
            peer: peer.remoteEpk,
            room: 'launcher',
          ),
        );
        await assertion;
        expect(repo.launcherStatus, null);
        await refresh();
        expect(
          channel.sent
              .whereType<LauncherRequest>()
              .where((r) => r.type == 'launcher_unlock')
              .length,
          1,
        );
        expect(repo.hasUnknownLaunch, false);
      },
    );
    test(
      'unsupported timeout bounded and explicitly recommends update',
      () async {
        await expectLater(
          repo.status(),
          throwsA(
            isA<AgentFailure>().having(
              (e) => e.message,
              'message',
              'Host update required.',
            ),
          ),
        );
        expect(repo.launcherStatus, null);
      },
    );
    test(
      'lost unlock reply stays locally locked, refresh never resubmits PIN',
      () async {
        final status = repo.status();
        await replyStatus(security(unlocked: false));
        await status;
        await expectLater(repo.unlock('123456'), throwsA(isA<AgentFailure>()));
        expect(repo.launcherStatus, null);
        final next = repo.status();
        await replyStatus(security(unlocked: false));
        await next;
        expect(
          channel.sent
              .whereType<LauncherRequest>()
              .where((r) => r.type == 'launcher_unlock')
              .length,
          1,
        );
      },
    );
    test(
      'uncertain launch requires fresh read and explicit duplicate-risk acknowledgement, new ID',
      () async {
        await refresh();
        await expectLater(
          repo.launch('project', 'Original'),
          throwsA(
            isA<AgentFailure>().having(
              (e) => e.outcomeUnknown,
              'unknown',
              true,
            ),
          ),
        );
        final original = channel.sent.last as LauncherRequest;
        expect(repo.hasUnknownLaunch, true);
        await expectLater(
          repo.launch('project', null, acknowledgeUnknown: true),
          throwsA(isA<AgentFailure>()),
        );
        await refresh();
        expect(
          channel.sent
              .whereType<LauncherRequest>()
              .where((r) => r.type == 'project_launch')
              .length,
          1,
        );
        await expectLater(
          repo.launch('project', null),
          throwsA(isA<AgentFailure>()),
        );
        final second = repo.launch(
          'project',
          'Second',
          acknowledgeUnknown: true,
        );
        final next = channel.sent.last as LauncherRequest;
        expect(next.id, isNot(original.id));
        channel.messages.add(
          AgentMutationResult('agent_launch_result', next.id, managed),
        );
        await second;
        expect(repo.hasUnknownLaunch, true);
        channel.messages.add(
          AgentMutationResult('agent_stop_result', original.id, managed),
        );
        await tick();
        expect(repo.hasUnknownLaunch, true);
        channel.messages.add(
          AgentMutationResult('agent_launch_result', original.id, managed),
        );
        await tick();
        expect(repo.hasUnknownLaunch, false);
      },
    );
    test(
      'global capacity includes historical attempts across targets',
      () async {
        for (var i = 0; i < 32; i++) {
          repo.dispose();
          repo = AgentRepositoryImpl(
            conn,
            Storage(),
            journal,
            Preferences(),
            timeout: const Duration(milliseconds: 100),
            mutationTimeout: const Duration(milliseconds: 1),
          );
          await repo.bind(peer.remoteEpk, 'target-$i');
          await refresh();
          await expectLater(
            repo.launch('project', null),
            throwsA(isA<AgentFailure>()),
          );
          await refresh();
          if (i < 31) {
            final replacement = repo.launch(
              'project',
              null,
              acknowledgeUnknown: true,
            );
            channel.messages.add(
              AgentMutationResult(
                'agent_launch_result',
                (channel.sent.last as LauncherRequest).id,
                managed,
              ),
            );
            await replacement;
            expect(repo.hasUnknownLaunch, true);
          } else {
            final count = channel.sent.length;
            await expectLater(
              repo.launch('project', null, acknowledgeUnknown: true),
              throwsA(isA<AgentFailure>()),
            );
            expect(channel.sent.length, count);
          }
        }
        // The first historical outcome was not silently evicted.
        repo.dispose();
        repo = AgentRepositoryImpl(conn, Storage(), journal, Preferences());
        await repo.bind(peer.remoteEpk, 'target-0');
        await refresh();
        expect(repo.hasUnknownLaunch, true);
        await expectLater(
          repo.launch('project', null),
          throwsA(isA<AgentFailure>()),
        );
      },
    );

    test(
      'authoritative incarnation reconciliation retires history without replay',
      () async {
        for (var i = 0; i < 32; i++) {
          await refresh();
          await expectLater(
            repo.launch('project', null, acknowledgeUnknown: i > 0),
            throwsA(isA<AgentFailure>()),
          );
        }
        final sent = channel.sent
            .whereType<LauncherRequest>()
            .where((r) => r.type == 'project_launch')
            .length;
        await refresh(value: security(epoch: 'epoch-2'));
        expect(repo.hasUnknownLaunch, false);
        expect(
          channel.sent
              .whereType<LauncherRequest>()
              .where((r) => r.type == 'project_launch')
              .length,
          sent,
        );
        final next = repo.launch('project', null);
        channel.messages.add(
          AgentMutationResult(
            'agent_launch_result',
            (channel.sent.last as LauncherRequest).id,
            managed,
          ),
        );
        await next;
        // Old-incarnation late replies cannot restore authority or old warnings.
        final read = repo.status();
        expect(repo.launcherStatus, null);
        channel.messages.add(
          AgentMutationResult(
            'agent_launch_result',
            channel.sent
                .whereType<LauncherRequest>()
                .firstWhere((r) => r.type == 'project_launch')
                .id,
            managed,
          ),
        );
        await tick();
        expect(repo.launcherStatus, null);
        await replyStatus(security(epoch: 'epoch-2'));
        await read;
        await refresh(value: security(epoch: 'epoch-1'));
        expect(repo.hasUnknownLaunch, false);
      },
    );

    test(
      'settled historical attempts free global capacity across many targets',
      () async {
        for (var i = 0; i < 40; i++) {
          repo.dispose();
          repo = AgentRepositoryImpl(
            conn,
            Storage(),
            journal,
            Preferences(),
            mutationTimeout: const Duration(milliseconds: 1),
          );
          await repo.bind(peer.remoteEpk, 'settled-$i');
          await refresh();
          await expectLater(
            repo.launch('project', null),
            throwsA(isA<AgentFailure>()),
          );
          final original = channel.sent.last as LauncherRequest;
          await refresh();
          final replacement = repo.launch(
            'project',
            null,
            acknowledgeUnknown: true,
          );
          channel.messages.add(
            AgentMutationResult(
              'agent_launch_result',
              (channel.sent.last as LauncherRequest).id,
              managed,
            ),
          );
          await replacement;
          channel.messages.add(
            ScopedPeerError(
              ErrorMessage(
                inReplyTo: original.id,
                code: 'failed',
                message: 'late',
              ),
              peer: peer.remoteEpk,
              room: 'settled-$i',
            ),
          );
          await tick();
          expect(repo.hasUnknownLaunch, false);
        }
      },
    );

    test('expiry immediately revokes authority and project cache', () async {
      await refresh(
        value: security(expiry: DateTime.now().millisecondsSinceEpoch + 100),
      );
      await Future<void>.delayed(const Duration(milliseconds: 110));
      expect(repo.launcherStatus, null);
      expect(repo.projects, isEmpty);
      await expectLater(
        repo.launch('project', null),
        throwsA(isA<AgentFailure>()),
      );
    });
    for (final change in [
      'disconnect',
      'room',
      'away-back',
      'channel',
      'host',
    ]) {
      test('$change cannot revive lease or accept a stale reply', () async {
        await refresh();
        final pending = repo.status();
        final assertion = expectLater(pending, throwsA(isA<AgentFailure>()));
        final request = channel.sent.last as LauncherRequest;
        switch (change) {
          case 'disconnect':
            conn.current = null;
            conn.statuses.add(const StatusNoPeer());
          case 'room':
            conn.switchRoom('other');
          case 'away-back':
            conn.switchRoom('other');
            conn.switchRoom('launcher');
          case 'channel':
            conn.current = Channel();
            conn.statuses.add(StatusOnline(conn.current!));
          case 'host':
            conn.selected = const PeerRecord(
              remoteEpk: 'different',
              sessionName: 'Other',
              relayUrl: 'ws://unused',
              pairedAt: '2026-01-01',
            );
            conn.statuses.add(StatusOnline(channel));
        }
        channel.messages.add(
          LauncherStatusResult(
            'launcher_status_result',
            request.id,
            security(),
            null,
          ),
        );
        await assertion;
        expect(repo.launcherStatus, null);
        await expectLater(
          repo.launch('project', null),
          throwsA(isA<AgentFailure>()),
        );
      });
    }
    test('reopen and new incarnation never replay uncertain launch', () async {
      await refresh();
      await expectLater(
        repo.launch('project', null),
        throwsA(isA<AgentFailure>()),
      );
      repo.dispose();
      repo = AgentRepositoryImpl(
        conn,
        Storage(),
        journal,
        Preferences(),
        timeout: const Duration(milliseconds: 40),
      );
      await repo.bind(peer.remoteEpk, 'launcher');
      await refresh(value: security(epoch: 'epoch-2'));
      expect(
        channel.sent
            .whereType<LauncherRequest>()
            .where((r) => r.type == 'project_launch')
            .length,
        1,
      );
      expect(repo.hasUnknownLaunch, false);
    });
    test(
      'Lock revokes immediately while agents run; lost reply is not replayed',
      () async {
        await refresh();
        final pending = repo.lock();
        expect(repo.launcherStatus, null);
        expect(repo.projects, isEmpty);
        final assertion = expectLater(pending, throwsA(isA<AgentFailure>()));
        expect((channel.sent.last as LauncherRequest).type, 'launcher_lock');
        await assertion;
        final status = repo.status();
        await replyStatus(security(unlocked: false));
        await status;
        expect(
          channel.sent
              .whereType<LauncherRequest>()
              .where((r) => r.type == 'launcher_lock')
              .length,
          1,
        );
        expect(channel.sent.whereType<AgentStop>(), isEmpty);
      },
    );
    test(
      'shutdown partial failure returns false and never restores local authority',
      () async {
        await refresh();
        final pending = repo.lock(shutdown: true);
        final request = channel.sent.last as LauncherRequest;
        expect(request.type, 'launcher_shutdown');
        channel.messages.add(
          LauncherStatusResult(
            'launcher_shutdown_result',
            request.id,
            security(),
            false,
          ),
        );
        expect(await pending, false);
        expect(repo.launcherStatus!.permitsControl, false);
      },
    );
    test(
      'wrong type and uncorrelated responses cannot satisfy status',
      () async {
        final pending = repo.status();
        final request = channel.sent.last as LauncherRequest;
        channel.messages.add(
          LauncherStatusResult(
            'launcher_status_result',
            'stale',
            security(),
            null,
          ),
        );
        channel.messages.add(
          LauncherStatusResult(
            'launcher_shutdown_result',
            request.id,
            security(),
            true,
          ),
        );
        await tick();
        expect(repo.launcherStatus, null);
        await replyStatus(security());
        await pending;
        expect(repo.launcherStatus!.permitsControl, true);
      },
    );
  });
}
