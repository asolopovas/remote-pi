import 'dart:convert';
import 'dart:io';

import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

const native = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const epoch = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
Map<String, dynamic> valid({
  Object? name = 'Pi · system',
  Object? revision = 1,
}) => {
  'native_session_id': native,
  'epoch': epoch,
  'revision': revision,
  'name': name,
};
void main() {
  test(
    'RoomDisplay exact UUID safeint name bounds match producer and Relay',
    () {
      for (final value in [
        valid(),
        valid(name: null),
        valid(name: ''),
        valid(revision: 0),
        valid(revision: 9007199254740991),
        valid(name: '😀' * 128),
      ]) {
        expect(RoomDisplay.tryFromJson(value)?.toJson(), value);
      }
      final invalid = <Object?>[
        null,
        [],
        'instructions',
        {},
        {...valid(), 'extra': true},
        {...valid()}..remove('name'),
        {...valid(), 'native_session_id': '$native\n'},
        {...valid(), 'epoch': 'not-a-uuid'},
        valid(revision: -1),
        valid(revision: 1.0),
        valid(revision: 9007199254740992),
        valid(revision: '1'),
        valid(name: true),
        valid(name: 'x' * 129),
        valid(name: '😀' * 129),
      ];
      for (final control in [
        0,
        10,
        127,
        159,
        0xad,
        0x61c,
        0x890,
        0x202e,
        0x2028,
        0xfeff,
        0x110bd,
        0x13430,
        0xe0001,
      ]) {
        invalid.add(valid(name: 'safe${String.fromCharCode(control)}unsafe'));
      }
      for (final value in invalid) {
        expect(RoomDisplay.tryFromJson(value), isNull, reason: '$value');
      }
    },
  );

  test(
    'incremental omission, explicit invalidation and verified reset are distinct',
    () {
      RoomMetaUpdated parse(Map<String, dynamic> meta) =>
          ControlInbound.tryFromJson({
                'type': 'room_meta_updated',
                'peer': 'peer',
                'room_id': 'r',
                'meta': meta,
              })!
              as RoomMetaUpdated;
      expect(parse({}).hasDisplay, isFalse);
      expect(parse({'display': null}).hasDisplay, isTrue);
      expect(parse({'display': valid(name: null)}).display?.name, isNull);
      expect(parse({'display': valid(name: null)}).display, isNotNull);
      expect(
        parse({
          'display': {'name': 'unbound'},
          'working': false,
        }).hasDisplay,
        isFalse,
      );
      expect(
        parse({'display': valid(), 'model': null, 'thinking': null}).hasModel,
        isTrue,
      );
      expect(parse({'display': valid()}).hasThinking, isFalse);
    },
  );

  test(
    'RoomInfo localName is never accepted from wire or serialized into routing metadata',
    () {
      final room = RoomInfo.fromJson({
        'room_id': 'r',
        'started_at': 1,
        'name': 'route',
        'local_name': 'untrusted',
        'display': valid(),
      });
      expect(room.localName, isNull);
      final local = room.copyWith(localName: 'mobile');
      expect(local, isNot(room));
      expect(local.name, 'route');
      expect(local.toJson().containsKey('local_name'), isFalse);
      expect(local.toJson()['display'], valid());
      expect(local.copyWith(localName: null).localName, isNull);
      expect(local.copyWith(display: null).display, isNull);
      expect(local.copyWith().display, room.display);
    },
  );

  test(
    'actual producer fixture bytes survive Relay subscriber envelope shapes',
    () {
      // Byte-identical copy of relay/tests/fixtures/81-display-serialization.json.
      // That Relay fixture itself copies the producer's serialization test bytes.
      final fixtures =
          jsonDecode(
                File(
                  'test/protocol/fixtures/81-display-serialization.json',
                ).readAsStringSync(),
              )
              as List<dynamic>;
      for (final fixture in fixtures) {
        final frame = fixture['frame'] as Map<String, dynamic>;
        if (frame['type'] == 'hello') {
          final room = {
            ...frame['room_meta'] as Map<String, dynamic>,
            'room_id': frame['room_id'],
            'started_at': 1,
            'working': false,
          };
          final parsed = RoomInfo.fromJson(room);
          expect(parsed.display?.toJson(), room['display']);
          final announcement =
              ControlInbound.tryFromJson({
                    ...room,
                    'type': 'room_announced',
                    'peer': frame['pubkey'],
                  })!
                  as RoomAnnounced;
          expect(announcement.display, parsed.display);
          final snapshot =
              ControlInbound.tryFromJson({
                    'type': 'rooms',
                    'peer': frame['pubkey'],
                    'rooms': [room],
                  })!
                  as RoomsSnapshot;
          expect(snapshot.rooms.single.display, parsed.display);
        } else {
          // Relay meta_frame always emits working and display (including null).
          final meta = frame['meta'] as Map<String, dynamic>;
          final subscriber =
              ControlInbound.tryFromJson({
                    'type': 'room_meta_updated',
                    'peer': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
                    'room_id': frame['room_id'],
                    'meta': {'working': false, 'display': null, ...meta},
                  })!
                  as RoomMetaUpdated;
          expect(subscriber.display?.toJson(), meta['display']);
          expect(subscriber.hasDisplay, isTrue);
        }
      }
    },
  );
}
