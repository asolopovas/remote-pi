import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/subagent_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ToolEvent tool(
  Object? args, {
  String name = 'subagent',
  String id = 'a',
  ToolEventStatus status = ToolEventStatus.pending,
  Object? result,
}) => ToolEvent(
  id: id,
  toolCallId: id,
  tool: name,
  args: args,
  status: status,
  result: result,
);
SubagentInvocation invocation({
  String id = 'a',
  ToolEventStatus status = ToolEventStatus.pending,
  Object? result,
  String name = 'scout',
}) => SubagentInvocation.fromTool(
  tool(
    {'agent': name, 'task': 'Review all files\nwith full assignment'},
    id: id,
    status: status,
    result: result,
  ),
)!;
Widget wrap(Widget child, {double scale = 1}) => MaterialApp(
  home: Scaffold(
    body: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: child,
    ),
  ),
);
void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'child accordions have no spacer while retaining 48px targets at ${scale}x',
      (tester) async {
        await tester.pumpWidget(
          wrap(
            SubagentPanel(
              invocations: [
                invocation(id: 'a'),
                invocation(id: 'b'),
              ],
              collapsed: true,
              onCollapsedChanged: (_) {},
            ),
            scale: scale,
          ),
        );
        await tester.pumpAndSettle();
        final first = find.byKey(const ValueKey('subagent-b'));
        final second = find.byKey(const ValueKey('subagent-a'));
        expect(tester.getRect(second).top - tester.getRect(first).bottom, 0);
        expect(tester.getSize(first).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(second).height, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);
      },
    );
  }
  test(
    'installed single, namespace suffix, parallel, named and raw workflows',
    () {
      for (final name in [
        'subagent',
        'mcp.subagent',
        'pi/subagent',
        'tools__subagent',
        'pi:subagent',
      ]) {
        expect(
          SubagentInvocation.fromTool(
            tool({'agent': 'scout', 'task': 'inspect'}, name: name),
          )?.name,
          'scout',
        );
      }
      final parallel = SubagentInvocation.fromTool(
        tool({
          'workflow': 'parallel',
          'args': {
            'tasks': [
              {
                'agent': 'reviewer',
                'task': 'Review API',
                'label': 'Correctness',
              },
              {'agent': 'scout', 'task': 'Map tests'},
            ],
          },
        }),
      )!;
      expect(parallel.name, 'parallel · 2 tasks');
      expect(
        parallel.task,
        'reviewer · Correctness: Review API\nscout: Map tests',
      );
      expect(
        SubagentInvocation.fromTool(
          tool({
            'workflow': 'review',
            'args': {'task': 'Review auth'},
          }),
        )?.task,
        contains('Review auth'),
      );
      for (final workflow in [true, 'true', './workflow/review.js']) {
        expect(
          SubagentInvocation.fromTool(tool({'workflow': workflow})),
          isNotNull,
        );
      }
      expect(
        SubagentInvocation.fromTool(
          tool({
            'tasks': [
              {'agent': 'scout', 'task': 'inspect'},
            ],
          }),
        )?.name,
        'Parallel · 1 tasks',
      );
    },
  );
  test(
    'control-only, unrelated and malformed calls stay normal tool cards',
    () {
      for (final args in [
        null,
        'bad',
        {},
        {'agent': 1, 'task': []},
        {'agent': '', 'task': 'x'},
        {'workflow': false},
        {'workflow': 42},
        {
          'workflow': 'parallel',
          'args': {
            'tasks': [
              null,
              {'agent': 4},
            ],
          },
        },
      ]) {
        expect(
          SubagentInvocation.fromTool(tool(args)),
          isNull,
          reason: '$args',
        );
      }
      for (final action in [
        'status',
        'stop',
        'guide',
        'validate',
        'schedule.create',
      ]) {
        expect(
          SubagentInvocation.fromTool(
            tool({
              'action': action,
              'workflow': true,
              'agent': 'scout',
              'task': 'x',
            }),
          ),
          isNull,
        );
      }
      expect(
        SubagentInvocation.fromTool(
          tool({'agent': 'a', 'task': 'b'}, name: 'subagents_enable'),
        ),
        isNull,
      );
    },
  );
  testWidgets(
    'default/preference expansion, per-item toggle and terminal updates',
    (tester) async {
      Future<void> pump({
        bool collapsed = true,
        ToolEventStatus status = ToolEventStatus.pending,
        Object? result,
      }) => tester.pumpWidget(
        wrap(
          SubagentPanel(
            invocations: [
              invocation(status: status, result: result),
              invocation(id: 'b'),
            ],
            collapsed: collapsed,
            onCollapsedChanged: (_) {},
          ),
        ),
      );
      await pump();
      expect(find.byType(SelectableText), findsNothing);
      await tester.tap(find.byKey(const ValueKey('subagent-a')));
      await tester.pump();
      expect(find.byType(SelectableText), findsOneWidget);
      await pump(status: ToolEventStatus.completed, result: 'full output');
      expect(find.byTooltip('Call returned'), findsOneWidget);
      expect(find.text('full output'), findsOneWidget);
      await pump(status: ToolEventStatus.failed, result: 'failure output');
      expect(find.byTooltip('Failed'), findsOneWidget);
      expect(find.text('failure output'), findsOneWidget);
      await pump(collapsed: false);
      expect(find.byType(SelectableText), findsNWidgets(2));
      await tester.tap(find.byKey(const ValueKey('subagent-a')));
      await tester.pump();
      expect(find.byType(SelectableText), findsOneWidget);
      await pump(collapsed: true);
      expect(find.byType(SelectableText), findsNothing);
    },
  );
  testWidgets(
    'lazy panel retains item choice and resets on peer/session scope',
    (tester) async {
      String scope = 'peer1/session1';
      final agents = [for (var i = 0; i < 50; i++) invocation(id: '$i')];
      Future<void> pump() => tester.pumpWidget(
        wrap(
          SubagentPanel(
            key: ValueKey(scope),
            invocations: agents,
            collapsed: true,
            onCollapsedChanged: (_) {},
          ),
        ),
      );
      await pump();
      await tester.tap(find.byKey(const ValueKey('subagent-49')));
      await tester.pump();
      final untouched = tester.state(find.byKey(const ValueKey('48')));
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      position.jumpTo(1800);
      await tester.pumpAndSettle();
      expect(untouched.mounted, isFalse);
      position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsOneWidget);
      for (final next in ['peer2/session1', 'peer2/session2']) {
        scope = next;
        await pump();
        expect(find.byType(SelectableText), findsNothing);
        await tester.tap(find.byKey(const ValueKey('subagent-49')));
        await tester.pump();
      }
    },
  );
  testWidgets('detached remains Launched without persistent helper text', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      wrap(
        SubagentPanel(
          invocations: [
            invocation(
              status: ToolEventStatus.completed,
              result: 'Async: Detached.',
            ),
          ],
          collapsed: true,
          onCollapsedChanged: (_) {},
        ),
      ),
    );
    expect(find.byTooltip('Launched'), findsOneWidget);
    expect(find.bySemanticsLabel('Launched'), findsOneWidget);
    expect(find.text('Launched'), findsNothing);
    expect(find.byTooltip('Call returned'), findsNothing);
    final header = find.byKey(const ValueKey('subagent-a'));
    expect(tester.getSize(header).height, greaterThanOrEqualTo(48));
    expect(
      tester.getSemantics(header),
      matchesSemantics(
        isButton: true,
        isFocusable: true,
        hasExpandedState: true,
        isExpanded: false,
        hasTapAction: true,
        hasFocusAction: true,
        label: 'scout · Review all files with full assignment',
      ),
    );
    await tester.tap(header);
    await tester.pump();
    expect(find.textContaining('Live child progress'), findsNothing);
    semantics.dispose();
  });
  testWidgets(
    'parallel assignments retain shared output once without invented child cards',
    (tester) async {
      final invocation = SubagentInvocation.fromTool(
        tool(
          {
            'workflow': 'parallel',
            'args': {
              'tasks': [
                {'agent': 'scout', 'task': 'Inspect'},
                {'agent': 'reviewer', 'task': 'Review'},
              ],
            },
          },
          result: 'Shared original result',
          status: ToolEventStatus.completed,
        ),
      )!;
      await tester.pumpWidget(
        wrap(
          SubagentPanel(
            invocations: [invocation],
            collapsed: false,
            onCollapsedChanged: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Shared workflow output'), findsOneWidget);
      expect(
        find.textContaining('Per-agent output is not supplied'),
        findsNothing,
      );
      expect(find.text('Shared original result'), findsOneWidget);
      expect(find.byKey(const ValueKey('subagent-a')), findsOneWidget);
      expect(find.textContaining('scout: Inspect'), findsWidgets);
      expect(find.byTooltip('Call returned'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('long inline agent headings fit at 320px/2x', (tester) async {
    tester.view.physicalSize = const Size(320, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      wrap(
        SubagentPanel(
          invocations: [invocation(name: 'A very long agent name ' * 30)],
          collapsed: true,
          onCollapsedChanged: (_) {},
        ),
        scale: 2,
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
