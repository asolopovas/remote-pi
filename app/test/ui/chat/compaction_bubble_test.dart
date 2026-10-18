// Plan/32 — the compaction system bubble renders the label, the recap summary
// and the reclaimed token count (distinct from user/assistant bubbles).

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, CompactionMsg msg) {
    return tester.pumpWidget(
      MaterialApp(home: Scaffold(body: CompactionBubble(msg))),
    );
  }

  testWidgets('shows label + summary + token count', (tester) async {
    await pump(
      tester,
      const CompactionMsg(
        id: 'c1',
        summary: 'Recapped the long thread',
        tokensBefore: 12000,
      ),
    );

    expect(find.text('Context compacted'), findsOneWidget);
    expect(find.text('Recapped the long thread'), findsOneWidget);
    expect(find.text('~12000 tokens'), findsOneWidget);
  });

  testWidgets('omits the token line when tokensBefore is null', (tester) async {
    await pump(
      tester,
      const CompactionMsg(id: 'c2', summary: 'done'),
    );

    expect(find.text('Context compacted'), findsOneWidget);
    expect(find.text('done'), findsOneWidget);
    expect(find.textContaining('tokens'), findsNothing);
  });
}
