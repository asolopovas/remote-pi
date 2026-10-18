import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/accordion_viewport.dart';
import 'package:app/ui/chat/widgets/code_viewport.dart';
import 'package:app/ui/chat/widgets/subagent_panel.dart';
import 'package:app/ui/chat/widgets/tool_request_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> doubleTapAt(WidgetTester tester, Offset point) async {
  await tester.tapAt(point);
  await tester.pump(const Duration(milliseconds: 80));
  await tester.tapAt(point);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'nested body padding collapses only innermost; selection and controls win',
    (tester) async {
      final nested = CodeViewport(
        key: const Key('inner'),
        text: 'select these words',
        label: 'inner',
        child: const SizedBox(
          height: 180,
          child: SelectableText('select these words'),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CodeViewport(
                key: const Key('outer'),
                text: 'outer',
                child: Column(children: [nested, const SizedBox(height: 80)]),
              ),
            ),
          ),
        ),
      );
      final outer = find.byKey(const Key('outer'));
      final inner = find.byKey(const Key('inner'));
      Finder header(Finder owner) => find
          .descendant(
            of: owner,
            matching: find.byKey(const Key('code-disclosure')),
          )
          .first;
      await tester.tap(header(outer));
      await tester.pumpAndSettle();
      await tester.tap(header(inner));
      await tester.pumpAndSettle();
      final selection = find.byType(SelectableText);
      await tester.longPressAt(
        tester.getTopLeft(selection) + const Offset(16, 10),
      );
      await tester.pumpAndSettle();
      expect(selection, findsOneWidget);

      await doubleTapAt(
        tester,
        tester.getTopLeft(selection) + const Offset(16, 10),
      );
      expect(selection, findsOneWidget);
      expect(
        tester
            .state<EditableTextState>(find.byType(EditableText).first)
            .textEditingValue
            .selection
            .isCollapsed,
        isFalse,
      );
      // Controls and nested headings never enter an ancestor collapse arena.
      await doubleTapAt(tester, tester.getCenter(header(inner)));
      expect(selection, findsOneWidget); // two single header toggles reopen
      final wrap = find.descendant(
        of: inner,
        matching: find.byKey(const Key('code-wrap')),
      );
      await doubleTapAt(tester, tester.getCenter(wrap));
      expect(selection, findsOneWidget);
      // Bottom internal padding is a supported non-text collapse surface.
      final anchor = find
          .descendant(of: inner, matching: find.byType(AccordionAnchor))
          .first;
      final point = tester.getBottomRight(anchor) - const Offset(3, 3);
      await tester.tapAt(point);
      await tester.pump(const Duration(milliseconds: 350));
      expect(selection, findsOneWidget);
      await doubleTapAt(tester, point);
      expect(selection, findsNothing);
      expect(inner, findsOneWidget); // outer remains expanded
      await tester.tap(header(inner));
      await tester.pumpAndSettle();
      expect(selection, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tool body surface collapses and reopens without resetting Scroll',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ToolRequestCard(
                tool: ToolEvent(
                  id: 'tool',
                  toolCallId: 'tool',
                  tool: 'bash',
                  args: {'command': 'echo hi'},
                  result: 'hi\n',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('tool-disclosure')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('code-wrap')).first);
      await tester.pumpAndSettle();
      final anchor = find.byType(AccordionAnchor).first;
      await doubleTapAt(
        tester,
        tester.getBottomLeft(anchor) + const Offset(2, -3),
      );
      expect(find.text('Output'), findsNothing);
      await tester.tap(find.byKey(const Key('tool-disclosure')));
      await tester.pumpAndSettle();
      expect(find.text('Output'), findsOneWidget);
      expect(find.byTooltip('Wrap code'), findsOneWidget);
    },
  );

  testWidgets('agent body left padding collapses owning launch disclosure', (
    tester,
  ) async {
    const tool = ToolEvent(
      id: 'agent',
      toolCallId: 'agent',
      tool: 'subagent',
      args: {'agent': 'worker', 'task': 'investigate'},
      result: 'output',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SubagentPanel(
            invocations: [SubagentInvocation.fromTool(tool)!],
            collapsed: true,
            onCollapsedChanged: (_) {},
          ),
        ),
      ),
    );
    final header = find.byKey(const ValueKey('subagent-agent'));
    await tester.tap(header);
    await tester.pumpAndSettle();
    final anchor = find.byType(AccordionAnchor).first;
    final rect = tester.getRect(anchor);
    await doubleTapAt(
      tester,
      Offset(rect.left + 3, tester.getRect(header).bottom + 12),
    );
    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
