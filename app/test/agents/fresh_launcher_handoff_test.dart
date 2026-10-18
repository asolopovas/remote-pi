import 'dart:async';
import 'package:app/data/agents/agent_repository_impl.dart';
import 'package:app/data/agents/fresh_launcher_repository_impl.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/contracts/agent_repository.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/agents/agents_page.dart';
import 'package:app/ui/agents/viewmodels/agents_viewmodel.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'session_control_repository_test.dart' as f;

const child = ManagedAgent(
  agentId: 'new',
  name: 'New child',
  cwd: '/project',
  roomId: 'exact-child',
  state: 'running',
);
LauncherStatus get security => LauncherStatus(
  launcherId: 'root-id',
  epoch: 'epoch',
  configured: true,
  unlocked: true,
  expiresAt: DateTime.now().millisecondsSinceEpoch + 300000,
  cooldownUntil: 0,
  launcherApi: 3,
);

class PairedChannel extends f.Channel implements IRoomLauncherProbe {
  bool publishChild = true;
  @override
  Future<({String peer, String room, LauncherStatus status})?> probeLauncher(
    String room,
  ) async => (peer: f.peer.remoteEpk, room: room, status: security);
  @override
  void cancelLauncherProbes() {}
  void announce(String room) => controls.add(
    RoomAnnounced(
      peer: f.peer.remoteEpk,
      roomId: room,
      startedAt: 1,
      name: room == 'root' ? 'Resolved root' : room,
    ),
  );
  @override
  Future<void> send(ClientMessage value) async {
    await super.send(value);
    if (value is LauncherRequest) {
      switch (value.type) {
        case 'launcher_status':
          messages.add(
            LauncherStatusResult(
              'launcher_status_result',
              value.id,
              security,
              null,
            ),
          );
        case 'project_list':
          messages.add(
            ProjectListResult(value.id, const [
              LauncherProject('project', 'Project', '/project', ['/project']),
            ]),
          );
        case 'project_launch':
          if (publishChild) announce(child.roomId);
          messages.add(
            AgentMutationResult('agent_launch_result', value.id, child),
          );
      }
    } else if (value is AgentList) {
      messages.add(
        AgentListResult(
          value.id,
          const AgentAvailability(
            available: true,
            launcherId: 'root-id',
            cwd: '/project',
            maxAgents: 4,
            agents: [],
          ),
        ),
      );
    }
  }
}

class ParkedPreferences extends Preferences {
  Completer<void>? release;
  bool entered = false;
  @override
  Future<void> setSelectedRoom({String? epk, String? roomId}) async {
    entered = true;
    if (release != null) await release!.future;
  }
}

void main() {
  for (final scenario in [
    'success',
    'confirmation',
    'confirmation-original',
    'preferences-selection',
    'discovery-selection',
    'preferences-epoch-aba',
    'preferences-incarnation',
  ]) {
    testWidgets('real fresh lease / repository / page: $scenario', (
      tester,
    ) async {
      final ch = PairedChannel();
      final storage = f.Storage();
      final conn = ConnectionManager(
        factory: (_, _) async => ch,
        storage: storage,
        emitDebounce: Duration.zero,
      );
      await conn.connectTo(f.peer);
      ch.announce('one');
      ch.announce('root');
      await tester.runAsync(f.settle);
      final prefs = ParkedPreferences();
      if (scenario.startsWith('preferences-')) {
        prefs.release = Completer<void>();
      }
      if (scenario == 'discovery-selection') ch.publishChild = false;
      final fresh = FreshLauncherRepositoryImpl(conn, storage);
      final repo = AgentRepositoryImpl(
        conn,
        storage,
        AgentMutationJournal(),
        prefs,
      );
      final vm = AgentsViewModel(repo, fresh: fresh);
      final selection = SessionSelection();
      final router = GoRouter(
        initialLocation: '/agents',
        routes: [
          GoRoute(
            path: '/agents',
            builder: (_, _) => AgentsPage(
              target: AgentsTarget(
                f.peer.remoteEpk,
                'one',
                'Machine',
                scenario == 'confirmation-original'
                    ? 'Wrong original child'
                    : 'Checking status…',
                freshStart: true,
                preferredRoom: 'root',
              ),
            ),
          ),
          GoRoute(
            path: '/home',
            builder: (_, _) => const Scaffold(body: Text('Navigated home')),
          ),
        ],
      );
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: vm),
            ChangeNotifierProvider.value(value: selection),
          ],
          child: MaterialApp.router(
            theme: buildDarkTheme(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Session: Resolved root'), findsOneWidget);
      expect(
        ch.sent.whereType<LauncherRequest>().where(
          (r) => r.type == 'project_launch',
        ),
        isEmpty,
      );
      await tester.tap(find.byKey(const ValueKey('launch-project-project')));
      await tester.pumpAndSettle();
      final start = find.widgetWithText(FilledButton, 'Start agent');
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pumpAndSettle();
      if (scenario.startsWith('confirmation')) {
        final detail = tester
            .widget<Text>(
              find
                  .descendant(
                    of: find.byType(AlertDialog),
                    matching: find.byType(Text),
                  )
                  .at(1),
            )
            .data!;
        expect(detail, contains('Machine · Resolved root · Project'));
        expect(detail, isNot(contains('Checking status')));
        expect(detail, isNot(contains('Wrong original child')));
        await tester.tap(find.text('Cancel'));
      } else {
        await tester.tap(find.widgetWithText(FilledButton, 'Start'));
        await tester.pumpAndSettle();
        if (scenario.startsWith('preferences-') ||
            scenario == 'discovery-selection') {
          expect(prefs.entered, scenario.startsWith('preferences-'));
          if (scenario == 'preferences-incarnation') {
            ch.controls.add(
              RoomAnnounced(
                peer: f.peer.remoteEpk,
                roomId: 'root',
                startedAt: 2,
              ),
            );
            await tester.pump();
          } else {
            conn.switchRoom('external-choice');
            if (scenario == 'preferences-epoch-aba') conn.switchRoom('root');
          }
          prefs.release?.complete();
          ch.announce(child.roomId);
          await tester.pump(const Duration(milliseconds: 150));
          await tester.pumpAndSettle();
          expect(
            conn.activeRoomId,
            scenario == 'preferences-epoch-aba' ||
                    scenario == 'preferences-incarnation'
                ? 'root'
                : 'external-choice',
          );
          expect(selection.current, isNull);
          expect(find.text('Navigated home'), findsNothing);
        } else {
          expect(conn.activeRoomId, child.roomId);
          expect(selection.current?.roomId, child.roomId);
          expect(find.text('Navigated home'), findsOneWidget);
          expect(vm.state.invalid, isFalse);
          expect(fresh.checkCurrent, throwsA(isA<AgentFailure>()));
        }
        // Even after successful consumption or an external selection, no PIN or Start replay.
        final count = ch.sent.length;
        await vm.unlock('123456');
        await vm.initializePin('123456');
        await vm.launch('project', null, confirmed: true);
        expect(await vm.openAgent(child), isFalse);
        expect(ch.sent.length, count);
      }
      expect(
        ch.sent.whereType<LauncherRequest>().where(
          (r) =>
              ['launcher_unlock', 'launcher_pin_initialize'].contains(r.type),
        ),
        isEmpty,
      );
      expect(
        ch.sent
            .whereType<LauncherRequest>()
            .where((r) => r.type == 'project_launch')
            .length,
        scenario.startsWith('confirmation') ? 0 : 1,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      vm.dispose();
      selection.dispose();
      await conn.disconnect();
      conn.dispose();
    });
  }
}
