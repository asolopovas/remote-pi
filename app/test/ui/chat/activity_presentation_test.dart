import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/compact_output_header.dart';
import 'package:app/ui/chat/widgets/activity_presentation.dart';
import 'package:app/ui/chat/widgets/activity_issue_notice.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui' show Tristate;
import 'package:flutter_test/flutter_test.dart';

ToolEvent read(
  String id,
  String path, {
  ToolEventStatus status = ToolEventStatus.completed,
}) => ToolEvent(
  id: id,
  toolCallId: id,
  tool: 'functions.read',
  args: {'path': path},
  status: status,
  result: 'file contents $id',
);

void main() {
  test(
    'routine coordination and inspection never become successful feed rows',
    () {
      final tools = [
        'functions.subagent_supervisor',
        'subagents_enable',
        'contact_supervisor',
        'mcp__remote__list_peers',
        'agent_send',
        'agent_request',
        'project_report',
        'module_report',
        'symbol_search',
        'effective_config',
        'lens_diagnostics',
        'pi_lens_activate_tools',
        'tool_search',
        'lsp_navigation',
        'ast_grep_search',
        'functions.subagent',
      ];
      for (final name in tools) {
        for (final status in ToolEventStatus.values) {
          final tool = ToolEvent(
            id: name,
            toolCallId: name,
            tool: name,
            args: name == 'functions.subagent' ? {'action': 'status'} : {},
            status: status,
          );
          expect(
            activityRows([tool]),
            hasActivityIssue(tool) ? [same(tool)] : isEmpty,
            reason: '$name $status',
          );
        }
      }
    },
  );

  test(
    'human messages, mutations, real delegation and unknown tools retain identity',
    () {
      final messages = <ChatMessage>[
        const UserMsg(id: 'u', text: 'Change direction'),
        const AssistantMsg(id: 'a', text: 'A decision is needed'),
        for (final name in [
          'edit',
          'write',
          'bash',
          'codemode',
          'custom_check',
          'ask_user',
          'request_approval',
        ])
          ToolEvent(
            id: name,
            toolCallId: name,
            tool: name,
            args: {'code': 'subagent_supervisor()'},
            status: ToolEventStatus.completed,
          ),
        const ToolEvent(
          id: 'launch',
          toolCallId: 'launch',
          tool: 'subagent',
          args: {'agent': 'worker', 'task': 'Implement the selected change'},
        ),
      ];
      expect(activityRows(messages), orderedEquals(messages));
      expect(isRoutineActivity(messages.last as ToolEvent), isFalse);
    },
  );

  test(
    'routine activity occupies only current status, never stale progress',
    () {
      const tool = ToolEvent(
        id: 's',
        toolCallId: 's',
        tool: 'functions.subagent_supervisor',
        args: {'action': 'reply'},
      );
      expect(activeActivityLabel([tool]), 'Coordinating agents…');
      expect(
        activeActivityLabel([tool.copyWith(status: ToolEventStatus.completed)]),
        isNull,
      );
      expect(
        activeActivityLabel([
          const ToolEvent(
            id: 'd',
            toolCallId: 'd',
            tool: 'lens_diagnostics',
            args: {},
          ),
        ]),
        'Checking project…',
      );
      expect(
        activeActivityLabel([
          read('r', 'main.dart', status: ToolEventStatus.pending),
        ]),
        'Reading main.dart…',
      );
    },
  );

  testWidgets('coordination failures are compact notices, not accordions', (
    tester,
  ) async {
    const tool = ToolEvent(
      id: 's',
      toolCallId: 's',
      tool: 'subagent_supervisor',
      args: {},
      status: ToolEventStatus.failed,
      result: {'message': 'Worker unavailable\nInternal diagnostic payload'},
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: const Scaffold(body: ActivityIssueNotice(tool: tool)),
      ),
    );
    expect(find.text('Agent coordination failed'), findsOneWidget);
    expect(find.text('Worker unavailable'), findsOneWidget);
    expect(find.textContaining('Internal diagnostic payload'), findsNothing);
    expect(find.byType(CompactOutputHeader), findsNothing);
    expect(find.byType(IconButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('all read states stay out of the feed; changes retain identity', () {
    const edit = ToolEvent(
      id: 'edit',
      toolCallId: 'edit',
      tool: 'edit',
      args: {},
    );
    final rows = activityRows([
      for (final status in ToolEventStatus.values)
        read('$status', 'lib/main.dart', status: status),
      const ToolEvent(
        id: 'symbol',
        toolCallId: 'symbol',
        tool: 'read_symbol',
        args: {},
      ),
      const ToolEvent(
        id: 'enclosing',
        toolCallId: 'enclosing',
        tool: 'functions.read_enclosing',
        args: {},
      ),
      edit,
    ]);
    expect(rows, [same(edit)]);
  });

  test('only the current running read appears in status', () {
    final running = read(
      'one',
      'lib/main.dart',
      status: ToolEventStatus.allowed,
    );
    expect(activeReadLabel([running]), 'Reading lib/main.dart…');
    expect(activeReadLabel([read('one', 'lib/main.dart')]), isNull);
    expect(
      activeReadLabel([
        running,
        const ToolEvent(id: 'edit', toolCallId: 'edit', tool: 'edit', args: {}),
      ]),
      isNull,
    );
    expect(
      activeReadLabel([read('one', '', status: ToolEventStatus.pending)]),
      'Reading…',
    );
    expect(activeReadLabel([]), isNull);
  });

  testWidgets(
    'disclosure supports keyboard activation, arrows, semantics and stable focus',
    (tester) async {
      final semantics = tester.ensureSemantics();
      bool expanded = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => CompactOutputHeader(
                title: 'EDIT · lib/main.dart',
                expanded: expanded,
                disclosureKey: const Key('header'),
                onToggle: () => setState(() => expanded = !expanded),
              ),
            ),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      final focus = FocusManager.instance.primaryFocus;
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(expanded, isTrue);
      expect(
        tester
            .getSemantics(find.byKey(const Key('header')))
            .getSemanticsData()
            .flagsCollection
            .isExpanded,
        Tristate.isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(expanded, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(expanded, isTrue);
      expect(FocusManager.instance.primaryFocus, same(focus));
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
    },
  );
}
