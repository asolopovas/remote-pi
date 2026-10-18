// Plan/27 Wave A — post-pair nickname modal.

import 'package:app/ui/pairing/widgets/nickname_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _openSheet(
  WidgetTester tester, {
  required String? defaultName,
  required void Function(String?) onResult,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ElevatedButton(
            child: const Text('open'),
            onPressed: () async {
              final result = await showNicknameSheet(
                ctx,
                defaultName: defaultName,
              );
              onResult(result);
            },
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('showNicknameSheet (plan/27 Wave A)', () {
    testWidgets(
      'Save with non-empty input returns the trimmed input',
      (tester) async {
        String? result;
        await _openSheet(
          tester,
          defaultName: 'Mac do Jacob',
          onResult: (v) => result = v,
        );

        await tester.enterText(
          find.byKey(const Key('nickname-sheet-field')),
          '  Macbook  ',
        );
        await tester.tap(find.byKey(const Key('nickname-sheet-save')));
        await tester.pumpAndSettle();

        expect(result, 'Macbook');
      },
    );

    testWidgets(
      'Save with empty input falls back to the hostname hint',
      (tester) async {
        String? result;
        await _openSheet(
          tester,
          defaultName: 'Mac do Jacob',
          onResult: (v) => result = v,
        );

        await tester.tap(find.byKey(const Key('nickname-sheet-save')));
        await tester.pumpAndSettle();

        expect(result, 'Mac do Jacob');
      },
    );

    testWidgets(
      'Skip returns the hostname hint when one was passed',
      (tester) async {
        String? result;
        await _openSheet(
          tester,
          defaultName: 'Mac do Jacob',
          onResult: (v) => result = v,
        );

        await tester.tap(find.byKey(const Key('nickname-sheet-skip')));
        await tester.pumpAndSettle();

        expect(result, 'Mac do Jacob');
      },
    );

    testWidgets(
      'Skip returns "Pi" when no hostname hint is available (legacy Pi)',
      (tester) async {
        String? result;
        await _openSheet(
          tester,
          defaultName: null,
          onResult: (v) => result = v,
        );

        await tester.tap(find.byKey(const Key('nickname-sheet-skip')));
        await tester.pumpAndSettle();

        expect(result, 'Pi');
      },
    );

    testWidgets(
      'placeholder text reflects the hostname hint',
      (tester) async {
        await _openSheet(
          tester,
          defaultName: 'Mac do Jacob',
          onResult: (_) {},
        );

        // hintText is rendered as a Text inside the TextField — assert
        // by finding it on screen.
        expect(find.text('Mac do Jacob'), findsWidgets);
      },
    );
  });
}
