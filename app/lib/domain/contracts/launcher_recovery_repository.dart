import 'repository.dart';
import 'session_control_repository.dart';

class LaunchHostChoice {
  const LaunchHostChoice(this.room, this.label);
  final String room, label;
}

/// One foreground-only recovery. No credentials, grants or Stop tokens retained.
abstract class LauncherRecoveryRepository extends Repository {
  Stream<void> get invalidations => const Stream.empty();
  Future<LaunchingHost?> resolve(String peer, String child);
  List<LaunchHostChoice> get choices;
  Future<void> selectParent(String room);
  Future<SessionStopCapability> returnToChild();
  void checkCurrent();
  void invalidate();
}
