import 'package:app/domain/value_objects/semver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('compareSemver', () {
    test('equal versions → 0', () {
      expect(compareSemver('1.1.0', '1.1.0'), 0);
    });

    test('greater major/minor/patch → 1', () {
      expect(compareSemver('2.0.0', '1.9.9'), 1);
      expect(compareSemver('1.2.0', '1.1.9'), 1);
      expect(compareSemver('1.1.1', '1.1.0'), 1);
    });

    test('smaller → -1', () {
      expect(compareSemver('1.0.0', '1.0.1'), -1);
      expect(compareSemver('1.9.9', '2.0.0'), -1);
    });

    test('numeric per-component (not lexical) — 1.10.0 > 1.9.0', () {
      expect(compareSemver('1.10.0', '1.9.0'), 1);
    });

    test('missing components count as 0 (1.2 == 1.2.0)', () {
      expect(compareSemver('1.2', '1.2.0'), 0);
    });

    test('pre-release / build suffix ignored', () {
      expect(compareSemver('1.1.0-beta', '1.1.0'), 0);
      expect(compareSemver('1.1.0+5', '1.1.0'), 0);
    });

    test('non-numeric components count as 0', () {
      expect(compareSemver('x.y.z', '0.0.0'), 0);
    });
  });

  group('isNewerVersion', () {
    test('true only when candidate is strictly greater', () {
      expect(isNewerVersion('1.2.0', '1.1.0'), isTrue);
      expect(isNewerVersion('1.1.0', '1.1.0'), isFalse);
      expect(isNewerVersion('1.0.0', '1.1.0'), isFalse);
    });
  });
}
