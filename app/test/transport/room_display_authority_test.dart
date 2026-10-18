import 'package:app/data/transport/room_display_authority.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

RoomDisplay value(
  int revision, {
  int incarnation = 0,
  String? name = 'alias',
}) => RoomDisplay.tryFromJson({
  'native_session_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'epoch':
      '${incarnation.toRadixString(16).padLeft(8, '0')}-dddd-4ddd-8ddd-dddddddddddd',
  'revision': revision,
  'name': name,
})!;
void main() {
  test('only snapshot bootstraps even a verified null name', () {
    final authority = RoomDisplayAuthority();
    expect(authority.update(value(0)), isNull);
    expect(authority.snapshot(value(0, name: null)), value(0, name: null));
    expect(authority.update(value(1)), value(1));
    expect(authority.update(value(2, incarnation: 1)), value(1));
  });
  test(
    'invalidation watermark rejects lower and conflicting snapshots; equal coherent recovery works',
    () {
      final authority = RoomDisplayAuthority();
      authority.snapshot(value(4));
      authority.update(null);
      expect(authority.update(value(5)), isNull);
      expect(authority.snapshot(value(3)), isNull);
      expect(authority.snapshot(value(4, name: 'conflict')), isNull);
      expect(authority.snapshot(value(4)), value(4));
      expect(authority.update(value(3)), value(4));
      expect(authority.update(value(4, name: 'conflict')), value(4));
      expect(authority.update(value(5)), value(5));
    },
  );
  test(
    'retired epochs cannot resurrect; 65th incarnation fails closed without eviction',
    () {
      final authority = RoomDisplayAuthority();
      for (var i = 0; i < RoomDisplayAuthority.maxIncarnations; i++) {
        expect(
          authority.snapshot(value(0, incarnation: i)),
          value(0, incarnation: i),
        );
      }
      expect(authority.snapshot(value(100)), value(0, incarnation: 63));
      expect(authority.snapshot(value(0, incarnation: 64)), isNull);
      expect(authority.snapshot(value(1, incarnation: 63)), isNull);
      expect(authority.update(value(2, incarnation: 63)), isNull);
      expect(authority.snapshot(value(101)), isNull);
      expect(authority.verified, isNull);
      expect(RoomDisplayAuthority().snapshot(value(0)), value(0));
    },
  );
}
