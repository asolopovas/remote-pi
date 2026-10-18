import 'dart:convert';
import 'dart:io';

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/tool_request_card.dart';
import 'package:app/ui/chat/widgets/codemode_preview.dart';
import 'package:app/ui/chat/widgets/source_code.dart';
import 'package:app/ui/chat/widgets/tool_presentation.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final fixture =
    jsonDecode(
          File(
            'test/ui/chat/fixtures/75/75-reported-tool.json',
          ).readAsStringSync(),
        )
        as Map;
final script = (fixture['arguments'] as Map)['code'] as String;
final result = File(
  'test/ui/chat/fixtures/75/75-reported-result.txt',
).readAsStringSync();

void main() {
  testWidgets(
    'device single-LF codemode Output renders parsed metadata with exact original output and source copy',
    (tester) async {
      const source = "text(await tools.read({path:'inert'}));\n";
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
      for (final fixtureName in [
        '75-device-codemode-result.txt',
        '75-single-codemode-result.txt',
      ]) {
        final device = File(
          'test/ui/chat/fixtures/75/$fixtureName',
        ).readAsStringSync();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ToolRequestCard(
                  tool: ToolEvent(
                    id: 'device-prefix',
                    toolCallId: 'device-prefix',
                    tool: 'codemode',
                    args: const {'code': source},
                    result: device,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const Key('tool-disclosure')));
        await tester.pump();
        expect(find.text(source), findsOneWidget);
        expect(find.byTooltip('Copy decoded embedded string'), findsNothing);
        expect(find.textContaining('Result metadata:'), findsNothing);
        expect(find.text(readableCodemodeOutput(device)), findsOneWidget);
        await tester.tap(find.byTooltip('Copy source'));
        await tester.pump();
        expect(copied, source);
        final original = find.byKey(
          const ValueKey('tool-original-output-device-prefix'),
        );
        final disclosure = find.descendant(
          of: original,
          matching: find.byKey(const Key('code-disclosure')),
        );
        await tester.ensureVisible(disclosure);
        await tester.tap(disclosure);
        await tester.pump();
        expect(find.text(device), findsOneWidget);
        await tester.ensureVisible(find.byTooltip('Copy original output'));
        await tester.tap(find.byTooltip('Copy original output'));
        await tester.pump();
        expect(copied, device);
        expect(
          find.byKey(const ValueKey('tool-args-device-prefix')),
          findsNothing,
        );
        expect(find.textContaining('Details ·'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
  testWidgets(
    'outer Scroll keeps recovered nested frames finite before and after disclosure at 320px/2x',
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
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final previews = embeddedCodemodeSource(script);
      for (final openedFirst in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: MediaQuery(
                  data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                  child: ToolRequestCard(
                    key: ValueKey(openedFirst),
                    tool: ToolEvent(
                      id: 'outer',
                      toolCallId: 'outer',
                      tool: 'codemode',
                      args: fixture['arguments'],
                      result: result,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const Key('tool-disclosure')));
        await tester.pump();
        final outer = find.byKey(const ValueKey('tool-code-outer'));
        final preview = find.byKey(
          ValueKey('tool-embedded-outer-${previews.first.offset}'),
        );
        final innerDisclosure = find.descendant(
          of: preview,
          matching: find.byKey(const Key('code-disclosure')),
        );
        final outerWrap = find
            .descendant(of: outer, matching: find.byKey(const Key('code-wrap')))
            .first;
        if (openedFirst) {
          await tester.ensureVisible(innerDisclosure);
          await tester.tap(innerDisclosure);
          await tester.pump();
        }
        await tester.ensureVisible(outerWrap);
        await tester.tap(outerWrap);
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(tester.getSize(preview).width, lessThanOrEqualTo(320));
        if (!openedFirst) {
          await tester.ensureVisible(innerDisclosure);
          await tester.tap(innerDisclosure);
          await tester.pump();
        }
        expect(find.text(previews.first.text), findsOneWidget);
        expect(
          find.ancestor(
            of: find.text(previews.first.text),
            matching: find.byType(SelectionArea),
          ),
          findsWidgets,
        );
        final innerCopy = find.descendant(
          of: preview,
          matching: find.byTooltip('Copy decoded embedded string'),
        );
        await tester.ensureVisible(innerCopy);
        await tester.tap(innerCopy);
        await tester.pump();
        expect(copied, previews.first.text);
        final innerWrap = find.descendant(
          of: preview,
          matching: find.byKey(const Key('code-wrap')),
        );
        await tester.ensureVisible(innerWrap);
        await tester.tap(innerWrap);
        await tester.pump();
        expect(
          find.descendant(of: preview, matching: find.byTooltip('Wrap code')),
          findsOneWidget,
        );
        await tester.ensureVisible(find.byTooltip('Copy source'));
        await tester.tap(find.byTooltip('Copy source'));
        await tester.pump();
        expect(copied, script);
        final original = find.byKey(const ValueKey('tool-original-outer'));
        final originalDisclosure = find.descendant(
          of: original,
          matching: find.byKey(const Key('code-disclosure')),
        );
        await tester.ensureVisible(originalDisclosure);
        await tester.tap(originalDisclosure);
        await tester.pump();
        expect(find.text(script), findsOneWidget);
        await tester.ensureVisible(find.byTooltip('Copy original script'));
        await tester.tap(find.byTooltip('Copy original script'));
        await tester.pump();
        expect(copied, script);
        expect(tester.getSize(original).width, lessThanOrEqualTo(320));
        final originalWrap = find.descendant(
          of: original,
          matching: find.byKey(const Key('code-wrap')),
        );
        await tester.ensureVisible(originalWrap);
        await tester.tap(originalWrap);
        await tester.pump();
        final innerState = tester.state(preview);
        final originalState = tester.state(original);
        final horizontal = tester
            .widget<SingleChildScrollView>(
              find
                  .descendant(
                    of: outer,
                    matching: find.byType(SingleChildScrollView),
                  )
                  .first,
            )
            .controller!;
        expect(horizontal.position.maxScrollExtent, greaterThan(0));
        horizontal.jumpTo(80.0.clamp(0, horizontal.position.maxScrollExtent));
        await tester.pump();
        await tester.ensureVisible(outerWrap);
        await tester.tap(outerWrap);
        await tester.pump();
        expect(horizontal.offset, 0);
        expect(horizontal.position.maxScrollExtent, 0);
        expect(tester.state(preview), same(innerState));
        expect(tester.state(original), same(originalState));
        expect(find.text(previews.first.text), findsOneWidget);
        expect(find.text(script), findsOneWidget);
        expect(
          find.descendant(of: preview, matching: find.byTooltip('Wrap code')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: original, matching: find.byTooltip('Wrap code')),
          findsOneWidget,
        );
        await tester.tap(outerWrap);
        await tester.pump();
        expect(tester.state(preview), same(innerState));
        expect(tester.state(original), same(originalState));
        expect(find.text(previews.first.text), findsOneWidget);
        expect(find.text(script), findsOneWidget);
        await tester.ensureVisible(innerCopy);
        await tester.tap(innerCopy);
        await tester.pump();
        expect(copied, previews.first.text);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
  testWidgets(
    'known Bash PowerShell Output is multiline with metadata and lossless originals',
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
      final cases =
          jsonDecode(
                File(
                  'test/ui/chat/fixtures/75/output-cases.json',
                ).readAsStringSync(),
              )
              as List;
      for (final entry in cases) {
        for (final tool in ['functions.bash', 'tools:PowerShell', 'unknown']) {
          for (final value in [
            entry['raw'],
            if (entry.containsKey('wrapper')) entry['wrapper'],
          ]) {
            final original = value is String
                ? value
                : const JsonEncoder.withIndent('  ').convert(value);
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  body: SingleChildScrollView(
                    child: ToolRequestCard(
                      key: UniqueKey(),
                      tool: ToolEvent(
                        id: 'shell',
                        toolCallId: 'shell',
                        tool: tool,
                        args: const {'command': 'review-only'},
                        result: value,
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.tap(find.byKey(const Key('tool-disclosure')));
            await tester.pump();
            final expected = tool == 'unknown'
                ? toolFields(value)
                : entry['expected'] ?? toolFields(value);
            expect(
              find.byWidgetPredicate(
                (widget) => widget is SourceCode && widget.source == expected,
              ),
              findsOneWidget,
            );
            expect(find.text('Output'), findsOneWidget);
            if (expected != original) {
              final disclosure = find.descendant(
                of: find.byKey(const ValueKey('tool-original-output-shell')),
                matching: find.byKey(const Key('code-disclosure')),
              );
              await tester.ensureVisible(disclosure);
              await tester.tap(disclosure);
              await tester.pump();
              await tester.ensureVisible(
                find.byTooltip('Copy original output'),
              );
              await tester.tap(find.byTooltip('Copy original output'));
              await tester.pump();
              expect(copied, original);
              expect(
                find.byKey(const ValueKey('tool-args-shell')),
                findsNothing,
              );
            } else {
              expect(find.byTooltip('Copy original output'), findsNothing);
            }
            expect(tester.takeException(), isNull);
          }
        }
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('unknown tools never decode codemode-looking results', (
    tester,
  ) async {
    for (final tool in ['unknown', 'bash']) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ToolRequestCard(
                tool: ToolEvent(
                  id: tool,
                  toolCallId: tool,
                  tool: tool,
                  args: const {'command': 'x'},
                  result: result,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('tool-disclosure')));
      await tester.pump();
      expect(find.text(result), findsOneWidget);
    }
  });
  testWidgets(
    'exact recovered previews copy decoded strings and originals without nested Details in both themes at 320px/2x',
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
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final previews = embeddedCodemodeSource(script);
      for (final theme in [buildDarkTheme(), buildLightTheme()]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: SingleChildScrollView(
                child: MediaQuery(
                  data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                  child: ToolRequestCard(
                    key: ValueKey(theme),
                    tool: ToolEvent(
                      id: 'reported',
                      toolCallId: 'reported',
                      tool: 'codemode',
                      args: fixture['arguments'],
                      result: result,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const Key('tool-disclosure')));
        await tester.pump();
        expect(find.byType(SourceCode), findsOneWidget);
        expect(find.text(readableCodemodeOutput(result)), findsOneWidget);
        await tester.tap(find.byTooltip('Copy source'));
        await tester.pump();
        expect(copied, script);
        for (final p in previews) {
          final viewport = find.byKey(
            ValueKey('tool-embedded-reported-${p.offset}'),
          );
          final disclosure = find.descendant(
            of: viewport,
            matching: find.byKey(const Key('code-disclosure')),
          );
          await tester.ensureVisible(disclosure);
          await tester.tap(disclosure);
          await tester.pump();
          expect(find.text(p.text), findsOneWidget);
          expect(
            find.ancestor(
              of: find.text(p.text),
              matching: find.byType(SelectionArea),
            ),
            findsWidgets,
          );
          final copy = find.descendant(
            of: viewport,
            matching: find.byTooltip('Copy decoded embedded string'),
          );
          await tester.ensureVisible(copy);
          await tester.tap(copy);
          await tester.pump();
          expect(copied, p.text);
          final wrap = find.descendant(
            of: viewport,
            matching: find.byKey(const Key('code-wrap')),
          );
          await tester.tap(wrap);
          await tester.pump();
          expect(
            find.descendant(
              of: viewport,
              matching: find.byTooltip('Wrap code'),
            ),
            findsOneWidget,
          );
          await tester.tap(wrap);
          await tester.pump();
          await tester.ensureVisible(disclosure);
          await tester.tap(disclosure);
          await tester.pump();
          expect(find.text(p.text), findsNothing);
        }
        final original = find.byKey(const ValueKey('tool-original-reported'));
        final originalDisclosure = find.descendant(
          of: original,
          matching: find.byKey(const Key('code-disclosure')),
        );
        await tester.ensureVisible(originalDisclosure);
        await tester.tap(originalDisclosure);
        await tester.pump();
        expect(find.text(script), findsOneWidget);
        await tester.ensureVisible(find.byTooltip('Copy original script'));
        await tester.tap(find.byTooltip('Copy original script'));
        await tester.pump();
        expect(copied, script);
        final originalOutput = find.byKey(
          const ValueKey('tool-original-output-reported'),
        );
        final outputDisclosure = find.descendant(
          of: originalOutput,
          matching: find.byKey(const Key('code-disclosure')),
        );
        await tester.ensureVisible(outputDisclosure);
        await tester.tap(outputDisclosure);
        await tester.pump();
        expect(find.text(result), findsOneWidget);
        await tester.ensureVisible(find.byTooltip('Copy original output'));
        await tester.tap(find.byTooltip('Copy original output'));
        await tester.pump();
        expect(copied, result);
        expect(find.byKey(const ValueKey('tool-args-reported')), findsNothing);
        expect(find.textContaining('Details ·'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
  testWidgets(
    'recovered codemode exposes readable embedded source not only escaped outer Script',
    (tester) async {
      expect(script.length, 4627);
      expect('\n'.allMatches(script).length, 7);
      expect(r'\n'.allMatches(script).length, 59);
      expect(
        File(
          'test/ui/chat/fixtures/75/75-reported-codemode.js',
        ).readAsStringSync(),
        script,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ToolRequestCard(
                tool: ToolEvent(
                  id: 'reported',
                  toolCallId: 'reported',
                  tool: fixture['name'] as String,
                  args: fixture['arguments'],
                  result: result,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('tool-disclosure')));
      await tester.pump();
      expect(find.textContaining('Static embedded bash command'), findsWidgets);
      expect(find.text(script), findsNothing);
    },
  );
}
