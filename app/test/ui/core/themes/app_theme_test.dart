import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/ui/core/themes/themes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'terminal text tokens meet body contrast on their rendered backgrounds',
    () {
      double contrast(Color a, Color b) {
        final x = a.computeLuminance();
        final y = b.computeLuminance();
        return x > y ? (x + .05) / (y + .05) : (y + .05) / (x + .05);
      }

      for (final c in [AppColors.dark, AppColors.light]) {
        for (final token in [
          c.text,
          c.muted,
          c.muted2,
          c.accent,
          c.highlight,
          c.success,
          c.error,
          c.warning,
        ]) {
          for (final background in [c.bg, c.surface]) {
            expect(contrast(token, background), greaterThanOrEqualTo(4.5));
          }
        }
        // Check the actual selected tile composite as well as opaque surfaces.
        for (final background in [
          c.bg,
          c.surface,
          c.inputFill,
          Color.alphaBlend(c.accent.withValues(alpha: 0.06), c.bg),
        ]) {
          expect(contrast(c.working, background), greaterThanOrEqualTo(4.5));
        }
        expect(c.working.g, greaterThan(c.working.r));
        expect(c.working.g, greaterThan(c.working.b));
      }
    },
  );

  test(
    'offline Fira Mono manifest includes licensed regular medium bold faces',
    () async {
      final manifest =
          jsonDecode(await rootBundle.loadString('FontManifest.json'))
              as List<dynamic>;
      final font = manifest.cast<Map<String, dynamic>>().singleWhere(
        (entry) => entry['family'] == kMonoFamily,
      );
      final faces = (font['fonts'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(faces.map((face) => face['weight']), [400, 500, 700]);
      for (final face in faces) {
        expect(
          (await rootBundle.load(face['asset'] as String)).lengthInBytes,
          greaterThan(0),
        );
        // No local italic face exists: Flutter deliberately synthesizes italic.
        expect(face['style'], isNull);
      }
      expect(
        await rootBundle.loadString('assets/fonts/fira_mono/LICENSE'),
        contains('SIL OPEN FONT LICENSE'),
      );
    },
  );

  test('dark theme uses terminal palette and keeps readable surfaces', () {
    final colors = AppColors.dark;
    expect(colors.bg, const Color(0xFF14191F));
    expect(colors.text, const Color(0xFFF2F6FC));
    expect(colors.accent, const Color(0xFF8BE9FD));
    expect(colors.surface, isNot(colors.bg));
    expect(colors.inputFill, isNot(colors.bg));
    expect(colors.success, const Color(0xFF50FA7B));
    expect(colors.warning, const Color(0xFFFFB86C));
    expect(colors.error, const Color(0xFFFF5555));
  });

  test(
    'mono typography resolves bundled Fira Mono while brand remains Inter',
    () {
      expect(kMonoFamily, 'FiraMono Nerd Font');
      expect(AppTypography.dark.mono.fontFamily, kMonoFamily);
      expect(AppTypography.light.mono.fontFamily, kMonoFamily);
      expect(brandTextStyle(fontSize: 20).fontFamily, contains('Inter'));
      expect(buildLightTheme().brightness, Brightness.light);
    },
  );
}
