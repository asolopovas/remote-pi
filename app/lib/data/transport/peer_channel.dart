import 'package:app/domain/contracts/agent_repository.dart';
// PlainPeerChannel — protocol message channel without E2E cipher.
//
// Wraps a connected PeerTransport. After pairing, use this to exchange
// ClientMessage / ServerMessage with the Pi extension.
//
//   send(ClientMessage)   → JSON          → transport.send()
//   serverMessages stream ← transport.receive() → JSON → ServerMessage

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app/data/transport/channel.dart';
import 'package:app/pairing/pair_request_flow.dart';
import 'package:app/protocol/codec.dart';
// ControlInbound + IControlLink come from these.
import 'package:app/protocol/protocol.dart';

class PeerChannelError implements Exception {
  final String message;
  const PeerChannelError(this.message);

  @override
  String toString() => 'PeerChannelError: $message';
}

class PlainPeerChannel
    implements
        IChannel,
        IControlLink,
        IRoomLauncherProbe,
        IScopedActionChannel {
  final PeerTransport _transport;

  final _controller = StreamController<ServerMessage>.broadcast();
  final _actions = StreamController<ScopedActionReply>.broadcast();
  @override
  Stream<ScopedActionReply> get actionReplies {
    // Start the same receive loop even without a chat consumer.
    serverMessages;
    return _actions.stream;
  }

  bool _started = false;
  bool _closed = false;

  PlainPeerChannel({required PeerTransport transport}) : _transport = transport;

  @override
  Future<({String peer, String room, LauncherStatus status})?> probeLauncher(
    String room,
  ) async {
    final t = _transport;
    if (_closed || t is! IRoomLauncherProbe) return null;
    return (t as IRoomLauncherProbe).probeLauncher(room);
  }

  @override
  void cancelLauncherProbes() {
    final t = _transport;
    if (t is IRoomLauncherProbe) {
      (t as IRoomLauncherProbe).cancelLauncherProbes();
    }
  }

  // ---- IControlLink — forwards to the underlying transport when it
  //      supports raw control frames (production: WsTransport). For
  //      non-WS transports (tests / in-memory), returns an empty stream
  //      and silently drops outbound control frames.
  @override
  Stream<ControlInbound> get controlFrames {
    final t = _transport;
    if (t is IControlLink) return (t as IControlLink).controlFrames;
    return const Stream.empty();
  }

  @override
  void sendControl(Map<String, dynamic> json) {
    final t = _transport;
    if (t is IControlLink) (t as IControlLink).sendControl(json);
  }

  /// Plan 17 — propagate the active Pi-side room to the underlying
  /// transport so subsequent `send`s carry the right outer `room` field.
  /// No-op when the transport doesn't support it (in-memory test fakes).
  void setActiveRoom(String roomId) {
    final t = _transport;
    try {
      (t as dynamic).setActiveRoom(roomId);
    } catch (_) {
      // Non-WS transports don't track rooms — fine to ignore.
    }
  }

  @override
  Stream<ServerMessage> get serverMessages {
    if (!_started) {
      _started = true;
      _receiveLoop();
    }
    return _controller.stream;
  }

  @override
  Future<void> send(ClientMessage msg) async {
    final bytes = Uint8List.fromList(
      utf8.encode(encodeClient(msg).trimRight()),
    );
    await _transport.send(bytes);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _transport.close();
    if (!_actions.isClosed) unawaited(_actions.close());
    if (!_controller.isClosed) await _controller.close();
  }

  Future<void> _receiveLoop() async {
    try {
      while (!_closed) {
        final transport = _transport;
        if (transport is IScopedPeerTransport) {
          final payload = await (transport as IScopedPeerTransport)
              .receiveScoped();
          _handleFrame(payload.bytes, scope: payload);
        } else {
          _handleFrame(await transport.receive());
        }
      }
    } catch (_) {
      if (!_actions.isClosed) unawaited(_actions.close());
      if (!_controller.isClosed) await _controller.close();
    }
  }

  void _handleFrame(Uint8List bytes, {ScopedPeerPayload? scope}) {
    try {
      var msg = decodeServer(utf8.decode(bytes));
      if (msg is ErrorMessage) {
        if (msg.inReplyTo?.startsWith(actionRequestPrefix) == true) {
          msg = ScopedActionError(
            msg,
            peer: scope?.peer ?? '',
            room: scope?.room,
          );
        } else if (msg.inReplyTo?.startsWith(sessionControlRequestPrefix) ==
            true) {
          msg = SessionControlError(
            msg,
            peer: scope?.peer ?? '',
            room: scope?.room,
          );
        } else if (msg.inReplyTo?.startsWith(launcherSetupRequestPrefix) ==
            true) {
          msg = LauncherSetupError(
            msg,
            peer: scope?.peer ?? '',
            room: scope?.room,
          );
        } else if (scope != null) {
          msg = ScopedPeerError(msg, peer: scope.peer, room: scope.room);
        }
      }
      if (scope != null && !_actions.isClosed) {
        _actions.add((message: msg, peer: scope.peer, room: scope.room));
      }
      if (!_controller.isClosed) _controller.add(msg);
    } on UnsupportedTypeException {
      // Forward-compat: surface unknown server types as ErrorMessage.
      if (!_controller.isClosed) {
        _controller.add(
          ErrorMessage(
            code: 'unsupported_type',
            message: 'unknown server type',
          ),
        );
      }
    } catch (_) {
      // Malformed frame — drop silently. Previous diagnostic logging
      // for cast / decode errors lived here; we trust upstream codecs
      // now that the channel pipeline is stable.
    }
  }
}
