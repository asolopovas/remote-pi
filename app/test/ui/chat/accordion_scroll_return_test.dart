import 'package:app/ui/chat/widgets/accordion_viewport.dart';
import 'package:app/ui/chat/widgets/code_viewport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final reverse in [false, true]) {
    for (final short in [false, true]) {
      for (final surface in [false, true]) {
        testWidgets(
          '${reverse ? 'reverse' : 'normal'} ${short ? 'short' : 'long'} code ${surface ? 'surface' : 'header'} returns to content after reading and growth',
          (tester) async {
            final controller = ScrollController();
            var growth = 0.0;
            var session = 0;
            late StateSetter update;
            const cardKey = Key('code');
            const beforeKey = Key('before');
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  body: Align(
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                      width: 320,
                      height: 400,
                      child: StatefulBuilder(
                        builder: (context, setState) {
                          update = setState;
                          final card = CodeViewport(
                            key: cardKey,
                            text: 'output',
                            child: SizedBox(height: short ? 80 : 1400),
                          );
                          final before = SizedBox(
                            key: beforeKey,
                            height: 500 + growth,
                          );
                          const after = SizedBox(height: 500);
                          return AccordionViewport(
                            key: ValueKey(session),
                            controller: controller,
                            reverse: reverse,
                            child: ListView(
                              controller: controller,
                              reverse: reverse,
                              padding: const EdgeInsets.all(kAccordionGutter),
                              children: reverse
                                  ? [
                                      const AccordionEdgeSpace(),
                                      after,
                                      card,
                                      before,
                                    ]
                                  : [
                                      before,
                                      card,
                                      after,
                                      const AccordionEdgeSpace(),
                                    ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            );
            final header = find.byKey(const Key('code-disclosure'));
            // Materialize the middle row in the lazy production-style list.
            controller.jumpTo(350);
            await tester.pumpAndSettle();
            await Scrollable.ensureVisible(
              tester.element(header),
              alignment: 0.5,
            );
            await tester.pumpAndSettle();
            for (var cycle = 0; cycle < 2; cycle++) {
              final original = tester.getRect(header).top;
              await tester.tap(header);
              await tester.pumpAndSettle();
              expect(tester.getRect(header).top, closeTo(8, 0.5));
              if (!short) {
                controller.jumpTo(controller.offset + (reverse ? -180 : 180));
                await tester.pumpAndSettle();
                expect(header.hitTestable(), findsNothing);
              }
              update(() => growth += 70);
              await tester.pumpAndSettle();
              if (surface) {
                // Non-text body surface, after scrolling into the result.
                final point = Offset(
                  250,
                  short ? tester.getRect(header).bottom + 30 : 160,
                );
                await tester.tapAt(point);
                await tester.pump(const Duration(milliseconds: 80));
                await tester.tapAt(point);
              } else {
                // Explicitly bring the natural heading back to tap it.
                await Scrollable.ensureVisible(tester.element(header));
                await tester.pumpAndSettle();
                await tester.tap(header);
              }
              await tester.pumpAndSettle();
              expect(find.byKey(const Key('code-wrap')), findsNothing);
              expect(tester.getRect(header).top, closeTo(original, 0.5));
              // Reopening must capture this new reading position, not cycle 1.
              controller.jumpTo(controller.offset + (reverse ? 35 : -35));
              await tester.pumpAndSettle();
            }
            await tester.tap(header);
            await tester.pumpAndSettle();
            update(() => session++);
            await tester.pumpAndSettle();
            expect(find.byKey(const Key('code-wrap')), findsNothing);
            final switched = controller.offset;
            await tester.pumpAndSettle();
            expect(controller.offset, switched);
            await tester.pumpWidget(const SizedBox());
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            controller.dispose();
          },
        );
      }
    }
  }
  testWidgets(
    'nested code returns independently and preserves outer bookmark',
    (tester) async {
      final controller = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: 320,
                height: 400,
                child: AccordionViewport(
                  controller: controller,
                  child: SingleChildScrollView(
                    controller: controller,
                    child: Column(
                      children: [
                        const SizedBox(height: 250),
                        CodeViewport(
                          key: const Key('outer'),
                          text: 'outer',
                          child: Column(
                            children: [
                              const SizedBox(height: 200),
                              const CodeViewport(
                                key: Key('inner'),
                                text: 'inner',
                                child: SizedBox(height: 1000),
                              ),
                              const SizedBox(height: 500),
                            ],
                          ),
                        ),
                        const SizedBox(height: 500),
                        const AccordionEdgeSpace(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      Finder heading(String name) => find
          .descendant(
            of: find.byKey(Key(name)),
            matching: find.byKey(const Key('code-disclosure')),
          )
          .first;
      final outer = heading('outer');
      final originalOuter = tester.getRect(outer).top;
      await tester.tap(outer);
      await tester.pumpAndSettle();
      final inner = heading('inner');
      final originalInner = tester.getRect(inner).top;
      await tester.tap(inner);
      await tester.pumpAndSettle();
      controller.jumpTo(controller.offset + 180);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(252, 160));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(const Offset(252, 160));
      await tester.pumpAndSettle();
      expect(tester.getRect(inner).top, closeTo(originalInner, 0.5));
      expect(find.byKey(const Key('inner')), findsOneWidget);
      await Scrollable.ensureVisible(tester.element(outer));
      await tester.pumpAndSettle();
      await tester.tap(outer);
      await tester.pumpAndSettle();
      expect(tester.getRect(outer).top, closeTo(originalOuter, 0.5));
      expect(find.byKey(const Key('inner')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
