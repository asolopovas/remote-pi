import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/data/transport/peer_channel.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/domain/contracts/agent_repository.dart';
import 'package:app/data/transport/ws_transport.dart';
import 'package:app/protocol/protocol.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

const _peer = 'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO/oMQ6yyQE=';
const _urlPeer = 'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO_oMQ6yyQE';
const _other = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

Map<String, dynamic> _pong(
  Object? peer,
  String id, {
  String? room = 'project',
}) => {
  'peer': peer,
  'room': ?room,
  'ct': base64.encode(
    utf8.encode(jsonEncode({'type': 'pong', 'in_reply_to': id})),
  ),
};

class LocalRelay {
  final HttpServer server;
  var authenticated = Completer<WebSocket>();
  WebSocket? socket;
  final outbound = StreamController<Map<String, dynamic>>.broadcast();

  LocalRelay._(this.server) {
    server.listen((request) async {
      final ws = await WebSocketTransformer.upgrade(request);
      socket = ws;
      ws.listen((raw) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        switch (frame['type']) {
          case 'hello':
            ws.add(
              jsonEncode({
                'type': 'challenge',
                'nonce': base64.encode(List.filled(32, 1)),
              }),
            );
          case 'auth':
            authenticated.complete(ws);
          default:
            outbound.add(frame);
        }
      });
    });
  }

  static Future<LocalRelay> start() async =>
      LocalRelay._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Future<WsTransport> connect() async {
    if (authenticated.isCompleted) authenticated = Completer<WebSocket>();
    final transport = await WsTransport.connect(
      relayUrl: 'ws://127.0.0.1:${server.port}',
      peerPubkey: _urlPeer,
      ed25519Key: await Ed25519().newKeyPair(),
    );
    await authenticated.future;
    transport.setActiveRoom('project');
    return transport;
  }

  void send(Map<String, dynamic> frame) => socket!.add(jsonEncode(frame));

  // Ordered control marker proves all preceding WS frames entered transport.
  Future<void> drain() async {
    send({'type': 'peer_online', 'peer': _other});
  }

  Future<void> close() async {
    await socket?.close();
    await server.close(force: true);
    await outbound.close();
  }
}

class _ActionStorage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => [];
}

void main() {
  for (final changeRoom in [false, true]) {
    test('repository ModelSet captures original WS room; no replay after '
        '${changeRoom ? "room change" : "timeout"}', () async {
      final relay = await LocalRelay.start();
      final transport = await relay.connect();
      final ch = PlainPeerChannel(transport: transport);
      final cm = ConnectionManager(
        factory: (_, _) async => ch,
        storage: _ActionStorage(),
        emitDebounce: Duration.zero,
      );
      final repo = ActionsRepository(
        cm,
        timeout: const Duration(milliseconds: 100),
      );
      final frames = <Map<String, dynamic>>[];
      final sub = relay.outbound.stream.listen(frames.add);
      addTearDown(() async {
        repo.dispose();
        cm.dispose();
        await sub.cancel();
        await ch.close();
        await relay.close();
      });
      cm.adopt(
        ch,
        const PeerRecord(
          remoteEpk: _peer,
          roomId: 'project',
          sessionName: 'pi',
          relayUrl: 'ws://localhost',
          pairedAt: 'now',
        ),
      );
      // adopt does not implicitly select a persisted room on this path.
      cm.switchRoom('project');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      relay.send({
        'type': 'room_announced',
        'peer': _peer,
        'room_id': 'project',
        'started_at': 1,
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(cm.roomsFor(_peer).single.startedAt, 1);
      final mutation = repo.setModel('actual', 'actual');
      final failed = expectLater(mutation, throwsA(isA<ActionFailure>()));
      // No await between repository invocation and selection change: this
      // exercises the full synchronous capture chain, not a recording fake.
      if (changeRoom) cm.switchRoom('next');
      await failed;
      cm.switchRoom('next');
      cm.switchRoom('project');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final actions = frames.where((f) => f['ct'] != null).where((f) {
        final inner = jsonDecode(utf8.decode(base64.decode(f['ct'] as String)));
        return inner['type'] == 'model_set';
      }).toList();
      expect(actions, hasLength(1));
      expect(actions.single['room'], 'project');
      final inner = jsonDecode(
        utf8.decode(base64.decode(actions.single['ct'] as String)),
      );
      expect(inner['provider'], 'actual');
      expect(inner['model_id'], 'actual');
    });
  }

  test(
    'action send captures selected room synchronously and ingress keeps authenticated scope',
    () async {
      final relay = await LocalRelay.start();
      final transport = await relay.connect();
      final channel = PlainPeerChannel(transport: transport);
      final incoming = channel.actionReplies.first;
      final outbound = relay.outbound.stream.first;
      final send = transport.send(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'type': 'model_set',
              'id': 'act_scope',
              'provider': 'actual',
              'model_id': 'actual',
            }),
          ),
        ),
      );
      transport.setActiveRoom('next');
      await send;
      expect((await outbound)['room'], 'project');
      for (final scope in [
        (_other, 'next'),
        (_peer, 'project'),
        (_peer, 'next'),
      ]) {
        relay.send({
          'peer': scope.$1,
          'room': scope.$2,
          'ct': base64.encode(
            utf8.encode(
              jsonEncode({
                'type': 'error',
                'in_reply_to': 'act_scope',
                'code': 'invalid_message',
                'message': 'Launcher locked',
              }),
            ),
          ),
        });
      }
      final reply = await incoming.timeout(const Duration(seconds: 2));
      expect(reply.peer, _peer);
      expect(reply.room, 'next');
      expect(reply.message, isA<ScopedActionError>());
      await channel.close();
      await relay.close();
    },
  );
  test(
    'launcher transport scopes all security requests and nested replies to exact paired host and room',
    () async {
      final relay = await LocalRelay.start();
      final ch = PlainPeerChannel(transport: await relay.connect());
      final messages = <ServerMessage>[];
      final sub = ch.serverMessages.listen(messages.add);
      const status = LauncherStatus(
        launcherId: 'launcher',
        epoch: 'epoch',
        configured: true,
        unlocked: false,
        expiresAt: null,
        cooldownUntil: 0,
      );
      const producerStatus = {
        'launcher_id': 'launcher',
        'epoch': 'epoch',
        'configured': true,
        'unlocked': false,
        'expires_at': null,
        'cooldown_until': 0,
      };
      Map<String, dynamic> envelope(
        Map<String, dynamic> body, {
        String? room,
        String peer = _peer,
      }) => {
        'peer': peer,
        'room': ?room,
        'ct': base64.encode(utf8.encode(jsonEncode(body))),
      };
      try {
        for (final type in [
          'launcher_status',
          'project_list',
          'launcher_unlock',
          'launcher_pin_initialize',
          'launcher_lock',
          'launcher_shutdown',
          'project_launch',
          'launcher_agent_stop',
        ]) {
          final sent = relay.outbound.stream.first;
          final request = LauncherRequest(
            type,
            type,
            status: type == 'launcher_status' || type == 'project_list'
                ? null
                : status,
            pin: ['launcher_unlock', 'launcher_pin_initialize'].contains(type)
                ? '123456'
                : null,
            projectId: type == 'project_launch' ? 'p' : null,
            agentId: type == 'launcher_agent_stop' ? 'a' : null,
          );
          await ch.send(request);
          final outer = await sent;
          expect(outer['peer'], _peer);
          expect(outer['room'], 'project');
          expect(
            jsonDecode(utf8.decode(base64.decode(outer['ct'] as String))),
            request.toJson(),
          );
        }
        for (final request in <ClientMessage>[
          SessionControlStatus('session-control:status', 'project'),
          SessionStop('session-control:stop', 'project', 'opaque'),
        ]) {
          await ch.send(request);
        }
        final results = [
          {
            'type': 'session_control_status_result',
            'in_reply_to': 'session-control:status',
            'room_id': 'project',
            'can_stop': true,
            'token': 'opaque',
          },
          {
            'type': 'session_stop_result',
            'in_reply_to': 'session-control:stop',
            'room_id': 'project',
            'state': 'requested',
          },
          {
            'type': 'error',
            'in_reply_to': 'session-control:stop',
            'code': 'invalid_message',
            'message': 'Expired confirmation',
          },
          {
            'type': 'launcher_status_result',
            'in_reply_to': 'launcher_status',
            'status': producerStatus,
          },
          {
            'type': 'launcher_shutdown_result',
            'in_reply_to': 'launcher_shutdown',
            'status': producerStatus,
            'stopped': false,
          },
          {
            'type': 'project_list_result',
            'in_reply_to': 'project_list',
            'projects': [],
          },
          {
            'type': 'error',
            'in_reply_to':
                '${launcherSetupRequestPrefix}retired-with-no-cache-entry',
            'code': 'invalid_message',
            'message': 'Already configured',
          },
          {
            'type': 'error',
            'in_reply_to': 'launcher_pin_initialize',
            'code': 'invalid_message',
            'message': 'Already configured',
          },
          {
            'type': 'error',
            'in_reply_to': 'launcher_unlock',
            'code': 'invalid_message',
            'message': 'Wrong PIN',
          },
        ];
        final done = ch.serverMessages.firstWhere(
          (m) => m is Pong && m.inReplyTo == 'done',
        );
        for (final result in results) {
          relay.send(envelope(result));
          relay.send(envelope(result, room: 'other'));
          relay.send(envelope(result, room: 'project', peer: _other));
          relay.send(envelope(result, room: 'project'));
        }
        relay.send(_pong(_peer, 'done'));
        await done;
        expect(messages.whereType<LauncherStatusResult>().length, 2);
        expect(messages.whereType<ProjectListResult>().length, 1);
        expect(messages.whereType<ErrorMessage>().length, 4);
        expect(messages.whereType<LauncherSetupError>().length, 1);
        expect(messages.whereType<SessionControlStatusResult>().length, 1);
        expect(messages.whereType<SessionStopResult>().length, 1);
        expect(messages.whereType<SessionControlError>().length, 1);
      } finally {
        await sub.cancel();
        await ch.close();
        await relay.close();
      }
    },
  );
  test(
    'agent replies and correlated errors require exact authenticated room',
    () async {
      final relay = await LocalRelay.start();
      final ch = PlainPeerChannel(transport: await relay.connect());
      final messages = <ServerMessage>[];
      final sub = ch.serverMessages.listen(messages.add);
      Map<String, dynamic> envelope(
        Map<String, dynamic> inner, {
        String? room,
      }) => {
        'peer': _peer,
        'room': ?room,
        'ct': base64.encode(utf8.encode(jsonEncode(inner))),
      };
      final result = {
        'type': 'agent_list_result',
        'in_reply_to': 'list',
        'available': true,
        'cwd': '/p',
        'max_agents': 4,
        'agents': [],
      };
      final error = {
        'type': 'error',
        'in_reply_to': 'list',
        'code': 'invalid_message',
        'message': 'bad',
      };
      try {
        await ch.send(AgentList('list'));
        final sentinel = ch.serverMessages.firstWhere(
          (m) => m is Pong && m.inReplyTo == 'done',
        );
        relay.send(envelope(result));
        relay.send(envelope(error));
        relay.send(envelope(result, room: 'other'));
        relay.send(envelope(result, room: 'project'));
        relay.send(_pong(_peer, 'done'));
        await sentinel;
        expect(messages.whereType<AgentListResult>().length, 1);
        expect(messages.whereType<ErrorMessage>(), isEmpty);
      } finally {
        await sub.cancel();
        await ch.close();
        await relay.close();
      }
    },
  );

  test(
    'WsTransport accepts expected standard/url-safe sender and scopes outgoing probe',
    () async {
      final relay = await LocalRelay.start();
      final transport = await relay.connect();
      final ch = PlainPeerChannel(transport: transport);
      final messages = <ServerMessage>[];
      final sub = ch.serverMessages.listen(messages.add);
      try {
        final sent = relay.outbound.stream.first;
        await ch.send(Ping(id: 'current-probe'));
        final envelope = await sent;
        expect(envelope['peer'], _peer);
        expect(envelope['room'], 'project');
        expect(
          jsonDecode(utf8.decode(base64.decode(envelope['ct'] as String))),
          {'type': 'ping', 'id': 'current-probe'},
        );

        final last = ch.serverMessages.firstWhere(
          (m) => m is Pong && m.inReplyTo == 'url',
        );
        relay.send(_pong(_peer, 'standard'));
        relay.send(
          _pong(_peer.substring(0, _peer.length - 1), 'standard-unpadded'),
        );
        relay.send(_pong('$_urlPeer=', 'url-padded'));
        relay.send(_pong(_urlPeer, 'url'));
        await last;
        expect(messages.whereType<Pong>().map((m) => m.inReplyTo), [
          'standard',
          'standard-unpadded',
          'url-padded',
          'url',
        ]);
      } finally {
        await sub.cancel();
        await ch.close();
        await relay.close();
      }
    },
  );

  test(
    'WsTransport rejects different same-room sender, malformed identity and wrong room',
    () async {
      final relay = await LocalRelay.start();
      final ch = PlainPeerChannel(transport: await relay.connect());
      final messages = <ServerMessage>[];
      final sub = ch.serverMessages.listen(messages.add);
      try {
        final last = ch.serverMessages.firstWhere(
          (m) => m is Pong && m.inReplyTo == 'sentinel',
        );
        // A different authenticated sender with the SAME room and matching probe
        // is not the paired target. Invalid frames precede a valid FIFO sentinel.
        relay.send(_pong(_other, 'current-probe'));
        for (final malformed in [null, 42, '', '!not-base64!', 'eA==']) {
          relay.send(_pong(malformed, 'current-probe'));
        }
        relay.send(_pong(_peer, 'current-probe', room: 'old-room'));
        relay.send(_pong(_peer, 'current-probe'));
        relay.send(_pong(_peer, 'sentinel'));
        await last;
        expect(messages.whereType<Pong>().map((m) => m.inReplyTo), [
          'current-probe',
          'sentinel',
        ]);
      } finally {
        await sub.cancel();
        await ch.close();
        await relay.close();
      }
    },
  );

  test(
    'WsTransport retains expected legacy sender without room and other-peer control snapshots',
    () async {
      final relay = await LocalRelay.start();
      final transport = await relay.connect();
      final ch = PlainPeerChannel(transport: transport);
      final message = ch.serverMessages.first;
      final control = ch.controlFrames.first;
      try {
        relay.send(_pong(_urlPeer, 'legacy', room: null));
        relay.send({'type': 'rooms', 'peer': _other, 'rooms': []});
        expect((await message as Pong).inReplyTo, 'legacy');
        expect((await control as RoomsSnapshot).peer, _other);
      } finally {
        await ch.close();
        await relay.close();
      }
    },
  );

  test(
    'WsTransport cannot misattribute queued old-room payload after selection changes',
    () async {
      final relay = await LocalRelay.start();
      final transport = await relay.connect();
      try {
        final drained = transport.controlFrames.first;
        relay.send(_pong(_peer, 'old-probe'));
        // A missing-room legacy payload is scoped to its receipt epoch too.
        relay.send(_pong(_peer, 'old-legacy', room: null));
        await relay.drain();
        await drained;
        transport.setActiveRoom('new-room');
        final received = transport.receive();
        relay.send(_pong(_peer, 'new-probe', room: 'new-room'));
        final frame =
            jsonDecode(utf8.decode(await received)) as Map<String, dynamic>;
        expect(frame['in_reply_to'], 'new-probe');
      } finally {
        await transport.close();
        await relay.close();
      }
    },
  );
}
