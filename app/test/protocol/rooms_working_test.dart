// Plan/32 — wire-level parsing of `meta.working` and the `RoomInfo.working`
// field across `room_announced`, `room_meta_updated` and `rooms` snapshots.
// The relay broadcasts `meta.working` (turn_start/turn_end from the
// Pi-extension) to every room subscriber, so Home can light the blue dot on
// any session — not just the connected one.

import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('room_meta_updated.meta.working', () {
    test('parses working=true', () {
      final m = ControlInbound.tryFromJson({
        'type': 'room_meta_updated',
        'peer': 'peer1',
        'room_id': 'r1',
        'meta': {'working': true},
      });
      final upd = m! as RoomMetaUpdated;
      expect(upd.working, isTrue);
    });

    test('parses working=false', () {
      final m = ControlInbound.tryFromJson({
        'type': 'room_meta_updated',
        'peer': 'peer1',
        'room_id': 'r1',
        'meta': {'working': false},
      });
      final upd = m! as RoomMetaUpdated;
      expect(upd.working, isFalse);
    });

    test('working absent → null (preserve current)', () {
      final m = ControlInbound.tryFromJson({
        'type': 'room_meta_updated',
        'peer': 'peer1',
        'room_id': 'r1',
        'meta': {'model': 'claude-opus-4-8'},
      });
      final upd = m! as RoomMetaUpdated;
      expect(upd.working, isNull);
      expect(upd.model, 'claude-opus-4-8');
    });

    test('working + thinking + model all present', () {
      final m = ControlInbound.tryFromJson({
        'type': 'room_meta_updated',
        'peer': 'peer1',
        'room_id': 'r1',
        'meta': {'working': true, 'thinking': 'high', 'model': 'gpt-4o'},
      });
      final upd = m! as RoomMetaUpdated;
      expect(upd.working, isTrue);
      expect(upd.thinking, ThinkingLevel.high);
      expect(upd.model, 'gpt-4o');
    });
  });

  group('room_announced.working', () {
    test('top-level working flattened by relay', () {
      final m = ControlInbound.tryFromJson({
        'type': 'room_announced',
        'peer': 'peer1',
        'room_id': 'r1',
        'started_at': 1,
        'working': true,
      });
      final ann = m! as RoomAnnounced;
      expect(ann.working, isTrue);
    });

    test('nested meta.working honored (un-flatten path)', () {
      final m = ControlInbound.tryFromJson({
        'type': 'room_announced',
        'peer': 'peer1',
        'room_id': 'r1',
        'started_at': 1,
        'meta': {'working': true},
      });
      final ann = m! as RoomAnnounced;
      expect(ann.working, isTrue);
    });

    test('working absent → null', () {
      final m = ControlInbound.tryFromJson({
        'type': 'room_announced',
        'peer': 'peer1',
        'room_id': 'r1',
        'started_at': 1,
      });
      final ann = m! as RoomAnnounced;
      expect(ann.working, isNull);
    });
  });

  group('RoomInfo.working', () {
    test('fromJson reads working key, defaults false when absent', () {
      final on = RoomInfo.fromJson({
        'room_id': 'r1',
        'started_at': 1,
        'working': true,
      });
      expect(on.working, isTrue);

      final off = RoomInfo.fromJson({'room_id': 'r1', 'started_at': 1});
      expect(off.working, isFalse);
    });

    test('toJson round-trips working', () {
      const a = RoomInfo(roomId: 'r1', startedAt: 1, working: true);
      expect(a.toJson()['working'], isTrue);
      final b = RoomInfo.fromJson(a.toJson());
      expect(b.working, isTrue);
    });

    test('copyWith preserves working by default, sets when given', () {
      const a = RoomInfo(roomId: 'r1', startedAt: 1, working: true);
      expect(a.copyWith(model: 'gpt-4o').working, isTrue);
      expect(a.copyWith(working: false).working, isFalse);
    });

    test('equality + hashCode consider working', () {
      const a = RoomInfo(roomId: 'r1', startedAt: 1, working: true);
      const b = RoomInfo(roomId: 'r1', startedAt: 1, working: true);
      const c = RoomInfo(roomId: 'r1', startedAt: 1, working: false);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });
}
