import 'dart:convert';
import 'dart:io';
import 'package:app/ui/chat/widgets/codemode_preview.dart';
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
  test(
    'single codemode wrapper uses the entire strict body without accepting padding prose or malformed markers',
    () {
      final input = File(
        'test/ui/chat/fixtures/75/75-single-codemode-result.txt',
      ).readAsStringSync();
      const prefix = 'Script completed\nWall time 0.1 seconds\nOutput:\n';
      final body = input.substring(prefix.length);
      const rendered =
          'plan75 harmless preview line1\nplan75 harmless preview line2\n';
      expect(readableToolOutput('codemode', input), rendered);
      for (final gap in ['\n', '\n\n']) {
        final envelope = 'Script completed\nWall time 0.1 seconds\nOutput:$gap';
        for (final validBody in [
          body,
          '${const JsonEncoder.withIndent('  ').convert(jsonDecode(body))}\n',
        ]) {
          expect(readableCodemodeOutput('$envelope$validBody'), rendered);
        }
      }
      for (final invalidBody in [
        '',
        'plain result',
        '{"output":"x"}',
        '{"output":',
        '{"output":"x","output":"y","truncated":false,"exit_code":0,"wall_time_seconds":0.1}',
        r'{"output":"x","\u006futput":"y","truncated":false,"exit_code":0,"wall_time_seconds":0.1}',
        '{"output":"x","truncated":false,"exit_code":"0","wall_time_seconds":0.1}',
        '$body trailing text',
        'garbage\n$body',
        ' $body',
        '\t$body',
        '\n\n$body',
        '==> text 0/1 <==\n$body',
        '==> text 1/1 <==$body',
        '$body\n==> text 1/2 <==\n',
        '$body\n==> text malformed <==\n',
      ]) {
        final malformed = '$prefix$invalidBody';
        expect(readableCodemodeOutput(malformed), malformed);
      }
      expect(readableCodemodeOutput(body), body);
      expect(readableToolOutput('unknown', input), isNull);
    },
  );
  test(
    'device codemode envelope accepts exactly one or two LF and compacts headers without changing plain sections',
    () {
      final device = File(
        'test/ui/chat/fixtures/75/75-device-codemode-result.txt',
      ).readAsStringSync();
      expect(device.length, 3229);
      expect(
        device,
        startsWith(
          'Script completed\nWall time 1.7 seconds\nOutput:\n==> text 1/2 <==\n',
        ),
      );
      for (final original in [device, result]) {
        final firstMarker = original.indexOf('==> text 1/');
        final gapStart = original.indexOf('Output:') + 'Output:'.length;
        for (final gap in ['\n', '\n\n']) {
          final input =
              original.substring(0, gapStart) +
              gap +
              original.substring(firstMarker);
          final readable = readableCodemodeOutput(input);
          expect(readable, isNot(input));
          expect(readable, startsWith('Output 1\n'));
          if (original == device) {
            final firstBody = input.substring(
              input.indexOf('==> text 1/2 <==\n') + '==> text 1/2 <==\n'.length,
              input.indexOf('==> text 2/2 <==\n'),
            );
            expect(readable, startsWith('Output 1\n$firstBody'));
            expect(
              readable,
              contains(
                'Output 2\nada9775762faaa67f59314d3ec58aa460829f345253a58e64b5ce47202e64068',
              ),
            );
            expect(
              readable,
              contains(
                'ada9775762faaa67f59314d3ec58aa460829f345253a58e64b5ce47202e64068  app/build/75-readable/code22.apk\n74df2ae06c445e2b2215742c053064b4bc69803820659e250a6700114ed57f95  app/lib/ui/chat/widgets/codemode_preview.dart\n',
              ),
            );
          } else {
            expect(
              readable,
              contains('Output 2\nSuccessfully replaced 2 block(s)'),
            );
            expect(readable, contains('Installed 1 package in 11ms\nHEY PC'));
            expect(readable, isNot(contains('Result metadata:')));
          }
        }
        for (final gap in [
          '',
          '\n\n\n',
          '\n\n\n\n',
          '\n garbage\n',
          '\n \n',
          '\r\n',
        ]) {
          final input =
              original.substring(0, gapStart) +
              gap +
              original.substring(firstMarker);
          expect(readableCodemodeOutput(input), input);
        }
      }
      for (final malformed in [
        device.replaceFirst('Script completed', 'Script done'),
        device.replaceFirst(
          'Wall time 1.7 seconds',
          'Wall time unknown seconds',
        ),
        'prefix\n$device',
      ]) {
        expect(readableCodemodeOutput(malformed), malformed);
      }
    },
  );
  test(
    'line comments terminate at all four JS line endings without partial previews',
    () {
      for (final ending in ['\n', '\r', '\u2028', '\u2029', '\r\n']) {
        const first =
            'tools.bash({command:"first"}); // ignored tools.bash({command:fake});';
        expect(
          embeddedCodemodeSource(
            '$first${ending}tools.bash({command:dynamic});',
          ),
          isEmpty,
          reason: 'terminator ${ending.codeUnits}',
        );
        expect(
          embeddedCodemodeSource(
            '$first${ending}tools.bash({command:"second\\nline"});',
          ).map((p) => p.text),
          ['first', 'second\nline'],
        );
        expect(
          embeddedCodemodeSource(
            '${ending}tools.bash({command:"first"});$ending',
          ).single.text,
          'first',
        );
      }
    },
  );
  test(
    'embedded language inference requires a basename extension on Unix and Windows paths',
    () {
      for (final path in [
        'json',
        'bash',
        'typescript',
        'folder.json/bash',
        r'C:\folder.json\bash',
        r'C:\folder.ts\json',
      ]) {
        for (final call in [
          'tools.write({path:${jsonEncode(path)},content:"read-only"});',
          'tools.edit({path:${jsonEncode(path)},edits:[{oldText:"before",newText:"after"}]});',
        ]) {
          final previews = embeddedCodemodeSource(call);
          expect(previews, isNotEmpty, reason: path);
          expect(
            previews.map((p) => p.language),
            everyElement('text'),
            reason: path,
          );
        }
      }
      for (final entry in {
        'folder.dot/file.json': 'json',
        r'C:\folder.dot\file.ts': 'typescript',
        'folder.json/file.sh': 'bash',
        r'C:\folder.json\file.ps1': 'powershell',
      }.entries) {
        expect(
          embeddedCodemodeSource(
            'tools.write({path:${jsonEncode(entry.key)},content:"read-only"});',
          ).single.language,
          entry.value,
        );
      }
    },
  );
  test(
    'known shell wrappers show essential warnings, preserve contents and reject other data/repr',
    () {
      final cases =
          jsonDecode(
                File(
                  'test/ui/chat/fixtures/75/output-cases.json',
                ).readAsStringSync(),
              )
              as List;
      for (final entry in cases) {
        for (final tool in ['bash', 'powershell']) {
          expect(
            readableToolOutput(tool, entry['raw']),
            entry['expected'],
            reason: entry['name'] as String,
          );
          if (entry.containsKey('wrapper')) {
            expect(
              readableToolOutput(tool, entry['wrapper']),
              entry['expected'],
            );
          }
        }
        const prefix =
            'Script completed\nWall time 1 seconds\nOutput:\n\n==> text 1/1 <==\n';
        final expected = entry['expected'] as String?;
        expect(
          readableCodemodeOutput('$prefix${entry['raw']}'),
          expected == null
              ? '${entry['raw']}'
              : '$expected${expected.endsWith('\n') ? '' : '\n'}',
        );
        for (final unknown in ['unknown', 'write', 'edit', 'notbash']) {
          expect(readableToolOutput(unknown, entry['raw']), isNull);
          expect(readableToolOutput(unknown, entry['wrapper']), isNull);
        }
      }
      for (final invalid in [
        {
          'output': 'x',
          'truncated': false,
          'exit_code': 0,
          'wall_time_seconds': double.nan,
        },
        {
          'output': 'x',
          'truncated': false,
          'exit_code': 0,
          'wall_time_seconds': double.infinity,
        },
        {
          'output': 'x' * 96001,
          'truncated': false,
          'exit_code': 0,
          'wall_time_seconds': 1,
        },
      ]) {
        expect(readableToolOutput('bash', invalid), isNull);
      }
    },
  );
  test('static-cases decode one supported layer or decline entire script', () {
    final cases =
        jsonDecode(
              File(
                'test/ui/chat/fixtures/75/static-cases.json',
              ).readAsStringSync(),
            )
            as List;
    for (final entry in cases) {
      final previews = embeddedCodemodeSource(entry['source'] as String);
      if (entry.containsKey('expected')) {
        expect(previews.map((p) => p.text), [
          entry['expected'],
        ], reason: entry['name'] as String);
      } else {
        expect(previews, isEmpty, reason: entry['name'] as String);
      }
    }
    expect(
      embeddedCodemodeSource('tools.bash({command:"${'x' * 24000}"});'),
      isEmpty,
    );
    expect(embeddedCodemodeSource('tools.bash({command:"x"});' * 33), isEmpty);
    expect(
      embeddedCodemodeSource(
        'tools.bash({command:"x",timeout:${'[' * 18}0${']' * 18}});',
      ),
      isEmpty,
    );
    // Truncation cannot crash or manufacture a partially decoded string.
    for (var i = 0; i < script.length; i++) {
      expect(
        () => embeddedCodemodeSource(script.substring(0, i)),
        returnsNormally,
      );
    }
  });
  test(
    'recovered input preserves embedded Bash/Edit bodies and literal escapes',
    () {
      final previews = embeddedCodemodeSource(script);
      expect(previews.length, 8);
      expect(previews.first.language, 'bash');
      expect(
        previews.first.text,
        startsWith(
          "uv run --with sentencepiece --no-project python - <<'PY'\nfrom pathlib import Path\n",
        ),
      );
      expect(previews.first.text, contains(r"+' @hey_pc\n')"));
      expect(previews.first.text.split('\n').length, 28);
      expect(previews[1].text, contains('\n\t\t"messages"'));
      expect(previews[2].text, contains('\n\tfor _, example'));
      expect(previews[5].text, contains('\ntuios new-window'));
      expect(previews.last.text, contains(r"printf '\n%s\n'"));
      expect(previews.map((p) => p.offset).toSet().length, previews.length);
    },
  );
  test('codemode output unwraps only complete known sections in order', () {
    expect(result.length, 2961);
    final readable = readableCodemodeOutput(result);
    expect(readable, isNot(contains('Result metadata:')));
    expect(readable, isNot(contains('wall_time_seconds')));
    expect(readable, isNot(contains('Script completed')));
    expect(readable, contains("Installed 1 package in 11ms\nHEY PC"));
    expect(readable, contains('Output 2\nSuccessfully replaced 2 block(s)'));
    expect(readable, contains('Output 3\nSuccessfully replaced 1 block(s)'));
    expect(
      readable,
      contains('Output 4\n?   \tai-pc/cmd/ai-pc\t[no test files]'),
    );
    for (var i = 1; i < 4; i++) {
      expect(
        readable.indexOf('Output $i\n'),
        lessThan(readable.indexOf('Output ${i + 1}\n')),
      );
    }
    const prefix =
        'Script completed\nWall time 1 seconds\nOutput:\n\n==> text 1/1 <==\n';
    for (final body in [
      '{"output":"a\\nb"}',
      '{"other":"a\\nb"}',
      '{"output":',
      '{"output":42,"truncated":false,"exit_code":0,"wall_time_seconds":1}',
      '{"output":"x","output":"y","truncated":false,"exit_code":0,"wall_time_seconds":1}',
      'plain literal \\n',
    ]) {
      expect(readableCodemodeOutput('$prefix$body'), body);
    }
    final wrapper = jsonEncode({
      'output': 'a\n${r'\n C:\tmp'}',
      'truncated': false,
      'exit_code': 0,
      'wall_time_seconds': 1,
    });
    expect(readableCodemodeOutput('$prefix$wrapper'), 'a\n${r'\n C:\tmp'}\n');
    expect(readableCodemodeOutput(wrapper), wrapper);
    final unordered = result.replaceFirst('text 2/4', 'text 3/4');
    expect(readableCodemodeOutput(unordered), unordered);
    final truncated = result.substring(0, result.indexOf('==> text 4/4'));
    expect(readableCodemodeOutput(truncated), truncated);
    expect(
      readableCodemodeOutput('$prefix${'x' * 96000}'),
      '$prefix${'x' * 96000}',
    );
  });
}
