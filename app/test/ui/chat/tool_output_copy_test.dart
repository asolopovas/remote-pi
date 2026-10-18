import 'dart:io';
import 'dart:ui' as ui;

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/codemode_preview.dart';
import 'package:app/ui/chat/widgets/tool_request_card.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() async {
    if (const bool.fromEnvironment('CAPTURE83')) {
      Directory('build/83-chat').createSync(recursive: true);
      final loader = FontLoader(kMonoFamily);
      loader.addFont(
        rootBundle.load('assets/fonts/fira_mono/FiraMonoNerdFont-Regular.otf'),
      );
      await loader.load();
      for (final (family, asset) in [
        ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
        (
          'packages/lucide_icons_flutter/Lucide',
          'packages/lucide_icons_flutter/assets/lucide.ttf',
        ),
        (
          'packages/lucide_icons_flutter/Lucide600',
          'packages/lucide_icons_flutter/assets/build_font/LucideVariable-w600.ttf',
        ),
      ]) {
        final icons = FontLoader(family)..addFont(rootBundle.load(asset));
        await icons.load();
      }
    }
  });
  testWidgets(
    'Copy output follows owning codemode result updates with exact lossless fallback',
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
      final supported = File(
        'test/ui/chat/fixtures/75/75-reported-result.txt',
      ).readAsStringSync();
      final single = File(
        'test/ui/chat/fixtures/75/75-single-codemode-result.txt',
      ).readAsStringSync();
      const fallback = 'Unknown output with literal "output": "a\\n"  \n';
      for (final result in [supported, single, fallback]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ToolRequestCard(
                  key: const Key('owner'),
                  tool: ToolEvent(
                    id: 'owner',
                    toolCallId: 'owner',
                    tool: 'codemode',
                    args: const {'code': 'not copied'},
                    status: ToolEventStatus.completed,
                    result: result,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (find.byTooltip('Copy output').evaluate().isEmpty) {
          await tester.tap(find.byKey(const Key('tool-disclosure')));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byTooltip('Copy output'));
        await tester.pumpAndSettle();
        expect(copied, readableToolOutput('codemode', result) ?? result);
        expect(find.text('Output'), findsOneWidget);
      }
    },
  );
  for (final dark in [false, true]) {
    for (final scaled in [false, true]) {
      testWidgets(
        'Copy output owns exact normalized/raw result, independent at ${dark ? 'dark' : 'light'} ${scaled ? '320/2x' : '400/1x'}',
        (tester) async {
          await tester.binding.setSurfaceSize(Size(scaled ? 320 : 400, 1000));
          addTearDown(() => tester.binding.setSurfaceSize(null));
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
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          const command = 'printf "literal \\n"\n';
          const result = {
            'output': '  first\n\nsecond \\n\t \n',
            'truncated': true,
            'exit_code': 0,
            'wall_time_seconds': 0.25,
          };
          const raw = 'Unknown {"output":"literal\\n"}  \n\n';
          final boundary = GlobalKey();
          final scroll = ScrollController();
          addTearDown(scroll.dispose);
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? buildDarkTheme() : buildLightTheme(),
              home: MediaQuery(
                data: MediaQueryData(
                  textScaler: TextScaler.linear(scaled ? 2 : 1),
                ),
                child: Scaffold(
                  body: RepaintBoundary(
                    key: boundary,
                    child: ListView(
                      controller: scroll,
                      children: const [
                        ToolRequestCard(
                          key: Key('first'),
                          tool: ToolEvent(
                            id: 'first',
                            toolCallId: 'first',
                            tool: 'bash',
                            args: {'command': command},
                            status: ToolEventStatus.completed,
                            result: result,
                          ),
                        ),
                        ToolRequestCard(
                          key: Key('second'),
                          tool: ToolEvent(
                            id: 'second',
                            toolCallId: 'second',
                            tool: 'unknown',
                            args: {'source': 'not output'},
                            status: ToolEventStatus.completed,
                            result: raw,
                          ),
                        ),
                        ToolRequestCard(
                          key: Key('absent'),
                          tool: ToolEvent(
                            id: 'absent',
                            toolCallId: 'absent',
                            tool: 'bash',
                            args: {'command': 'no result'},
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          Finder inside(String key, Finder action) =>
              find.descendant(of: find.byKey(Key(key)), matching: action);
          final copy = find.byTooltip('Copy output');
          expect(copy, findsNothing);
          for (final key in ['first', 'second']) {
            final disclosure = inside(
              key,
              find.byKey(const Key('tool-disclosure')),
            );
            await tester.ensureVisible(disclosure);
            await tester.tap(disclosure);
            await tester.pumpAndSettle();
          }
          expect(copy, findsNWidgets(2));
          expect(inside('absent', copy), findsNothing);
          final firstCopy = inside('first', copy);
          await tester.ensureVisible(firstCopy);
          await tester.pumpAndSettle();
          expect(
            tester.getSize(firstCopy).shortestSide,
            greaterThanOrEqualTo(48),
          );
          final status = inside('first', find.byTooltip('DONE'));
          expect(
            tester.getRect(firstCopy).left,
            greaterThanOrEqualTo(tester.getRect(status).right),
          );
          expect(
            tester.getRect(firstCopy).center.dy,
            closeTo(tester.getRect(status).center.dy, 1),
          );
          await tester.tap(firstCopy);
          await tester.pumpAndSettle();
          expect(copied, readableToolOutput('bash', result));
          expect(inside('first', find.text('Output')), findsOneWidget);
          await tester.ensureVisible(inside('second', copy));
          await tester.pumpAndSettle();
          await tester.tap(inside('second', copy));
          await tester.pumpAndSettle();
          expect(copied, raw);
          await tester.ensureVisible(firstCopy);
          await tester.pumpAndSettle();
          await tester.tap(
            inside('first', find.byKey(const Key('code-wrap'))).first,
          );
          await tester.pumpAndSettle();
          final offset = scroll.offset;
          await tester.tap(firstCopy);
          await tester.pumpAndSettle();
          expect(copied, readableToolOutput('bash', result));
          expect(scroll.offset, offset);
          expect(inside('first', find.byTooltip('Wrap code')), findsOneWidget);
          expect(inside('first', find.text('Output')), findsOneWidget);
          await tester.tap(inside('first', find.byTooltip('Copy command')));
          await tester.pumpAndSettle();
          expect(copied, command);
          expect(tester.takeException(), isNull);
          if (const bool.fromEnvironment('CAPTURE83')) {
            await tester.runAsync(() async {
              final image =
                  await (boundary.currentContext!.findRenderObject()
                          as RenderRepaintBoundary)
                      .toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                'build/83-chat/tool-${dark ? 'dark' : 'light'}-${scaled ? '320-2x' : '400-1x'}.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
        },
      );
    }
  }
}
