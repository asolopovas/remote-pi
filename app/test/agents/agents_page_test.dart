import 'dart:async';

import 'package:app/domain/contracts/agent_repository.dart';
import 'package:app/ui/agents/agents_page.dart';
import 'package:app/ui/agents/viewmodels/agents_viewmodel.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:app/routing/adaptive.dart';
import 'agents_viewmodel_test.dart' show Repo;

Future<void> selectProject(WidgetTester tester) async {
  final tile = find.byKey(const ValueKey('launch-project-project'));
  await tester.ensureVisible(tile);
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

Widget page(
  AgentsViewModel vm, {
  String room = 'room',
  bool dark = true,
  double scale = 1,
}) => ChangeNotifierProvider.value(
  value: vm,
  child: MaterialApp(
    theme: dark ? buildDarkTheme() : buildLightTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: AgentsPage(target: AgentsTarget('peer', room, 'Laptop', 'Project')),
  ),
);

bool canStart(WidgetTester tester) {
  final button = find.widgetWithText(FilledButton, 'Start agent');
  return button.evaluate().isNotEmpty &&
      tester.widget<FilledButton>(button).onPressed != null;
}

Future<void> openRunning(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Agent options'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Started here'));
  await tester.pumpAndSettle();
}

LauncherStatus locked({bool configured = true, String epoch = 'epoch-1'}) =>
    LauncherStatus(
      launcherId: 'launcher-1',
      launcherApi: 3,
      epoch: epoch,
      configured: configured,
      unlocked: false,
      expiresAt: null,
      cooldownUntil: 0,
    );

class _UnlockRepo extends Repo {
  int unlocks = 0;
  @override
  Future<void> unlock(String pin) async {
    if (pin.length < 6) throw const AgentFailure('PIN must be 6–12 digits.');
    unlocks++;
    security = LauncherStatus(
      launcherId: security.launcherId,
      launcherApi: 3,
      epoch: 'unlocked-epoch',
      configured: true,
      unlocked: true,
      expiresAt: DateTime.now().millisecondsSinceEpoch + 600000,
      cooldownUntil: 0,
    );
  }
}

const initialSetup = LauncherStatus(
  launcherId: 'launcher-1',
  launcherApi: 3,
  epoch: 'epoch-1',
  configured: false,
  unlocked: false,
  expiresAt: null,
  cooldownUntil: 0,
  pinSetup: PinSetup.available,
);

class _SetupRepo extends _UnlockRepo {
  _SetupRepo() {
    security = initialSetup;
  }
  int setups = 0, statuses = 0;
  bool loseReply = false, grant = false;
  @override
  Future<void> initializePin(String pin) async {
    setups++;
    security = LauncherStatus(
      launcherId: 'launcher-1',
      launcherApi: 3,
      epoch: 'created',
      configured: true,
      unlocked: grant,
      expiresAt: grant ? DateTime.now().millisecondsSinceEpoch + 600000 : null,
      cooldownUntil: 0,
      pinSetup: PinSetup.configured,
    );
    if (loseReply) {
      throw const AgentFailure(
        'Setup result unknown. Refresh status.',
        outcomeUnknown: true,
      );
    }
  }

  @override
  Future<void> status() async {
    statuses++;
  }
}

void main() {
  testWidgets('explicit API 2 session keeps controls but has no new Start', (
    tester,
  ) async {
    final repo = Repo()
      ..security = LauncherStatus(
        launcherId: 'launcher-1',
        epoch: 'epoch-1',
        configured: true,
        unlocked: true,
        expiresAt: DateTime.now().millisecondsSinceEpoch + 600000,
        cooldownUntil: 0,
        launcherApi: 2,
      );
    final vm = AgentsViewModel(repo);
    await tester.pumpWidget(page(vm));
    await tester.pumpAndSettle();
    expect(find.text(newLaunchCompatibilityMessage), findsOneWidget);
    expect(find.byKey(const Key('launch-agent')), findsNothing);
    await vm.launch('project', null, confirmed: true);
    expect(repo.launches, 0);
    await openRunning(tester);
    expect(find.text('New Pi'), findsOneWidget);
    expect(repo.stops, 0);
    await tester.pumpWidget(const SizedBox());
    vm.dispose();
  });

  testWidgets(
    'Create keyboard Next and Done unlock once without retaining PIN',
    (tester) async {
      final repo = _SetupRepo()..grant = true;
      final vm = AgentsViewModel(repo);
      await tester.pumpWidget(page(vm));
      await tester.pumpAndSettle();
      final first = find.byKey(const Key('launcher-create-pin'));
      final second = find.byKey(const Key('launcher-confirm-pin'));
      expect(find.text('Session: Project'), findsOneWidget);
      expect(find.text('Create PIN & unlock'), findsOneWidget);
      expect(
        tester.widget<TextField>(first).keyboardType,
        TextInputType.number,
      );
      expect(tester.widget<TextField>(first).autofillHints, isEmpty);
      expect(
        tester.widget<TextField>(first).enableIMEPersonalizedLearning,
        false,
      );
      expect(tester.widget<TextField>(first).obscureText, true);
      final a = tester.widget<TextField>(first).controller!;
      final b = tester.widget<TextField>(second).controller!;
      await tester.enterText(first, '123456');
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pump();
      expect(tester.widget<TextField>(second).focusNode!.hasFocus, true);
      await tester.enterText(second, '1');
      await tester.pump();
      expect(find.text('PINs do not match.'), findsNothing);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(repo.setups, 0);
      expect(find.text('PINs do not match.'), findsOneWidget);
      await tester.enterText(second, '123456');
      await tester.pump();
      expect(find.text('PINs do not match.'), findsNothing);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(a.text, isEmpty);
      expect(b.text, isEmpty);
      expect(repo.setups, 1);
      expect(repo.unlocks, 0);
      expect(find.byKey(const Key('launch-project-project')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      vm.dispose();
    },
  );

  testWidgets('Show PIN resets masked and empty on background', (tester) async {
    final repo = _SetupRepo();
    final vm = AgentsViewModel(repo);
    await tester.pumpWidget(page(vm));
    await tester.pumpAndSettle();
    final first = find.byKey(const Key('launcher-create-pin'));
    await tester.enterText(first, '123456');
    await tester.tap(find.byTooltip('Show PIN').first);
    await tester.pump();
    expect(tester.widget<TextField>(first).obscureText, false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(tester.widget<TextField>(first).obscureText, true);
    expect(tester.widget<TextField>(first).controller!.text, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
    vm.dispose();
  });

  testWidgets(
    'cooldown counts down, disables input, and re-enables without refresh',
    (tester) async {
      final repo = _UnlockRepo();
      repo.security = LauncherStatus(
        launcherId: 'launcher-1',
        launcherApi: 3,
        epoch: 'epoch-1',
        configured: true,
        unlocked: false,
        expiresAt: null,
        cooldownUntil: DateTime.now().millisecondsSinceEpoch + 1050,
      );
      final vm = AgentsViewModel(repo);
      await tester.pumpWidget(page(vm));
      await tester.pump();
      await tester.pump();
      final field = find.byKey(const Key('launcher-pin'));
      expect(tester.widget<TextField>(field).enabled, false);
      expect(find.textContaining('Try again in'), findsOneWidget);
      tester.widget<TextField>(field).onSubmitted!('123456');
      expect(repo.unlocks, 0);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1100)),
      );
      await tester.pump(const Duration(seconds: 2));
      expect(tester.widget<TextField>(field).enabled, true);
      expect(find.textContaining('Try again in'), findsNothing);
      await tester.enterText(field, '123456');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(repo.unlocks, 1);
      await tester.pumpWidget(const SizedBox());
      vm.dispose();
    },
  );

  testWidgets(
    'running launch connects then navigates only to exact returned room',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = Repo()..connecting = Completer<void>();
      final vm = AgentsViewModel(repo);
      final selection = SessionSelection();
      final router = GoRouter(
        initialLocation: '/agents',
        routes: [
          GoRoute(
            path: '/agents',
            builder: (_, _) => const AgentsPage(
              target: AgentsTarget(
                'original-peer',
                'launcher-room',
                'Laptop',
                'Launcher session',
              ),
            ),
          ),
          GoRoute(
            path: '/home',
            builder: (_, _) => const Scaffold(body: Text('Home')),
          ),
          GoRoute(
            path: '/chat',
            builder: (_, _) => const Scaffold(body: Text('Exact chat')),
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
      await selectProject(tester);
      await tester.tap(find.byKey(const Key('launch-agent')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Connecting…'), findsOneWidget);
      expect(selection.current, null);
      expect(find.text('Exact chat'), findsNothing);
      expect(repo.launches, 1);
      repo.connecting!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Exact chat'), findsOneWidget);
      expect(selection.current?.epk, 'original-peer');
      expect(selection.current?.roomId, 'new-room');
      expect(repo.opened?.roomId, 'new-room');
      await tester.pumpWidget(const SizedBox());
      router.dispose();
      selection.dispose();
      vm.dispose();
    },
  );

  testWidgets(
    'Create PIN validates locally, clears both, then ordinary unlock and project confirmation',
    (tester) async {
      final repo = _SetupRepo();
      final vm = AgentsViewModel(repo);
      await tester.pumpWidget(page(vm));
      await tester.pumpAndSettle();
      final first = find.byKey(const Key('launcher-create-pin'));
      final second = find.byKey(const Key('launcher-confirm-pin'));
      final submit = find.byKey(const Key('create-launcher-pin'));
      final a = tester.widget<TextField>(first).controller!;
      final b = tester.widget<TextField>(second).controller!;
      bool enabled() => tester.widget<FilledButton>(submit).onPressed != null;
      await tester.enterText(first, '12345');
      await tester.enterText(second, '12345');
      await tester.pump();
      expect(enabled(), false);
      await tester.enterText(first, '123456');
      await tester.enterText(second, '654321');
      await tester.pump();
      expect(enabled(), false);
      expect(find.text('PINs do not match.'), findsOneWidget);
      await tester.enterText(first, '1234567890123');
      expect(a.text.length, 12);
      await tester.enterText(first, '123456');
      await tester.enterText(second, '123456');
      await tester.pump();
      expect(enabled(), true);
      expect(repo.setups, 0);
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      expect(a.text, isEmpty);
      expect(b.text, isEmpty);
      await tester.pumpAndSettle();
      expect(repo.setups, 1);
      expect(repo.unlocks, 0);
      expect(find.text('Unlock'), findsOneWidget);
      expect(find.byType(RadioListTile<String>), findsNothing);
      await tester.enterText(find.byKey(const Key('launcher-pin')), '123456');
      await tester.pump();
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(repo.unlocks, 1);
      await selectProject(tester);
      await tester.tap(find.byKey(const Key('launch-agent')));
      await tester.pumpAndSettle();
      expect(find.text('Start agent?'), findsOneWidget);
      expect(repo.launches, 0);
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      expect(repo.launches, 1);
      await tester.pumpWidget(const SizedBox());
      vm.dispose();
    },
  );

  for (final cause in [
    'inactive',
    'target',
    'reload',
    'expiry',
    'disconnect',
    'refresh',
    'owner',
    'dispose',
  ]) {
    testWidgets('both setup inputs clear on $cause', (tester) async {
      final repo = _SetupRepo();
      final vm = AgentsViewModel(repo);
      await tester.pumpWidget(page(vm));
      await tester.pumpAndSettle();
      final first = find.byKey(const Key('launcher-create-pin'));
      final second = find.byKey(const Key('launcher-confirm-pin'));
      final a = tester.widget<TextField>(first).controller!;
      final b = tester.widget<TextField>(second).controller!;
      await tester.enterText(first, '123456');
      await tester.enterText(second, '123456');
      switch (cause) {
        case 'inactive':
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        case 'target':
          await tester.pumpWidget(page(vm, room: 'other'));
        case 'dispose':
          await tester.pumpWidget(const SizedBox());
        case 'owner':
          final replacement = AgentsViewModel(_SetupRepo());
          await tester.pumpWidget(page(replacement));
          await tester.pumpAndSettle();
          replacement.dispose();
        case 'disconnect':
        case 'expiry':
          repo.invalid.add(null);
        case 'reload':
          repo.security = const LauncherStatus(
            launcherId: 'launcher-2',
            launcherApi: 3,
            epoch: 'new',
            configured: false,
            unlocked: false,
            expiresAt: null,
            cooldownUntil: 0,
            pinSetup: PinSetup.available,
          );
          await vm.refresh();
        case 'refresh':
          await vm.refresh();
      }
      await tester.pumpAndSettle();
      expect(a.text, isEmpty);
      expect(b.text, isEmpty);
      expect(repo.setups, 0);
      await tester.pumpWidget(const SizedBox());
      vm.dispose();
    });
  }

  testWidgets(
    'lost setup reconciles status only, never automatically unlocks or replays',
    (tester) async {
      final repo = _SetupRepo()..loseReply = true;
      final vm = AgentsViewModel(repo);
      await tester.pumpWidget(page(vm));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('launcher-create-pin')),
        '123456',
      );
      await tester.enterText(
        find.byKey(const Key('launcher-confirm-pin')),
        '123456',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('create-launcher-pin')));
      await tester.pumpAndSettle();
      expect(repo.setups, 1);
      expect(repo.statuses, 1);
      expect(repo.unlocks, 0);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('launcher-pin')))
            .controller!
            .text,
        isEmpty,
      );
      await vm.refresh();
      await tester.pumpAndSettle();
      expect(repo.setups, 1);
      await tester.pumpWidget(const SizedBox());
      vm.dispose();
    },
  );

  testWidgets('unsafe storage offers local repair, never remote overwrite', (
    tester,
  ) async {
    final repo = _SetupRepo()
      ..security = const LauncherStatus(
        launcherId: 'launcher-1',
        launcherApi: 3,
        epoch: 'epoch-1',
        configured: false,
        unlocked: false,
        expiresAt: null,
        cooldownUntil: 0,
        pinSetup: PinSetup.unavailable,
      );
    final vm = AgentsViewModel(repo);
    await tester.pumpWidget(page(vm));
    await tester.pumpAndSettle();
    expect(find.textContaining('repair it locally'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const Key('create-launcher-pin')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    vm.dispose();
  });

  for (final scale in [1.0, 2.0]) {
    for (final dark in [true, false]) {
      testWidgets(
        'project list has one clear action at 320px/${scale}x/dark=$dark',
        (tester) async {
          tester.view.physicalSize = const Size(320, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final vm = AgentsViewModel(Repo());
          await tester.pumpWidget(page(vm, dark: dark, scale: scale));
          await tester.pumpAndSettle();
          expect(find.text('Host: Laptop'), findsOneWidget);
          expect(find.byType(RadioListTile<String>), findsOneWidget);
          expect(find.byType(TextField), findsNothing);
          expect(find.text('Managed agents'), findsNothing);
          expect(find.text('Lock'), findsNothing);
          expect(find.text('Stop all and lock'), findsNothing);
          expect(find.widgetWithText(TextButton, 'Refresh'), findsNothing);
          expect(canStart(tester), isFalse);
          await selectProject(tester);
          expect(canStart(tester), isTrue);
          final start = find.widgetWithText(FilledButton, 'Start agent');
          await tester.ensureVisible(start);
          await tester.pumpAndSettle();
          expect(
            tester.getRect(start).top -
                tester.getRect(find.byType(RadioGroup<String>)).bottom,
            AppSpacing.md,
          );
          expect(
            tester.getSize(start).height,
            greaterThanOrEqualTo(AppSpacing.tap),
          );
          expect(tester.getRect(start).left, AppSpacing.md);
          expect(tester.getRect(start).right, 320 - AppSpacing.md);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          vm.dispose();
        },
      );
    }
  }

  testWidgets('missing host PIN is setup, not a disabled unlock/project form', (
    tester,
  ) async {
    final repo = Repo()..security = locked(configured: false);
    final vm = AgentsViewModel(repo);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(page(vm));
    await tester.pumpAndSettle();
    expect(find.text('Host setup required'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(RadioListTile<String>), findsNothing);
    expect(find.text('Unlock'), findsNothing);
    expect(canStart(tester), isFalse);
    await tester.tap(find.byKey(const Key('copy-launcher-setup')));
    await tester.pump();
    expect(copied, 'remote-pi-launcher pin-setup');
    repo.security = locked();
    await vm.refresh();
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byKey(const Key('launcher-pin'))).enabled,
      isTrue,
    );
    expect(find.byType(RadioListTile<String>), findsNothing);
    await tester.pumpWidget(const SizedBox());
    vm.dispose();
  });

  testWidgets(
    'configured PIN is editable and unlock reveals approved projects',
    (tester) async {
      final repo = _UnlockRepo()..security = locked();
      final vm = AgentsViewModel(repo);
      await tester.pumpWidget(page(vm));
      await tester.pumpAndSettle();
      final pin = find.byKey(const Key('launcher-pin'));
      final controller = tester.widget<TextField>(pin).controller!;
      expect(tester.widget<TextField>(pin).enabled, isTrue);
      expect(tester.widget<TextField>(pin).obscureText, isTrue);
      expect(tester.widget<TextField>(pin).autofillHints, isEmpty);
      expect(find.byType(RadioListTile<String>), findsNothing);
      await tester.enterText(pin, '123456');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
      await tester.pumpAndSettle();
      expect(repo.unlocks, 1);
      expect(controller.text, isEmpty);
      expect(find.byKey(const Key('launcher-pin')), findsNothing);
      expect(find.text('Registered project'), findsOneWidget);
      await selectProject(tester);
      expect(canStart(tester), isTrue);
      await tester.pumpWidget(const SizedBox());
      vm.dispose();
    },
  );

  testWidgets('PIN clears on background, disposal and target replacement', (
    tester,
  ) async {
    final repo = Repo()..security = locked();
    final vm = AgentsViewModel(repo);
    await tester.pumpWidget(page(vm));
    await tester.pumpAndSettle();
    final pin = find.byKey(const Key('launcher-pin'));
    final controller = tester.widget<TextField>(pin).controller!;
    await tester.enterText(pin, '123456');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(controller.text, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.enterText(pin, '123456');
    await tester.pumpWidget(page(vm, room: 'other'));
    await tester.pumpAndSettle();
    expect(controller.text, isEmpty);
    expect(vm.state.invalid, isTrue);
    expect(canStart(tester), isFalse);
    expect(find.byType(RadioListTile<String>), findsNothing);
    await tester.pumpWidget(const SizedBox());
    vm.dispose();
  });

  testWidgets('changed project access or host epoch clears selection', (
    tester,
  ) async {
    final repo = Repo();
    final vm = AgentsViewModel(repo);
    await tester.pumpWidget(page(vm));
    await tester.pumpAndSettle();
    await selectProject(tester);
    expect(canStart(tester), isTrue);
    repo.projectCatalog = const [
      LauncherProject('project', 'Registered project', '/project', [
        '/different',
      ]),
    ];
    await vm.refresh();
    await tester.pumpAndSettle();
    expect(canStart(tester), isFalse);
    expect(
      tester
          .widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
          .groupValue,
      isNull,
    );
    await selectProject(tester);
    repo.security = LauncherStatus(
      launcherId: 'launcher-1',
      launcherApi: 3,
      epoch: 'epoch-2',
      configured: true,
      unlocked: true,
      expiresAt: DateTime.now().millisecondsSinceEpoch + 600000,
      cooldownUntil: 0,
    );
    await vm.refresh();
    await tester.pumpAndSettle();
    expect(canStart(tester), isFalse);
    await tester.pumpWidget(const SizedBox());
    vm.dispose();
  });

  testWidgets('start confirms project/access/lifetime without optional name', (
    tester,
  ) async {
    final repo = Repo();
    final vm = AgentsViewModel(repo);
    await tester.pumpWidget(page(vm));
    await tester.pumpAndSettle();
    await selectProject(tester);
    expect(find.text('Name (optional)'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Start agent'));
    await tester.pumpAndSettle();
    expect(find.textContaining('/project'), findsWidgets);
    expect(find.textContaining('Access: /shared'), findsOneWidget);
    expect(find.textContaining('launcher closes or reloads'), findsOneWidget);
    expect(repo.launches, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(repo.launches, 0);
    await tester.tap(find.widgetWithText(FilledButton, 'Start agent'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Start'));
    await tester.pumpAndSettle();
    expect(repo.launches, 1);
    expect(find.text('Managed agents'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    vm.dispose();
  });

  testWidgets(
    'management is separate; failed owned agent has confirmed cleanup retry',
    (tester) async {
      final repo = Repo()
        ..availability = const AgentAvailability(
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
      await tester.pumpWidget(page(vm));
      await tester.pumpAndSettle();
      expect(find.text('Stop'), findsNothing);
      await openRunning(tester);
      expect(find.text('Failed Pi'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Stop'));
      await tester.pumpAndSettle();
      expect(find.text('Stop agent?'), findsOneWidget);
      expect(repo.stops, 0);
      await tester.tap(find.widgetWithText(FilledButton, 'Stop'));
      await tester.pumpAndSettle();
      expect(repo.stops, 1);
      expect(repo.shutdowns, 0);
      await tester.pumpWidget(const SizedBox());
      vm.dispose();
    },
  );

  testWidgets('Lock access is secondary and never stops processes', (
    tester,
  ) async {
    final repo = Repo();
    final vm = AgentsViewModel(repo);
    await tester.pumpWidget(page(vm));
    await tester.pumpAndSettle();
    expect(find.text('Lock access'), findsNothing);
    await tester.tap(find.byTooltip('Agent options'));
    await tester.pumpAndSettle();
    expect(find.text('Stop all and lock'), findsNothing);
    await tester.tap(find.text('Lock access'));
    await tester.pumpAndSettle();
    expect(repo.locks, 1);
    expect(repo.shutdowns, 0);
    expect(repo.stops, 0);
    expect(find.byKey(const Key('launcher-pin')), findsOneWidget);
    expect(find.byType(RadioListTile<String>), findsNothing);
    await tester.pumpWidget(const SizedBox());
    vm.dispose();
  });

  testWidgets(
    'unknown start needs reconciliation and explicit duplicate-risk confirmation',
    (tester) async {
      final repo = Repo();
      final vm = AgentsViewModel(repo);
      await tester.pumpWidget(page(vm));
      await tester.pumpAndSettle();
      await selectProject(tester);
      repo.pending = Completer<ManagedAgent>();
      final launch = vm.launch('project', null, confirmed: true);
      repo.pending!.completeError(
        const AgentFailure('Timed out', outcomeUnknown: true),
      );
      await launch;
      await tester.pumpAndSettle();
      expect(canStart(tester), isFalse);
      repo.listFails = true;
      await vm.refresh();
      await tester.pumpAndSettle();
      expect(canStart(tester), isFalse);
      repo.listFails = false;
      await vm.refresh();
      await tester.pumpAndSettle();
      expect(canStart(tester), isTrue);
      await tester.tap(find.widgetWithText(FilledButton, 'Start agent'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Starting another may create a second agent'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repo.launches, 1);
      await tester.pumpWidget(const SizedBox());
      vm.dispose();
    },
  );

  testWidgets('unavailable and empty catalogs have no dead creation fields', (
    tester,
  ) async {
    final repo = Repo()
      ..availability = const AgentAvailability(
        available: false,
        reason: 'Not allowed',
        cwd: '/p',
        maxAgents: 4,
        agents: [],
      );
    final vm = AgentsViewModel(repo);
    await tester.pumpWidget(page(vm));
    await tester.pumpAndSettle();
    expect(find.text('Not allowed'), findsOneWidget);
    expect(find.byType(RadioListTile<String>), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Start agent'), findsNothing);
    repo.availability = const AgentAvailability(
      available: true,
      cwd: '/p',
      maxAgents: 4,
      agents: [],
    );
    repo.projectCatalog = [];
    await vm.refresh();
    await tester.pumpAndSettle();
    expect(find.text('No approved projects on this PC.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Start agent'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    vm.dispose();
  });
}
