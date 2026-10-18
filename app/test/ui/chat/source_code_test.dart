import 'package:app/ui/chat/widgets/source_code.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Set<Color> _colors(InlineSpan span) => {
  ?span.style?.color,
  if (span is TextSpan)
    for (final child in span.children ?? <InlineSpan>[]) ..._colors(child),
};

void main() {
  testWidgets(
    'known aliases have colored tokens and lossless plaintext in both themes',
    (tester) async {
      for (final theme in [buildDarkTheme(), buildLightTheme()]) {
        for (final entry in {
          'shell': '# comment\nif true; then\n  echo "hello"\nfi\n',
          'pwsh': '# comment\nif (\$true) {\n  Write-Output "hello"\n}\n',
          'js': '// comment\nconst x = "hello";\nconsole.log(x);\n',
          'ts': '// comment\nconst x: number = 42;\n',
          'py': '# comment\nprint("hello")\n',
          'rs': 'fn example() -> i32 { 42 }\n',
          'go': 'package main\nfunc main() { println("hello") }\n',
          'kt': 'fun main() { val message = "hello" }\n',
          'java': 'class Example { static int value = 42; }\n',
          'sql': "SELECT 'hello' FROM users WHERE id = 42;\n",
          'swift': 'let message = "hello"\n',
        }.entries) {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: Scaffold(
                body: SelectionArea(
                  child: SourceCode(entry.value, language: entry.key),
                ),
              ),
            ),
          );
          final span = tester.widget<Text>(find.byType(Text)).textSpan!;
          expect(span.toPlainText(), entry.value);
          expect(_colors(span).length, greaterThan(2), reason: entry.key);
        }
      }
    },
  );

  testWidgets(
    'unknown and huge source fallback is lossless; updates replace cached tree',
    (tester) async {
      for (final entry in {
        'unknown': 'literal \\n and \\t\n  actual indentation\n',
        'javascript': 'const x = "hello";\n' * 2000,
        'bash': 'echo "unterminated\n\\n',
      }.entries) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: SourceCode(entry.value, language: entry.key)),
          ),
        );
        final span = tester.widget<Text>(find.byType(Text)).textSpan!;
        expect(span.toPlainText(), entry.value);
        if (entry.key != 'bash') expect((span as TextSpan).children, isNull);
      }
    },
  );
}
