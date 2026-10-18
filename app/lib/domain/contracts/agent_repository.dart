import 'repository.dart';

class ManagedAgent {
  const ManagedAgent({
    required this.agentId,
    required this.name,
    required this.cwd,
    required this.roomId,
    required this.state,
    this.error,
  });
  final String agentId, name, cwd, roomId, state;
  final String? error;
}

class AgentAvailability {
  const AgentAvailability({
    required this.available,
    this.launcherId,
    this.reason,
    required this.cwd,
    required this.maxAgents,
    required this.agents,
  });
  final bool available;
  final String? launcherId;
  final String? reason;
  final String cwd;
  final int maxAgents;
  final List<ManagedAgent> agents;
}

class AgentFailure implements Exception {
  const AgentFailure(this.message, {this.outcomeUnknown = false});
  final String message;
  final bool outcomeUnknown;
}

abstract class AgentRepository extends Repository {
  /// Guarded recovery binds only to the already-selected exact target. The
  /// guard remains authoritative for the lifetime of the resulting lease.
  Future<void> bind(String peer, String room, {bool Function()? isCurrent});
  Stream<void> get invalidations;
  Stream<void> get changes => const Stream.empty();

  /// Read-only reconciliation; security and launch requests are never replayed.
  Future<AgentAvailability> list();
  LauncherStatus? get launcherStatus => null;
  List<LauncherProject> get projects => const [];
  Future<void> status() async =>
      throw const AgentFailure('Update/setup the host launcher.');
  Future<void> initializePin(String pin) async =>
      throw const AgentFailure('Update/setup the host launcher.');
  Future<void> unlock(String pin) async =>
      throw const AgentFailure('Update/setup the host launcher.');
  Future<bool> lock({bool shutdown = false}) async =>
      throw const AgentFailure('Update/setup the host launcher.');
  bool get hasUnknownLaunch => false;
  Future<ManagedAgent> launch(
    String projectId,
    String? name, {
    bool acknowledgeUnknown = false,
  });
  Future<ManagedAgent> stop(String agentId);

  /// Wait for the exact returned room, then select it on the bound peer.
  /// [beforeHandoff] runs synchronously after all asynchronous authority checks,
  /// immediately before selecting the exact running child on the bound peer.
  Future<void> openAgent(
    ManagedAgent agent, {
    void Function(String peer, String room)? beforeHandoff,
  });
  void refreshDiscovery();
}

String? validateAgentInput(String cwd, String? name) {
  final controls = RegExp(r'[\x00-\x1f\x7f-\x9f]');
  if (cwd.trim().isEmpty || cwd.length > 4096 || controls.hasMatch(cwd)) {
    return 'Enter an existing directory (up to 4096 characters, no control characters).';
  }
  if (name != null &&
      (name.trim().isEmpty || name.length > 80 || controls.hasMatch(name))) {
    return 'Name must be 1–80 characters, not blank, with no control characters.';
  }
  return null;
}

const newLaunchCompatibilityMessage =
    'New agents require launcher API 3 to preserve the configured model. '
    'Update the host after running jobs finish, then check status. '
    'Existing agents remain available.';

enum PinSetup { available, configured, unavailable }

class LauncherStatus {
  const LauncherStatus({
    required this.launcherId,
    required this.epoch,
    required this.configured,
    required this.unlocked,
    required this.expiresAt,
    required this.cooldownUntil,
    this.pinSetup,
    this.launcherApi,
  });
  final String launcherId, epoch;
  final bool configured, unlocked;
  final PinSetup? pinSetup;
  final int? launcherApi;
  final int? expiresAt;
  final int cooldownUntil;
  bool get supportsNewLaunch => (launcherApi ?? 0) >= 3;
  bool get permitsControl =>
      configured &&
      unlocked &&
      expiresAt != null &&
      expiresAt! > DateTime.now().millisecondsSinceEpoch;
}

class LauncherProject {
  const LauncherProject(
    this.projectId,
    this.name,
    this.cwd,
    this.allowedFolders,
  );
  final String projectId, name, cwd;
  final List<String> allowedFolders;
}
