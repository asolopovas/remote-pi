import 'package:app/data/preferences/preferences.dart';
import 'dart:async';
import 'dart:convert';

import 'package:app/data/agents/agent_repository_impl.dart';
import 'package:app/data/transport/peer_channel.dart';
import 'package:app/domain/contracts/agent_repository.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:app/ui/agents/agents_page.dart';
import 'package:app/ui/agents/viewmodels/agents_viewmodel.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'agents_page_test.dart' show selectProject;
import '../transport/ws_transport_discovery_recovery_test.dart' show LocalRelay;
import 'agent_repository_test.dart' as helpers;

const paired = PeerRecord(
  remoteEpk: 'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO_oMQ6yyQE',
  sessionName: 'Host',
  relayUrl: 'ws://unused',
  pairedAt: '2026-01-01',
);

class SocketStorage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => [paired];
}

class LauncherHarness {
  late LocalRelay relay;
  late PlainPeerChannel channel;
  late helpers.Connection connection;
  late AgentRepositoryImpl repo;
  late StreamSubscription<Map<String, dynamic>> subscription;
  final journal = AgentMutationJournal();
  String epoch = 'epoch-1';
  int api = 3;
  List<String> folders = ['/project'];
  bool delayStatus = false, delayAgents = false;
  bool configured = true, unlocked = true, setupGrant = false;
  Map<String, dynamic>? waitingStatus, waitingAgents;
  final requests = <Map<String, dynamic>>[];

  Future<void> open() async {
    relay = await LocalRelay.start();
    final transport = await relay.connect();
    transport.setActiveRoom('launcher');
    channel = PlainPeerChannel(transport: transport);
    connection = helpers.Connection(channel);
    repo = AgentRepositoryImpl(
      connection,
      SocketStorage(),
      journal,
      Preferences(),
      timeout: const Duration(seconds: 2),
      mutationTimeout: const Duration(milliseconds: 20),
    );
    subscription = relay.outbound.stream.listen((frame) {
      if (frame['ct'] == null) return;
      final request =
          jsonDecode(utf8.decode(base64.decode(frame['ct'] as String)))
              as Map<String, dynamic>;
      requests.add(request);
      switch (request['type']) {
        case 'launcher_status':
          if (delayStatus) {
            waitingStatus = request;
          } else {
            status(request);
          }
        case 'launcher_pin_initialize':
          configured = true;
          unlocked = setupGrant;
          epoch = 'setup-epoch';
          status(request);
        case 'launcher_unlock':
          unlocked = true;
          epoch = 'unlock-epoch';
          status(request);
        case 'project_list':
          send({
            'type': 'project_list_result',
            'in_reply_to': request['id'],
            'projects': [
              {
                'project_id': 'project',
                'name': 'Registered project',
                'cwd': '/project',
                'allowed_folders': folders,
              },
            ],
          });
        case 'agent_list':
          if (delayAgents) {
            waitingAgents = request;
          } else {
            agents(request);
          }
      }
    });
  }

  void agents(Map<String, dynamic> request) => send({
    'type': 'agent_list_result',
    'in_reply_to': request['id'],
    'available': true,
    'launcher_id': 'launcher-1',
    'cwd': '/project',
    'max_agents': 4,
    'agents': [],
  });
  void status(Map<String, dynamic> request) => send({
    'type': 'launcher_status_result',
    'in_reply_to': request['id'],
    'status': {
      'launcher_id': 'launcher-1',
      'launcher_api': api,
      'epoch': epoch,
      'configured': configured,
      'pin_setup': configured ? 'configured' : 'available',
      'unlocked': unlocked,
      'expires_at': unlocked
          ? DateTime.now().millisecondsSinceEpoch + 600000
          : null,
      'cooldown_until': 0,
    },
  });
  void send(
    Map<String, dynamic> body, {
    String? room = 'launcher',
    String? peer,
  }) => relay.send({
    'peer': peer ?? paired.remoteEpk,
    'room': ?room,
    'ct': base64.encode(utf8.encode(jsonEncode(body))),
  });
  Future<void> barrier() async {
    final received = channel.serverMessages.firstWhere((m) => m is Pong);
    send({'type': 'pong', 'in_reply_to': 'barrier'});
    await received;
  }

  Future<void> close() async {
    repo.dispose();
    await subscription.cancel();
    await channel.close();
    await relay.close();
    await connection.statuses.close();
    await connection.rooms.close();
    connection.dispose();
  }
}

void main() {
  test('real socket setup grant loads projects without a second PIN', () async {
    final h = LauncherHarness()
      ..api = 2
      ..configured = false
      ..unlocked = false
      ..setupGrant = true;
    await h.open();
    final vm = AgentsViewModel(h.repo);
    try {
      await vm.initialize(paired.remoteEpk, 'launcher');
      await vm.initializePin('123456');
      expect(vm.unlocked, true);
      expect(vm.security?.launcherApi, 2);
      expect(vm.projects.single.projectId, 'project');
      expect(vm.state.availability?.available, true);
      expect(
        h.requests.where((r) => r['type'] == 'launcher_pin_initialize'),
        hasLength(1),
      );
      expect(h.requests.where((r) => r['type'] == 'launcher_unlock'), isEmpty);
    } finally {
      await h.close();
      vm.dispose();
    }
  });
  test(
    'real socket setup sends one PIN only, stays locked and requires explicit unlock before project list',
    () async {
      final h = LauncherHarness()
        ..configured = false
        ..unlocked = false;
      await h.open();
      try {
        await h.repo.bind(paired.remoteEpk, 'launcher');
        await h.repo.status();
        expect(h.repo.launcherStatus?.pinSetup, PinSetup.available);
        await h.repo.initializePin('123456');
        final setup = h.requests.singleWhere(
          (r) => r['type'] == 'launcher_pin_initialize',
        );
        expect(setup, {
          'type': 'launcher_pin_initialize',
          'id': setup['id'],
          'launcher_id': 'launcher-1',
          'epoch': 'epoch-1',
          'pin': '123456',
        });
        expect(h.repo.launcherStatus?.epoch, 'setup-epoch');
        expect(h.repo.launcherStatus?.permitsControl, false);
        expect(h.repo.hasUnknownLaunch, false);
        expect(h.repo.projects, isEmpty);
        await expectLater(
          h.repo.initializePin('123456'),
          throwsA(isA<AgentFailure>()),
        );
        await expectLater(h.repo.list(), throwsA(isA<AgentFailure>()));
        expect(
          h.requests.where(
            (r) =>
                r['type'] == 'launcher_unlock' || r['type'] == 'project_list',
          ),
          isEmpty,
        );
        await h.repo.unlock('123456');
        await h.repo.list();
        expect(h.repo.projects.single.projectId, 'project');
        expect(h.repo.launcherStatus?.permitsControl, true);
        expect(
          h.requests.where((r) => r['type'] == 'launcher_pin_initialize'),
          hasLength(1),
        );
        expect(
          h.requests.where((r) => r['type'] == 'launcher_unlock'),
          hasLength(1),
        );
      } finally {
        await h.close();
      }
    },
  );

  testWidgets(
    'delayed socket refresh restores only reconciled unchanged project definition',
    (tester) async {
      final h = LauncherHarness();
      await tester.runAsync(() => h.open());
      final vm = AgentsViewModel(h.repo);
      await tester.runAsync(() => vm.initialize(paired.remoteEpk, 'launcher'));
      Widget page(String room) => ChangeNotifierProvider.value(
        value: vm,
        child: MaterialApp(
          theme: buildDarkTheme(),
          home: AgentsPage(
            target: AgentsTarget(paired.remoteEpk, room, 'Laptop', 'Project'),
          ),
        ),
      );
      await tester.pumpWidget(page('launcher'));
      await tester.pumpAndSettle();
      bool canStart() {
        final button = find.widgetWithText(FilledButton, 'Start agent');
        return button.evaluate().isNotEmpty &&
            tester.widget<FilledButton>(button).onPressed != null;
      }

      Future<void> delayedRefresh({
        bool expectRestore = true,
        bool changeTarget = false,
      }) async {
        h.delayStatus = true;
        h.delayAgents = true;
        h.waitingStatus = null;
        h.waitingAgents = null;
        late Future<void> refresh;
        await tester.runAsync(() async {
          refresh = vm.refresh();
          while (h.waitingStatus == null) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
        });
        await tester.pump(); // Real status() has revoked security and catalog.
        expect(h.repo.launcherStatus, null);
        expect(h.repo.projects, isEmpty);
        expect(canStart(), false);
        expect(find.byType(RadioGroup<String>), findsNothing);
        await tester.runAsync(() async {
          h.delayStatus = false;
          h.status(h.waitingStatus!);
          while (h.waitingAgents == null) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
        });
        await tester.pump();
        expect(h.repo.launcherStatus?.permitsControl, true);
        expect(h.repo.projects, isNotEmpty);
        expect(canStart(), false); // Catalog alone cannot restore selection.
        if (changeTarget) {
          await tester.pumpWidget(page('other-room'));
          await tester.pump();
        }
        await tester.runAsync(() async {
          h.delayAgents = false;
          h.agents(h.waitingAgents!);
          await refresh;
        });
        await tester.pumpAndSettle();
        expect(canStart(), expectRestore);
      }

      await selectProject(tester);
      expect(canStart(), true);
      await delayedRefresh();
      h.folders = ['/different'];
      await delayedRefresh(expectRestore: false);
      await selectProject(tester);
      h.epoch = 'epoch-2';
      await delayedRefresh(expectRestore: false);
      await selectProject(tester);
      await delayedRefresh(expectRestore: false, changeTarget: true);
      expect(vm.state.invalid, true);
      expect(
        h.requests.where(
          (r) =>
              r['type'] == 'launcher_unlock' || r['type'] == 'project_launch',
        ),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
      vm.dispose();
      await tester.runAsync(() => h.close());
    },
  );

  for (final fresh in [false, true]) {
    test(
      'unknown launch rejects unscoped errors after ${fresh ? 'fresh transport' : '129 ID churn'}',
      () async {
        final h = LauncherHarness();
        await h.open();
        try {
          await h.repo.bind(paired.remoteEpk, 'launcher');
          await h.repo.list();
          await expectLater(
            h.repo.launch('project', null),
            throwsA(isA<AgentFailure>()),
          );
          final id = h.requests.lastWhere(
            (r) => r['type'] == 'project_launch',
          )['id'];
          if (fresh) {
            await h.close();
            await h
                .open(); // Same App-lifetime journal, completely new transport.
            await h.repo.bind(paired.remoteEpk, 'launcher');
            await h.repo.list();
          } else {
            for (var i = 0; i < 43; i++) {
              await h.repo.list();
            }
          }
          final errors = <ErrorMessage>[];
          final sub = h.channel.serverMessages
              .where((m) => m is ErrorMessage)
              .cast<ErrorMessage>()
              .listen(errors.add);
          final error = {
            'type': 'error',
            'in_reply_to': id,
            'code': 'failed',
            'message': 'late',
            'room': 'launcher',
          }; // Inner scope is not evidence.
          h.send(error, room: 'wrong');
          h.send(error, room: null);
          await h.barrier();
          expect(
            errors,
            hasLength(1),
          ); // Legacy chat still receives its unscoped error.
          expect(h.repo.hasUnknownLaunch, true);
          await expectLater(
            h.repo.launch('project', null),
            throwsA(isA<AgentFailure>()),
          );
          h.send(error);
          await h.barrier();
          expect(h.repo.hasUnknownLaunch, false);
          await sub.cancel();
        } finally {
          await h.close();
        }
      },
    );
  }
}
