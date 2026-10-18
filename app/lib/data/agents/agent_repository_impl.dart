import 'dart:async';
import 'package:flutter/services.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/domain/contracts/agent_repository.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/protocol/uuid7.dart';

typedef _AgentMutation = ({
  String id,
  String type,
  (String, String) incarnation,
});

/// App-lifetime request journal: page disposal or reconnect must not forget an
/// uncertain launch. No payload or PIN is retained, and nothing is replayed.
class AgentMutationJournal {
  final _entries = <(String, String), _AgentMutation>{};
  final _history = <(String, String), List<_AgentMutation>>{};
  static const _limit = 32;
  int get _retainedCount =>
      _entries.length +
      _history.values.fold(0, (count, entries) => count + entries.length);

  void _pruneHistory(
    (String, String) key,
    bool Function(_AgentMutation) remove,
  ) {
    final history = _history[key];
    history?.removeWhere(remove);
    if (history != null && history.isEmpty) _history.remove(key);
  }
}

/// Each page owns one pinned channel lease. Reconnect never renews it silently.
class AgentRepositoryImpl extends AgentRepository {
  AgentRepositoryImpl(
    this._conn,
    this._storage,
    this._journal,
    this._preferences, {
    this.timeout = const Duration(seconds: 20),
    this.mutationTimeout = const Duration(seconds: 35),
  });
  final ConnectionManager _conn;
  final PairingStorage _storage;
  final AgentMutationJournal _journal;
  final Preferences _preferences;
  final Duration timeout;

  /// Host readiness (20s) plus failed-child cleanup (up to 6s), with margin.
  final Duration mutationTimeout;
  String? _peer, _room;
  (String, String)? _incarnation;
  LauncherStatus? _security;
  List<LauncherProject> _projects = const [];
  Timer? _expiry;
  bool _reconciled = false;
  @override
  bool get hasUnknownLaunch =>
      _peer != null &&
      _incarnation != null &&
      (_journal._entries[(_peer!, _room!)]?.incarnation == _incarnation ||
          (_journal._history[(_peer!, _room!)]?.any(
                (entry) => entry.incarnation == _incarnation,
              ) ??
              false));
  @override
  LauncherStatus? get launcherStatus => _security;
  @override
  List<LauncherProject> get projects => _projects;
  void _revoke() {
    _reconciled = false;
    _security = null;
    _projects = const [];
    _expiry?.cancel();
  }

  void _accept(LauncherStatus value) {
    if (_disposed || !_valid) {
      _revoke();
      throw const AgentFailure('Host changed. Reopen the launcher.');
    }
    final changed =
        _security?.launcherId != value.launcherId ||
        _security?.epoch != value.epoch;
    if (changed || !value.permitsControl) _projects = const [];
    _security = value;
    _incarnation = (value.launcherId, value.epoch);
    _expiry?.cancel();
    if (value.permitsControl) {
      _expiry = Timer(
        Duration(
          milliseconds:
              value.expiresAt! - DateTime.now().millisecondsSinceEpoch,
        ),
        () {
          _revoke();
          if (!_invalidations.isClosed) _invalidations.add(null);
        },
      );
    }
  }

  @override
  Future<void> status() async {
    _revoke();
    final result = await _request(
      'launcher_status_result',
      (id) => LauncherRequest('launcher_status', id),
    );
    _accept((result as LauncherStatusResult).status);
  }

  @override
  Future<void> initializePin(String pin) async {
    final security = _security;
    if (security == null ||
        security.configured ||
        security.pinSetup != PinSetup.available) {
      throw const AgentFailure(
        'Initial PIN setup is not available. Refresh status.',
      );
    }
    if (!RegExp(r'^\d{6,12}$').hasMatch(pin)) {
      throw const AgentFailure('PIN must be 6–12 digits.');
    }
    if (security.cooldownUntil > DateTime.now().millisecondsSinceEpoch) {
      throw const AgentFailure(
        'PIN cooldown active. Wait before trying again.',
      );
    }
    _revoke();
    final pending = _request(
      'launcher_status_result',
      (id) => LauncherRequest(
        'launcher_pin_initialize',
        id,
        status: security,
        pin: pin,
      ),
      idPrefix: launcherSetupRequestPrefix,
    );
    pin = '';
    final reply = (await pending as LauncherStatusResult).status;
    if (reply.launcherId != security.launcherId ||
        reply.epoch.isEmpty ||
        !reply.configured) {
      throw const AgentFailure(
        'PIN setup result could not be verified. Check status.',
        outcomeUnknown: true,
      );
    }
    // _request accepts only the current lease's correlated result. A legacy
    // host may return locked; never synthesize/replay an unlock in that case.
    _accept(reply);
  }

  @override
  Future<void> unlock(String pin) async {
    final security = _security;
    if (security == null || !security.configured) {
      throw const AgentFailure(
        'Configure the PIN and registered projects on the host.',
      );
    }
    if (!RegExp(r'^\d{6,12}$').hasMatch(pin)) {
      throw const AgentFailure('PIN must be 6–12 digits.');
    }
    if (security.cooldownUntil > DateTime.now().millisecondsSinceEpoch) {
      throw const AgentFailure(
        'PIN cooldown active. Wait before trying again.',
      );
    }
    _revoke();
    final pending = _request(
      'launcher_status_result',
      (id) =>
          LauncherRequest('launcher_unlock', id, status: security, pin: pin),
    );
    pin = '';
    final result = await pending;
    _accept((result as LauncherStatusResult).status);
  }

  @override
  Future<bool> lock({bool shutdown = false}) async {
    final security = _security;
    _revoke();
    if (security == null) {
      throw const AgentFailure(
        'Refresh launcher status before locking. Local control is revoked.',
      );
    }
    final result = await _request(
      shutdown ? 'launcher_shutdown_result' : 'launcher_status_result',
      (id) => LauncherRequest(
        shutdown ? 'launcher_shutdown' : 'launcher_lock',
        id,
        status: security,
      ),
    );
    final reply = result as LauncherStatusResult;
    // Never restore local authority from a lock/shutdown response.
    _accept(
      LauncherStatus(
        launcherId: reply.status.launcherId,
        epoch: reply.status.epoch,
        configured: reply.status.configured,
        pinSetup: reply.status.pinSetup,
        launcherApi: reply.status.launcherApi,
        unlocked: false,
        expiresAt: null,
        cooldownUntil: reply.status.cooldownUntil,
      ),
    );
    return reply.stopped ?? true;
  }

  void _requireUnlocked() {
    if (_security?.permitsControl != true) {
      throw const AgentFailure('Unlock the host launcher first.');
    }
  }

  int? _roomEpoch, _roomStartedAt;
  bool Function()? _bindingCurrent;
  bool _sameRoomIncarnation(String peer, String room, int? startedAt) =>
      _conn
          .roomsFor(peer)
          .where((r) => r.roomId == room)
          .firstOrNull
          ?.startedAt ==
      startedAt;
  bool _disposed = false;
  IChannel? _channel;
  StreamSubscription<ServerMessage>? _messages;
  StreamSubscription<ConnectionStatus>? _status;
  StreamSubscription<Map<String, List<RoomInfo>>>? _rooms;
  final _invalidations = StreamController<void>.broadcast();
  final _changes = StreamController<void>.broadcast();
  @override
  Stream<void> get changes => _changes.stream;
  final _pending =
      <
        String,
        ({
          Completer<ServerMessage> completer,
          Timer timer,
          String type,
          bool securityMutation,
        })
      >{};
  @override
  Stream<void> get invalidations => _invalidations.stream;
  bool get _valid =>
      !_disposed &&
      (_bindingCurrent?.call() ?? true) &&
      _channel != null &&
      identical(_conn.channel, _channel) &&
      _conn.activePeer?.remoteEpk == _peer &&
      _conn.activeRoomId == _room &&
      _conn.roomSelectionEpoch == _roomEpoch &&
      _conn.isRoomLive(_peer!, _room!) &&
      _sameRoomIncarnation(_peer!, _room!, _roomStartedAt);

  @override
  Future<void> bind(
    String peer,
    String room, {
    bool Function()? isCurrent,
  }) async {
    final channel = _conn.channel;
    final epoch = _conn.roomSelectionEpoch;
    final selectedPeer = _conn.activePeer?.remoteEpk;
    final selectedRoom = _conn.activeRoomId;
    final startedAt = _conn
        .roomsFor(peer)
        .where((r) => r.roomId == room)
        .firstOrNull
        ?.startedAt;
    bool current() =>
        !_disposed &&
        (isCurrent?.call() ?? true) &&
        identical(channel, _conn.channel) &&
        epoch == _conn.roomSelectionEpoch &&
        selectedPeer == _conn.activePeer?.remoteEpk &&
        selectedRoom == _conn.activeRoomId &&
        _sameRoomIncarnation(peer, room, startedAt);
    void check() {
      if (!current()) {
        _invalidate();
        throw const AgentFailure('Host changed. Reopen the launcher.');
      }
    }

    check();
    final peers = await _storage.listPeers();
    check(); // Never navigate using an intent parked across changed selection.
    final matches = peers.where((p) => p.remoteEpk == peer);
    if (matches.isEmpty || !_conn.isRoomLive(peer, room)) {
      throw const AgentFailure('Selected paired session is offline.');
    }
    if (isCurrent != null) {
      // selectParent already selected the exact target. Recovery may not create
      // a new navigation intent (and thereby renew an invalidated lease).
      if (selectedPeer != peer ||
          selectedRoom != room ||
          _conn.status is! StatusOnline) {
        _invalidate();
        throw const AgentFailure('Host changed. Reopen the launcher.');
      }
    } else {
      await _conn.switchTo(matches.first.copyWith(roomId: room));
      if (selectedPeer == peer) check();
      if (_disposed ||
          _conn.activePeer?.remoteEpk != peer ||
          _conn.status is! StatusOnline ||
          !_sameRoomIncarnation(peer, room, startedAt) ||
          !_conn.isRoomLive(peer, room)) {
        throw const AgentFailure('Host changed. Reopen the launcher.');
      }
      _conn.switchRoom(room); // Explicit ordinary navigation remains supported.
    }
    _bindingCurrent = isCurrent;
    _roomStartedAt = startedAt;
    _peer = peer;
    _room = room;
    _roomEpoch = _conn.roomSelectionEpoch;
    _channel = _conn.channel;
    _messages = _channel!.serverMessages.listen(
      _onMessage,
      onDone: _invalidate,
    );
    _status = _conn.statusStream.listen((_) {
      if (!_valid) _invalidate();
    });
    _rooms = _conn.roomsStream.listen((_) {
      if (!_valid) _invalidate();
    });
  }

  void _invalidate() {
    _revoke();
    _channel = null;
    for (final p in _pending.values) {
      p.timer.cancel();
      p.completer.completeError(
        AgentFailure(
          'Host disconnected or session changed. Return home and select it again.',
          outcomeUnknown:
              p.type == 'agent_launch_result' ||
              p.type == 'agent_stop_result' ||
              p.securityMutation,
        ),
      );
    }
    _pending.clear();
    if (!_invalidations.isClosed) _invalidations.add(null);
  }

  void _onMessage(ServerMessage message) {
    if (!_valid) {
      _invalidate();
      return;
    }
    // Legacy chat errors may still arrive without a room. They must never
    // complete or settle management work, even after request-cache eviction.
    if (message is ErrorMessage &&
        (message is! ScopedPeerError ||
            toStandardB64(message.peer) != toStandardB64(_peer!) ||
            message.room != _room)) {
      return;
    }
    final id = switch (message) {
      LauncherStatusResult() => message.inReplyTo,
      ProjectListResult() => message.inReplyTo,
      AgentListResult() => message.inReplyTo,
      AgentMutationResult() => message.inReplyTo,
      ErrorMessage() => message.inReplyTo,
      _ => null,
    };
    final key = (_peer!, _room!);
    if (message is AgentMutationResult || message is ErrorMessage) {
      bool settles(_AgentMutation entry) =>
          entry.id == id &&
          (message is ErrorMessage ||
              (message as AgentMutationResult).type == entry.type);
      final entry = _journal._entries[key];
      if (entry != null && settles(entry)) _journal._entries.remove(key);
      _journal._pruneHistory(key, settles);
      if (!_changes.isClosed) _changes.add(null);
    }
    final p = _pending[id];
    if (p == null) return;
    if (message is! ErrorMessage &&
        (message is LauncherStatusResult
                ? message.type
                : message is ProjectListResult
                ? 'project_list_result'
                : message is AgentListResult
                ? 'agent_list_result'
                : (message as AgentMutationResult).type) !=
            p.type) {
      return;
    }
    _pending.remove(id);
    p.timer.cancel();

    if (message is ErrorMessage) {
      _revoke();
      p.completer.completeError(AgentFailure(message.message));
    } else {
      p.completer.complete(message);
    }
  }

  Future<ServerMessage> _request(
    String type,
    ClientMessage Function(String) create, {
    String idPrefix = '',
  }) {
    if (!_valid) {
      _invalidate();
      throw const AgentFailure(
        'Host disconnected or session changed. Return home and select it again.',
      );
    }
    final key = (_peer!, _room!);
    final id = '$idPrefix${uuid7()}';
    final mutation =
        type == 'agent_launch_result' || type == 'agent_stop_result';
    if (mutation && _incarnation == null) {
      throw const AgentFailure(
        'Refresh launcher capabilities before starting an operation.',
      );
    }
    final previous = _journal._entries[key];
    if (type == 'agent_launch_result' &&
        previous != null &&
        previous.id != id) {
      throw const AgentFailure(
        'Refresh to settle the previous operation before starting another.',
        outcomeUnknown: true,
      );
    }
    final pending = _pending[id];
    if (pending != null) return pending.completer.future;
    final request = create(id);
    // Timers retain only operation metadata, never the PIN-bearing message.
    final securityMutation =
        request is LauncherRequest &&
        const [
          'launcher_unlock',
          'launcher_pin_initialize',
          'launcher_lock',
          'launcher_shutdown',
        ].contains(request.type);
    if (type == 'agent_launch_result') {
      if (previous == null &&
          _journal._retainedCount >= AgentMutationJournal._limit) {
        throw const AgentFailure(
          'Resolve pending agent operations before managing more hosts.',
        );
      }
      _journal._entries[key] = (id: id, type: type, incarnation: _incarnation!);
    }
    final completer = Completer<ServerMessage>();
    final deadline = mutation ? mutationTimeout : timeout;
    final timer = Timer(deadline, () {
      final p = _pending.remove(id);
      _revoke();
      p?.completer.completeError(
        AgentFailure(
          mutation
              ? 'Result unknown. Refresh before retrying.'
              : securityMutation
              ? 'Access locked. Result unknown; refresh status.'
              : 'Host update required.',
          outcomeUnknown: mutation || securityMutation,
        ),
      );
    });
    _pending[id] = (
      completer: completer,
      timer: timer,
      type: type,
      securityMutation: securityMutation,
    );
    // Send synchronously against the captured channel, never after an async target lookup.
    unawaited(
      Future<void>.sync(() => _channel!.send(request)).catchError((
        Object error,
        StackTrace stack,
      ) {
        final p = _pending.remove(id);
        if (p != null) {
          _revoke();
          p.timer.cancel();
          p.completer.completeError(
            AgentFailure(
              'Could not send to selected host. Refresh before retrying.',
              outcomeUnknown: mutation || securityMutation,
            ),
          );
        }
      }),
    );
    return completer.future;
  }

  @override
  Future<AgentAvailability> list() async {
    await status();
    _requireUnlocked();
    final projects = await _request(
      'project_list_result',
      (id) => LauncherRequest('project_list', id),
    );
    _requireUnlocked();
    _projects = (projects as ProjectListResult).projects;
    final snapshot = await _fetchList();
    final key = (_peer!, _room!);
    final mutation = _journal._entries[key];
    if (mutation != null && mutation.incarnation != _incarnation) {
      _journal._entries.remove(key);
    }
    _requireUnlocked();
    _journal._pruneHistory(key, (entry) => entry.incarnation != _incarnation);
    _reconciled = true;
    return snapshot;
  }

  Future<AgentAvailability> _fetchList() async {
    final result =
        ((await _request('agent_list_result', AgentList.new))
                as AgentListResult)
            .availability;
    if (result.available &&
        (result.launcherId == null || result.launcherId!.isEmpty)) {
      throw const AgentFailure(
        'Update the host Remote Pi extension: launcher identity is unavailable.',
      );
    }
    if (result.launcherId != _security?.launcherId) {
      _revoke();
      throw const AgentFailure(
        'Launcher incarnation changed. Refresh and unlock again.',
      );
    }
    return result;
  }

  @override
  Future<ManagedAgent> launch(
    String projectId,
    String? name, {
    bool acknowledgeUnknown = false,
  }) async {
    _requireUnlocked();
    // Applies to every new Start, including generic/recovery-derived routes.
    // API 2 grants still authorize list, recovery and existing-child controls.
    if (_security?.supportsNewLaunch != true) {
      throw const AgentFailure(newLaunchCompatibilityMessage);
    }
    if (!_reconciled) {
      throw const AgentFailure(
        'Refresh security, projects and agents before starting.',
        outcomeUnknown: true,
      );
    }
    if (!_projects.any((p) => p.projectId == projectId)) {
      throw const AgentFailure('Select a registered project.');
    }
    final error = validateAgentInput(projectId, name);
    if (error != null) throw AgentFailure(error);
    final key = (_peer!, _room!);
    final previous = _journal._entries[key];
    if (hasUnknownLaunch && (!acknowledgeUnknown || !_reconciled)) {
      throw const AgentFailure(
        'Launch unconfirmed. Refresh before retrying; retry may duplicate.',
        outcomeUnknown: true,
      );
    }
    if (_journal._retainedCount >= AgentMutationJournal._limit) {
      throw const AgentFailure(
        'Resolve pending agent operations before managing more hosts.',
      );
    }
    if (previous != null) {
      final history = _journal._history.putIfAbsent(key, () => []);
      history.add(previous);
      _journal._entries.remove(key);
    }
    _reconciled = false;
    final reply = await _request(
      'agent_launch_result',
      (id) => LauncherRequest(
        'project_launch',
        id,
        status: _security!,
        projectId: projectId,
        name: name,
      ),
    );
    _reconciled = true;
    refreshDiscovery();
    return (reply as AgentMutationResult).agent;
  }

  @override
  Future<ManagedAgent> stop(String agentId) async {
    _requireUnlocked();
    return ((await _request(
              'agent_stop_result',
              (id) => LauncherRequest(
                'launcher_agent_stop',
                id,
                status: _security!,
                agentId: agentId,
              ),
            ))
            as AgentMutationResult)
        .agent;
  }

  @override
  Future<void> openAgent(
    ManagedAgent agent, {
    void Function(String peer, String room)? beforeHandoff,
  }) async {
    if (_disposed || !_valid || _security?.permitsControl != true) {
      throw const AgentFailure('Host changed. Reopen the launcher.');
    }
    if (agent.state != 'running' || agent.roomId.trim().isEmpty) {
      throw const AgentFailure('Agent is not confirmed running. Check status.');
    }
    final deadline = DateTime.now().add(timeout);
    // Discovery can lag launch publication. Never substitute another room and
    // never change the bound peer/channel while waiting.
    refreshDiscovery();
    while (!_conn.isRoomLive(_peer!, agent.roomId)) {
      if (_disposed || !_valid || _security?.permitsControl != true) {
        throw const AgentFailure('Host changed. Reopen the launcher.');
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const AgentFailure(
          'Agent is running, but its room is not visible yet. Check status; do not start another.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_disposed || !_valid || _security?.permitsControl != true) {
      throw const AgentFailure('Host changed. Reopen the launcher.');
    }
    try {
      await _preferences.setSelectedRoom(epk: _peer!, roomId: agent.roomId);
    } on PlatformException {
      throw const AgentFailure(
        'Agent is running, but its chat selection could not be saved. Open it from Home; do not start another.',
      );
    }
    if (_disposed ||
        !_valid ||
        _security?.permitsControl != true ||
        !_conn.isRoomLive(_peer!, agent.roomId)) {
      throw const AgentFailure('Host changed. Reopen the launcher.');
    }
    beforeHandoff?.call(_peer!, agent.roomId);
    _expiry?.cancel();
    // Intentional handoff consumes this management lease. Do not interpret our
    // own room selection as an external target change during navigation.
    unawaited(_messages?.cancel());
    unawaited(_status?.cancel());
    unawaited(_rooms?.cancel());
    _conn.switchRoom(agent.roomId);
  }

  @override
  void refreshDiscovery() {
    if (_valid) _conn.refreshDiscovery();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _expiry?.cancel();
    _messages?.cancel();
    _status?.cancel();
    _rooms?.cancel();
    _invalidate();
    _invalidations.close();
    _changes.close();
  }
}
