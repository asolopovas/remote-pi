import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/tool_request_card.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(
    body: child is ScrollView ? child : SingleChildScrollView(child: child),
  ),
);

const _bashTool = ToolEvent(
  id: 'tc1',
  toolCallId: 'tc1',
  tool: 'Bash',
  args: {'command': 'ls -la'},
);

const _editToolWithHunk = ToolEvent(
  id: 'tc2',
  toolCallId: 'tc4',
  tool: 'edit',
  args: {
    'path': 'app/test/ui/chat/tool_request_card_test.dart',
    'hunks': [
      {
        'lines': [
          {'kind': 'context', 'oldLine': 16, 'newLine': 16, 'text': 'args: {'},
          {'kind': 'remove', 'oldLine': 17, 'text': "  tool: 'Edit',"},
          {'kind': 'add', 'newLine': 17, 'text': "  tool: 'edit',"},
          {'kind': 'context', 'oldLine': 18, 'newLine': 18, 'text': '},'},
        ],
      },
    ],
  },
);

void main() {
  testWidgets(
    'compact card keeps separate 48dp actions at narrow/scaled widths',
    (tester) async {
      for (final (width, scale) in [(320.0, 1.0), (400.0, 1.0), (320.0, 2.0)]) {
        await tester.binding.setSurfaceSize(Size(width, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: buildDarkTheme(),
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: ToolRequestCard(
                    key: ValueKey((width, scale)),
                    tool: _bashTool.copyWith(
                      status: ToolEventStatus.completed,
                      result: 'done',
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final disclosure = find.byKey(const Key('tool-disclosure'));
        final output = find.byTooltip('Copy output');
        expect(tester.getSize(disclosure).height, greaterThanOrEqualTo(48));
        expect(output, findsNothing); // Details/copy stay behind disclosure.
        if (scale == 1) {
          // One borderless 48dp activity row plus the 6dp outer margin.
          expect(tester.getSize(find.byType(ToolRequestCard)).height, 54);
        }
        await tester.tap(disclosure);
        await tester.pumpAndSettle();
        final source = find.byTooltip('Copy command');
        final wrap = find.byKey(const Key('code-wrap')).first;
        for (final target in [source, output, wrap]) {
          final size = tester.getSize(target);
          expect(size.width, greaterThanOrEqualTo(48));
          expect(size.height, greaterThanOrEqualTo(48));
        }
        expect(
          tester.getRect(source).overlaps(tester.getRect(output)),
          isFalse,
        );
        expect(tester.getRect(source).overlaps(tester.getRect(wrap)), isFalse);
        if (scale == 1) {
          for (final target in [output, source, wrap]) {
            expect(tester.getRect(target).top, tester.getRect(disclosure).top);
          }
          expect(tester.getSize(disclosure).height, 48);
        } else {
          expect(
            tester.getRect(source).top,
            greaterThanOrEqualTo(tester.getRect(disclosure).bottom),
          );
        }
        await tester.tap(wrap);
        await tester.pumpAndSettle();
        expect(find.byTooltip('Wrap code'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'multiline namespaced commands with metadata copy exact source, not wrapper',
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
      const source = 'if true; then\n  printf "literal \\n and \\t"\nfi\n';
      for (final name in [
        'Bash',
        'functions.bash',
        'mcp__tools__bash',
        'tools/powershell',
        'tools:PowerShell',
      ]) {
        await tester.pumpWidget(
          _wrap(
            ToolRequestCard(
              tool: ToolEvent(
                id: name,
                toolCallId: name,
                tool: name,
                args: const {
                  'command': source,
                  'timeout': 120,
                  'description': 'review only',
                },
                result: const {'raw': 'JSON output'},
                error: 'failed output',
              ),
            ),
          ),
        );
        expect(find.text(source), findsNothing);
        await tester.tap(find.byKey(const Key('tool-disclosure')));
        await tester.pump();
        expect(find.text(source), findsOneWidget);
        expect(find.textContaining('"timeout"'), findsNothing);
        expect(find.text('Output'), findsOneWidget);
        expect(find.text('Error'), findsOneWidget);
        expect(find.text('raw: JSON output'), findsOneWidget);
        await tester.tap(find.byTooltip('Copy command'));
        await tester.pump();
        expect(copied, source);
        expect(find.textContaining('Details ·'), findsNothing);
        expect(find.byTooltip('Copy full details'), findsNothing);
        expect(
          find.textContaining('"timeout": 120', findRichText: true),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets(
    'codemode and write render exact source with language; unknown shape stays raw',
    (tester) async {
      const source = 'const x = 42;\n  console.log("literal \\n", x);\n';
      for (final entry in {
        'functions.codemode': {'code': source, 'timeout': 30},
        'mcp__tools__write': {'path': 'src/file.ts', 'content': source},
        'write': {'path': 'notes.unknown', 'content': source},
      }.entries) {
        await tester.pumpWidget(
          _wrap(
            ToolRequestCard(
              tool: ToolEvent(
                id: entry.key,
                toolCallId: entry.key,
                tool: entry.key,
                args: entry.value,
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const Key('tool-disclosure')));
        await tester.pump();
        expect(find.text(source), findsOneWidget);
        expect(find.textContaining('"timeout"'), findsNothing);
        expect(
          find.text(
            entry.key.contains('codemode')
                ? 'Script · javascript'
                : entry.key == 'write'
                ? 'Source · text'
                : 'Source · typescript',
          ),
          findsOneWidget,
        );
      }
      for (final name in ['unknown', 'notbash', 'bash.extra']) {
        await tester.pumpWidget(
          _wrap(
            ToolRequestCard(
              tool: ToolEvent(
                id: name,
                toolCallId: name,
                tool: name,
                args: const {'command': source},
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const Key('tool-disclosure')));
        await tester.pump();
        expect(find.byTooltip('Copy command'), findsNothing);
        expect(find.textContaining('command: '), findsOneWidget);
      }
    },
  );

  testWidgets(
    'full write/edit args, result/error selection and full-content copy',
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
      for (final args in [
        {'path': 'file.txt', 'content': 'first line\nsecond line'},
        {
          'path': 'file.txt',
          'edits': [
            {'oldText': 'before', 'newText': 'after'},
          ],
        },
      ]) {
        final event = ToolEvent(
          id: args.keys.last,
          toolCallId: args.keys.last,
          tool: args.containsKey('content') ? 'write' : 'edit',
          args: args,
          status: ToolEventStatus.failed,
          result: 'full result\nnext result',
          error: 'full error',
        );
        await tester.pumpWidget(_wrap(ToolRequestCard(tool: event)));
        expect(find.byType(SelectionArea), findsNothing);
        await tester.tap(find.byKey(const Key('tool-disclosure')));
        await tester.pump();
        expect(
          find.textContaining(
            args.containsKey('content') ? 'second line' : '+ after',
          ),
          findsOneWidget,
        );
        expect(find.text('full result\nnext result'), findsOneWidget);
        expect(
          find.ancestor(
            of: find.text('✗ full error'),
            matching: find.byType(SelectionArea),
          ),
          findsOneWidget,
        );
        if (args.containsKey('content')) {
          await tester.tap(find.byKey(const Key('code-copy')).first);
          await tester.pump();
          expect(copied, args['content']);
        } else {
          await tester.tap(find.byTooltip('Copy full details'));
          await tester.pump();
          expect(copied, contains('after'));
          expect(copied, contains('full result\nnext result'));
          expect(copied, contains('full error'));
        }
        expect(find.textContaining('Details ·'), findsNothing);
        expect(find.byKey(ValueKey('tool-args-${event.id}')), findsNothing);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('malformed args remain available, safe fallback titles', (
    tester,
  ) async {
    for (final args in [
      null,
      42,
      ['raw'],
      {'command': 123},
      {
        'hunks': [
          {'lines': 4},
        ],
        'edits': 'raw edit',
      },
    ]) {
      await tester.pumpWidget(
        _wrap(
          ToolRequestCard(
            tool: ToolEvent(
              id: '$args',
              toolCallId: '$args',
              tool: 'Bash',
              args: args,
            ),
          ),
        ),
      );
      expect(find.text('Bash'), findsOneWidget);
      await tester.tap(find.byKey(const Key('tool-disclosure')));
      await tester.pump();
      expect(tester.takeException(), isNull);
      if (args is Map && args.containsKey('command')) {
        expect(find.textContaining('123'), findsOneWidget);
      }
    }
  });
  testWidgets(
    'lazy list and pending-to-done retain expansion/Scroll; identities reset',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      var event = _bashTool;
      String scope = 'peer1/session1';
      Future<void> pump() => tester.pumpWidget(
        _wrap(
          ListView.builder(
            key: ValueKey(scope),
            controller: scroll,
            scrollCacheExtent: const ScrollCacheExtent.pixels(0),
            itemCount: 50,
            itemBuilder: (_, i) => i == 0
                ? ToolRequestCard(key: const ValueKey('first'), tool: event)
                : SizedBox(
                    height: 150,
                    child: ToolRequestCard(
                      key: ValueKey(i),
                      tool: ToolEvent(
                        id: '$i',
                        toolCallId: '$i',
                        tool: 'read',
                        args: {'path': '$i'},
                      ),
                    ),
                  ),
          ),
        ),
      );
      await pump();
      await tester.tap(find.byKey(const Key('tool-disclosure')).first);
      await tester.pump();
      await tester.tap(find.byKey(const Key('code-wrap')).first);
      await tester.pump();
      event = event.copyWith(
        status: ToolEventStatus.completed,
        result: 'terminal output',
      );
      await pump();
      expect(find.text('terminal output'), findsOneWidget);
      final untouched = tester.state(find.byType(ToolRequestCard).at(1));
      scroll.jumpTo(4000);
      await tester.pumpAndSettle();
      expect(untouched.mounted, isFalse);
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.text('terminal output'), findsOneWidget);
      expect(find.byTooltip('Wrap code'), findsOneWidget);
      await tester.tap(find.byKey(const Key('tool-disclosure')).first);
      await tester.pump();
      scroll.jumpTo(4000);
      await tester.pumpAndSettle();
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.text('terminal output'), findsNothing);
      event = event.copyWith(
        status: ToolEventStatus.failed,
        error: 'late failure',
      );
      await pump();
      expect(find.byTooltip('FAILED'), findsOneWidget);
      expect(find.text('✗ late failure'), findsNothing);
      await tester.tap(find.byKey(const Key('tool-disclosure')).first);
      await tester.pump();
      expect(find.text('✗ late failure'), findsOneWidget);
      expect(find.byTooltip('Wrap code'), findsOneWidget);
      event = const ToolEvent(
        id: 'different',
        toolCallId: 'different',
        tool: 'Bash',
        args: {'command': 'different body'},
      );
      await pump();
      expect(find.text('different body'), findsNothing);
      await tester.tap(find.byKey(const Key('tool-disclosure')).first);
      await tester.pump();
      for (final next in ['peer2/session1', 'peer2/session2']) {
        scope = next;
        await pump();
        expect(find.text('different body'), findsNothing);
        await tester.tap(find.byKey(const Key('tool-disclosure')).first);
        await tester.pump();
      }
    },
  );
  testWidgets(
    '320px/2x header title and status remain usable, controls do not toggle',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _wrap(
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: ToolRequestCard(
              tool: ToolEvent(
                id: 'a',
                toolCallId: 'a',
                tool: 'Bash',
                args: {'command': 'long command ' * 20},
              ),
            ),
          ),
        ),
      );
      expect(
        tester.getSize(find.byKey(const Key('tool-disclosure'))).height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.textContaining('BASH ·'));
      await tester.pump();
      expect(find.byTooltip('RUNNING'), findsOneWidget);
      await tester.tap(find.byKey(const Key('code-wrap')));
      await tester.pump();
      expect(find.byTooltip('Wrap code'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  group('ToolRequestCard (informational)', () {
    testWidgets('shows tool name and command', (tester) async {
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: _bashTool)));
      expect(find.text('BASH · ls -la'), findsOneWidget);
      expect(find.text('ls -la'), findsNothing);
      await tester.tap(find.byKey(const Key('tool-disclosure')));
      await tester.pump();
      expect(find.text('ls -la'), findsOneWidget);
    });

    testWidgets('edit renders rich hunks with context lines', (tester) async {
      await tester.pumpWidget(
        _wrap(const ToolRequestCard(tool: _editToolWithHunk)),
      );
      expect(find.textContaining('args: {', findRichText: true), findsNothing);
      await tester.tap(find.byKey(const Key('tool-disclosure')));
      await tester.pump();

      expect(
        find.textContaining('   16 args: {', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining("-  17   tool: 'Edit',", findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining("+  17   tool: 'edit',", findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('   18 },', findRichText: true),
        findsOneWidget,
      );
      // The diff is the content: no nested duplicate raw metadata accordion.
      expect(find.textContaining('Details ·'), findsNothing);
      expect(find.textContaining('"oldLine"'), findsNothing);
      expect(find.byKey(const ValueKey('tool-args-tc2')), findsNothing);
    });

    testWidgets('pending state shows RUNNING and no Allow/Deny buttons', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: _bashTool)));
      expect(find.byTooltip('RUNNING'), findsOneWidget);
      expect(find.text('Allow'), findsNothing);
      expect(find.text('Deny'), findsNothing);
      expect(find.textContaining('s'), findsAny); // no '60s' countdown
      expect(find.textContaining('60s'), findsNothing);
    });

    testWidgets('completed state has named success icon, no visible DONE', (
      tester,
    ) async {
      const done = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'Bash',
        args: {'command': 'ls'},
        status: ToolEventStatus.completed,
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: done)));
      expect(find.byTooltip('DONE'), findsOneWidget);
      expect(find.text('DONE'), findsNothing);
      expect(find.text('✓ Done'), findsNothing);
    });

    testWidgets('denied state shows named DENIED icon', (tester) async {
      const denied = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'Bash',
        args: {'command': 'ls'},
        status: ToolEventStatus.denied,
        error: 'user denied',
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: denied)));
      expect(find.byTooltip('DENIED'), findsOneWidget);
    });

    testWidgets('allowed state shows RUNNING (still in flight)', (
      tester,
    ) async {
      const allowed = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'Bash',
        args: {'command': 'ls'},
        status: ToolEventStatus.allowed,
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: allowed)));
      expect(find.byTooltip('RUNNING'), findsOneWidget);
      expect(find.text('Allow'), findsNothing);
    });

    Color? outcomeColor(WidgetTester tester, String text) =>
        text.startsWith('✗')
        ? tester.widget<Text>(find.text(text)).style?.color
        : tester
              .widget<Icon>(
                find.byWidgetPredicate(
                  (w) => w is Icon && w.semanticLabel == text,
                ),
              )
              .color;

    testWidgets('completed → green header without duplicate footer', (
      tester,
    ) async {
      const done = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'Bash',
        args: {'command': 'ls'},
        status: ToolEventStatus.completed,
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: done)));
      expect(outcomeColor(tester, 'DONE'), AppColors.dark.success);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.text('DONE'), findsNothing);
      expect(find.text('✓ Done'), findsNothing);
    });

    testWidgets('failed → red "✗ {error}" + named FAILED icon', (tester) async {
      const failed = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'Bash',
        args: {'command': 'exit 1'},
        status: ToolEventStatus.failed,
        error: 'command failed: exit 1',
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: failed)));
      expect(find.byTooltip('FAILED'), findsOneWidget);
      expect(find.byIcon(Icons.error), findsOneWidget);
      expect(outcomeColor(tester, 'FAILED'), AppColors.dark.error);
      expect(find.text('FAILED'), findsNothing);
      expect(find.textContaining('✗ command failed: exit 1'), findsNothing);
      await tester.tap(find.byKey(const Key('tool-disclosure')));
      await tester.pump();
      expect(
        outcomeColor(tester, '✗ command failed: exit 1'),
        AppColors.dark.error,
      );
    });

    testWidgets('running → blue header without duplicate footer', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: _bashTool)));
      expect(outcomeColor(tester, 'RUNNING'), AppColors.dark.accent);
      expect(find.byIcon(Icons.sync), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsNothing);
      expect(find.text('⏳ Running…'), findsNothing);
    });
  });
}
