import 'dart:async';
import 'dart:convert';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/peer_channel.dart';
import 'package:app/data/transport/ws_transport.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'ws_transport_discovery_recovery_test.dart' show LocalRelay;

const peer = 'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO/oMQ6yyQE=';
const other = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
Map<String, dynamic> reply(
  String id, {
  String type = 'launcher_status_result',
}) => {
  'type': type,
  'in_reply_to': id,
  if (type == 'error') ...{
    'code': 'locked',
    'message': 'must never enter chat',
  },
  if (type == 'launcher_status_result')
    'status': {
      'launcher_id': 'root-id',
      'epoch': 'epoch',
      'configured': true,
      'unlocked': false,
      'expires_at': null,
      'cooldown_until': 0,
      'launcher_api': 2,
      'pin_setup': 'configured',
    },
};
void main() {
  late LocalRelay relay;
  late WsTransport transport;
  late PlainPeerChannel channel;
  late StreamSubscription<ServerMessage> sub;
  final messages = <ServerMessage>[];
  setUp(() async {
    messages.clear();
    relay = await LocalRelay.start();
    transport = await relay.connect();
    channel = PlainPeerChannel(transport: transport);
    sub = channel.serverMessages.listen(messages.add);
  });
  tearDown(() async {
    await sub.cancel();
    await channel.close();
    await relay.close();
  });
  Future<Map<String, dynamic>> outgoing() async {
    final frame = await relay.outbound.stream.firstWhere(
      (f) => f['ct'] != null,
    );
    expect(frame['room'], 'root');
    final request =
        jsonDecode(utf8.decode(base64.decode(frame['ct'] as String)))
            as Map<String, dynamic>;
    expect(request['type'], 'launcher_status');
    expect(request.keys.toSet(), {'type', 'id'});
    return request;
  }

  void send(
    Map<String, dynamic> body, {
    String? room = 'root',
    String sender = peer,
  }) => relay.send({
    'peer': sender,
    'room': ?room,
    'ct': base64.encode(utf8.encode(jsonEncode(body))),
  });
  Future<void> barrier() async {
    final marker = transport.controlFrames.first;
    await relay.drain();
    await marker;
  }

  for (final oldType in ['launcher_status_result', 'error']) {
    test(
      'reconnected probe rejects delayed old $oldType on same scope',
      () async {
        final oldSent = outgoing();
        final oldProbe = channel.probeLauncher('root');
        final oldId = (await oldSent)['id'] as String;
        await sub.cancel();
        await channel.close();
        expect(await oldProbe, isNull);
        transport = await relay.connect();
        channel = PlainPeerChannel(transport: transport);
        sub = channel.serverMessages.listen(messages.add);
        final sent = outgoing();
        final probe = channel.probeLauncher('root');
        final id = (await sent)['id'] as String;
        bool completed = false;
        unawaited(
          probe.then((_) {
            completed = true;
          }),
        );
        send(reply(oldId, type: oldType));
        await barrier();
        expect(completed, isFalse);
        expect(id, isNot(oldId));
        send(reply(id, type: 'error'), room: 'wrong');
        send(reply(id), sender: other);
        send(
          reply('${launcherProbeRequestPrefix}unmatched', type: 'error'),
          room: 'project',
        );
        await barrier();
        expect(completed, isFalse);
        expect(messages, isEmpty);
        send(reply(id));
        expect((await probe)!.room, 'root');
        expect(messages, isEmpty);
      },
    );
  }
  test(
    'off-room read-only reply retains outer scope, no chat or active-room change',
    () async {
      final sent = outgoing();
      final probe = channel.probeLauncher('root');
      final request = await sent;
      send(reply(request['id'] as String));
      final result = await probe;
      expect(result!.peer, peer);
      expect(result.room, 'root');
      expect(result.status.launcherId, 'root-id');
      await channel.send(Ping(id: 'active-room-check'));
      // Plain chat is still routed to the original selected project room.
      expect(messages, isEmpty);
      final received = channel.serverMessages.first;
      send({
        'type': 'pong',
        'in_reply_to': 'active-room-check',
      }, room: 'project');
      expect(await received, isA<Pong>());
    },
  );
  test(
    'wrong peer/room/missing scope/type/correlation ignored; late error consumed',
    () async {
      final sent = outgoing();
      final probe = channel.probeLauncher('root');
      final request = await sent;
      final id = request['id'] as String;
      bool completed = false;
      unawaited(
        probe.then((_) {
          completed = true;
        }),
      );
      send(reply(id), sender: other);
      send(reply(id), room: 'wrong');
      send(reply(id), room: null);
      send(reply('wrong-id'));
      send(reply(id, type: 'project_list_result'));
      await barrier();
      expect(completed, isFalse);
      expect(messages, isEmpty);
      send(reply(id));
      expect((await probe)!.room, 'root');
      send(reply(id, type: 'error'), room: 'project');
      send(reply(id), room: 'project');
      await barrier();
      expect(messages, isEmpty);
    },
  );
  for (final action in ['selection', 'cancel', 'close', 'timeout', 'error']) {
    test('finite scoped settlement, no history: $action', () async {
      final sent = outgoing();
      final probe = channel.probeLauncher('root');
      final id = (await sent)['id'] as String;
      switch (action) {
        case 'selection':
          transport.setActiveRoom('other');
        case 'cancel':
          channel.cancelLauncherProbes();
        case 'close':
          await relay.socket!.close();
        case 'timeout':
          break;
        case 'error':
          send(reply(id, type: 'error'));
      }
      expect(await probe, isNull);
      expect(messages, isEmpty);
      if (action != 'close') {
        send(
          reply(id, type: 'error'),
          room: action == 'selection' ? 'other' : 'project',
        );
        await barrier();
        expect(messages, isEmpty);
      }
    });
  }
  test(
    'at most two concurrent probes; responses may arrive out of order',
    () async {
      final sent = outgoing();
      final first = channel.probeLauncher('root');
      final firstId = (await sent)['id'] as String;
      final next = outgoing();
      final second = channel.probeLauncher('root');
      final secondId = (await next)['id'] as String;
      expect(await channel.probeLauncher('root'), isNull);
      send(reply(secondId));
      expect((await second)!.room, 'root');
      send(reply(firstId));
      expect((await first)!.room, 'root');
      expect(messages, isEmpty);
    },
  );
}
