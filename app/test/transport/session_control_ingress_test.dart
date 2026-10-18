import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/peer_channel.dart';
import 'package:app/pairing/pair_request_flow.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport implements PeerTransport, IScopedPeerTransport {
  final frames = StreamController<ScopedPeerPayload>();
  late final iterator = StreamIterator(frames.stream);
  @override
  Future<void> send(Uint8List bytes) async {}
  @override
  Future<Uint8List> receive() async => (await receiveScoped()).bytes;
  @override
  Future<ScopedPeerPayload> receiveScoped() async {
    if (!await iterator.moveNext()) throw StateError('Closed');
    return iterator.current;
  }

  @override
  Future<void> close() async {
    await frames.close();
  }
}

void main() {
  for (final room in ['selected-room', null]) {
    test(
      'control error keeps authenticated scope and classification with room=$room',
      () async {
        final transport = _Transport();
        final channel = PlainPeerChannel(transport: transport);
        final pending = channel.serverMessages.first;
        transport.frames.add((
          peer: 'verified-owner',
          room: room,
          bytes: Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'type': 'error',
                'in_reply_to': '${sessionControlRequestPrefix}retired-request',
                'code': 'invalid_message',
                'message': 'Denied',
              }),
            ),
          ),
        ));
        final message = await pending;
        expect(message, isA<SessionControlError>());
        expect((message as SessionControlError).peer, 'verified-owner');
        expect(message.room, room);
        // Classification does not depend on a request cache that can evict IDs.
        expect(
          message.inReplyTo,
          '${sessionControlRequestPrefix}retired-request',
        );
        await channel.close();
      },
    );
  }
  for (final room in ['selected-room', null]) {
    test(
      'late setup errors keep classification without request history room=$room',
      () async {
        final transport = _Transport();
        final channel = PlainPeerChannel(transport: transport);
        final pending = channel.serverMessages.first;
        transport.frames.add((
          peer: 'verified-owner',
          room: room,
          bytes: Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'type': 'error',
                'in_reply_to': '${launcherSetupRequestPrefix}retired',
                'code': 'invalid_message',
                'message': 'Already configured',
              }),
            ),
          ),
        ));
        final message = await pending;
        expect(message, isA<LauncherSetupError>());
        expect((message as LauncherSetupError).peer, 'verified-owner');
        expect(message.room, room);
        await channel.close();
      },
    );
  }
  test('ordinary chat errors retain their existing classification', () async {
    final transport = _Transport();
    final channel = PlainPeerChannel(transport: transport);
    final pending = channel.serverMessages.first;
    transport.frames.add((
      peer: 'verified-owner',
      room: 'room',
      bytes: Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'type': 'error',
            'in_reply_to': 'ordinary-chat',
            'code': 'internal_error',
            'message': 'Chat failed',
          }),
        ),
      ),
    ));
    final message = await pending;
    expect(message, isA<ScopedPeerError>());
    expect(message, isNot(isA<SessionControlError>()));
    await channel.close();
  });
}
