import 'dart:async';
import 'package:app/domain/contracts/agent_repository.dart';
import 'package:app/domain/contracts/fresh_launcher_repository.dart';
import 'package:app/ui/agents/agents_page.dart';
import 'package:app/ui/agents/viewmodels/agents_viewmodel.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'agents_viewmodel_test.dart' show Repo;

class Fresh extends FreshLauncherRepository {
  final pending = Completer<FreshLauncherEndpoint>();
  bool invalid = false;
  @override
  Stream<void> get invalidations => const Stream.empty();
  @override
  Future<FreshLauncherEndpoint> resolve(String peer, {String? preferredRoom}) =>
      pending.future;
  @override
  List<FreshLauncherSession> get sessions => const [
    FreshLauncherSession('root', 'Real root'),
  ];
  @override
  Future<FreshLauncherEndpoint> selectSession(String room) async =>
      FreshLauncherEndpoint('peer', room, 'Real root', 'launcher-1');
  @override
  void consumeHandoff(String peer, ManagedAgent agent) {
    checkCurrent();
    invalid = true;
  }

  @override
  void checkCurrent() {
    if (invalid) throw const AgentFailure('Changed');
  }

  @override
  void invalidate() {
    invalid = true;
  }
}

class AuditedRepo extends Repo {
  int unlocks = 0, setups = 0;
  String? bound;
  @override
  Future<void> bind(
    String peer,
    String room, {
    bool Function()? isCurrent,
  }) async {
    if (!(isCurrent?.call() ?? true)) throw const AgentFailure('Changed');
    bound = room;
  }

  @override
  Future<void> unlock(String pin) async {
    unlocks++;
  }

  @override
  Future<void> initializePin(String pin) async {
    setups++;
  }
}

void main() {
  for (final advanced in [false, true]) {
    testWidgets(
      'fresh Start pins actual detail before PIN; no automatic Start; advanced=$advanced',
      (tester) async {
        final fresh = Fresh();
        final repo = AuditedRepo();
        repo.security = const LauncherStatus(
          launcherId: 'launcher-1',
          launcherApi: 3,
          epoch: 'epoch',
          configured: true,
          unlocked: false,
          expiresAt: null,
          cooldownUntil: 0,
        );
        final vm = AgentsViewModel(repo, fresh: fresh);
        addTearDown(vm.dispose);
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: vm,
            child: MaterialApp(
              theme: buildDarkTheme(),
              home: const AgentsPage(
                target: AgentsTarget(
                  'peer',
                  'child',
                  'Machine',
                  'Child',
                  freshStart: true,
                  preferredRoom: 'child',
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.byKey(const Key('launcher-pin')), findsNothing);
        expect(repo.bound, isNull);
        if (advanced) {
          fresh.pending.completeError(const FreshLauncherUnavailable());
          await tester.pumpAndSettle();
          expect(find.text('Choose launching session'), findsOneWidget);
          expect(find.byKey(const Key('launcher-pin')), findsNothing);
          await tester.tap(find.text('Real root'));
        } else {
          fresh.pending.complete(
            const FreshLauncherEndpoint(
              'peer',
              'root',
              'Real root',
              'launcher-1',
            ),
          );
        }
        await tester.pumpAndSettle();
        expect(repo.bound, 'root');
        expect(find.text('Session: Real root'), findsOneWidget);
        expect(find.byKey(const Key('launcher-pin')), findsOneWidget);
        expect(repo.unlocks + repo.setups + repo.launches + repo.stops, 0);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  for (final advanced in [false, true]) {
    testWidgets(
      'API 2 bind after API 3 probe blocks PIN and Start; advanced=$advanced',
      (tester) async {
        final fresh = Fresh();
        final repo = AuditedRepo()
          ..security = const LauncherStatus(
            launcherId: 'launcher-1',
            launcherApi: 2,
            epoch: 'epoch',
            configured: true,
            unlocked: false,
            expiresAt: null,
            cooldownUntil: 0,
          );
        final vm = AgentsViewModel(repo, fresh: fresh);
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: vm,
            child: MaterialApp(
              theme: buildDarkTheme(),
              home: const AgentsPage(
                target: AgentsTarget(
                  'peer',
                  'child',
                  'Machine',
                  'Child',
                  freshStart: true,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        if (advanced) {
          fresh.pending.completeError(const FreshLauncherUnavailable());
          await tester.pumpAndSettle();
          await tester.tap(find.text('Real root'));
        } else {
          fresh.pending.complete(
            const FreshLauncherEndpoint(
              'peer',
              'root',
              'Real root',
              'launcher-1',
            ),
          );
        }
        await tester.pumpAndSettle();
        expect(find.text(newLaunchCompatibilityMessage), findsOneWidget);
        expect(find.byKey(const Key('launcher-pin')), findsNothing);
        expect(find.byKey(const Key('launch-agent')), findsNothing);
        await vm.unlock('123456');
        await vm.launch('project', null, confirmed: true);
        expect(repo.unlocks + repo.setups + repo.launches + repo.stops, 0);
        await tester.pumpWidget(const SizedBox.shrink());
        vm.dispose();
      },
    );
  }
  test('disposed resolver completion never binds or mutates', () async {
    final fresh = Fresh();
    final repo = AuditedRepo();
    final vm = AgentsViewModel(repo, fresh: fresh);
    final pending = vm.resolveFresh('peer');
    vm.dispose();
    fresh.pending.complete(
      const FreshLauncherEndpoint('peer', 'root', 'Real root', 'launcher-1'),
    );
    await pending;
    expect(repo.bound, isNull);
    expect(repo.unlocks + repo.setups + repo.launches, 0);
  });
}
