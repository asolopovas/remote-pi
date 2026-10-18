import 'agent_repository.dart';
import 'repository.dart';

class FreshLauncherEndpoint {
  const FreshLauncherEndpoint(
    this.peer,
    this.room,
    this.label,
    this.launcherId,
  );
  final String peer, room, label, launcherId;
}

class FreshLauncherSession {
  const FreshLauncherSession(this.room, this.label);
  final String room, label;
}

class FreshLauncherUnavailable extends AgentFailure {
  const FreshLauncherUnavailable()
    : super('No compatible launcher found. $newLaunchCompatibilityMessage');
}

/// Fresh Start only. Never used to infer a managed child's parent.
abstract class FreshLauncherRepository extends Repository {
  Stream<void> get invalidations;
  Future<FreshLauncherEndpoint> resolve(String peer, {String? preferredRoom});
  List<FreshLauncherSession> get sessions;
  Future<FreshLauncherEndpoint> selectSession(String room);

  /// Terminal consumption, only at a validated synchronous child-room handoff.
  /// It authorizes navigation, never further launcher mutations.
  void consumeHandoff(String peer, ManagedAgent agent);

  void checkCurrent();
  void invalidate();
}
