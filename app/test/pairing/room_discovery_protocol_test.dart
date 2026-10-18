// Plan 17 fix — protocol additions for room discovery.

import 'dart:convert';

import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PairOk — plan 17 room_id', () {
    test('parses room_id from pair_ok payload', () {
      final j = {
        'type': 'pair_ok',
        'in_reply_to': 'cli_1',
        'session_name': 'Pi',
        'session_started_at': 1700000000000,
        'room_id': 'cwd-uuid-1234',
      };
      final m = PairOk.fromJson(j);
      expect(m.roomId, 'cwd-uuid-1234');
      expect(m.sessionName, 'Pi');
      expect(m.sessionStartedAt, 1700000000000);
    });

    test('legacy pair_ok (no room_id field) falls back to "main"', () {
      final j = {
        'type': 'pair_ok',
        'in_reply_to': 'cli_1',
        'session_name': 'Pi',
        'session_started_at': 1700000000000,
      };
      final m = PairOk.fromJson(j);
      expect(m.roomId, 'main');
    });
  });

  group('PeerRecord — plan 17 roomId', () {
    test('roundtrip preserves roomId', () {
      const peer = PeerRecord(
        remoteEpk: 'epk_A',
        sessionName: 'Pi',
        relayUrl: 'wss://relay.example',
        pairedAt: '2026-01-01T00:00:00Z',
        roomId: 'room-xyz',
      );
      final j = peer.toJson();
      final back = PeerRecord.fromJson(j);
      expect(back.roomId, 'room-xyz');
      expect(back, peer);
    });

    test('legacy PeerRecord JSON (no room_id) hydrates with roomId=null',
        () {
      final j = {
        'remote_epk': 'epk_legacy',
        'session_name': 'Pi',
        'relay_url': 'wss://relay.example',
        'paired_at': '2025-12-01T00:00:00Z',
        // No 'room_id' key — pre-fix records.
      };
      final p = PeerRecord.fromJson(j);
      expect(p.roomId, isNull);
      expect(p.remoteEpk, 'epk_legacy');
    });

    test('copyWith(roomId: ...) overrides; default keeps existing',
        () {
      const peer = PeerRecord(
        remoteEpk: 'epk_A',
        sessionName: 'Pi',
        relayUrl: 'wss://relay.example',
        pairedAt: '2026-01-01T00:00:00Z',
        roomId: 'room-old',
      );
      // Default = keep
      final same = peer.copyWith(sessionName: 'Pi2');
      expect(same.roomId, 'room-old');
      // Explicit override
      final updated = peer.copyWith(roomId: 'room-new');
      expect(updated.roomId, 'room-new');
      // Explicit null clears
      final cleared = peer.copyWith(roomId: null);
      expect(cleared.roomId, isNull);
    });

    test('toJson includes room_id even when null', () {
      const peer = PeerRecord(
        remoteEpk: 'epk_A',
        sessionName: 'Pi',
        relayUrl: 'wss://relay.example',
        pairedAt: '2026-01-01T00:00:00Z',
      );
      final j = peer.toJson();
      expect(j.containsKey('room_id'), isTrue);
      expect(j['room_id'], isNull);
      // Serializable end-to-end.
      final s = jsonEncode(j);
      final back = PeerRecord.fromJson(
          jsonDecode(s) as Map<String, dynamic>);
      expect(back.roomId, isNull);
    });
  });
}
