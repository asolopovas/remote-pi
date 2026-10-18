import 'package:app/ui/chat/widgets/code_viewport.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));
Widget code(String text, {Key? key}) =>
    CodeViewport(key: key, label: 'dart', text: text, child: Text(text));
void main() {
  for (final defaultWrap in [true, false]) {
    testWidgets(
      'saved $defaultWrap default follows preference until local choice',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({
          'prefs.wrap_text_by_default': '$defaultWrap',
        });
        final prefs = Preferences();
        await prefs.load();
        addTearDown(prefs.dispose);
        Future<void> pumpBlock(String identity) => tester.pumpWidget(
          ChangeNotifierProvider<Preferences>.value(
            value: prefs,
            child: wrap(
              code('original bytes\n  remain', key: ValueKey(identity)),
            ),
          ),
        );
        await pumpBlock('first');
        await tester.tap(find.byKey(const Key('code-disclosure')));
        await tester.pump();
        expect(
          find.byTooltip(defaultWrap ? 'Scroll horizontally' : 'Wrap code'),
          findsOneWidget,
        );
        // Disclosure is a keepalive choice, not a local wrap override.
        await prefs.setWrapTextByDefault(!defaultWrap);
        await tester.pump();
        expect(
          find.byTooltip(defaultWrap ? 'Wrap code' : 'Scroll horizontally'),
          findsOneWidget,
        );
        expect(find.text('original bytes\n  remain'), findsOneWidget);
        await tester.tap(find.byKey(const Key('code-wrap')));
        await tester.pump();
        expect(
          find.byTooltip(defaultWrap ? 'Scroll horizontally' : 'Wrap code'),
          findsOneWidget,
        );
        await prefs.setWrapTextByDefault(defaultWrap);
        await prefs.setWrapTextByDefault(!defaultWrap);
        await tester.pump();
        expect(
          find.byTooltip(defaultWrap ? 'Scroll horizontally' : 'Wrap code'),
          findsOneWidget,
        );
        await pumpBlock('new identity');
        await tester.tap(find.byKey(const Key('code-disclosure')));
        await tester.pump();
        expect(
          find.byTooltip(defaultWrap ? 'Wrap code' : 'Scroll horizontally'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'nested composite saved scroll default at 320px/2x, live wrap and copy',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      FlutterSecureStorage.setMockInitialValues({
        'prefs.wrap_text_by_default': 'false',
      });
      final prefs = Preferences();
      await prefs.load();
      addTearDown(prefs.dispose);
      final text = '  original\tbytes\n${'long output ' * 30}';
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
      await tester.pumpWidget(
        ChangeNotifierProvider<Preferences>.value(
          value: prefs,
          child: wrap(
            MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: ListView(
                children: [
                  CodeViewport(
                    text: text,
                    bodyWrapWidth: 300,

                    child: SizedBox(
                      width: 300,
                      child: CodeViewport(text: text, child: Text(text)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('code-disclosure')).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('code-disclosure')).last);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Wrap code'), findsNWidgets(2));
      final horizontal = find.byWidgetPredicate(
        (widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal,
      );
      final innerScroll = tester
          .widget<SingleChildScrollView>(horizontal.last)
          .controller!;
      innerScroll.jumpTo(80);
      await tester.pump();
      await tester.tap(find.byKey(const Key('code-copy')).last);
      await tester.pump();
      expect(copied, text);
      // Copy also leaves the viewport following the saved default.
      await prefs.setWrapTextByDefault(true);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Scroll horizontally'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await prefs.setWrapTextByDefault(false);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Wrap code'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'optional composite wrap width rejects nonpositive and nonfinite values',
    () {
      for (final width in [
        0.0,
        -1.0,
        double.infinity,
        double.negativeInfinity,
        double.nan,
      ]) {
        expect(
          () => CodeViewport(
            text: '',
            bodyWrapWidth: width,
            child: const SizedBox(),
          ),
          throwsAssertionError,
        );
      }
      expect(
        const CodeViewport(
          text: '',
          bodyWrapWidth: 320,
          child: SizedBox(),
        ).bodyWrapWidth,
        320,
      );
    },
  );
  testWidgets(
    'exact title/count, default wrapping, streaming updates and full clipboard',
    (tester) async {
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
      await tester.pumpWidget(wrap(code('one\ntwo')));
      expect(find.text('dart · 2 lines'), findsOneWidget);
      expect(find.text('one\ntwo'), findsNothing);
      await tester.tap(find.text('dart · 2 lines'));
      await tester.pump();
      expect(find.byTooltip('Scroll horizontally'), findsOneWidget);
      expect(find.byType(SingleChildScrollView), findsNothing);
      await tester.tap(find.byKey(const Key('code-wrap')));
      await tester.pump();
      expect(find.byTooltip('Wrap code'), findsOneWidget);
      await tester.pumpWidget(wrap(code('one\ntwo\nthree')));
      expect(find.text('dart · 3 lines'), findsOneWidget);
      expect(find.text('one\ntwo\nthree'), findsOneWidget);
      expect(find.byTooltip('Wrap code'), findsOneWidget);
      await tester.tap(find.byKey(const Key('code-copy')));
      await tester.pump();
      expect(copied, 'one\ntwo\nthree');
      expect(find.text('one\ntwo\nthree'), findsOneWidget);
      await tester.tap(find.text('dart · 3 lines'));
      await tester.pump();
      expect(find.text('one\ntwo\nthree'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'lazy list preserves toggles, releases untouched defaults and scopes identity',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      String scope = 'peer1/session1';
      Future<void> pump() => tester.pumpWidget(
        wrap(
          ListView.builder(
            key: ValueKey(scope),
            controller: scroll,
            scrollCacheExtent: const ScrollCacheExtent.pixels(0),
            itemCount: 60,
            itemBuilder: (_, index) => SizedBox(
              height: 160,
              child: code('body $index', key: ValueKey(index)),
            ),
          ),
        ),
      );
      await pump();
      await tester.tap(find.byKey(const Key('code-disclosure')).first);
      await tester.pump();
      await tester.tap(find.byKey(const Key('code-wrap')).first);
      await tester.pump();
      final untouched = tester.state(find.byType(CodeViewport).at(1));
      scroll.jumpTo(5000);
      await tester.pumpAndSettle();
      expect(
        untouched.mounted,
        isFalse,
        reason: 'default wrapped bodies must not pin lazy rows',
      );
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.text('body 0'), findsOneWidget);
      expect(find.byTooltip('Wrap code'), findsOneWidget);
      scope = 'peer2/session1';
      await pump();
      expect(find.text('body 0'), findsNothing);
      await tester.tap(find.byKey(const Key('code-disclosure')).first);
      await tester.pump();
      scope = 'peer2/session2';
      await pump();
      expect(find.text('body 0'), findsNothing);
    },
  );
  testWidgets(
    'narrow large text controls do not consume disclosure/title width',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        wrap(
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: ListView(children: [code('long line ' * 60)]),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('code-disclosure')));
      await tester.pump();
      expect(find.byTooltip('Scroll horizontally'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
