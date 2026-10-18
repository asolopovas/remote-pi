import 'package:app/domain/contracts/fresh_launcher_repository.dart';
import 'package:app/domain/contracts/launcher_recovery_repository.dart';
import 'package:app/domain/contracts/session_control_repository.dart';
import 'dart:async';
import 'package:app/domain/contracts/agent_repository.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import '../states/agents_state.dart';

class AgentsViewModel extends ViewModel<AgentsViewState> {
  AgentsViewModel(
    this._repo, {
    LauncherRecoveryRepository? recovery,
    FreshLauncherRepository? fresh,
  }) : _fresh = fresh,
       _recovery = recovery,
       super(const AgentsViewState()) {
    _subscription = _repo.invalidations.listen((_) {
      if (!_disposed) {
        emit(
          const AgentsViewState(
            invalid: true,
            message: 'Host disconnected. Reopen the launcher.',
          ),
        );
      }
    });
    _freshInvalidations = _fresh?.invalidations.listen(
      (_) => rejectTargetChange(),
    );
    _recoveryInvalidations = _recovery?.invalidations.listen((_) {
      rejectTargetChange();
    });
    _changes = _repo.changes.listen((_) {
      if (_canAct) {
        emit(
          AgentsViewState(
            busy: state.busy,
            invalid: state.invalid,
            needsReconciliation: state.needsReconciliation,
            availability: state.availability,
            message: state.message,
          ),
        );
      }
    });
  }
  final FreshLauncherRepository? _fresh;
  StreamSubscription<void>? _freshInvalidations;
  bool _freshActive = false, _freshConsumed = false;
  String? launchSession;
  bool choosingFreshSession = false;
  List<FreshLauncherSession> freshSessions = const [];

  Future<void> _acceptFresh(FreshLauncherEndpoint endpoint) async {
    if (_disposed || state.invalid) return;
    _freshActive = true;
    expectedLauncher = endpoint.launcherId;
    launchRoom = endpoint.room;
    launchSession = endpoint.label;
    choosingFreshSession = false;
    recoveryError = null;
    await initialize(endpoint.peer, endpoint.room);
    if (security?.launcherId != expectedLauncher) rejectTargetChange();
  }

  void _freshUnavailable(AgentFailure error) {
    if (_disposed || state.invalid) return;
    if (error is FreshLauncherUnavailable) {
      _freshActive = true;
      freshSessions = _fresh!.sessions;
      choosingFreshSession = true;
      emit(AgentsViewState(message: error.message));
    } else {
      recoveryError = error.message;
      rejectTargetChange();
    }
  }

  Future<void> chooseFreshSession(String room) async {
    if (!_canAct || _started || resolvingHost || !choosingFreshSession) return;
    resolvingHost = true;
    choosingFreshSession = false;
    emit(const AgentsViewState(busy: true));
    try {
      await _acceptFresh(await _fresh!.selectSession(room));
    } on AgentFailure catch (error) {
      _freshUnavailable(error);
    } finally {
      resolvingHost = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> resolveFresh(String peer, {String? preferredRoom}) async {
    if (_started || _disposed || resolvingHost) return;
    resolvingHost = true;
    emit(const AgentsViewState(busy: true));
    try {
      final endpoint = await _fresh!.resolve(
        peer,
        preferredRoom: preferredRoom,
      );
      await _acceptFresh(endpoint);
    } on AgentFailure catch (error) {
      _freshUnavailable(error);
    } finally {
      resolvingHost = false;
      if (!_disposed) notifyListeners();
    }
  }

  final AgentRepository _repo;
  final LauncherRecoveryRepository? _recovery;
  bool resolvingHost = false, choosingHost = false, recovering = false;
  bool _selectingHost = false, _recoveryActive = false;
  StreamSubscription<void>? _recoveryInvalidations;
  String? expectedLauncher;
  List<LaunchHostChoice> hostChoices = const [];
  String? launchRoom;
  String? recoveryError;

  Future<void> resolveHost(
    String peer,
    String child, {
    required bool returnToChild,
  }) async {
    if (_started || _disposed || resolvingHost || choosingHost) return;
    _recoveryActive = true;
    recovering = returnToChild;
    resolvingHost = true;
    emit(const AgentsViewState(busy: true));
    try {
      final origin = await _recovery!.resolve(peer, child);
      if (!_recoveryCurrent()) return;
      if (origin == null) {
        hostChoices = _recovery.choices;
        choosingHost = true;
        emit(const AgentsViewState());
      } else {
        expectedLauncher = origin.launcherId;
        await chooseHost(peer, origin.roomId);
      }
    } on SessionControlFailure catch (error) {
      if (_disposed) return;
      recoveryError = error.message;
      rejectTargetChange();
    } finally {
      resolvingHost = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> chooseHost(String peer, String room) async {
    if (!_canAct || _started || _selectingHost) return;
    _selectingHost = true;
    choosingHost = false;
    resolvingHost = true;
    emit(const AgentsViewState(busy: true));
    try {
      await _recovery!.selectParent(room);
      if (!_recoveryCurrent()) return;
      launchRoom = room;
      await initialize(peer, room);
      if (expectedLauncher != null &&
          security?.launcherId != expectedLauncher) {
        rejectTargetChange();
      }
    } on SessionControlFailure catch (error) {
      if (_disposed) return;
      recoveryError = error.message;
      rejectTargetChange();
    } finally {
      _selectingHost = false;
      resolvingHost = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<SessionStopCapability?> finishRecovery() async {
    if (!_canAct || !recovering || state.busy || !unlocked) {
      return null;
    }
    try {
      return await _recovery!.returnToChild();
    } on SessionControlFailure catch (error) {
      recoveryError = error.message;
      if (!_disposed) {
        emit(AgentsViewState(message: error.message, invalid: true));
      }
      return null;
    }
  }

  Future<bool> cancelRecovery() async {
    if (!_canAct || state.busy) return false;
    try {
      await _recovery!.returnToChild();
      return !_disposed;
    } on SessionControlFailure {
      return false;
    }
  }

  void invalidateRecovery() {
    _fresh?.invalidate();
    if (_recovery == null ||
        launchRoom == null && !choosingHost && !resolvingHost) {
      return;
    }
    _recovery.invalidate();
    rejectTargetChange();
  }

  void rejectTargetChange() {
    if (_disposed) return;
    emit(
      const AgentsViewState(
        invalid: true,
        message: 'Host changed. Reopen the launcher.',
      ),
    );
  }

  LauncherStatus? get security => _repo.launcherStatus;
  List<LauncherProject> get projects => _repo.projects;
  bool get hasUnknownLaunch => _repo.hasUnknownLaunch;
  bool get unlocked =>
      security?.permitsControl == true &&
      (expectedLauncher == null || security?.launcherId == expectedLauncher);
  bool get _canAct =>
      !_disposed && !_freshConsumed && !state.invalid && _recoveryCurrent();
  bool _recoveryCurrent() {
    if (_disposed || state.invalid) return false;
    if (_freshActive) {
      if (expectedLauncher != null &&
          security != null &&
          security!.launcherId != expectedLauncher) {
        rejectTargetChange();
        return false;
      }
      if (security != null && !security!.supportsNewLaunch) {
        emit(
          const AgentsViewState(
            invalid: true,
            message: newLaunchCompatibilityMessage,
          ),
        );
        return false;
      }
      try {
        _fresh!.checkCurrent();
      } on AgentFailure {
        rejectTargetChange();
        return false;
      }
    }
    if (!_recoveryActive) return true;
    try {
      _recovery!.checkCurrent();
      return true;
    } on SessionControlFailure {
      rejectTargetChange();
      return false;
    }
  }

  Future<void> initializePin(String pin) async {
    if (!_canAct || state.busy) {
      pin = '';
      return;
    }
    await _run(() async {
      try {
        final pending = _repo.initializePin(pin);
        pin = '';
        await pending;
      } on AgentFailure catch (error) {
        pin = '';
        if (error.outcomeUnknown && _canAct) {
          // Read-only reconciliation, never replay setup or reuse the PIN.
          try {
            await _repo.status();
          } on AgentFailure {
            // Preserve the uncertain mutation outcome, not a refresh error.
          }
        }
        rethrow;
      }
      _checkAction();
      if (unlocked) return _repo.list();
      return const AgentAvailability(
        available: false,
        cwd: '',
        maxAgents: 0,
        agents: [],
      );
    }, reconciles: true);
  }

  Future<void> unlock(String pin) async {
    if (!_canAct || state.busy) {
      pin = '';
      return;
    }
    if (expectedLauncher != null && security?.launcherId != expectedLauncher) {
      pin = '';
      rejectTargetChange();
      return;
    }
    await _run(() async {
      final pending = _repo.unlock(pin);
      pin = '';
      await pending;
      _checkAction();
      return _repo.list();
    }, reconciles: true);
  }

  Future<void> lock({bool shutdown = false}) async {
    if (!_canAct || state.busy) return;
    await _run(
      () async {
        final stopped = await _repo.lock(shutdown: shutdown);
        if (!stopped) {
          throw const AgentFailure(
            'Access locked, but some of your managed agents could not stop. Check the host.',
          );
        }
        return AgentAvailability(
          available: false,
          cwd: '',
          maxAgents: 0,
          agents: const [],
        );
      },
      message: shutdown
          ? 'Your managed agents stopped. Access locked.'
          : 'Access locked. Background agents keep running.',
    );
  }

  late final StreamSubscription<void> _subscription, _changes;
  bool _disposed = false, _started = false;
  bool _reconcilingSelection = false;
  bool get reconcilingSelection => _reconcilingSelection && state.busy;
  Future<void> initialize(String peer, String room) async {
    if (_started || !_canAct) return;
    _started = true;
    await _run(() async {
      await _repo.bind(
        peer,
        room,
        isCurrent: _recoveryActive || _freshActive ? () => _canAct : null,
      );
      _checkAction();
      return _repo.list();
    }, reconciles: true);
  }

  Future<void> refresh() async {
    if (!_canAct || state.busy) return;
    _repo.refreshDiscovery();
    await _run(_repo.list, reconciles: true);
  }

  Future<ManagedAgent?> launch(
    String projectId,
    String? name, {
    required bool confirmed,
    bool acknowledgeUnknown = false,
  }) async {
    if (!_canAct ||
        !confirmed ||
        state.busy ||
        state.invalid ||
        !unlocked ||
        state.needsReconciliation ||
        state.availability?.available != true) {
      return null;
    }
    if (security?.supportsNewLaunch != true) {
      emit(
        AgentsViewState(
          availability: state.availability,
          message: newLaunchCompatibilityMessage,
        ),
      );
      return null;
    }
    final error = validateAgentInput(projectId, name);
    if (error != null) {
      emit(AgentsViewState(availability: state.availability, message: error));
      return null;
    }
    final old = state.availability!;
    ManagedAgent? launched;
    await _run(
      () async {
        final agent = await _repo.launch(
          projectId,
          name,
          acknowledgeUnknown: acknowledgeUnknown,
        );
        if (agent.state != 'running' || agent.roomId.trim().isEmpty) {
          throw AgentFailure(
            agent.error ??
                (agent.roomId.trim().isEmpty
                    ? 'Host returned no agent room. Check status.'
                    : 'Agent is ${agent.state}. Check status before starting another.'),
            outcomeUnknown: agent.state != 'failed' && agent.state != 'stopped',
          );
        }
        _checkAction();
        launched = agent;
        _repo.refreshDiscovery();
        return AgentAvailability(
          available: old.available,
          launcherId: old.launcherId,
          reason: old.reason,
          cwd: old.cwd,
          maxAgents: old.maxAgents,
          agents: List.unmodifiable([
            ...old.agents.where((a) => a.agentId != agent.agentId),
            agent,
          ]),
        );
      },
      message: 'Agent running.',
      busyMessage: 'Starting…',
    );
    return !_disposed && !state.invalid && !state.needsReconciliation
        ? launched
        : null;
  }

  Future<bool> openAgent(ManagedAgent agent) async {
    if (!_canAct || state.busy || !unlocked) return false;
    if (_freshActive) {
      final previous = state.availability;
      emit(
        AgentsViewState(
          busy: true,
          availability: previous,
          message: 'Connecting…',
        ),
      );
      try {
        await _repo.openAgent(
          agent,
          beforeHandoff: (peer, room) {
            _checkAction();
            if (room != agent.roomId) {
              throw const AgentFailure('Agent changed. Reopen from Home.');
            }
            _fresh!.consumeHandoff(peer, agent);
            _freshConsumed = true;
          },
        );
        // A one-shot navigation result, not a bypass of _canAct. The consumed
        // fresh lease cannot authorize any more PIN, Start or other mutations.
        if (!_disposed && !state.invalid && _freshConsumed) {
          emit(AgentsViewState(availability: previous));
          return true;
        }
      } on AgentFailure catch (error) {
        if (_canAct) {
          emit(AgentsViewState(availability: previous, message: error.message));
        }
      }
      return false;
    }
    var opened = false;
    await _run(() async {
      await _repo.openAgent(agent);
      opened = true;
      return state.availability!;
    }, busyMessage: 'Connecting…');
    return opened && !_disposed && !state.invalid;
  }

  Future<void> stop(String id, {required bool confirmed}) async {
    if (!_canAct || !confirmed || state.busy || !unlocked) return;
    final old = state.availability;
    if (old == null ||
        !old.agents.any(
          (a) =>
              a.agentId == id &&
              (a.state == 'running' ||
                  a.state == 'starting' ||
                  a.state == 'failed'),
        )) {
      return;
    }
    await _run(() async {
      final agent = await _repo.stop(id);
      return AgentAvailability(
        available: old.available,
        launcherId: old.launcherId,
        reason: old.reason,
        cwd: old.cwd,
        maxAgents: old.maxAgents,
        agents: List.unmodifiable(
          old.agents.map((a) => a.agentId == agent.agentId ? agent : a),
        ),
      );
    });
  }

  void _checkAction() {
    if (!_canAct) {
      throw const AgentFailure('Host changed. Reopen the launcher.');
    }
  }

  Future<void> _run(
    Future<AgentAvailability> Function() operation, {
    String? message,
    bool reconciles = false,
    String? busyMessage,
  }) async {
    if (!_canAct) return;
    _reconcilingSelection = reconciles;
    final wasUncertain = state.needsReconciliation;
    final previous = state.availability;
    emit(
      AgentsViewState(
        busy: true,
        message: busyMessage,
        availability: previous,
        needsReconciliation: wasUncertain,
      ),
    );
    try {
      final result = await operation();
      if (_canAct) {
        emit(
          AgentsViewState(
            availability: result,
            message: message,
            needsReconciliation: reconciles ? false : wasUncertain,
          ),
        );
      }
    } on AgentFailure catch (error) {
      if (_canAct) {
        emit(
          AgentsViewState(
            availability: previous,
            message: error.message,
            needsReconciliation:
                wasUncertain || error.outcomeUnknown || reconciles,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription.cancel();
    _changes.cancel();
    _recoveryInvalidations?.cancel();
    _freshInvalidations?.cancel();
    _fresh?.dispose();
    _repo.dispose();
    _recovery?.dispose();
    super.dispose();
  }
}
