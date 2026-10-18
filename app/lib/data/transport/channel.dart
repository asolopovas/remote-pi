import 'package:app/domain/contracts/agent_repository.dart';
import 'dart:typed_data';

import 'package:app/protocol/protocol.dart';

/// Abstract channel — testable interface over [PlainPeerChannel].
abstract class IChannel {
  Stream<ServerMessage> get serverMessages;
  Future<void> send(ClientMessage msg);
  Future<void> close();
}

/// Optional capability mixed into a channel that also speaks raw relay
/// control frames (subscribe_presence, peer_online, etc — see plano 12).
/// ConnectionManager does an `is IControlLink` cast to drive presence;
/// channels that don't implement it simply skip the subsystem.
abstract class IControlLink {
  Stream<ControlInbound> get controlFrames;
  void sendControl(Map<String, dynamic> json);
}

/// Authenticated outer-envelope scope, never decoded from the inner payload.
typedef ScopedPeerPayload = ({Uint8List bytes, String peer, String? room});

abstract class IScopedPeerTransport {
  Future<ScopedPeerPayload> receiveScoped();
}

/// Local ingress evidence for management error settlement; not a wire field.
const sessionControlRequestPrefix = 'session-control:';
const launcherSetupRequestPrefix = 'launcher-setup:';

class LauncherSetupError extends ScopedPeerError {
  LauncherSetupError(super.error, {required super.peer, required super.room});
}

/// Local-only classification: control errors must never become chat history.
class SessionControlError extends ScopedPeerError {
  SessionControlError(super.error, {required super.peer, required super.room});
}

class ScopedPeerError extends ErrorMessage {
  ScopedPeerError(ErrorMessage error, {required this.peer, required this.room})
    : super(
        inReplyTo: error.inReplyTo,
        code: error.code,
        message: error.message,
      );
  final String peer;
  final String? room;
}

/// Optional read-only request path. Results retain authenticated outer scope;
/// implementations must consume replies/errors without publishing chat events.
abstract class IRoomLauncherProbe {
  Future<({String peer, String room, LauncherStatus status})?> probeLauncher(
    String room,
  );
  void cancelLauncherProbes();
}

const launcherProbeRequestPrefix = 'launcher-probe:';

/// Authenticated action ingress, kept separate from decoded wire fields.
typedef ScopedActionReply = ({
  ServerMessage message,
  String peer,
  String? room,
});

abstract class IScopedActionChannel {
  Stream<ScopedActionReply> get actionReplies;
}

const actionRequestPrefix = 'act_';

class ScopedActionError extends ScopedPeerError {
  ScopedActionError(super.error, {required super.peer, required super.room});
}
