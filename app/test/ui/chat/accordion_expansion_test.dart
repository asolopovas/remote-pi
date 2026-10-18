import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/accordion_expansion.dart';
import 'package:app/ui/chat/widgets/tool_request_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'lazy rows inherit bulk commands without retaining every expanded row; manual choices last until the next command',
    (tester) async {
      final scroll = ScrollController();
      int revision = 0;
      bool? expanded;
      Future<void> pump() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AccordionExpansion(
                revision: revision,
                expanded: expanded,
                child: ListView.builder(
                  controller: scroll,
                  itemCount: 80,
                  itemBuilder: (_, i) => ToolRequestCard(
                    key: ValueKey('row-$i'),
                    tool: ToolEvent(
                      id: '$i',
                      toolCallId: '$i',
                      tool: 'bash',
                      args: {'command': 'echo $i'},
                      result: 'output $i',
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await pump();
      final firstState = tester.state(find.byKey(const ValueKey('row-0')));
      revision = 1;
      expanded = true;
      await pump();
      expect(find.text('output 0'), findsOneWidget);
      scroll.jumpTo(1800);
      await tester.pumpAndSettle();
      expect(firstState.mounted, isFalse);
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.text('output 0'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('tool-disclosure')).hitTestable().first,
      );
      await tester.pumpAndSettle();
      expect(find.text('output 0'), findsNothing);
      await pump(); // ordinary rebuild is not a new command
      expect(find.text('output 0'), findsNothing);
      revision = 2;
      expanded = false;
      await pump();
      revision = 3;
      expanded = true;
      await pump();
      expect(find.text('output 0'), findsOneWidget);
      final wrap = find.byTooltip('Scroll horizontally').hitTestable().first;
      await tester.tap(wrap);
      await tester.pumpAndSettle();
      revision = 4;
      expanded = false;
      await pump();
      revision = 5;
      expanded = true;
      await pump();
      expect(find.byTooltip('Wrap code'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    },
  );
}
