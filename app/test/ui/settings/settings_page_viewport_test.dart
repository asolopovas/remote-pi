import 'dart:ui' show Tristate;

import 'package:app/config/dependencies.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/settings/settings_page.dart';
import 'package:app/ui/settings/settings_sheet.dart';
import 'package:app/ui/settings/viewmodels/settings_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

class _PairingStorage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => List.generate(
    20,
    (i) => PeerRecord(
      remoteEpk: 'peer-$i',
      sessionName: 'Peer $i',
      relayUrl: 'ws://example',
      pairedAt: 'today',
    ),
  );
}

class _SecureStorage implements FlutterSecureStorage {
  final values = <String, String>{};
  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(() async {
    // Use incumbent type metrics rather than Ahem for responsive layout.
    final font = FontLoader(kMonoFamily)
      ..addFont(
        rootBundle.load('assets/fonts/fira_mono/FiraMonoNerdFont-Regular.otf'),
      );
    await font.load();
  });

  for (final initial in [true, false]) {
    testWidgets(
      'Settings wrap switch reflects saved $initial and persists at 320px/2x',
      (tester) async {
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final semantics = tester.ensureSemantics();
        try {
          final store = _SecureStorage()
            ..values['prefs.wrap_text_by_default'] = '$initial';
          final prefs = Preferences(store);
          await prefs.load();
          final storage = _PairingStorage();
          final conn = ConnectionManager(
            storage: storage,
            factory: (_, _) async =>
                throw StateError('No transport in fixture'),
          );
          final vm = SettingsViewModel(storage, prefs, conn);
          addTearDown(vm.dispose);
          addTearDown(prefs.dispose);
          Widget page(Preferences value) => MultiProvider(
            providers: [
              ChangeNotifierProvider<Preferences>.value(value: value),
              ChangeNotifierProvider<SettingsViewModel>.value(value: vm),
            ],
            child: MaterialApp(
              theme: buildDarkTheme(),
              home: const SettingsPage(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
            ),
          );
          await tester.pumpWidget(page(prefs));
          await tester.pumpAndSettle();
          final tile = find.widgetWithText(
            SwitchListTile,
            'Wrap text by default',
          );
          await tester.scrollUntilVisible(
            tile,
            180,
            scrollable: find.byType(Scrollable).last,
          );
          await tester.pumpAndSettle();
          expect(tester.widget<SwitchListTile>(tile).value, initial);
          await tester.ensureVisible(tile);
          await tester.pumpAndSettle();
          final node = tester.getSemantics(tile);
          expect(node.label, contains('Wrap text by default'));
          final flags = node.getSemanticsData().flagsCollection;
          expect(flags.isToggled, initial ? Tristate.isTrue : Tristate.isFalse);
          await tester.tap(tile);
          await tester.pumpAndSettle();
          expect(tester.widget<SwitchListTile>(tile).value, !initial);
          expect(store.values['prefs.wrap_text_by_default'], '${!initial}');
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          final restored = Preferences(store);
          await restored.load();
          addTearDown(restored.dispose);
          await tester.pumpWidget(page(restored));
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            tile,
            180,
            scrollable: find.byType(Scrollable).last,
          );
          expect(tester.widget<SwitchListTile>(tile).value, !initial);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          conn.dispose();
        } finally {
          semantics.dispose();
        }
      },
    );
  }

  for (final (embedded, scale, keyboard) in [
    (false, 1.0, 0.0),
    (false, 2.0, 180.0),
    (true, 2.0, 180.0),
  ]) {
    testWidgets(
      '${embedded ? 'sheet' : 'phone'} pairing footer stays reachable at ${scale}x with keyboard $keyboard',
      (tester) async {
        final width = embedded ? 600.0 : 320.0;
        tester.view.physicalSize = Size(width, 540);
        tester.view.devicePixelRatio = 1;
        tester.view.viewPadding = const FakeViewPadding(bottom: 24);
        tester.view.padding = const FakeViewPadding(bottom: 24);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewPadding);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewInsets);
        final prefs = Preferences(_SecureStorage());
        final storage = _PairingStorage();
        final conn = ConnectionManager(
          storage: storage,
          factory: (_, _) async => throw StateError('No transport in fixture'),
        );
        final vm = SettingsViewModel(storage, prefs, conn);
        addTearDown(vm.dispose);
        addTearDown(prefs.dispose);
        if (embedded) {
          injector.addViewModel<SettingsViewModel>(
            () => SettingsViewModel(storage, prefs, conn),
          );
          injector.commit();
          addTearDown(injector.dispose);
        }
        final router = GoRouter(
          initialLocation: '/settings',
          routes: [
            GoRoute(
              path: '/settings',
              builder: (_, _) => embedded
                  ? Scaffold(
                      body: Builder(
                        builder: (context) => TextButton(
                          onPressed: () => showSettingsSheet(context),
                          child: const Text('Open settings'),
                        ),
                      ),
                    )
                  : ChangeNotifierProvider<SettingsViewModel>.value(
                      value: vm,
                      child: const SettingsPage(),
                    ),
            ),
            GoRoute(
              path: '/pair',
              builder: (_, _) => const Scaffold(body: Text('Pair route')),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ChangeNotifierProvider<Preferences>.value(
            value: prefs,
            child: MaterialApp.router(
              theme: buildDarkTheme(),
              routerConfig: router,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (embedded) {
          await tester.tap(find.text('Open settings'));
          await tester.pumpAndSettle();
          expect(
            tester.widget<SettingsPage>(find.byType(SettingsPage)).embedded,
            isTrue,
          );
        }
        if (keyboard > 0) {
          // Focus the real Relay field, then model the platform IME metrics.
          await tester.tap(find.byType(TextField));
          tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
          tester.view.padding = const FakeViewPadding();
          await tester.pumpAndSettle();
        }
        final cta = find.widgetWithText(OutlinedButton, 'Add new pairing');
        expect(cta, findsOneWidget);
        expect(cta.hitTestable(), findsOneWidget);
        expect(tester.getSize(cta).height, greaterThanOrEqualTo(48));
        final position = tester.getRect(cta);
        expect(position.left, greaterThanOrEqualTo(0));
        expect(position.right, lessThanOrEqualTo(width));
        expect(
          position.bottom,
          lessThanOrEqualTo(540 - keyboard - (keyboard == 0 ? 24 : 0)),
        );
        final list = find.byType(ListView);
        expect(tester.getRect(list).bottom, lessThanOrEqualTo(position.top));
        expect(tester.takeException(), isNull);
        final scroll = tester
            .state<ScrollableState>(
              find
                  .descendant(of: list, matching: find.byType(Scrollable))
                  .first,
            )
            .position;
        await tester.drag(list, const Offset(0, -250));
        await tester.pumpAndSettle();
        expect(scroll.pixels, greaterThan(0));
        scroll.jumpTo(scroll.maxScrollExtent);
        await tester.pumpAndSettle();
        // The lazy ListView learns the full peer-column extent after layout.
        scroll.jumpTo(scroll.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(find.text('Peer 19').hitTestable(), findsOneWidget);
        expect(tester.getRect(cta), position);
        await tester.tap(cta);
        await tester.pumpAndSettle();
        expect(find.text('Pair route').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        conn.dispose();
      },
    );
  }
}
