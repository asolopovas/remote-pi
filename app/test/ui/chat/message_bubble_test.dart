// Agent output (AssistantBubble) must use the FULL content width, not the old
// 340px cap (user-reported: markdown reply not filling the horizontal space).

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/chat/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('AssistantBubble wraps at the full available width (>340)', (
    tester,
  ) async {
    const longText =
        'This is a sufficiently long agent reply that would have wrapped at '
        'the old 340px cap but should now span the full content width of the '
        'message list so it reads naturally on wide screens.';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            child: AssistantBubble(AssistantMsg(id: 'a1', text: longText)),
          ),
        ),
      ),
    );
    await tester.pump();

    // Markdown rendered + spanning beyond the old 340px cap.
    expect(find.byType(AgentMarkdown), findsOneWidget);
    final width = tester.getSize(find.byType(AgentMarkdown)).width;
    expect(
      width,
      greaterThan(340),
      reason: 'agent markdown should fill beyond the old 340px cap',
    );
  });

  testWidgets('AssistantBubble is selectable (copyable)', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AssistantBubble(AssistantMsg(id: 'a1', text: 'reply')),
        ),
      ),
    );
    await tester.pump();
    // AgentMarkdown wraps the reply in a SelectionArea when selectable.
    expect(find.byType(SelectionArea), findsOneWidget);
  });

  testWidgets('UserBubble text is selectable (copyable)', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UserBubble(UserMsg(id: 'u1', text: 'my message')),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('my message'), findsOneWidget);
  });

  testWidgets('pending steer bubble shows steering label', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UserBubble(
            UserMsg(
              id: 'u1',
              text: 'busy follow-up',
              status: UserMsgStatus.pending,
              steering: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('steering…'), findsOneWidget);
    expect(find.text('sending…'), findsNothing);
  });

  testWidgets('confirmed steer bubble keeps steering label', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UserBubble(
            UserMsg(id: 'u1', text: 'accepted follow-up', steering: true),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('steering…'), findsOneWidget);
  });

  testWidgets('pending normal bubble keeps sending label', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UserBubble(
            UserMsg(
              id: 'u1',
              text: 'normal send',
              status: UserMsgStatus.pending,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('sending…'), findsOneWidget);
  });
}
