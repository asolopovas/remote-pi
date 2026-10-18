import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_pi_identity/remote_pi_identity.dart';

Uint8List _bytes(int seed) =>
    Uint8List.fromList(List.generate(32, (i) => (i * 7 + seed) & 0xff));

void main() {
  group('OwnerIdentity', () {
    test('constructor rejects non-32B public key', () {
      expect(
        () => OwnerIdentity(
          ownerPk: Uint8List(16),
          ownerSk: _bytes(0),
        ),
        throwsArgumentError,
      );
    });

    test('constructor rejects non-32B private key', () {
      expect(
        () => OwnerIdentity(
          ownerPk: _bytes(0),
          ownerSk: Uint8List(31),
        ),
        throwsArgumentError,
      );
    });

    test('toBlob produces a 64-byte buffer with pk||sk layout', () {
      final id = OwnerIdentity(ownerPk: _bytes(1), ownerSk: _bytes(2));
      final blob = id.toBlob();
      expect(blob, hasLength(64));
      expect(Uint8List.sublistView(blob, 0, 32), equals(id.ownerPk));
      expect(Uint8List.sublistView(blob, 32, 64), equals(id.ownerSk));
    });

    test('toBlob → fromBlob roundtrips', () {
      final id = OwnerIdentity(ownerPk: _bytes(1), ownerSk: _bytes(2));
      final reborn = OwnerIdentity.fromBlob(id.toBlob());
      expect(reborn, equals(id));
    });

    test('fromBlob rejects undersize input', () {
      expect(
        () => OwnerIdentity.fromBlob(Uint8List(63)),
        throwsFormatException,
      );
    });

    test('fromBlob rejects oversize input', () {
      expect(
        () => OwnerIdentity.fromBlob(Uint8List(65)),
        throwsFormatException,
      );
    });

    test('fromBlob rejects empty input', () {
      expect(
        () => OwnerIdentity.fromBlob(Uint8List(0)),
        throwsFormatException,
      );
    });

    test('equality + hashCode are value-based', () {
      final a = OwnerIdentity(ownerPk: _bytes(1), ownerSk: _bytes(2));
      final b = OwnerIdentity(ownerPk: _bytes(1), ownerSk: _bytes(2));
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('constructor copies input bytes (no aliasing)', () {
      final pk = _bytes(1);
      final sk = _bytes(2);
      final id = OwnerIdentity(ownerPk: pk, ownerSk: sk);
      pk[0] = 0xff;
      sk[0] = 0xff;
      // Mutation of the caller's buffer must not leak into the
      // identity — fields are defensively copied.
      expect(id.ownerPk[0], isNot(0xff));
      expect(id.ownerSk[0], isNot(0xff));
    });
  });
}
