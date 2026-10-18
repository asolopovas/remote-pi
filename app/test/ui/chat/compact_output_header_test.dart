import 'package:app/ui/chat/widgets/compact_output_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('status is one named icon, not a visible word beside title', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.binding.setSurfaceSize(const Size(320, 180));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final (status, icon) in [
      ('DONE', Icons.check_circle),
      ('FAILED', Icons.error),
      ('RUNNING', Icons.sync),
      ('UNKNOWN', Icons.info_outline),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CompactOutputHeader(
              title: 'A command title that should remain readable',
              status: status,
              icon: icon,
              expanded: true,
              disclosureKey: const Key('header'),
              onToggle: _noop,
            ),
          ),
        ),
      );
      expect(find.text(status), findsNothing);
      expect(find.byTooltip(status), findsOneWidget);
      expect(find.bySemanticsLabel(status), findsOneWidget);
      expect(find.byIcon(icon), findsOneWidget);
      final title = tester.widget<Text>(
        find.text('A command title that should remain readable'),
      );
      expect(title.maxLines, 1);
      expect(title.overflow, TextOverflow.ellipsis);
      expect(tester.getSize(find.byKey(const Key('header'))).height, 48);
      expect(tester.takeException(), isNull);
    }
    semantics.dispose();
  });

  testWidgets('long status semantics do not consume title space at 2x', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 180));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: SizedBox(
              width: 280,
              child: CompactOutputHeader(
                title: 'A long command title that is allowed to truncate',
                status: 'FAILED WITH A VERY LONG STATUS DESCRIPTION',
                expanded: true,
                disclosureKey: Key('header'),
                onToggle: _noop,
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byKey(const Key('header'))).height, 48);
    expect(
      find.text('FAILED WITH A VERY LONG STATUS DESCRIPTION'),
      findsNothing,
    );
  });
}

void _noop() {}
