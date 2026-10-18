import 'package:app/domain/contracts/agent_repository.dart';
import 'package:app/protocol/codec.dart';
import 'package:app/protocol/uuid7.dart';
// WebSocket-based PeerTransport.
//
// Flow per connection:
//   1. Connect to relay WS
//   2. Ed25519 challenge-response (hello → challenge → auth)
//   3. After auth, two parallel streams of inbound frames:
//        - envelope frames `{peer, ct}` → decoded to the peer queue
//        - control frames (top-level `type`, no `peer`) → control stream
//      Outbound `subscribe_presence` / `presence_check` go raw too.
//
// `peer` is standard base64 of the destination's Ed25519 pubkey (matches
// the relay registry, populated from the peer's hello). `ct` is base64 of
// the inner-envelope bytes (plain JSON post-rollback, see plano 06).

import 'dart:async';
import 'dart:convert';

import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/data/transport/relay_config.dart';
import 'package:app/protocol/protocol.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../pairing/pair_request_flow.dart';

class WsTransportError implements Exception {
  final String message;
  const WsTransportError(this.message);

  @override
  String toString() => 'WsTransportError: $message';
}

class WsTransport
    implements
        PeerTransport,
        IControlLink,
        IScopedPeerTransport,
        IRoomLauncherProbe {
  final WebSocketChannel _ws;
  final _queue = _MsgQueue();
  final _controlController = StreamController<ControlInbound>.broadcast();

  WsTransport._(this._ws);

  // Connect, authenticate with relay, and return a ready transport.
  static Future<WsTransport> connect({
    required String relayUrl,
    required String peerPubkey, // base64 standard or url — destination peer
    required SimpleKeyPair ed25519Key, // this device's Ed25519 long-term key
  }) async {
    // Plan-18 follow-up — set a WS-level pingInterval (RFC 6455
    // control frames). This keeps the TCP connection alive through
    // NAT / corporate proxies that aggressively close idle sockets,
    // and surfaces a dead WS as `onDone` / `onError` instead of
    // letting it silently linger until the next user action. The
    // protocol-level Ping/Pong handled by ConnectionManager covers
    // app↔Pi liveness; this one covers app↔relay TCP liveness.
    // Accept http(s) URLs in the user-facing form but always speak
    // ws(s) on the wire — IOWebSocketChannel rejects http schemes.
    final WebSocketChannel ws = IOWebSocketChannel.connect(
      Uri.parse(toWsRelayUrl(relayUrl)),
      pingInterval: const Duration(seconds: 20),
    );
    // Scope ingress before auth can release any queued envelope frames.
    final transport = WsTransport._(ws)
      .._peerPubkey = toStandardB64(peerPubkey);

    final challengeCompleter = Completer<Map<String, dynamic>>();
    bool authDone = false;

    final sub = ws.stream.listen(
      (raw) {
        // Volume probe: log every frame the relay pushes onto this
        // socket so we can spot firehose patterns (e.g. presence
        // churn, repeated room snapshots) by counting prefix
        // occurrences — body kept compact so the log stays grep-able
        // even when the relay is chatty.
        final rawStr = raw is String ? raw : raw.toString();
        if (!authDone) {
          debugPrint('[ws-in] bytes=${rawStr.length} stage=preauth');
          try {
            challengeCompleter.complete(
              jsonDecode(raw as String) as Map<String, dynamic>,
            );
          } catch (e) {
            if (!challengeCompleter.isCompleted) {
              challengeCompleter.completeError(e);
            }
          }
          return;
        }
        try {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          // Envelope: {peer, room?, ct} → enqueue payload bytes.
          if (frame.containsKey('peer') && frame.containsKey('ct')) {
            // Relay rewrites `peer` from the authenticated sender. This inner
            // channel belongs to ONE paired target, unlike discovery controls.
            if (!transport._isExpectedSender(frame['peer'])) {
              debugPrint(
                '[ws-in] bytes=${rawStr.length} DROPPED (peer-mismatch)',
              );
              return;
            }
            final bytes = _b64Decode(frame['ct'] as String);
            final senderRoom = frame['room'] as String?;
            final inner = jsonDecode(utf8.decode(bytes));
            // Probe traffic is management-only, including late replies and errors.
            // Never relabel this outer room as the currently selected room.
            final probeId = inner is Map<String, dynamic>
                ? inner['in_reply_to']
                : null;
            if (probeId is String &&
                probeId.startsWith(launcherProbeRequestPrefix)) {
              final pending = transport._launcherProbes[probeId];
              if (pending != null && senderRoom == pending.room) {
                if (inner['type'] == 'launcher_status_result') {
                  final result = decodeServer(utf8.decode(bytes));
                  if (result is LauncherStatusResult) {
                    transport._finishProbe(probeId, (
                      peer: transport._peerPubkey,
                      room: senderRoom!,
                      status: result.status,
                    ));
                  }
                } else if (inner['type'] == 'error') {
                  transport._finishProbe(probeId, null);
                }
              }
              return;
            }
            // Metadata is independent of chat selection, but still belongs
            // to this authenticated paired sender and exact routing room.
            if (inner is Map<String, dynamic> &&
                (inner['type'] == 'room_display_snapshot' ||
                    inner['type'] == 'room_display_request')) {
              if (bytes.length <= 4096) {
                final snapshot = RoomDisplaySnapshot.fromEnvelope(
                  transport._peerPubkey,
                  senderRoom,
                  inner,
                );
                if (snapshot != null &&
                    !transport._controlController.isClosed) {
                  transport._controlController.add(snapshot);
                }
              }
              return;
            }
            // Agent management never accepts legacy unscoped replies, including
            // correlated errors. Keep other legacy chat/action behavior intact.
            if (inner is Map<String, dynamic> &&
                (const [
                      'agent_list_result',
                      'launcher_status_result',
                      'launcher_shutdown_result',
                      'project_list_result',
                      'agent_launch_result',
                      'agent_stop_result',
                      'session_control_status_result',
                      'session_stop_result',
                    ].contains(inner['type']) ||
                    (inner['type'] == 'error' &&
                        (transport._agentRequestIds.contains(
                              inner['in_reply_to'],
                            ) ||
                            (inner['in_reply_to'] is String &&
                                (inner['in_reply_to'] as String).startsWith(
                                  launcherSetupRequestPrefix,
                                ))))) &&
                senderRoom != transport._activeRoom) {
              return;
            }
            // Plan-18 follow-up — DEMUX inbound by sender room.
            // SessionRepository is singleton; without this guard,
            // AgentChunks for a chat the user just left bleed into
            // the chat they're now viewing. When senderRoom doesn't
            // match the currently-addressed Pi cwd, drop the payload.
            // Legacy Pis without `room` route unconditionally.
            if (senderRoom != null && senderRoom != transport._activeRoom) {
              debugPrint(
                '[ws-in] bytes=${rawStr.length} kind=envelope '
                'sender_room=$senderRoom DROPPED (room-mismatch)',
              );
              return;
            }
            debugPrint(
              '[ws-in] bytes=${rawStr.length} kind=envelope '
              'ct.bytes=${bytes.length}',
            );
            transport._queue.add((
              bytes: bytes,
              roomEpoch: transport._roomEpoch,
              room: senderRoom,
            ));
            return;
          }
          // Control: top-level `type` only → presence stream.
          final ctrl = ControlInbound.tryFromJson(frame);
          if (ctrl != null && !transport._controlController.isClosed) {
            debugPrint(
              '[ws-in] bytes=${rawStr.length} kind=control '
              'type=${frame['type']}',
            );
            transport._controlController.add(ctrl);
            return;
          }
          // Anything else: unknown shape — drop silently.
          debugPrint('[ws-in] bytes=${rawStr.length} kind=unknown DROPPED');
        } catch (e) {
          debugPrint(
            '[ws-in] bytes=${rawStr.length} kind=malformed DROPPED err=$e',
          );
        }
      },
      onError: (e) {
        if (!challengeCompleter.isCompleted) {
          challengeCompleter.completeError(e);
        }
        transport.cancelLauncherProbes();
        transport._probeClosed = true;
        transport._queue.error(e);
      },
      onDone: () {
        if (!challengeCompleter.isCompleted) {
          challengeCompleter.completeError(
            const WsTransportError('WS closed during auth'),
          );
        }
        transport.cancelLauncherProbes();
        transport._probeClosed = true;
        transport._queue.close();
        if (!transport._controlController.isClosed) {
          transport._controlController.close();
        }
      },
    );

    try {
      // 1. Hello (standard base64 — matches relay registry format).
      // Plan 17: app is a client (no cwd) and always announces itself
      // on the canonical 'main' room. Pi-side hellos include their own
      // room_id (one per cwd) AND room_meta; that's not our concern here.
      final pub = await ed25519Key.extractPublicKey();
      ws.sink.add(
        jsonEncode({
          'type': 'hello',
          'pubkey': base64.encode(pub.bytes),
          'room_id': 'main',
        }),
      );

      // 2. Challenge
      final ch = await challengeCompleter.future;
      if (ch['type'] != 'challenge') {
        throw WsTransportError('Expected challenge, got ${ch['type']}');
      }
      final nonce = _b64Decode(ch['nonce'] as String);

      // 3. Auth
      final sig = await Ed25519().sign(nonce, keyPair: ed25519Key);
      ws.sink.add(
        jsonEncode({'type': 'auth', 'sig': base64.encode(sig.bytes)}),
      );
      authDone = true;

      transport._sub = sub;
      return transport;
    } catch (e) {
      await sub.cancel();
      await ws.sink.close();
      rethrow;
    }
  }

  String _peerPubkey = '';
  StreamSubscription? _sub;

  /// Active target room on the Pi side. Plan 17: set via
  /// `setActiveRoom`, defaults to 'main' when unset. The outer envelope
  /// embeds this so the Pi can route the inner message to the right
  /// per-cwd session.
  String _activeRoom = 'main';
  int _roomEpoch = 0;
  final _agentRequestIds = <String>{};

  /// Override the destination room (Pi side). The app remains on the
  /// 'main' room itself (that's what we sent in `hello.room_id`).
  void setActiveRoom(String room) {
    if (room == _activeRoom) {
      return;
    }
    cancelLauncherProbes();
    _activeRoom = room;
    _roomEpoch++;
  }

  final _launcherProbes = <String, _LauncherProbe>{};
  bool _probeClosed = false;

  @override
  Future<({String peer, String room, LauncherStatus status})?> probeLauncher(
    String room,
  ) async {
    if (_probeClosed || room.isEmpty || _launcherProbes.length >= 2) {
      return null;
    }
    final id = '$launcherProbeRequestPrefix${uuid7()}';
    final pending = _LauncherProbe(room);
    _launcherProbes[id] = pending;
    pending.timer = Timer(
      const Duration(seconds: 2),
      () => _finishProbe(id, null),
    );
    // Same authenticated codec/envelope path, but a fixed read-only message and
    // scoped request sink instead of the ordinary selected-room receive queue.
    _agentRequestIds.add(id);
    if (_agentRequestIds.length > 128) {
      _agentRequestIds.remove(_agentRequestIds.first);
    }
    try {
      _ws.sink.add(
        jsonEncode({
          'peer': _peerPubkey,
          'room': room,
          'ct': base64.encode(
            utf8.encode(
              encodeClient(LauncherRequest('launcher_status', id)).trimRight(),
            ),
          ),
        }),
      );
    } on StateError {
      _finishProbe(id, null);
    }
    return pending.result.future;
  }

  void _finishProbe(
    String id,
    ({String peer, String room, LauncherStatus status})? result,
  ) {
    final pending = _launcherProbes.remove(id);
    if (pending == null) return;
    pending.timer?.cancel();
    pending.result.complete(result);
  }

  @override
  void cancelLauncherProbes() {
    for (final id in _launcherProbes.keys.toList()) {
      _finishProbe(id, null);
    }
  }

  bool _isExpectedSender(Object? sender) {
    if (sender is! String) return false;
    try {
      final standard = toStandardB64(sender);
      return base64.decode(standard).length == 32 && standard == _peerPubkey;
    } on FormatException {
      return false;
    }
  }

  @override
  Future<void> send(Uint8List data) async {
    final inner = jsonDecode(utf8.decode(data));
    if (inner is Map<String, dynamic> &&
        const [
          'agent_list',
          'launcher_status',
          'launcher_unlock',
          'launcher_pin_initialize',
          'launcher_lock',
          'launcher_shutdown',
          'project_list',
          'project_launch',
          'launcher_agent_stop',
          'agent_launch',
          'agent_stop',
          'session_control_status',
          'session_stop',
        ].contains(inner['type'])) {
      _agentRequestIds.add(inner['id'] as String);
      if (_agentRequestIds.length > 128) {
        _agentRequestIds.remove(_agentRequestIds.first);
      }
    }
    _ws.sink.add(
      jsonEncode({
        'peer': _peerPubkey,
        'room': _activeRoom,
        'ct': base64.encode(data),
      }),
    );
  }

  @override
  Future<Uint8List> receive() async {
    return (await receiveScoped()).bytes;
  }

  @override
  Future<ScopedPeerPayload> receiveScoped() async {
    while (true) {
      final payload = await _queue.next();
      // Includes legacy payloads without sender room: they belong to the
      // selection at ingress, not a later room that drains the same queue.
      if (payload.roomEpoch == _roomEpoch) {
        return (bytes: payload.bytes, peer: _peerPubkey, room: payload.room);
      }
    }
  }

  // ---- IControlLink --------------------------------------------------------

  @override
  Stream<ControlInbound> get controlFrames => _controlController.stream;

  @override
  void sendControl(Map<String, dynamic> json) {
    _ws.sink.add(jsonEncode(json));
  }

  // -------------------------------------------------------------------------

  @override
  Future<void> close() async {
    _probeClosed = true;
    cancelLauncherProbes();
    await _sub?.cancel();
    await _ws.sink.close();
    _queue.close();
    if (!_controlController.isClosed) await _controlController.close();
  }
}

// ---------------------------------------------------------------------------

typedef _QueuedPayload = ({Uint8List bytes, int roomEpoch, String? room});

class _MsgQueue {
  final _buf = <_QueuedPayload>[];
  final _waiters = <Completer<_QueuedPayload>>[];
  bool _closed = false;

  void add(_QueuedPayload msg) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(msg);
    } else if (!_closed) {
      _buf.add(msg);
    }
  }

  void error(Object e) {
    for (final w in _waiters) {
      w.completeError(e);
    }
    _waiters.clear();
    _closed = true;
  }

  void close() {
    for (final w in _waiters) {
      w.completeError(const WsTransportError('transport closed'));
    }
    _waiters.clear();
    _closed = true;
  }

  Future<_QueuedPayload> next() {
    if (_closed) {
      return Future.error(const WsTransportError('transport closed'));
    }
    if (_buf.isNotEmpty) return Future.value(_buf.removeAt(0));
    final c = Completer<_QueuedPayload>();
    _waiters.add(c);
    return c.future;
  }
}

// Decodes standard or url-safe base64 (pads defensively).
Uint8List _b64Decode(String s) {
  final pad = (4 - s.length % 4) % 4;
  final padded = s + '=' * pad;
  try {
    return base64.decode(padded);
  } on FormatException {
    return base64Url.decode(padded);
  }
}

class _LauncherProbe {
  _LauncherProbe(this.room);
  final String room;
  final result =
      Completer<({String peer, String room, LauncherStatus status})?>();
  Timer? timer;
}
