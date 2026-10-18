import 'dart:convert';
import 'dart:typed_data';

import 'package:app/data/mesh/mesh_blob.dart';
import 'package:app/data/mesh/mesh_envelope.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(int seed) =>
    Uint8List.fromList(List.generate(32, (i) => (i * 7 + seed) & 0xff));

MeshBlob _blob({int v = 1, List<MeshMember> members = const []}) => MeshBlob(
      version: v,
      issuedAt: 1747958400000,
      ownerPk: _bytes(1),
      members: members,
    );

void main() {
  group('MeshMember', () {
    test('toJson omits nickname when null', () {
      const m = MeshMember(
        remoteEpk: 'epk',
        relayUrl: 'wss://r',
        pairedAt: '2026-05-15T10:30:00Z',
      );
      expect(m.toJson().containsKey('nickname'), isFalse);
    });

    test('toJson includes nickname when set', () {
      const m = MeshMember(
        remoteEpk: 'epk',
        relayUrl: 'wss://r',
        pairedAt: '2026-05-15T10:30:00Z',
        nickname: 'Mac',
      );
      expect(m.toJson()['nickname'], 'Mac');
    });

    test('fromJson rejects missing required string fields', () {
      expect(
        () => MeshMember.fromJson({'remote_epk': 'x'}),
        throwsFormatException,
      );
    });
  });

  group('MeshBlob canonicalization', () {
    test('toCanonicalBytes sorts top-level keys lexicographically', () {
      final blob = _blob();
      final canon = utf8.decode(blob.toCanonicalBytes());
      // First non-{ char must be the first key — issued_at comes before
      // members which comes before owner_pk which comes before version.
      final keyOrder = RegExp(r'"(issued_at|members|owner_pk|version)"')
          .allMatches(canon)
          .map((m) => m.group(1))
          .toList();
      expect(keyOrder.take(4), ['issued_at', 'members', 'owner_pk', 'version']);
    });

    test('toCanonicalBytes sorts member keys lexicographically', () {
      final blob = _blob(
        members: const [
          MeshMember(
            remoteEpk: 'epk-z',
            relayUrl: 'wss://r',
            pairedAt: 't',
            nickname: 'n',
          ),
        ],
      );
      final canon = utf8.decode(blob.toCanonicalBytes());
      // member object: keys must come as nickname, paired_at, relay_url, remote_epk
      final memberMatch = RegExp(r'\{[^}]*"remote_epk"[^}]*\}').firstMatch(canon);
      expect(memberMatch, isNotNull);
      final obj = memberMatch!.group(0)!;
      final keyOrder = RegExp(r'"(nickname|paired_at|relay_url|remote_epk)"')
          .allMatches(obj)
          .map((m) => m.group(1))
          .toList();
      expect(keyOrder, ['nickname', 'paired_at', 'relay_url', 'remote_epk']);
    });

    test('toCanonicalBytes is deterministic across constructions', () {
      final a = _blob(members: const [
        MeshMember(
          remoteEpk: 'epk-a',
          relayUrl: 'wss://r',
          pairedAt: 't',
        ),
      ]);
      final b = _blob(members: const [
        MeshMember(
          remoteEpk: 'epk-a',
          relayUrl: 'wss://r',
          pairedAt: 't',
        ),
      ]);
      expect(a.toCanonicalBytes(), equals(b.toCanonicalBytes()));
    });

    test('toCanonicalBytes contains no whitespace', () {
      final blob = _blob(members: const [
        MeshMember(
          remoteEpk: 'epk',
          relayUrl: 'wss://r',
          pairedAt: 't',
        ),
      ]);
      final bytes = blob.toCanonicalBytes();
      for (final b in bytes) {
        expect(b, isNot(0x20), reason: 'space byte at offset');
        expect(b, isNot(0x09), reason: 'tab byte');
        expect(b, isNot(0x0a), reason: 'newline byte');
      }
    });

    test('fromCanonicalBytes roundtrips', () {
      final original = _blob(members: const [
        MeshMember(
          remoteEpk: 'epk-a',
          relayUrl: 'wss://r',
          pairedAt: '2026-05-15T10:30:00Z',
          nickname: 'Mac',
        ),
        MeshMember(
          remoteEpk: 'epk-b',
          relayUrl: 'wss://r2',
          pairedAt: '2026-05-16T10:30:00Z',
        ),
      ]);
      final parsed = MeshBlob.fromCanonicalBytes(original.toCanonicalBytes());
      expect(parsed.version, original.version);
      expect(parsed.issuedAt, original.issuedAt);
      expect(parsed.ownerPk, original.ownerPk);
      expect(parsed.members.length, 2);
      expect(parsed.members[0].nickname, 'Mac');
      expect(parsed.members[1].nickname, isNull);
    });

    test('fromCanonicalBytes rejects non-JSON bytes', () {
      expect(
        () => MeshBlob.fromCanonicalBytes(Uint8List.fromList([0xff, 0xfe])),
        throwsFormatException,
      );
    });

    test('fromCanonicalBytes rejects non-positive version', () {
      final bytes = Uint8List.fromList(utf8.encode(
        '{"issued_at":1,"members":[],"owner_pk":"AA==","version":0}',
      ));
      expect(() => MeshBlob.fromCanonicalBytes(bytes), throwsFormatException);
    });
  });

  group('MeshBlob sign / verify', () {
    test('signWith → verifyEnvelope roundtrips against the matching pk',
        () async {
      final ed = Ed25519();
      final keyPair = await ed.newKeyPair();
      final pub = await keyPair.extractPublicKey();
      final blob = MeshBlob(
        version: 7,
        issuedAt: 1700000000000,
        ownerPk: Uint8List.fromList(pub.bytes),
        members: const [
          MeshMember(
            remoteEpk: 'epk',
            relayUrl: 'wss://r',
            pairedAt: 't',
          ),
        ],
      );
      final envelope = await blob.signWith(keyPair);
      expect(envelope.blob, equals(blob.toCanonicalBytes()));
      expect(await MeshBlob.verifyEnvelope(envelope), isTrue);
    });

    test('verifyEnvelope rejects tampered blob', () async {
      final ed = Ed25519();
      final keyPair = await ed.newKeyPair();
      final pub = await keyPair.extractPublicKey();
      final blob = MeshBlob(
        version: 1,
        issuedAt: 1,
        ownerPk: Uint8List.fromList(pub.bytes),
      );
      final envelope = await blob.signWith(keyPair);
      final tampered = MeshEnvelope(
        blob: Uint8List.fromList([...envelope.blob]..first ^= 0xff),
        sig: envelope.sig,
      );
      expect(await MeshBlob.verifyEnvelope(tampered), isFalse);
    });
  });

  group('MeshEnvelope JSON', () {
    test('toJson + fromJson roundtrip', () {
      final env = MeshEnvelope(
        blob: Uint8List.fromList([1, 2, 3, 4]),
        sig: Uint8List.fromList(List.filled(64, 7)),
      );
      final restored = MeshEnvelope.fromJson(env.toJson());
      expect(restored.blob, env.blob);
      expect(restored.sig, env.sig);
    });

    test('fromJson rejects non-string fields', () {
      expect(
        () => MeshEnvelope.fromJson({'blob': 1, 'sig': 'x'}),
        throwsFormatException,
      );
    });
  });
}
