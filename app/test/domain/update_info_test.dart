import 'dart:convert';

import 'package:app/domain/entities/update_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UpdateInfo.fromJson', () {
    test('parses a well-formed Android manifest', () {
      final json = jsonDecode('''
        {
          "version": "1.2.0",
          "date": "2026-06-12",
          "notes": "Bug fixes",
          "artifacts": [
            { "platform": "android", "arch": "universal", "format": "apk",
              "url": "https://example.com/RemotePi.apk",
              "sha256": "abc", "size": 1234 }
          ]
        }
      ''');
      final info = UpdateInfo.fromJson(json);
      expect(info.version, '1.2.0');
      expect(info.date, '2026-06-12');
      expect(info.notes, 'Bug fixes');
      expect(info.artifacts, hasLength(1));
      final a = info.artifacts.single;
      expect(a.platform, 'android');
      expect(a.format, 'apk');
      expect(a.arch, 'universal');
      expect(a.url, 'https://example.com/RemotePi.apk');
      expect(a.sha256, 'abc');
      expect(a.size, 1234);
    });

    test('tolerates missing optional fields (date/notes/arch/sha256/size)', () {
      final info = UpdateInfo.fromJson({
        'version': '1.0.0',
        'artifacts': [
          {'platform': 'android', 'format': 'apk', 'url': 'https://x/y.apk'},
        ],
      });
      expect(info.date, '');
      expect(info.notes, '');
      final a = info.artifacts.single;
      expect(a.arch, '');
      expect(a.sha256, '');
      expect(a.size, 0);
    });

    test('throws FormatException when not a JSON object', () {
      expect(() => UpdateInfo.fromJson('nope'), throwsFormatException);
      expect(() => UpdateInfo.fromJson(null), throwsFormatException);
    });

    test('throws FormatException when version missing/empty', () {
      expect(
        () => UpdateInfo.fromJson({'artifacts': const []}),
        throwsFormatException,
      );
      expect(
        () => UpdateInfo.fromJson({'version': '', 'artifacts': const []}),
        throwsFormatException,
      );
    });

    test('throws FormatException when artifacts is not a list', () {
      expect(
        () => UpdateInfo.fromJson({'version': '1.0.0', 'artifacts': 'x'}),
        throwsFormatException,
      );
    });

    test('throws FormatException when an artifact misses required fields', () {
      expect(
        () => UpdateInfo.fromJson({
          'version': '1.0.0',
          'artifacts': [
            {'platform': 'android'}, // no url / format
          ],
        }),
        throwsFormatException,
      );
    });
  });

  group('UpdateInfo.artifactFor', () {
    UpdateInfo build(List<Map<String, Object?>> artifacts) =>
        UpdateInfo.fromJson({'version': '1.0.0', 'artifacts': artifacts});

    test('matches platform + format (android/apk)', () {
      final info = build([
        {
          'platform': 'android',
          'arch': 'universal',
          'format': 'apk',
          'url': 'https://x/RemotePi.apk',
        },
      ]);
      final a = info.artifactFor(
        platform: 'android',
        format: 'apk',
        arch: 'universal',
      );
      expect(a, isNotNull);
      expect(a!.url, 'https://x/RemotePi.apk');
    });

    test('returns null when no compatible artifact (e.g. only macos/dmg)', () {
      final info = build([
        {
          'platform': 'macos',
          'arch': 'universal',
          'format': 'dmg',
          'url': 'https://x/RemotePi.dmg',
        },
      ]);
      final a = info.artifactFor(
        platform: 'android',
        format: 'apk',
        arch: 'universal',
      );
      expect(a, isNull);
    });
  });
}
