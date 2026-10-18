// Plan/32b — AgentMarkdown renders fenced code with a copy button.

import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, String md) {
    return tester.pumpWidget(
      MaterialApp(home: Scaffold(body: AgentMarkdown(md))),
    );
  }

  testWidgets('fenced code block shows a copy button', (tester) async {
    await pump(tester, '```dart\nfinal x = 1;\n```');
    await tester.pump();
    expect(find.byKey(const Key('code-copy')), findsOneWidget);
    expect(find.textContaining('final x = 1;'), findsNothing);
    await tester.tap(find.byKey(const Key('code-disclosure')));
    await tester.pump();
    expect(find.byTooltip('Scroll horizontally'), findsOneWidget);
    expect(find.textContaining('final x = 1;'), findsOneWidget);
    await tester.tap(find.byKey(const Key('code-wrap')));
    await tester.pump();
    expect(find.byTooltip('Wrap code'), findsOneWidget);
  });

  testWidgets('tapping copy puts the code on the clipboard', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await pump(tester, '```\nhello code\n```');
    await tester.pump();
    await tester.tap(find.byKey(const Key('code-disclosure')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('code-copy')));
    await tester.pump();

    expect(calls, isNotEmpty, reason: 'Clipboard.setData was invoked');
    final text = (calls.first.arguments as Map)['text'] as String;
    expect(text, contains('hello code'));
  });

  testWidgets(
    'assistant prose stays visible around a collapsed selectable code example',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentMarkdown(
              'Visible before.\n\n```dart\nfinal x = 1;\n```\n\nVisible after.',
              selectable: true,
            ),
          ),
        ),
      );
      expect(find.textContaining('Visible before.'), findsOneWidget);
      expect(find.textContaining('Visible after.'), findsOneWidget);
      expect(find.textContaining('final x = 1;'), findsNothing);
      expect(find.text('RUNNING'), findsNothing);
      expect(find.text('DONE'), findsNothing);
      await tester.tap(find.byKey(const Key('code-disclosure')));
      await tester.pump();
      expect(
        find.ancestor(
          of: find.textContaining('final x = 1;'),
          matching: find.byType(SelectionArea),
        ),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'markdown fenced block retains expansion/Scroll as streaming finishes',
    (tester) async {
      await pump(tester, 'Still writing.\n\n```dart\none');
      await tester.tap(find.byKey(const Key('code-disclosure')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('code-wrap')));
      await tester.pump();
      await pump(
        tester,
        'Still writing.\n\n```dart\none\ntwo\n```\n\nFinished.',
      );
      expect(find.byTooltip('Wrap code'), findsOneWidget);
      expect(find.textContaining('one\ntwo'), findsOneWidget);
      expect(find.textContaining('Finished.'), findsOneWidget);
    },
  );
  testWidgets('plain prose renders without a code block', (tester) async {
    await pump(tester, 'just a normal sentence.');
    await tester.pump();
    expect(find.byKey(const Key('code-copy')), findsNothing);
  });
}
