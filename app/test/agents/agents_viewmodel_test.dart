import 'dart:async';
import 'package:app/domain/contracts/agent_repository.dart';
import 'package:app/ui/agents/viewmodels/agents_viewmodel.dart';
import 'package:flutter_test/flutter_test.dart';

const agent = ManagedAgent(
  agentId: 'managed',
  name: 'New Pi',
  cwd: '/project',
  roomId: 'new-room',
  state: 'running',
);

class Repo extends AgentRepository {
  AgentAvailability availability = const AgentAvailability(
    available: true,
    cwd: '/project',
    maxAgents: 4,
    agents: [agent],
  );
  ManagedAgent? opened;
  Completer<void>? connecting;
  @override
  Future<void> openAgent(
    ManagedAgent agent, {
    void Function(String peer, String room)? beforeHandoff,
  }) async {
    if (connecting != null) await connecting!.future;
    opened = agent;
  }

  int launches = 0, stops = 0, locks = 0, shutdowns = 0;
  bool unknownLaunch = false;
  bool partialShutdown = false;
  final acknowledgements = <bool>[];
  @override
  bool get hasUnknownLaunch => unknownLaunch;
  LauncherStatus security = LauncherStatus(
    launcherId: 'launcher-1',
    launcherApi: 3,
    epoch: 'epoch-1',
    configured: true,
    unlocked: true,
    expiresAt: DateTime.now().millisecondsSinceEpoch + 600000,
    cooldownUntil: 0,
  );
  @override
  LauncherStatus get launcherStatus => security;
  List<LauncherProject> projectCatalog = const [
    LauncherProject('project', 'Registered project', '/project', [
      '/project',
      '/shared',
    ]),
  ];
  @override
  List<LauncherProject> get projects => projectCatalog;
  @override
  Future<void> unlock(String pin) async {}
  @override
  Future<bool> lock({bool shutdown = false}) async {
    if (shutdown) {
      shutdowns++;
    } else {
      locks++;
    }
    security = const LauncherStatus(
      launcherId: 'launcher-1',
      launcherApi: 3,
      epoch: 'epoch-1',
      configured: true,
      unlocked: false,
      expiresAt: null,
      cooldownUntil: 0,
    );
    return !partialShutdown;
  }

  bool listFails = false;
  final invalid = StreamController<void>.broadcast();
  Completer<ManagedAgent>? pending;
  @override
  Stream<void> get invalidations => invalid.stream;
  @override
  Future<void> bind(
    String peer,
    String room, {
    bool Function()? isCurrent,
  }) async {}
  @override
  Future<AgentAvailability> list() async {
    if (listFails) throw const AgentFailure('List failed');
    return availability;
  }

  @override
  Future<ManagedAgent> launch(
    String cwd,
    String? name, {
    bool acknowledgeUnknown = false,
  }) async {
    if (unknownLaunch && !acknowledgeUnknown) {
      throw const AgentFailure(
        'Explicit duplicate-risk acknowledgement required',
        outcomeUnknown: true,
      );
    }
    acknowledgements.add(acknowledgeUnknown);
    launches++;
    try {
      return pending == null ? agent : await pending!.future;
    } on AgentFailure catch (error) {
      unknownLaunch = unknownLaunch || error.outcomeUnknown;
      rethrow;
    }
  }

  @override
  Future<ManagedAgent> stop(String agentId) async {
    stops++;
    return agent;
  }

  @override
  void refreshDiscovery() {}
  @override
  void dispose() {
    invalid.close();
  }
}

void main() {
  for (final state in ['failed', 'stopped', 'starting', 'unknown', 'running']) {
    test('launch $state with invalid readiness cannot claim success', () async {
      final repo = Repo();
      final vm = AgentsViewModel(repo);
      await vm.initialize('peer', 'room');
      repo.pending = Completer<ManagedAgent>();
      final pending = vm.launch('project', null, confirmed: true);
      expect(vm.state.message, 'Starting…');
      repo.pending!.complete(
        ManagedAgent(
          agentId: 'new',
          name: 'New',
          cwd: '/project',
          roomId: state == 'running' ? '' : 'room-new',
          state: state,
        ),
      );
      expect(await pending, null);
      expect(vm.state.message, isNot(contains('Agent running')));
      expect(repo.opened, null);
      expect(repo.launches, 1);
      vm.dispose();
    });
  }

  test(
    'confirmed launch waits for connection without another launch',
    () async {
      final repo = Repo();
      final vm = AgentsViewModel(repo);
      await vm.initialize('peer', 'room');
      final launched = await vm.launch('project', null, confirmed: true);
      repo.connecting = Completer<void>();
      final opened = vm.openAgent(launched!);
      expect(vm.state.busy, true);
      expect(vm.state.message, 'Connecting…');
      await vm.launch('project', null, confirmed: true);
      expect(repo.launches, 1);
      repo.connecting!.complete();
      expect(await opened, true);
      expect(repo.opened?.roomId, 'new-room');
      vm.dispose();
    },
  );
  test(
    'locked machine status blocks Start and Stop; Lock keeps agents, shutdown partial wording',
    () async {
      final repo = Repo();
      final vm = AgentsViewModel(repo);
      await vm.initialize('peer', 'room');
      await vm.lock();
      expect(vm.unlocked, false);
      expect(vm.state.message, contains('keep running'));
      await vm.launch('project', null, confirmed: true);
      await vm.stop('managed', confirmed: true);
      expect(repo.launches, 0);
      expect(repo.stops, 0);
      repo.partialShutdown = true;
      await vm.lock(shutdown: true);
      expect(
        vm.state.message,
        contains('some of your managed agents could not stop'),
      );
      vm.dispose();
    },
  );
  test(
    'owned failed records can retry Stop but still require confirmation',
    () async {
      final repo = Repo();
      repo.availability = const AgentAvailability(
        available: true,
        cwd: '/p',
        maxAgents: 4,
        agents: [
          ManagedAgent(
            agentId: 'failed-live',
            name: 'Failed Pi',
            cwd: '/p',
            roomId: 'failed-room',
            state: 'failed',
            error: 'Cleanup failed',
          ),
        ],
      );
      final vm = AgentsViewModel(repo);
      await vm.initialize('peer', 'room');
      await vm.stop('failed-live', confirmed: false);
      await vm.stop('not-owned', confirmed: true);
      expect(repo.stops, 0);
      await vm.stop('failed-live', confirmed: true);
      expect(repo.stops, 1);
      vm.dispose();
    },
  );
  test(
    'unknown launch outcome requires successful list before a new request',
    () async {
      final repo = Repo();
      final subject = AgentsViewModel(repo);
      await subject.initialize('peer', 'room');
      repo.pending = Completer<ManagedAgent>();
      final start = subject.launch('/p', null, confirmed: true);
      repo.pending!.completeError(
        const AgentFailure('Timed out', outcomeUnknown: true),
      );
      await start;
      expect(subject.state.needsReconciliation, true);
      await subject.launch('/p', null, confirmed: true);
      expect(repo.launches, 1);
      await subject.stop('managed', confirmed: true);
      expect(subject.state.needsReconciliation, true);
      repo.listFails = true;
      await subject.refresh();
      expect(subject.state.needsReconciliation, true);
      await subject.launch('/p', null, confirmed: true);
      expect(repo.launches, 1);
      repo.listFails = false;
      await subject.refresh();
      expect(subject.state.needsReconciliation, false);
      repo.pending = null;
      await subject.launch(
        '/p',
        null,
        confirmed: true,
        acknowledgeUnknown: true,
      );
      expect(repo.launches, 2);
      expect(repo.unknownLaunch, true);
      subject.dispose();
    },
  );

  test('confirmation, duplicate suppression and managed-only stop', () async {
    final repo = Repo();
    final subject = AgentsViewModel(repo);
    await subject.initialize('peer', 'room');
    await subject.launch('/project', null, confirmed: false);
    expect(repo.launches, 0);
    repo.pending = Completer<ManagedAgent>();
    final start = subject.launch('/project', null, confirmed: true);
    await subject.launch('/project', null, confirmed: true);
    expect(repo.launches, 1);
    repo.pending!.complete(agent);
    await start;
    expect(subject.state.availability!.agents.length, 1);
    await subject.stop('managed', confirmed: false);
    await subject.stop('unmanaged', confirmed: true);
    expect(repo.stops, 0);
    await subject.stop('managed', confirmed: true);
    expect(repo.stops, 1);
    subject.dispose();
  });
  test(
    'unsupported and invalidation prohibit launch and ignore late completion',
    () async {
      final repo = Repo();
      repo.availability = const AgentAvailability(
        available: false,
        reason: 'Managed child',
        cwd: '/p',
        maxAgents: 4,
        agents: [],
      );
      final vm = AgentsViewModel(repo);
      await vm.initialize('peer', 'room');
      await vm.launch('/p', null, confirmed: true);
      expect(repo.launches, 0);
      repo.availability = const AgentAvailability(
        available: true,
        cwd: '/p',
        maxAgents: 4,
        agents: [],
      );
      await vm.refresh();
      repo.pending = Completer<ManagedAgent>();
      final start = vm.launch('/p', null, confirmed: true);
      repo.invalid.add(null);
      await Future<void>.delayed(Duration.zero);
      repo.pending!.complete(agent);
      await start;
      expect(vm.state.invalid, true);
      expect(vm.state.availability, null);
      await vm.launch('/p', null, confirmed: true);
      expect(repo.launches, 1);
      vm.dispose();
    },
  );
  test('invalid input never dispatches', () async {
    final repo = Repo();
    final subject = AgentsViewModel(repo);
    await subject.initialize('peer', 'room');
    await subject.launch('/p\ncode', null, confirmed: true);
    expect(repo.launches, 0);
    expect(subject.state.message, contains('control'));
    subject.dispose();
  });
}
