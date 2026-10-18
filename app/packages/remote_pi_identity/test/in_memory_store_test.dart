import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_pi_identity/remote_pi_identity.dart';

Uint8List _bytes(int seed) =>
    Uint8List.fromList(List.generate(32, (i) => (i * 7 + seed) & 0xff));

OwnerIdentity _ident({int seed = 0}) => OwnerIdentity(
      ownerPk: _bytes(seed + 1),
      ownerSk: _bytes(seed + 2),
    );

void main() {
  group('InMemoryOwnerIdentityStore', () {
    late InMemoryOwnerIdentityStore store;

    setUp(() {
      store = InMemoryOwnerIdentityStore();
    });

    tearDown(() async {
      await store.dispose();
    });

    test('load returns null on fresh store', () async {
      expect(await store.load(), isNull);
    });

    test('save → load roundtrips', () async {
      final id = _ident();
      await store.save(id);
      expect(await store.load(), equals(id));
    });

    test('save replaces previous identity', () async {
      final first = _ident(seed: 0);
      final second = _ident(seed: 10);
      await store.save(first);
      await store.save(second);
      expect(await store.load(), equals(second));
    });

    test('watch emits on each save', () async {
      final emitted = <OwnerIdentity>[];
      final sub = store.watch().listen(emitted.add);
      addTearDown(sub.cancel);

      final a = _ident(seed: 0);
      await store.save(a);
      await Future<void>.delayed(Duration.zero);
      expect(emitted, hasLength(1));
      expect(emitted.first, equals(a));

      final b = _ident(seed: 1);
      await store.save(b);
      await Future<void>.delayed(Duration.zero);
      expect(emitted, hasLength(2));
      expect(emitted.last, equals(b));
    });

    test('delete clears stored identity', () async {
      await store.save(_ident());
      await store.delete();
      expect(await store.load(), isNull);
    });

    test('isSyncAvailable reflects flag', () async {
      expect(await store.isSyncAvailable(), isTrue);
      store.syncAvailable = false;
      expect(await store.isSyncAvailable(), isFalse);
    });

    test('load/save/delete throw SyncUnavailable when flag is off', () async {
      store.syncAvailable = false;
      expect(store.load(), throwsA(isA<SyncUnavailable>()));
      expect(store.save(_ident()), throwsA(isA<SyncUnavailable>()));
      expect(store.delete(), throwsA(isA<SyncUnavailable>()));
    });

    test('initial value can be seeded', () async {
      final seeded = _ident();
      final s = InMemoryOwnerIdentityStore(initial: seeded);
      addTearDown(s.dispose);
      expect(await s.load(), equals(seeded));
    });
  });
}
