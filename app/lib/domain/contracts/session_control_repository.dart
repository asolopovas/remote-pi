import 'repository.dart';

class SessionStopCapability {
  const SessionStopCapability({
    required this.peer,
    required this.room,
    required this.canStop,
    this.token,
    this.reason,
    this.access,
    this.launchingHost,
  });
  final String peer, room;
  final bool canStop;
  final String? token, reason;
  final SessionAccess? access;
  final LaunchingHost? launchingHost;
}

enum SessionStopOutcome { requested, stopped }

class SessionControlFailure implements Exception {
  const SessionControlFailure(this.message, {this.outcomeUnknown = false});
  final String message;
  final bool outcomeUnknown;
}

/// Tokens and confirmations are ephemeral, exact-session scoped, never replayed.
abstract class SessionControlRepository extends Repository {
  Future<SessionStopCapability> inspect(String peer, String room);
  Future<SessionStopOutcome> stop(SessionStopCapability capability);
}

/// A fresh host snapshot, never an authorization or a reusable confirmation.
class SessionAccess {
  const SessionAccess(this.state, this.expiresAt);
  final String state;
  final int? expiresAt;
  String get label {
    if (state == 'unlocked' &&
        (expiresAt ?? 0) <= DateTime.now().millisecondsSinceEpoch) {
      return 'Access snapshot expired · Check access';
    }
    return switch (state) {
      'unlocked' =>
        'Last check: host unlocked until ${DateTime.fromMillisecondsSinceEpoch(expiresAt!).toLocal().toString().substring(11, 19)}',
      'expired' => 'Last check: launching host access expired',
      'locked' => 'Last check: launching host locked',
      _ => 'Launching host unavailable · Check status',
    };
  }
}

class LaunchingHost {
  const LaunchingHost(this.roomId, this.launcherId);
  final String roomId, launcherId;
}
