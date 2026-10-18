import 'package:app/domain/contracts/agent_repository.dart';
import 'package:app/domain/contracts/launcher_recovery_repository.dart';
import 'package:app/domain/contracts/session_control_repository.dart';
import 'package:app/ui/agents/agents_page.dart';
import 'package:app/ui/agents/viewmodels/agents_viewmodel.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'agents_viewmodel_test.dart' show Repo, agent;

class Recovery extends LauncherRecoveryRepository {
  LaunchingHost? origin = const LaunchingHost('parent-exact', 'launcher-1');
  String? selected;
  bool permitted = true;
  int inspected = 0;
  bool invalid = false;
  @override
  Future<LaunchingHost?> resolve(String peer, String child) async => origin;
  @override
  List<LaunchHostChoice> get choices => const [
    LaunchHostChoice('manual-parent', 'Root session'),
  ];
  @override
  Future<void> selectParent(String room) async {
    selected = room;
  }

  @override
  Future<SessionStopCapability> returnToChild() async {
    inspected++;
    return SessionStopCapability(
      peer: 'peer',
      room: 'child-exact',
      canStop: permitted,
      token: permitted ? 'new-token' : null,
    );
  }

  @override
  void checkCurrent() {
    if (invalid) throw const SessionControlFailure('Host changed');
  }

  @override
  void invalidate() {
    invalid = true;
  }

  @override
  void dispose() {}
}

class UnlockRepo extends Repo {
  int unlocks = 0;
  String? bound;
  @override
  Future<void> bind(
    String peer,
    String room, {
    bool Function()? isCurrent,
  }) async {
    bound = room;
  }

  @override
  Future<void> unlock(String pin) async {
    unlocks++;
    security = LauncherStatus(
      launcherId: security.launcherId,
      launcherApi: 2,
      epoch: 'new-epoch',
      configured: true,
      unlocked: true,
      expiresAt: DateTime.now().millisecondsSinceEpoch + 300000,
      cooldownUntil: 0,
    );
  }
}

class AuditedRepo extends UnlockRepo {
  int setups = 0, lists = 0;
  @override
  Future<void> initializePin(String pin) async {
    setups++;
  }

  @override
  Future<AgentAvailability> list() {
    lists++;
    return super.list();
  }
}

void main() {
  for (final known in [true, false]) {
    for (final allowed in [true, false]) {
      testWidgets(
        '${known ? 'authoritative' : 'manual legacy'} parent unlock returns to child; access confirmed=$allowed',
        (tester) async {
          final repo = UnlockRepo();
          repo.security = const LauncherStatus(
            launcherId: 'launcher-1',
            launcherApi: 2,
            epoch: 'locked',
            configured: true,
            unlocked: false,
            expiresAt: null,
            cooldownUntil: 0,
          );
          final recovery = Recovery()
            ..origin = known
                ? const LaunchingHost('parent-exact', 'launcher-1')
                : null;
          recovery.permitted = allowed;
          final vm = AgentsViewModel(repo, recovery: recovery);
          String? result;
          final router = GoRouter(
            routes: [
              GoRoute(
                path: '/',
                builder: (context, _) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      result = await context.push<String>('/agents');
                    },
                    child: const Text('Child chat'),
                  ),
                ),
              ),
              GoRoute(
                path: '/agents',
                builder: (_, _) => ChangeNotifierProvider.value(
                  value: vm,
                  child: const AgentsPage(
                    target: AgentsTarget(
                      'peer',
                      'child-exact',
                      'PC',
                      'Child',
                      resolveOrigin: true,
                      recoverChild: true,
                    ),
                  ),
                ),
              ),
            ],
          );
          await tester.pumpWidget(
            MaterialApp.router(theme: buildDarkTheme(), routerConfig: router),
          );
          await tester.tap(find.text('Child chat'));
          await tester.pumpAndSettle();
          if (!known) {
            expect(recovery.selected, isNull);
            expect(repo.bound, isNull);
            expect(
              find.textContaining('Choose launching session'),
              findsOneWidget,
            );
            await tester.tap(find.text('Root session'));
            await tester.pumpAndSettle();
          }
          expect(repo.bound, known ? 'parent-exact' : 'manual-parent');
          expect(find.byKey(const Key('launcher-pin')), findsOneWidget);
          await tester.enterText(
            find.byKey(const Key('launcher-pin')),
            '654321',
          );
          await tester.pump();
          await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
          await tester.pumpAndSettle();
          expect(repo.unlocks, 1);
          expect(recovery.inspected, 1);
          expect(repo.stops, 0);
          expect(repo.launches, 0);
          expect(find.text('Child chat'), findsOneWidget);
          expect(
            result,
            allowed ? isNull : contains('Child access not confirmed'),
          );
          expect(find.text('Start agent?'), findsNothing);
          await tester.pumpWidget(const SizedBox.shrink());
          router.dispose();
          vm.dispose();
        },
      );
    }
  }
  testWidgets(
    'Back from a locked parent restores and inspects original child without PIN or Stop',
    (tester) async {
      final repo = UnlockRepo();
      repo.security = const LauncherStatus(
        launcherId: 'launcher-1',
        epoch: 'locked',
        configured: true,
        unlocked: false,
        expiresAt: null,
        cooldownUntil: 0,
      );
      final recovery = Recovery()..permitted = false;
      final vm = AgentsViewModel(repo, recovery: recovery);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, _) => Scaffold(
              body: TextButton(
                onPressed: () => context.push('/agents'),
                child: const Text('Original child'),
              ),
            ),
          ),
          GoRoute(
            path: '/agents',
            builder: (_, _) => ChangeNotifierProvider.value(
              value: vm,
              child: const AgentsPage(
                target: AgentsTarget(
                  'peer',
                  'child-exact',
                  'PC',
                  'Child',
                  resolveOrigin: true,
                  recoverChild: true,
                ),
              ),
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp.router(theme: buildDarkTheme(), routerConfig: router),
      );
      await tester.tap(find.text('Original child'));
      await tester.pumpAndSettle();
      expect(repo.bound, 'parent-exact');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Original child'), findsOneWidget);
      expect(recovery.inspected, 1);
      expect(repo.unlocks, 0);
      expect(repo.stops, 0);
      expect(repo.launches, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      vm.dispose();
    },
  );
  testWidgets(
    'parent lifecycle invalidation blocks PIN before sending even without repo notification',
    (tester) async {
      final repo = UnlockRepo();
      final recovery = Recovery();
      final vm = AgentsViewModel(repo, recovery: recovery);
      await vm.resolveHost('peer', 'child', returnToChild: true);
      recovery.invalid = true;
      await vm.unlock('654321');
      expect(repo.unlocks, 0);
      expect(vm.state.invalid, isTrue);
      vm.dispose();
    },
  );
  testWidgets(
    'known parent changed launcher identity cannot offer or send PIN',
    (tester) async {
      final repo = UnlockRepo();
      final recovery = Recovery()
        ..origin = const LaunchingHost('same-room', 'old-launcher');
      final vm = AgentsViewModel(repo, recovery: recovery);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: vm,
          child: MaterialApp(
            theme: buildDarkTheme(),
            home: const AgentsPage(
              target: AgentsTarget(
                'peer',
                'child',
                'PC',
                'Child',
                resolveOrigin: true,
                recoverChild: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(vm.state.invalid, isTrue);
      expect(find.byKey(const Key('launcher-pin')), findsNothing);
      await vm.unlock('654321');
      expect(repo.unlocks, 0);
      expect(recovery.inspected, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      vm.dispose();
    },
  );
  for (final action in [
    'initializePin',
    'unlock',
    'lock',
    'shutdown',
    'launch',
    'stop',
    'openAgent',
    'refresh',
    'finish',
    'cancel',
  ]) {
    test('unnotified stale recovery blocks $action independently', () async {
      final repo = AuditedRepo();
      final recovery = Recovery();
      final vm = AgentsViewModel(repo, recovery: recovery);
      await vm.resolveHost('peer', 'child', returnToChild: true);
      expect(vm.state.invalid, isFalse);
      final lists = repo.lists;
      recovery.invalid = true; // Deliberately no invalidation notification.
      switch (action) {
        case 'initializePin':
          await vm.initializePin('654321');
        case 'unlock':
          await vm.unlock('654321');
        case 'lock':
          await vm.lock();
        case 'shutdown':
          await vm.lock(shutdown: true);
        case 'launch':
          expect(await vm.launch('project', null, confirmed: true), isNull);
        case 'stop':
          await vm.stop(agent.agentId, confirmed: true);
        case 'openAgent':
          expect(await vm.openAgent(agent), isFalse);
        case 'refresh':
          await vm.refresh();
        case 'finish':
          expect(await vm.finishRecovery(), isNull);
        case 'cancel':
          expect(await vm.cancelRecovery(), isFalse);
      }
      expect(vm.state.invalid, isTrue);
      expect(repo.setups, 0);
      expect(repo.unlocks, 0);
      expect(repo.locks, 0);
      expect(repo.shutdowns, 0);
      expect(repo.launches, 0);
      expect(repo.stops, 0);
      expect(repo.opened, isNull);
      expect(repo.lists, lists);
      expect(recovery.inspected, 0);
      vm.dispose();
    });
  }
}
