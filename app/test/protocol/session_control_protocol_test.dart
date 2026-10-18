import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'exact session-control requests have no process/path or replay fields',
    () {
      expect(SessionControlStatus('s', 'room').toJson(), {
        'type': 'session_control_status',
        'id': 's',
        'room_id': 'room',
      });
      expect(SessionStop('x', 'room', 'opaque').toJson(), {
        'type': 'session_stop',
        'id': 'x',
        'room_id': 'room',
        'token': 'opaque',
      });
    },
  );
  test('capability and stop outcomes decode without becoming chat events', () {
    final status =
        ServerMessage.fromJson({
              'type': 'session_control_status_result',
              'in_reply_to': 's',
              'room_id': 'room',
              'can_stop': true,
              'token': 'opaque',
              'reason': 'Stops its launched agents.',
            })
            as SessionControlStatusResult;
    expect(status.canStop, isTrue);
    expect(status.roomId, 'room');
    expect(status.token, 'opaque');
    final unavailable =
        ServerMessage.fromJson({
              'type': 'session_control_status_result',
              'in_reply_to': 's',
              'room_id': 'room',
              'can_stop': false,
              'reason': 'Unlock host.',
            })
            as SessionControlStatusResult;
    expect(unavailable.token, isNull);
    for (final state in ['requested', 'stopped']) {
      final message =
          ServerMessage.fromJson({
                'type': 'session_stop_result',
                'in_reply_to': 'x',
                'room_id': 'room',
                'state': state,
              })
              as SessionStopResult;
      expect(message.state, state);
    }
  });
  test(
    'strict optional own access and authoritative launch origin; old hosts remain valid',
    () {
      final base = <String, dynamic>{
        'type': 'session_control_status_result',
        'in_reply_to': 'q',
        'room_id': 'child',
        'can_stop': false,
      };
      for (final state in ['unlocked', 'expired', 'locked', 'unavailable']) {
        final result =
            ServerMessage.fromJson({
                  ...base,
                  'access': {
                    'state': state,
                    'expires_at': state == 'unlocked' || state == 'expired'
                        ? 1234
                        : null,
                  },
                  'launching_host': {
                    'room_id': 'actual-root',
                    'launcher_id': 'actual-launcher',
                  },
                })
                as SessionControlStatusResult;
        expect(result.access!.state, state);
        expect(result.launchingHost!.roomId, 'actual-root');
      }
      expect(
        (ServerMessage.fromJson(base) as SessionControlStatusResult).access,
        isNull,
      );
      for (final access in [
        null,
        {},
        {'state': 'unknown', 'expires_at': null},
        {'state': 'unlocked', 'expires_at': null},
        {'state': 'expired', 'expires_at': -1},
        {'state': 'locked', 'expires_at': 123},
        {'state': 'locked', 'expires_at': null, 'owner': 'foreign'},
        {'state': 'expired', 'expires_at': 1.5},
      ]) {
        expect(
          () => ServerMessage.fromJson({...base, 'access': access}),
          throwsFormatException,
        );
      }
      for (final host in [
        null,
        {},
        {'room_id': '', 'launcher_id': 'l'},
        {'room_id': 'r', 'launcher_id': 'l', 'cwd': '/guess'},
      ]) {
        expect(
          () => ServerMessage.fromJson({...base, 'launching_host': host}),
          throwsFormatException,
        );
      }
      expect(
        () => ServerMessage.fromJson({
          ...base,
          'can_stop': true,
          'token': 't',
          'access': {'state': 'expired', 'expires_at': 1},
        }),
        throwsFormatException,
      );
    },
  );
  test(
    'malformed capabilities, unknown fields and invented completion fail closed',
    () {
      final base = {
        'type': 'session_control_status_result',
        'in_reply_to': 's',
        'room_id': 'room',
        'can_stop': true,
        'token': 'opaque',
      };
      for (final bad in [
        {...base, 'token': null},
        {...base, 'can_stop': false},
        {...base, 'room_id': ''},
        {...base, 'in_reply_to': 'bad\nid'},
        {...base, 'token': 'x' * 129},
        {...base, 'pid': 123},
        {...base, 'reason': null},
      ]) {
        expect(() => ServerMessage.fromJson(bad), throwsFormatException);
      }
      expect(
        () => ServerMessage.fromJson({
          'type': 'session_stop_result',
          'in_reply_to': 'x',
          'room_id': 'room',
          'state': 'terminated',
        }),
        throwsFormatException,
      );
      expect(
        () => ServerMessage.fromJson({
          'type': 'session_stop_result',
          'in_reply_to': 'x',
          'room_id': 'room',
          'state': 'stopped',
          'pid': 123,
        }),
        throwsFormatException,
      );
    },
  );
}
