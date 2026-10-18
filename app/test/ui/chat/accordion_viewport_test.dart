import 'package:app/ui/chat/widgets/accordion_viewport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final reverse in [false, true]) {
    for (final short in [false, true]) {
      testWidgets(
        '${reverse ? 'reverse' : 'normal'} ${short ? 'short edge' : 'long'} original heading aligns once and scrolls normally',
        (tester) async {
          final controller = ScrollController();
          var expanded = false;
          var revision = 0;
          var bodyTaps = 0;
          late StateSetter update;
          const viewportKey = Key('viewport');
          const headerKey = Key('original-heading');
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
                        final card = AccordionAnchor(
                          expanded: expanded,
                          onCollapse: () => setState(() => expanded = false),
                          header: SizedBox(
                            height: 60,
                            child: TextButton(
                              key: headerKey,
                              onPressed: () =>
                                  setState(() => expanded = !expanded),
                              child: const Text('Heading'),
                            ),
                          ),
                          body: Padding(
                            padding: const EdgeInsets.fromLTRB(
                              8,
                              0,
                              8,
                              kAccordionGutter,
                            ),
                            child: Column(
                              children: List.generate(short ? 1 : 20, (i) {
                                return SizedBox(
                                  height: 80,
                                  child: TextButton(
                                    key: ValueKey('body-$i'),
                                    onPressed: () => bodyTaps++,
                                    child: Text('Body $i revision $revision'),
                                  ),
                                );
                              }),
                            ),
                          ),
                        );
                        return AccordionViewport(
                          key: viewportKey,
                          controller: controller,
                          reverse: reverse,
                          child: ListView(
                            controller: controller,
                            reverse: reverse,
                            padding: const EdgeInsets.symmetric(
                              vertical: kAccordionGutter,
                            ),
                            children: reverse
                                ? [const AccordionEdgeSpace(), card]
                                : [
                                    const SizedBox(height: 260),
                                    card,
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
          final originalTop = tester.getRect(find.byKey(headerKey)).top;
          await tester.tap(find.byKey(headerKey));
          await tester.pumpAndSettle();
          final top = tester.getRect(find.byKey(viewportKey)).top;
          expect(
            tester.getRect(find.byKey(headerKey)).top,
            closeTo(top + kAccordionGutter, 0.5),
          );
          expect(find.byKey(headerKey), findsOneWidget);
          expect(
            find.byKey(const Key('accordion-pinned-heading')),
            findsNothing,
          );
          expect(find.byType(Visibility), findsNothing);
          final anchor = find.byType(AccordionAnchor);
          final lastBody = find.byKey(ValueKey('body-${short ? 0 : 19}'));
          expect(
            tester.getRect(anchor).bottom - tester.getRect(lastBody).bottom,
            kAccordionGutter,
          );
          final aligned = controller.offset;
          if (short) {
            final space = tester
                .getSize(find.byType(AccordionEdgeSpace))
                .height;
            expect(space, greaterThan(0));
            expect(space, lessThanOrEqualTo(400));
          } else {
            controller.jumpTo(aligned + (reverse ? -220 : 220));
            await tester.pumpAndSettle();
            expect(find.byKey(headerKey).hitTestable(), findsNothing);
            // Row 2 now starts exactly at the viewport top. A tap within the
            // former 60px heading slot must reach the body, not a clip/overlay.
            expect(
              tester.getRect(find.byKey(const ValueKey('body-2'))).top,
              closeTo(top + kAccordionGutter, 0.5),
            );
            await tester.tapAt(
              Offset(
                tester.getRect(find.byKey(viewportKey)).center.dx,
                top + 20,
              ),
            );
            await tester.pump(const Duration(milliseconds: 350));
            expect(bodyTaps, 1);
            expect(expanded, isTrue);
          }
          final reading = controller.offset;
          update(() => revision++);
          await tester.pumpAndSettle();
          expect(controller.offset, closeTo(reading, 0.5));
          controller.jumpTo(aligned);
          await tester.pumpAndSettle();
          final surface = Offset(
            tester.getRect(find.byKey(viewportKey)).left + 3,
            tester.getRect(find.byKey(headerKey)).bottom + 20,
          );
          await tester.dragFrom(surface, const Offset(0, -30));
          await tester.pumpAndSettle();
          expect(expanded, isTrue);
          controller.jumpTo(aligned);
          await tester.pumpAndSettle();
          await tester.tapAt(surface);
          await tester.pump(const Duration(milliseconds: 80));
          await tester.tapAt(surface);
          await tester.pumpAndSettle();
          expect(expanded, isFalse);
          expect(
            tester.getRect(find.byKey(headerKey)).top,
            closeTo(originalTop, 0.5),
          );
          expect(controller.position.maxScrollExtent, 0);
          for (final edge in find.byType(AccordionEdgeSpace).evaluate()) {
            expect(tester.getSize(find.byWidget(edge.widget)).height, 0);
          }
          expect(find.byKey(const ValueKey('body-0')), findsNothing);
          // A fresh explicit expansion is allowed to align again.
          await tester.tap(find.byKey(headerKey));
          await tester.pumpAndSettle();
          expect(
            tester.getRect(find.byKey(headerKey)).top,
            closeTo(top + kAccordionGutter, 0.5),
          );
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          controller.dispose();
        },
      );
    }
  }
}
