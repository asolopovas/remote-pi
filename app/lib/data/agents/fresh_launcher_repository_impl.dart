import 'dart:async';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/domain/contracts/agent_repository.dart';
import 'package:app/domain/contracts/fresh_launcher_repository.dart';
import 'package:app/pairing/storage.dart';

/// A foreground, single-machine scan. No chat-room changes during probing.
class FreshLauncherRepositoryImpl extends FreshLauncherRepository {
  FreshLauncherRepositoryImpl(this._conn, this._storage);
  final ConnectionManager _conn;
  final PairingStorage _storage;
  final _events = StreamController<void>.broadcast(sync: true);
  StreamSubscription<Object?>? _status, _discovery;
  IChannel? _channel;
  void Function()? _cancelConnectionWait;
  String? _peer;
  int? _epoch, _pairingRevision;
  final _rooms = <String, int>{};
  bool _consumed = false;
  bool _invalid = false, _moving = false, _resolved = false, _searching = false;
  @override
  Stream<void> get invalidations => _events.stream;

  bool get _current =>
      !_consumed &&
      !_invalid &&
      _pairingRevision == _storage.peerRevision &&
      identical(_channel, _conn.channel) &&
      _channel != null &&
      toStandardB64(_conn.activePeer?.remoteEpk ?? '') ==
          toStandardB64(_peer ?? '') &&
      (_moving || _epoch == _conn.roomSelectionEpoch) &&
      _rooms.entries.every(
        (e) =>
            _conn.isRoomLive(_peer!, e.key) &&
            _conn
                .roomsFor(_peer!)
                .any((r) => r.roomId == e.key && r.startedAt == e.value),
      );

  @override
  void checkCurrent() {
    if (_consumed) {
      throw const AgentFailure('Launcher handoff already consumed.');
    }
    if (!_current) {
      invalidate();
      throw const AgentFailure(
        'Session changed or offline. Check status from Home.',
      );
    }
  }

  Future<void> _paired() async {
    checkCurrent();
    final peers = await _storage.listPeers();
    checkCurrent();
    if (!peers.any(
      (p) => toStandardB64(p.remoteEpk) == toStandardB64(_peer!),
    )) {
      invalidate();
      throw const AgentFailure('Pairing changed. Reopen from Home.');
    }
  }

  @override
  Future<FreshLauncherEndpoint> resolve(
    String peer, {
    String? preferredRoom,
  }) async {
    if (_peer != null || _invalid) {
      throw const AgentFailure('Reopen Start from Home.');
    }
    final pairingRevision = _storage.peerRevision;
    final channel = _conn.channel;
    final epoch = _conn.roomSelectionEpoch;
    final beforeRoom = _conn.activeRoomId;
    final active = _conn.activePeer?.remoteEpk;
    final snapshot = {
      for (final r in _conn.roomsFor(peer))
        if (_conn.isRoomLive(peer, r.roomId)) r.roomId: r.startedAt,
    };
    final peers = await _storage.listPeers();
    if (_invalid ||
        pairingRevision != _storage.peerRevision ||
        !identical(channel, _conn.channel) ||
        epoch != _conn.roomSelectionEpoch ||
        active != _conn.activePeer?.remoteEpk) {
      throw const AgentFailure('Session changed. Reopen from Home.');
    }
    final record = peers
        .where((p) => toStandardB64(p.remoteEpk) == toStandardB64(peer))
        .firstOrNull;
    if (record == null || snapshot.isEmpty) {
      throw const AgentFailure(
        'No live paired sessions. Check status from Home.',
      );
    }
    // The machine was explicitly chosen before entering this repository. This
    // is the only permitted peer connection; a scan never hops between peers.
    if (toStandardB64(active ?? '') != toStandardB64(peer)) {
      final expectedEpoch =
          epoch + ((record.roomId ?? 'main') == beforeRoom ? 0 : 1);
      await _conn.switchToGuarded(
        record,
        isCurrent: () =>
            !_invalid &&
            pairingRevision == _storage.peerRevision &&
            epoch == _conn.roomSelectionEpoch &&
            active == _conn.activePeer?.remoteEpk,
      );
      if (_invalid ||
          expectedEpoch != _conn.roomSelectionEpoch ||
          toStandardB64(_conn.activePeer?.remoteEpk ?? '') !=
              toStandardB64(peer)) {
        throw const AgentFailure('Connection changed. Reopen from Home.');
      }
      await _waitForRooms(peer, snapshot, pairingRevision, expectedEpoch);
    }
    if (pairingRevision != _storage.peerRevision) {
      throw const AgentFailure('Pairing changed. Reopen from Home.');
    }
    _pairingRevision = pairingRevision;
    _peer = _conn.activePeer?.remoteEpk;
    _channel = _conn.channel;
    _epoch = _conn.roomSelectionEpoch;
    _rooms.addAll(snapshot);
    void changed(Object? _) {
      if (!_current) invalidate();
    }

    _status = _conn.statusStream.listen(changed);
    _discovery = _conn.roomsStream.listen(changed);
    _storage.addListener(_pairingChanged);
    checkCurrent();
    await _paired();
    final rooms = snapshot.keys.toList()..sort();
    if (rooms.remove(preferredRoom)) rooms.insert(0, preferredRoom!);
    return _search(rooms.take(16));
  }

  Future<void> _waitForRooms(
    String peer,
    Map<String, int> rooms,
    int pairingRevision,
    int epoch,
  ) async {
    final channel = _conn.channel;
    if (channel == null) {
      throw const AgentFailure('Machine unavailable. Check status from Home.');
    }
    final completed = Completer<void>();
    bool current() =>
        !_invalid &&
        pairingRevision == _storage.peerRevision &&
        identical(channel, _conn.channel) &&
        epoch == _conn.roomSelectionEpoch &&
        toStandardB64(_conn.activePeer?.remoteEpk ?? '') == toStandardB64(peer);
    void check([Object? _]) {
      if (completed.isCompleted) return;
      if (!current() ||
          rooms.entries.any(
            (e) => _conn
                .roomsFor(peer)
                .any((r) => r.roomId == e.key && r.startedAt != e.value),
          )) {
        completed.completeError(
          const AgentFailure('Machine changed. Reopen from Home.'),
        );
      } else if (rooms.keys.every((room) => _conn.isRoomLive(peer, room))) {
        completed.complete();
      }
    }

    final status = _conn.statusStream.listen(check);
    final discovery = _conn.roomsStream.listen(check);
    void pairing() => check();
    _storage.addListener(pairing);
    _cancelConnectionWait = () {
      if (!completed.isCompleted) {
        completed.completeError(
          const AgentFailure('Start closed. Reopen from Home.'),
        );
      }
    };
    final timer = Timer(const Duration(seconds: 5), () {
      if (!completed.isCompleted) {
        completed.completeError(
          const AgentFailure('Sessions unavailable. Check status from Home.'),
        );
      }
    });
    try {
      _conn.refreshDiscovery();
      check();
      await completed.future;
      if (!current()) {
        throw const AgentFailure('Machine changed. Reopen from Home.');
      }
    } finally {
      timer.cancel();
      _cancelConnectionWait = null;
      _storage.removeListener(pairing);
      await status.cancel();
      await discovery.cancel();
    }
  }

  @override
  List<FreshLauncherSession> get sessions {
    checkCurrent();
    return _conn
        .roomsFor(_peer!)
        .where((r) => _rooms.containsKey(r.roomId))
        .map(
          (r) =>
              FreshLauncherSession(r.roomId, r.localName ?? r.name ?? r.roomId),
        )
        .toList()
      ..sort((a, b) => a.room.compareTo(b.room));
  }

  @override
  Future<FreshLauncherEndpoint> selectSession(String room) {
    checkCurrent();
    if (!_rooms.containsKey(room)) {
      throw const AgentFailure('Session changed. Reopen from Home.');
    }
    return _search([room]);
  }

  Future<FreshLauncherEndpoint> _search(Iterable<String> rooms) async {
    checkCurrent();
    if (_resolved || _searching) {
      throw const AgentFailure('Reopen Start from Home.');
    }
    final probe = _channel;
    if (probe is! IRoomLauncherProbe) {
      throw const AgentFailure(
        'Status inspection unavailable. Update the app connection and check status.',
      );
    }
    _searching = true;
    try {
      // Sequential and capped: deterministic selection, at most one request in
      // flight, at most 16 two-second requests. No unlock or mutation is sent.
      for (final room in rooms) {
        final result = await (probe as IRoomLauncherProbe).probeLauncher(room);
        checkCurrent();
        if (result == null ||
            result.room != room ||
            toStandardB64(result.peer) != toStandardB64(_peer!)) {
          continue;
        }
        final status = result.status;
        if (!launcherEligible(status)) continue;
        await _paired();
        _resolved = true;
        _moving = true;
        try {
          _conn.switchRoom(room);
          _epoch = _conn.roomSelectionEpoch;
        } finally {
          _moving = false;
        }
        checkCurrent();
        // Recheck the very same socket and room incarnation before exposing PIN.
        final recheck = await (probe as IRoomLauncherProbe).probeLauncher(room);
        await _paired();
        if (recheck == null ||
            recheck.room != room ||
            toStandardB64(recheck.peer) != toStandardB64(_peer!) ||
            !launcherEligible(recheck.status) ||
            recheck.status.launcherId != status.launcherId) {
          invalidate();
          throw const AgentFailure('Launcher changed. Reopen Start from Home.');
        }
        final info = _conn.roomsFor(_peer!).firstWhere((r) => r.roomId == room);
        _rooms.removeWhere((key, _) => key != room);
        return FreshLauncherEndpoint(
          _peer!,
          room,
          info.localName ?? info.name ?? room,
          status.launcherId,
        );
      }
      throw const FreshLauncherUnavailable();
    } finally {
      _searching = false;
    }
  }

  @override
  void consumeHandoff(String peer, ManagedAgent agent) {
    checkCurrent();
    if (!_resolved ||
        toStandardB64(peer) != toStandardB64(_peer!) ||
        agent.state != 'running' ||
        agent.roomId.trim().isEmpty ||
        !_conn.isRoomLive(_peer!, agent.roomId)) {
      throw const AgentFailure('Agent changed. Reopen from Home.');
    }
    // No await between this final fence and the repository's switchRoom.
    // Detach the resolution listeners, not the external-selection fences:
    // this lease is terminal and checkCurrent can never authorize again.
    _consumed = true;
    _storage.removeListener(_pairingChanged);
    unawaited(_status?.cancel());
    unawaited(_discovery?.cancel());
  }

  void _pairingChanged() {
    if (_pairingRevision != _storage.peerRevision) invalidate();
  }

  @override
  void invalidate() {
    if (_invalid || _consumed) return;
    _invalid = true;
    _cancelConnectionWait?.call();
    final channel = _channel;
    if (channel is IRoomLauncherProbe) {
      (channel as IRoomLauncherProbe).cancelLauncherProbes();
    }
    _events.add(null);
  }

  @override
  void dispose() {
    invalidate();
    _storage.removeListener(_pairingChanged);
    unawaited(_status?.cancel());
    unawaited(_discovery?.cancel());
    unawaited(_events.close());
  }
}

bool launcherEligible(LauncherStatus status) =>
    status.launcherId.isNotEmpty &&
    status.supportsNewLaunch &&
    (status.configured || status.pinSetup == PinSetup.available);
