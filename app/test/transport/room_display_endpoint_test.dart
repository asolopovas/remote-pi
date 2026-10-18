import 'dart:convert';
import 'dart:io';

import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/peer_channel.dart';
import 'package:app/data/transport/ws_transport.dart';
import 'package:app/protocol/protocol.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'connection_manager_display_test.dart'
    show Storage, peer, wirePeer, display;

const otherPeer = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

class LegacyRelay {
  final HttpServer server;
  final requests = <Map<String, dynamic>>[];
  final sockets = <WebSocket>[];
  final titles = <String, Object?>{
    'r1': display(1, 'Desktop A'),
    'r2': display(1, 'Desktop B'),
  };
  bool autoReply = true;

  LegacyRelay(this.server) {
    server.listen((http) async {
      final ws = await WebSocketTransformer.upgrade(http);
      sockets.add(ws);
      ws.listen((raw) {
        final outer = jsonDecode(raw as String) as Map<String, dynamic>;
        if (outer['type'] == 'hello') {
          ws.add(
            jsonEncode({
              'type': 'challenge',
              'nonce': base64.encode(List.filled(32, 1)),
            }),
          );
        } else if (outer['ct'] != null) {
          final inner =
              jsonDecode(utf8.decode(base64.decode(outer['ct'] as String)))
                  as Map<String, dynamic>;
          if (inner['type'] == 'room_display_request') {
            expect(outer.keys.toSet(), {'peer', 'room', 'ct'});
            expect(outer['peer'], wirePeer);
            expect(outer['room'], inner['room_id']);
            expect(inner.keys.toSet(), {'type', 'id', 'room_id'});
            expect(
              inner['id'],
              matches(
                r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
              ),
            );
            requests.add(inner);
            if (autoReply) reply(inner, titles[inner['room_id']], socket: ws);
          }
        }
      });
    });
  }

  static Future<LegacyRelay> start() async =>
      LegacyRelay(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  void send(Map<String, dynamic> value, {WebSocket? socket}) =>
      (socket ?? sockets.last).add(jsonEncode(value));

  void reply(
    Map<String, dynamic> request,
    Object? value, {
    String sender = wirePeer,
    String? room,
    String? nonce,
    WebSocket? socket,
    Map<String, dynamic>? inner,
  }) {
    // Legacy relay routes ct opaquely and replaces peer/room with the
    // authenticated producer socket registration, without display controls.
    send({
      'peer': sender,
      'room': room ?? request['room_id'],
      'ct': base64.encode(
        utf8.encode(
          jsonEncode(
            inner ??
                {
                  'type': 'room_display_snapshot',
                  'in_reply_to': nonce ?? request['id'],
                  'room_id': request['room_id'],
                  'display': value,
                },
          ),
        ),
      ),
    }, socket: socket);
  }

  void announce({int startedAt = 1}) => send({
    'type': 'rooms',
    'peer': wirePeer,
    'rooms': [
      for (final room in ['r1', 'r2'])
        {
          'room_id': room,
          'name': 'routing-agent',
          'cwd': '/duplicate',
          'started_at': startedAt,
        },
    ],
  });

  Future<void> close() async {
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
  }
}

Future<void> until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 6));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for metadata');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<({ConnectionManager cm, LegacyRelay relay, List<ServerMessage> chat})>
harness({bool autoReply = true}) async {
  final relay = (await LegacyRelay.start())..autoReply = autoReply;
  final chat = <ServerMessage>[];
  final cm = ConnectionManager(
    factory: (_, _) async {
      final transport = await WsTransport.connect(
        relayUrl: 'ws://127.0.0.1:${relay.server.port}',
        peerPubkey: peer.remoteEpk,
        ed25519Key: await Ed25519().newKeyPair(),
      );
      final channel = PlainPeerChannel(transport: transport);
      channel.serverMessages.listen(chat.add);
      return channel;
    },
    storage: Storage(),
    emitDebounce: Duration.zero,
  );
  addTearDown(() async {
    await cm.disconnect();
    cm.dispose();
    await relay.close();
  });
  await cm.boot();
  relay.announce();
  await until(() => relay.requests.length == 2);
  return (cm: cm, relay: relay, chat: chat);
}

void main() {
  test(
    'legacy ct forwarding polls rename/reset for selected and unselected exact rooms without chat or alias writes',
    () async {
      final h = await harness();
      await until(
        () => h.cm.roomsFor(wirePeer).every((r) => r.display != null),
      );
      expect(h.cm.activeRoomId, 'r1');
      await h.cm.setRoomLocalName(wirePeer, 'r1', 'Mobile alias');
      h.relay.titles['r1'] = display(2, 'Renamed');
      h.relay.titles['r2'] = display(2, 'Unselected rename');
      await until(
        () => h.cm.roomsFor(wirePeer).first.display?.name == 'Renamed',
      );
      expect(h.cm.roomsFor(wirePeer).last.display?.name, 'Unselected rename');
      h.relay.titles['r1'] = display(3, null);
      h.relay.titles['r2'] = null;
      await until(
        () =>
            h.cm.roomsFor(wirePeer).first.display?.revision == 3 &&
            h.cm.roomsFor(wirePeer).last.display == null,
      );
      expect(h.cm.roomsFor(wirePeer).first.localName, 'Mobile alias');
      expect(h.cm.activeRoomId, 'r1');
      expect(h.chat, isEmpty);
      expect(
        h.relay.requests.map((r) => r['id']).toSet().length,
        h.relay.requests.length,
      );
      expect(h.relay.requests.length, lessThanOrEqualTo(8));
    },
  );

  test(
    'metadata rejects foreign/wrong/malformed/unknown/late/conflicting duplicate and relay invalidation wins',
    () async {
      final h = await harness(autoReply: false);
      final r = h.relay.requests.first;
      h.relay.reply(r, display(1, 'Foreign'), sender: otherPeer);
      h.relay.reply(r, display(1, 'Wrong room'), room: 'r2');
      h.relay.reply(
        r,
        display(1, 'Wrong nonce'),
        nonce: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      );
      h.relay.reply(r, {'name': 'Malformed'});
      h.relay.reply(
        r,
        null,
        inner: {'type': 'room_display_request', 'id': r['id'], 'room_id': 'r1'},
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(h.cm.roomsFor(wirePeer).first.display, isNull);
      h.relay.reply(r, display(1, 'Accepted'));
      await until(() => h.cm.roomsFor(wirePeer).first.display != null);
      h.relay.reply(r, display(2, 'Conflicting duplicate'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(h.cm.roomsFor(wirePeer).first.display?.name, 'Accepted');
      await until(() => h.relay.requests.length >= 4);
      final next = h.relay.requests.lastWhere((r) => r['room_id'] == 'r1');
      h.relay.reply(r, display(10, 'Late'));
      h.relay.send({
        'type': 'room_meta_updated',
        'peer': wirePeer,
        'room_id': 'r1',
        'meta': {'display': null},
      });
      h.relay.reply(next, display(11, 'Pre-invalidation reply'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(h.cm.roomsFor(wirePeer).first.display, isNull);
      expect(h.chat, isEmpty);
    },
  );

  test(
    'unsubscribe, exact room replacement and reconnect retire pending socket/room authority',
    () async {
      final h = await harness(autoReply: false);
      final old = h.relay.requests.first;
      h.cm.subscribeToPeers([]);
      h.relay.reply(old, display(1, 'Unsubscribed'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(h.cm.roomsFor(wirePeer).first.display, isNull);
      h.cm.subscribeToPeers([peer.remoteEpk]);
      h.relay.announce(startedAt: 2);
      await until(() => h.relay.requests.length >= 4);
      final replacement = h.relay.requests.lastWhere(
        (r) => r['room_id'] == 'r1',
      );
      h.relay.reply(old, display(20, 'Old incarnation'));
      h.relay.reply(replacement, display(1, 'Replacement'));
      await until(
        () => h.cm.roomsFor(wirePeer).first.display?.name == 'Replacement',
      );
      await h.cm.disconnect();
      expect(h.cm.roomsFor(wirePeer).first.display, isNull);
      await h.cm.connectTo(peer);
      h.relay.announce(startedAt: 2);
      await until(() => h.relay.requests.length >= 6);
      h.relay.reply(replacement, display(30, 'Old socket nonce'));
      final current = h.relay.requests.lastWhere((r) => r['room_id'] == 'r1');
      h.relay.reply(current, display(1, 'Reconnected'));
      await until(
        () => h.cm.roomsFor(wirePeer).first.display?.name == 'Reconnected',
      );
      expect(h.cm.activeRoomId, 'r1');
      expect(h.chat, isEmpty);
    },
  );
}
